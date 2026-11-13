import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_client.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_service.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables;

/// B19 回归（2026-11-10）：**只读工具回注后的有界续跑**。
///
/// 背景：一个回合原本只发一次请求，工具结果以 role=tool 消息落库；不续跑
/// 的话模型要等用户下一句才看得到结果 —— 表现就是「工具回注后 Agent 停住」。
///
/// 本文件钉住 6 条行为：
/// 1. 只读回注 → chat() 两次，第二轮历史里能看到回注的工具消息；
/// 2. 第二轮**看得到本轮自己上一段正文**（assistant streaming 消息纳入历史），
///    最终 assistant 正文完整、每段只出现一次、done 只 1 次；
/// 3. 写工具（task.create）→ 只请求 1 次，提案落 pending，等审批；
/// 4. 持续只读 → 续跑受 [maxToolContinuations]=2 限制（总请求数 = 1 + 2）；
/// 5. 出错 → 不续跑，消息置 error；
/// 6. 混合（同一轮里既有只读又有写提案）→ 不续跑。

const _readBlock =
    '\n\x60\x60\x60tool\n{"tool":"task.list","args":{"status":"active"}}\n\x60\x60\x60\n';
const _writeBlock =
    '\n\x60\x60\x60tool\n{"tool":"task.create","args":{"title":"A"}}\n\x60\x60\x60\n';

class _ScriptedClient extends AssistantClient {
  _ScriptedClient(this.rounds) : super.independent();

  /// 第 N 次 chat() 产出的事件；用尽后用最后一个。
  final List<List<ChatEvent>> rounds;

  /// 每次 chat() 收到的完整消息序列（用于断言历史/正文是否带上）。
  final List<List<ChatMessageModel>> calls = [];

  /// 每次 chat() 调用后的钩子（用于「取消」这类跨回调操作）。
  void Function(int callIndex)? onCall;

  @override
  Stream<ChatEvent> chat({
    required String conversationId,
    required List<ChatMessageModel> messages,
    List<ChatAttachment> attachments = const [],
    String? modelConfigId,
    String? reasoning,
  }) async* {
    final i = calls.length;
    calls.add(List<ChatMessageModel>.of(messages));
    onCall?.call(i);
    final events = rounds[i < rounds.length ? i : rounds.length - 1];
    for (final e in events) {
      yield e;
    }
  }

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
    appDb.debugAttachDatabase(db);
    realClient = service.client;
    service.debugReset();
    final now = DateTime.now().millisecondsSinceEpoch;
    conv = Conversation(
        id: 'c-b19', title: '新对话', createdAt: now, updatedAt: now);
    await appDb.insertConversation(conv);
  });

  tearDown(() async {
    service.client = realClient;
    service.debugReset();
    appDb.debugDetachDatabase();
    await db.close();
  });

  Future<List<AssistantEvent>> run(_ScriptedClient fake) {
    service.client = fake;
    return service.sendTurn(conversation: conv, text: '帮我整理一下').toList();
  }

  Future<ChatMessage?> currentAssistant() async {
    final msgs = await appDb.getChatMessages(conv.id);
    for (final m in msgs) {
      if (m.role == ChatRole.assistant) return m;
    }
    return null;
  }

  int occurrences(String haystack, String needle) =>
      needle.isEmpty ? 0 : haystack.split(needle).length - 1;

  test('① 只读回注后续跑一次，第二轮历史含回注的工具消息', () async {
    final fake = _ScriptedClient([
      [const ChatTokenDelta('我先查一下任务。$_readBlock')],
      [const ChatTokenDelta('查完了：今天没有待办。')],
    ]);
    final events = await run(fake);

    expect(fake.calls.length, 2, reason: '只读回注后应自动再请求一次');
    final second = fake.calls[1];
    expect(
        second.any((m) => m.role == ChatRole.tool && m.content.isNotEmpty),
        isTrue,
        reason: '第二轮请求必须带上一轮回注的 [工具执行结果]（role=tool）');
    // 客户端把 tool 折叠成 [工具执行结果] 文本（assistant_client.dart）
    final folded = buildRemoteMessages(second);
    expect(folded.any((m) => (m['content'] as String).contains('[工具执行结果]')),
        isTrue,
        reason: '折叠后模型实际看到的是 [工具执行结果] 前缀');
    expect(events.whereType<AssistantTurnDone>().length, 1);
  });

  test('② 续跑轮带上本轮正文，最终内容完整不重复、done 只 1 次', () async {
    final fake = _ScriptedClient([
      [const ChatTokenDelta('第一段：我先查一下。$_readBlock')],
      [const ChatTokenDelta('第二段：查完了，共 0 条。')],
    ]);
    final events = await run(fake);

    expect(fake.calls.length, 2);
    final second = fake.calls[1];
    final ownNarration = second.where(
        (m) => m.role == ChatRole.assistant && m.content.contains('第一段'));
    expect(ownNarration, hasLength(1),
        reason: '续跑轮必须把本回合已生成的 assistant 正文带进上下文，否则会丢上下文/重复生成');
    // 顺序：assistant 正文要在 tool 结果之前
    final idxAssistant = second.indexWhere((m) => m.role == ChatRole.assistant);
    final idxTool = second.indexWhere((m) => m.role == ChatRole.tool);
    expect(idxAssistant, lessThan(idxTool), reason: '时间顺序应为 正文 → 工具结果');

    final assistant = await currentAssistant();
    expect(assistant, isNotNull);
    expect(assistant!.content, contains('第一段'));
    expect(assistant.content, contains('第二段'));
    expect(occurrences(assistant.content, '第一段'), 1, reason: '同一段落不得重复落库');
    expect(assistant.status, ChatMessageStatus.done);
    expect(events.whereType<AssistantTurnDone>().length, 1,
        reason: '续跑共用同一 assistant 消息，done 只发一次');
  });

  test('③ 写工具（提案）→ 只请求一次并落 pending，等审批', () async {
    final fake = _ScriptedClient([
      [const ChatTokenDelta('建个任务。$_writeBlock')],
      [const ChatTokenDelta('不该走到这一轮')],
    ]);
    final events = await run(fake);

    expect(fake.calls.length, 1, reason: '有待审批提案时不得自动续跑');
    final pending = await appDb.getProposals(status: ProposalStatus.pending);
    expect(pending, hasLength(1));
    expect(pending.single.tool, 'task.create');

    final assistant = await currentAssistant();
    expect(assistant!.content, contains('建个任务'));
    expect(assistant.content, isNot(contains('不该走到这一轮')));
    expect(events.whereType<AssistantTurnDone>().length, 1);
  });

  test('④ 持续只读 → 首轮 + 最多 2 轮续跑（共 3 次请求）', () async {
    final fake = _ScriptedClient([
      [const ChatTokenDelta('第1轮$_readBlock')],
      [const ChatTokenDelta('第2轮$_readBlock')],
      [const ChatTokenDelta('第3轮$_readBlock')],
      [const ChatTokenDelta('第4轮$_readBlock')],
      [const ChatTokenDelta('第5轮$_readBlock')],
    ]);
    await run(fake);

    expect(fake.calls.length, 3,
        reason: 'maxToolContinuations = 2：首轮之外最多再请求 2 次');
  });

  test('⑤ 出错 → 不续跑，消息置 error', () async {
    final fake = _ScriptedClient([
      [
        const ChatTokenDelta('查一下。$_readBlock'),
        const ChatError('连接中断，未收到完成事件'),
      ],
      [const ChatTokenDelta('不该走到这一轮')],
    ]);
    final events = await run(fake);

    expect(fake.calls.length, 1);
    final assistant = await currentAssistant();
    expect(assistant!.status, ChatMessageStatus.error);
    expect(events.whereType<AssistantTurnError>().length, 1);
    expect(events.whereType<AssistantTurnDone>(), isEmpty);
  });

  test('⑥ 同一轮里既有只读又有写提案 → 不续跑', () async {
    final fake = _ScriptedClient([
      [const ChatTokenDelta('先查再建。$_readBlock$_writeBlock')],
      [const ChatTokenDelta('不该走到这一轮')],
    ]);
    await run(fake);

    expect(fake.calls.length, 1, reason: '本轮已产出提案 → 停，等审批');
    final pending = await appDb.getProposals(status: ProposalStatus.pending);
    expect(pending, hasLength(1));
  });

  test('⑦ 用户中途「停止」→ 不再续跑', () async {
    final fake = _ScriptedClient([
      [const ChatTokenDelta('查一下。$_readBlock')],
      [const ChatTokenDelta('不该走到这一轮')],
    ]);
    fake.onCall = (i) {
      if (i == 0) service.cancelTurn(conv.id);
    };
    await run(fake);

    expect(fake.calls.length, 1, reason: '取消后不得再发请求');
  });
}
