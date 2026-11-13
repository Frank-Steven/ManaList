import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_client.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_service.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables;

/// 消息操作回归（2026-11-01 多 Agent 批次）：assistant 消息重试、用户消息
/// 编辑/撤回——三种操作都自目标消息（重试时为触发它的用户消息）起截断
/// 后续消息， doomed 批次产出的 pending 提案一并置 rejected；重试/编辑用
/// 原文（或新文本）+ 原附件重跑回合，撤回不重跑。
/// 用 sqflite_common_ffi 内存库 + mock 通道，不依赖网络与手机。
class _MockAssistantClient extends AssistantClient {
  _MockAssistantClient() : super.independent();

  /// 每次请求收到的最后一条消息文本（即本轮用户输入）。
  final List<String> capturedInputs = [];

  @override
  Stream<ChatEvent> chat({
    required String conversationId,
    required List<ChatMessageModel> messages,
    List<ChatAttachment> attachments = const [],
    String? modelConfigId,
    String? reasoning,
  }) async* {
    capturedInputs.add(messages.isEmpty ? '' : messages.last.content);
    yield ChatTokenDelta('回复${capturedInputs.length}');
    yield const ChatDone();
  }

  @override
  void cancelActive() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  final appDb = AppDatabase.instance;
  final service = AssistantService.instance;
  final mock = _MockAssistantClient();
  late AssistantClient realClient;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createBaseTables(db);
    appDb.debugAttachDatabase(db);
    realClient = service.client;
    service.client = mock;
    service.debugReset();
    mock.capturedInputs.clear();
  });

  tearDown(() async {
    service.client = realClient;
    service.debugReset();
    appDb.debugDetachDatabase();
    await db.close();
  });

  Future<Conversation> newConversation() => service.createConversation();

  Future<List<ChatMessage>> messagesOf(String conversationId) =>
      appDb.getChatMessages(conversationId);

  /// 落一条 pending 提案，批次 = assistant 消息 id（与提案落库约定一致）。
  Future<void> insertPendingProposal(String conversationId, String batchId,
          {String idSuffix = '1'}) =>
      appDb.insertProposal(ChangeProposal(
        id: '${batchId}_b$idSuffix',
        conversationId: conversationId,
        batchId: batchId,
        tool: 'task.create',
        summary: '创建任务',
        payload: const {'title': '买菜'},
        createdAt: 1000,
      ));

  test('重试：自用户消息起截断，pending 提案置 rejected，原文重跑', () async {
    final conv = await newConversation();
    await service.sendTurn(conversation: conv, text: '提醒我买菜').toList();
    await service.sendTurn(conversation: conv, text: '改到明天').toList();

    final before = await messagesOf(conv.id);
    expect(before.map((m) => m.role),
        [ChatRole.user, ChatRole.assistant, ChatRole.user, ChatRole.assistant]);
    final doomedAssistant = before.last;
    await insertPendingProposal(conv.id, doomedAssistant.id);

    final handle = await service.retryAssistantMessage(conv, before.last.id);
    expect(handle, isNotNull);
    await handle!.events.toList();

    final after = await messagesOf(conv.id);
    expect(after.map((m) => m.role),
        [ChatRole.user, ChatRole.assistant, ChatRole.user, ChatRole.assistant],
        reason: '第二轮整轮被截断后用原文重跑一轮');
    expect(after[2].content, '改到明天', reason: '重试复用触发它的用户消息原文');
    expect(after.map((m) => m.id), isNot(contains(before[2].id)),
        reason: '旧消息已删除，重跑是新消息 id');
    expect(mock.capturedInputs.last, '改到明天');

    final proposals = await appDb.getProposals();
    expect(proposals.single.status, ProposalStatus.rejected,
        reason: '被截断批次的 pending 提案撤销');
    expect(proposals.single.resolvedAt, isNotNull);
  });

  test('编辑用户消息：截断后用新文本重跑（附件沿用原消息）', () async {
    final conv = await newConversation();
    const attachment = ChatAttachment(type: ChatAttachmentType.note, id: 'n1');
    await service
        .sendTurn(conversation: conv, text: '原始问题', attachments: const [attachment])
        .toList();
    final before = await messagesOf(conv.id);
    final userMsg = before.first;

    final handle =
        await service.editUserMessage(conv, userMsg.id, '改后的问题');
    expect(handle, isNotNull);
    await handle!.events.toList();

    final after = await messagesOf(conv.id);
    expect(after.map((m) => m.role), [ChatRole.user, ChatRole.assistant]);
    expect(after.first.content, '改后的问题');
    expect(after.first.attachments.single.id, 'n1', reason: '附件沿用原消息');
    expect(mock.capturedInputs.last, '改后的问题');
  });

  test('撤回用户消息：截断且不重跑，后续轮次一并删除', () async {
    final conv = await newConversation();
    await service.sendTurn(conversation: conv, text: '第一条').toList();
    await service.sendTurn(conversation: conv, text: '第二条').toList();
    final before = await messagesOf(conv.id);
    final secondAssistant = before.last;
    await insertPendingProposal(conv.id, secondAssistant.id);

    final requestCount = mock.capturedInputs.length;
    await service.recallUserMessage(conv, before[2].id);

    final after = await messagesOf(conv.id);
    expect(after.map((m) => m.role), [ChatRole.user, ChatRole.assistant]);
    expect(mock.capturedInputs, hasLength(requestCount),
        reason: '撤回不发起新回合');
    expect((await appDb.getProposals()).single.status,
        ProposalStatus.rejected);
  });

  test('applied 提案不受截断影响（走撤销队列，不在此回滚）', () async {
    final conv = await newConversation();
    await service.sendTurn(conversation: conv, text: '建个任务').toList();
    final assistant = (await messagesOf(conv.id)).last;
    await appDb.insertProposal(ChangeProposal(
      id: '${assistant.id}_b1',
      conversationId: conv.id,
      batchId: assistant.id,
      tool: 'task.create',
      summary: '创建任务',
      payload: const {'title': '买菜'},
      status: ProposalStatus.applied,
      createdAt: 1000,
    ));

    final handle = await service.retryAssistantMessage(conv, assistant.id);
    await handle!.events.toList();

    expect((await appDb.getProposals()).single.status, ProposalStatus.applied,
        reason: '只撤销 pending，已应用的不动');
  });
}
