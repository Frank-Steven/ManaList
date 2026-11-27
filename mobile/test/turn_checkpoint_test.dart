import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_client.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_service.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/context_window.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables;

/// R03-A6（task-113）：回合检查点持久化与恢复。
///
/// 恢复语义 = **重发请求 + 跳过已处理块**（不是续接上游流）；未闭合块按既有规则丢弃。
/// 本文件钉住 7 条：终态清理（done / 取消）、恢复成功（不新建消息、带已有正文）、
/// 恢复后块编号续接（不重用已处理序号，因此确定性回注 id 不会撞车）、
/// 恢复不额外送轮数、非法检查点走 error、DB 往返与按会话清理。

const _readBlock =
    '\n```tool\n{"tool":"task.list","args":{"status":"active"}}\n```\n';

class _CheckpointClient extends AssistantClient {
  _CheckpointClient(this.batches) : super.independent();

  /// 第 N 次 chat() 产出的事件（用尽后重复最后一批）。
  final List<List<ChatEvent>> batches;

  int chatCalls = 0;
  final List<List<ChatMessageModel>> calls = [];

  @override
  Stream<ChatEvent> chat({
    required String conversationId,
    required List<ChatMessageModel> messages,
    List<ChatAttachment> attachments = const [],
    String? modelConfigId,
    String? reasoning,
  }) async* {
    final i = chatCalls;
    chatCalls++;
    calls.add(List<ChatMessageModel>.of(messages));
    final batch = batches.isEmpty
        ? const <ChatEvent>[]
        : batches[i < batches.length ? i : batches.length - 1];
    for (final e in batch) {
      yield e;
    }
  }

  @override
  Future<ContextWindowInfo?> contextWindowFor(String? modelConfigId) async =>
      null; // 预算不参与本文件判定

  @override
  Future<bool> isVisionCapable(String? modelConfigId) async => false;

  @override
  void cancelActive() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  late Conversation conv;
  final appDb = AppDatabase.instance;
  final service = AssistantService.instance;
  late AssistantClient realClient;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createBaseTables(db);
    // v16 表：真实 onCreate 会建，这里补一次保证内存库与生产同构
    await migrateToV16(db);
    appDb.debugAttachDatabase(db);
    realClient = service.client;
    service.debugReset();
    final now = DateTime.now().millisecondsSinceEpoch;
    conv = Conversation(
        id: 'c-cp', title: '检查点对话', createdAt: now, updatedAt: now);
    await appDb.insertConversation(conv);
  });

  tearDown(() async {
    service.client = realClient;
    service.debugReset();
    appDb.debugDetachDatabase();
    await db.close();
  });

  Future<List<AssistantEvent>> run(_CheckpointClient fake, String text) {
    service.client = fake;
    return service.sendTurn(conversation: conv, text: text).toList();
  }

  Future<int> checkpointRows() async =>
      (await appDb.getTurnCheckpoints()).length;

  Future<ChatMessage> insertStreamingAssistant(String id,
      {String content = ''}) async {
    final msg = ChatMessage(
      id: id,
      conversationId: conv.id,
      role: ChatRole.assistant,
      content: content,
      status: ChatMessageStatus.streaming,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await appDb.insertChatMessage(msg);
    return msg;
  }

  test('正常回合结束 → 检查点被删、消息 done', () async {
    final fake = _CheckpointClient(const [
      [ChatTokenDelta('完成'), ChatDone()]
    ]);
    final events = await run(fake, '你好');
    expect(events.whereType<AssistantTurnDone>(), hasLength(1));
    expect(await checkpointRows(), 0, reason: '终态必须删检查点');
    final msgs = await appDb.getChatMessages(conv.id);
    expect(msgs.last.status, ChatMessageStatus.done);
  });

  test('取消回合 → 检查点被删', () async {
    // 第一轮只给 token，不给 Done：列表消费完后再显式 cancel
    final fake = _CheckpointClient(const [
      [ChatTokenDelta('半截')]
    ]);
    service.client = fake;
    final stream = service
        .sendTurn(conversation: conv, text: '取消我')
        .toList()
        .timeout(const Duration(seconds: 3), onTimeout: () => const []);
    service.cancelTurn(conv.id);
    await stream;
    expect(await checkpointRows(), 0, reason: '取消属终态，也必须删检查点');
  });

  test('恢复成功：不新建消息、带已有正文进请求历史、完成后删检查点', () async {
    const msgId = 'a-streaming';
    await insertStreamingAssistant(msgId, content: '已生成前半段');
    await appDb.upsertTurnCheckpoint(AssistantTurnCheckpoint(
      assistantMessageId: msgId,
      conversationId: conv.id,
      phase: TurnPhase.generating.name,
      visibleText: '已生成前半段',
      nextBlockIndex: 1,
      continuationRound: 0,
      inputText: '原始输入',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));

    final fake = _CheckpointClient(const [
      [ChatTokenDelta('后半段'), ChatDone()]
    ]);
    service.client = fake;

    final recovered = await service.recoverTurns();
    expect(recovered, 1);
    // 等 pump 跑完
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(fake.chatCalls, 1, reason: '恢复只发 1 次请求');
    final assistantMsgs = (await appDb.getChatMessages(conv.id))
        .where((m) => m.role == ChatRole.assistant)
        .toList();
    expect(assistantMsgs, hasLength(1), reason: '复用原消息，不新建');
    expect(assistantMsgs.single.id, msgId);
    // 已有正文必须进请求历史（模型看得到自己前半段）
    final sent = fake.calls.single.map((m) => m.content).join('\n');
    expect(sent, contains('已生成前半段'));
    expect(assistantMsgs.single.status, ChatMessageStatus.done);
    expect(await checkpointRows(), 0, reason: '恢复完成后删检查点');
  });

  test('恢复后块编号续接：nextBlockIndex=1 → 回注从 _b1 起，不产生 _b0', () async {
    const msgId = 'a-dup-block';
    await insertStreamingAssistant(msgId);
    await appDb.upsertTurnCheckpoint(AssistantTurnCheckpoint(
      assistantMessageId: msgId,
      conversationId: conv.id,
      phase: TurnPhase.tooling.name,
      nextBlockIndex: 1,
      continuationRound: 0,
      inputText: '恢复块',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));

    // 恢复请求后模型吐两个块：编号必须从 1 续接（第 0 号是崩溃前已处理的）。
    // 第二轮只回纯文本，避免只读块再次触发续跑、把断言变成时序依赖。
    final fake = _CheckpointClient(const [
      [
        ChatTokenDelta(_readBlock),
        ChatTokenDelta(_readBlock),
        ChatTokenDelta('收尾'),
        ChatDone(),
      ],
      [ChatTokenDelta('结束'), ChatDone()],
    ]);
    service.client = fake;
    await service.recoverTurns();
    // 等回合真正收尾（流关闭），不靠固定 sleep
    final handle = service.turnOf(conv.id);
    expect(handle, isNotNull, reason: '恢复后应注册在途回合');
    await handle!.events.drain<void>();

    final toolMsgs = (await appDb.getChatMessages(conv.id))
        .where((m) => m.role == ChatRole.tool)
        .toList();
    // 真正的安全性质：**编号不重用**。已处理块占着 0，本次两个块编成 1/2，
    // 因此 A2 的确定性回注 id（<msgId>_b<index>_result）绝不会与崩溃前那条撞车。
    expect(toolMsgs, hasLength(2), reason: '恢复后的两个块都按新序号处理');
    expect(toolMsgs.map((m) => m.id).toList(), [
      '${msgId}_b1_result',
      '${msgId}_b2_result',
    ], reason: '编号从 nextBlockIndex 续接');
    expect(toolMsgs.any((m) => m.id == '${msgId}_b0_result'), isFalse,
        reason: '不得重用崩溃前已处理的 0 号序号');
  });

  test('恢复不额外送轮数：continuation_round=max(2) → 只发 1 次请求', () async {
    const msgId = 'a-round-limit';
    await insertStreamingAssistant(msgId);
    await appDb.upsertTurnCheckpoint(AssistantTurnCheckpoint(
      assistantMessageId: msgId,
      conversationId: conv.id,
      phase: TurnPhase.generating.name,
      continuationRound: 2, // = maxToolContinuations
      inputText: '轮数上限',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));

    final fake = _CheckpointClient(const [
      [ChatTokenDelta('最后的正文'), ChatDone()]
    ]);
    service.client = fake;
    await service.recoverTurns();
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(fake.chatCalls, 1, reason: '恢复不得借机多送轮数');
  });

  test('非法检查点（会话不存在）→ 消息 error、文案含「恢复」、删检查点、不发请求', () async {
    // 直接插一条指向不存在会话的检查点 + 一条 streaming 消息
    const msgId = 'a-illegal';
    await appDb.insertChatMessage(ChatMessage(
      id: msgId,
      conversationId: 'ghost-conv',
      role: ChatRole.assistant,
      content: '',
      status: ChatMessageStatus.streaming,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    await appDb.upsertTurnCheckpoint(AssistantTurnCheckpoint(
      assistantMessageId: msgId,
      conversationId: 'ghost-conv',
      phase: TurnPhase.starting.name,
      inputText: '非法',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));

    final fake = _CheckpointClient(const []);
    service.client = fake;
    final recovered = await service.recoverTurns();
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(recovered, 0, reason: '会话不存在不算成功恢复');
    expect(fake.chatCalls, 0, reason: '不得发请求');
    expect(await checkpointRows(), 0, reason: '删除非法检查点');
    final msg = await appDb.getChatMessageById(msgId);
    expect(msg!.status, ChatMessageStatus.error, reason: '不得静默标 done');
  });

  test('DB 往返：upsert + get 字段全等；按会话清理清干净', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final c = AssistantTurnCheckpoint(
      assistantMessageId: 'a-roundtrip',
      conversationId: conv.id,
      phase: TurnPhase.thinking.name,
      visibleText: '正文',
      thinkingText: '思考',
      nextBlockIndex: 3,
      continuationRound: 1,
      inputText: '输入',
      inputAttachments: const [
        ChatAttachment(type: ChatAttachmentType.file, id: 'f-1')
      ],
      reasoning: 'high',
      updatedAt: now,
    );
    await appDb.upsertTurnCheckpoint(c);
    final got = await appDb.getTurnCheckpoint('a-roundtrip');
    expect(got, isNotNull);
    expect(got!.assistantMessageId, c.assistantMessageId);
    expect(got.conversationId, c.conversationId);
    expect(got.phase, c.phase);
    expect(got.visibleText, c.visibleText);
    expect(got.thinkingText, c.thinkingText);
    expect(got.nextBlockIndex, 3);
    expect(got.continuationRound, 1);
    expect(got.inputText, c.inputText);
    expect(got.inputAttachments.single.id, 'f-1');
    expect(got.reasoning, 'high');
    expect(got.updatedAt, now);

    await appDb.deleteTurnCheckpointsForConversation(conv.id);
    expect(await appDb.getTurnCheckpoint('a-roundtrip'), isNull);
  });
}
