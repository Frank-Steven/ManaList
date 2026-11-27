import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_client.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_service.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/assistant/screenshot_convention.dart';
import 'package:msgrepo_mobile/services/assistant/tool_spec.dart';
import 'package:msgrepo_mobile/services/context_window.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/services/token_estimate.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables;

/// R03-A5（task-112）：请求级上下文预算 + 续跑上限。
///
/// 钉住 5 条行为：
/// 1. 估算 > 100% → **不发请求**（chatCalls == 0），assistant 消息置 error；
/// 2. 恰好 100% → 仍然发送（严格 >，不误杀）；
/// 3. 90%（over80 但未超）→ 正常发送 1 次（预算 ≠ 拦截）；
/// 4. 预算内正常完成 → done；
/// 5. 续跑上限：1 + maxToolContinuations(2) = 3 次请求封顶，且没有第 4 次。
///
/// 另含纯函数直测（不起服务）。

const _readBlock =
    '\n```tool\n{"tool":"task.list","args":{"status":"active"}}\n```\n';

/// 本轮请求里「说明书前言」的真实字符数。
///
/// 闸门统计的是**整条请求**（前言 + 历史正文），不是只有用户那句话；
/// 夹具若不把它算进去，就会写出"200 字符 = 100 tokens"这种错预期。
int _preambleChars() => systemPreambleWithConvention(
      buildToolSpecPrompt(DateTime.now()),
      hasScreenshots: false,
    ).length;

class _BudgetClient extends AssistantClient {
  _BudgetClient({this.window, this.events = const []}) : super.independent();

  /// contextWindowFor 的返回值：null = 无法判定（不拦截）。
  final ContextWindowInfo? window;

  /// 每次 chat() 产出的事件（用尽后重复最后一批）。
  final List<List<ChatEvent>> events;

  /// chat() 实际被调用的次数 —— 预算拦截的核心判据。
  int chatCalls = 0;

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
    final batch = events.isEmpty
        ? const <ChatEvent>[]
        : events[i < events.length ? i : events.length - 1];
    for (final e in batch) {
      yield e;
    }
  }

  @override
  Future<ContextWindowInfo?> contextWindowFor(String? modelConfigId) async =>
      window;

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
        id: 'c-budget', title: '预算对话', createdAt: now, updatedAt: now);
    await appDb.insertConversation(conv);
  });

  tearDown(() async {
    service.client = realClient;
    service.debugReset();
    appDb.debugDetachDatabase();
    await db.close();
  });

  Future<List<AssistantEvent>> run(_BudgetClient fake, String text) {
    service.client = fake;
    return service.sendTurn(conversation: conv, text: text).toList();
  }

  Future<ChatMessage?> latestAssistant() async {
    final msgs = await appDb.getChatMessages(conv.id);
    final assistants = msgs.where((m) => m.role == ChatRole.assistant);
    return assistants.isEmpty ? null : assistants.last;
  }

  // ---------- 纯函数直测 ----------
  group('estimateRequestBudget / RequestBudget 边界', () {
    ChatMessageModel msg(String content) =>
        ChatMessageModel(role: ChatRole.user, content: content);

    test('400 字符 → 200 tokens（字符/2）', () {
      final b =
          estimateRequestBudget(messages: [msg('x' * 400)], limitTokens: 1000);
      expect(b.usedTokens, 200);
      expect(b.over100, isFalse);
    });

    test('一张 dataBase64 非空附件 +1400；空串不计', () {
      final withData = estimateRequestBudget(messages: [
        msg('x' * 20)
      ], attachments: [
        const ChatAttachment(
            type: ChatAttachmentType.file, id: 'f1', dataBase64: 'AAAA')
      ], limitTokens: 100000);
      expect(withData.usedTokens, 10 + kConservativeImageTokens);

      final emptyData = estimateRequestBudget(messages: [
        msg('x' * 20)
      ], attachments: [
        const ChatAttachment(type: ChatAttachmentType.file, id: 'f2')
      ], limitTokens: 100000);
      expect(emptyData.usedTokens, 10, reason: 'dataBase64 为空串不得按图片计');
    });

    test('over100 严格大于：100/100 false、101/100 true；上限 <=0 不判定', () {
      expect(const RequestBudget(100, 100).over100, isFalse);
      expect(const RequestBudget(101, 100).over100, isTrue);
      expect(const RequestBudget(999999, 0).over100, isFalse);
      expect(const RequestBudget(999999, -1).over100, isFalse);
      expect(const RequestBudget(90, 100).over80, isTrue);
      expect(const RequestBudget(80, 100).over80, isFalse);
    });

    test('label 含估算值与上限', () {
      expect(const RequestBudget(1234, 32000).label, contains('1234'));
      expect(const RequestBudget(1234, 32000).label, contains('32k'));
    });
  });

  // ---------- 服务层：预算闸门 ----------
  group('请求级预算闸门', () {
    test('估算超 100%：不发请求、消息置 error、文案含估算/上限/未发送请求', () async {
      // 用真实用量反推：窗口比估算**少 1 token** → 必然超限
      final text = 'x' * 400;
      final used = estimateTokensFromChars(_preambleChars() + text.length);
      final fake = _BudgetClient(
        window: ContextWindowInfo(used - 1, ContextWindowSource.configured),
        events: const [
          [ChatTokenDelta('不该出现')]
        ],
      );
      final events = await run(fake, text);

      expect(fake.chatCalls, 0, reason: '超限必须不发起网络请求');
      final msg = await latestAssistant();
      expect(msg, isNotNull);
      expect(msg!.status, ChatMessageStatus.error);
      expect(events.whereType<AssistantTurnError>(), hasLength(1));
      final err = events.whereType<AssistantTurnError>().single;
      expect(err.message, contains('估算'));
      expect(err.message, contains('上限'));
      expect(err.message, contains('未发送请求'));
    });

    test('恰好 100%：仍然发送（严格 >，不误杀）', () async {
      // 窗口**正好等于**真实估算 → over100 为 false（严格 >）
      final text = 'x' * 200;
      final used = estimateTokensFromChars(_preambleChars() + text.length);
      final fake = _BudgetClient(
        window: ContextWindowInfo(used, ContextWindowSource.configured),
        events: const [
          [ChatTokenDelta('ok'), ChatDone()]
        ],
      );
      await run(fake, text);
      expect(fake.chatCalls, 1, reason: '等于上限仍应发送');
      expect((await latestAssistant())!.status, ChatMessageStatus.done);
    });

    test('90%（over80 未超）：正常发送 1 次并完成', () async {
      // 估算占窗口 ~90%（over80 但未超 → 只预警、不拦截）
      final text = 'x' * 180;
      final used = estimateTokensFromChars(_preambleChars() + text.length);
      final fake = _BudgetClient(
        window: ContextWindowInfo((used / 0.9).round(), ContextWindowSource.configured),
        events: const [
          [ChatTokenDelta('ok'), ChatDone()]
        ],
      );
      await run(fake, text);
      expect(fake.chatCalls, 1);
      expect((await latestAssistant())!.status, ChatMessageStatus.done);
    });

    test('窗口无法判定（null）：不拦截，正常发送', () async {
      final fake = _BudgetClient(events: const [
        [ChatTokenDelta('ok'), ChatDone()]
      ]);
      await run(fake, 'x' * 4000);
      expect(fake.chatCalls, 1, reason: 'null = 无法判定（desktop 路径）不拦截');
    });

    test('预算内正常完成 → done', () async {
      final fake = _BudgetClient(
        window: const ContextWindowInfo(32000, ContextWindowSource.endpoint),
        events: const [
          [ChatTokenDelta('你好'), ChatDone()]
        ],
      );
      await run(fake, '短问题');
      expect(fake.chatCalls, 1);
      final msg = await latestAssistant();
      expect(msg!.status, ChatMessageStatus.done);
      expect(msg.content, '你好');
    });

    test('续跑上限：只读工具每轮都回注 → 总请求数 3（1 + 2），没有第 4 次', () async {
      final fake = _BudgetClient(
        window: const ContextWindowInfo(32000, ContextWindowSource.endpoint),
        events: const [
          [ChatTokenDelta('第一次'), ChatTokenDelta(_readBlock), ChatDone()],
          [ChatTokenDelta('第二次'), ChatTokenDelta(_readBlock), ChatDone()],
          [ChatTokenDelta('第三次'), ChatTokenDelta(_readBlock), ChatDone()],
          [ChatTokenDelta('不该发生的第四次'), ChatDone()],
        ],
      );
      await run(fake, '帮我整理');
      expect(fake.chatCalls, 3,
          reason: '1 次首轮 + maxToolContinuations(2) 次续跑 = 3 次封顶');
      expect(fake.chatCalls, lessThan(4), reason: '不得出现第 4 次请求');
      final msg = await latestAssistant();
      expect(msg!.status, ChatMessageStatus.done);
      expect(msg.content.trim(), isNotEmpty);
    });
  });
}
