import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../models/conversation.dart';
import '../database.dart';
import 'assistant_client.dart';
import 'image_encoder.dart';
import 'models.dart';
import 'proposal_executor.dart';
import 'proposal_service.dart';
import 'screenshot_convention.dart';
import 'think_parser.dart';
import 'tool_parser.dart';
import 'tool_spec.dart';

/// 助理回合的流式事件（chat_page 渲染用；proposal_flow_test 也直接驱动它）。
sealed class AssistantEvent {
  const AssistantEvent();
}

/// 首条用户消息派生对话标题（design-v3 §1.4 / assistant-v4-ui §9 验收）：
/// 去首尾空白，超 20 字截断加省略号。纯函数便于单测。
String deriveConversationTitle(String firstMessage) {
  final t = firstMessage.trim();
  return t.length > 20 ? '${t.substring(0, 20)}…' : t;
}

/// 可见文本增量（工具块内容不含在内）。
class AssistantTextDelta extends AssistantEvent {
  final String delta;

  /// 截至目前的完整可见文本。
  final String fullText;
  const AssistantTextDelta(this.delta, this.fullText);
}

/// 一条提案已落待确认区（对话页内联提案卡片即时出现）。
class AssistantProposalCreated extends AssistantEvent {
  final ChangeProposal proposal;
  const AssistantProposalCreated(this.proposal);
}

/// 工具块校验失败 / 只读工具结果：已回注对话为 tool 消息。
class AssistantToolMessage extends AssistantEvent {
  /// 对应的工具块序号（本条 assistant 消息内，0 起；用于落定占位块状态）。
  final int blockIndex;
  final String content;
  const AssistantToolMessage(this.blockIndex, this.content);
}

/// 回合开始（用户消息与 assistant 占位已落库）——对话页立即刷新，
/// 用户消息马上上屏（2026-11-01：原先要等首个 token 才看得到自己的消息）。
class AssistantTurnStarted extends AssistantEvent {
  const AssistantTurnStarted();
}

/// 思考块增量（<think> 标签内容，不上屏、不落库，仅流式展示）。
class AssistantThinkingDelta extends AssistantEvent {
  /// 本回合第几个思考段（0 起；思考 → 正文 → 再思考时分段递增）。
  final int section;

  /// 该段截至目前的完整思考文本。
  final String text;

  /// true = 仍在思考块内（思考中）；false = 本段思考已闭合。
  final bool active;
  const AssistantThinkingDelta(this.section, this.text, this.active);
}

/// 一个工具块开始流入（模型开始输出 ```tool 围栏块，UI 先出占位块）。
class AssistantToolBlockStarted extends AssistantEvent {
  /// 本条 assistant 消息内的块序号（0 起）。
  final int index;
  const AssistantToolBlockStarted(this.index);
}

/// 回合正常结束。
class AssistantTurnDone extends AssistantEvent {
  const AssistantTurnDone();
}

/// 回合失败（通道错误等）。
class AssistantTurnError extends AssistantEvent {
  final String message;
  const AssistantTurnError(this.message);
}

/// 回合阶段（2026-11-01 多 Agent 并行）：对话列表与对话页的状态指示。
enum TurnPhase { starting, thinking, generating, tooling, done, error }

/// 阶段的人类可读标签（对话列表副标题）。
String turnPhaseLabel(TurnPhase p) => switch (p) {
      TurnPhase.starting => '启动中',
      TurnPhase.thinking => '思考中',
      TurnPhase.generating => '回复中',
      TurnPhase.tooling => '工具执行中',
      TurnPhase.done => '已完成',
      TurnPhase.error => '出错',
    };

/// 一个在途回合（2026-11-01）：pump 由 [AssistantService] 驱动、独立于页面
/// 存活——离开对话页回合继续跑，多个对话的回合可并行（通道各自独立，
/// 并发上限由 desktop 分模型闸调度）。页面经 [events] 订阅增量事件，
/// 经 [phase] 观察阶段。
class AssistantTurnHandle {
  AssistantTurnHandle._({
    required this.conversation,
    required this.text,
    required this.attachments,
  });

  /// 启动时的对话快照（modelConfigId 取自它）。
  final Conversation conversation;
  final String text;
  final List<ChatAttachment> attachments;

  String get conversationId => conversation.id;

  final _controller = StreamController<AssistantEvent>.broadcast();

  /// 流式事件（broadcast：页面开关随意订阅/退订，不影响 pump）。
  Stream<AssistantEvent> get events => _controller.stream;

  /// 当前阶段（对话列表指示用）。
  final ValueNotifier<TurnPhase> phase = ValueNotifier(TurnPhase.starting);

  /// 回合开始时间（对话列表副标题「思考中 12s」的秒数来源，assistant-v4-ui §2.2）。
  final DateTime startedAt = DateTime.now();

  /// 本回合的独立通道（取消时中断其 SSE）。
  late final AssistantClient channel;

  bool _closed = false;

  /// 用户主动取消了本回合（B19：续跑前必须检查——否则点了「停止」
  /// 之后循环还会再发一轮请求）。
  bool cancelledByUser = false;

  void _emit(AssistantEvent ev) {
    switch (ev) {
      case AssistantThinkingDelta():
        // 思考闭合后通常回到正文生成
        phase.value = ev.active ? TurnPhase.thinking : TurnPhase.generating;
      case AssistantTextDelta():
        phase.value = TurnPhase.generating;
      case AssistantToolBlockStarted():
        phase.value = TurnPhase.tooling;
      case AssistantProposalCreated() || AssistantToolMessage():
        phase.value = TurnPhase.generating;
      case AssistantTurnDone():
        phase.value = TurnPhase.done;
      case AssistantTurnError():
        phase.value = TurnPhase.error;
      default:
        break;
    }
    if (!_closed) _controller.add(ev);
  }

  void _close() {
    _closed = true;
    _controller.close();
    phase.dispose();
  }
}

/// 助理编排服务（design-v3 §5.4）：
/// 组装请求（对话历史 + 附件正文内联展开 + tool_spec 说明书）→
/// AssistantClient 通道 → tool_parser 流式解析 → proposal_service 落提案。
///
/// 2026-11-01 多 Agent 并行：回合 pump 由服务自持（[AssistantTurnHandle]），
/// 不再依赖页面消费流——多对话可同时各跑一个回合；同对话新回合自动
/// 取消旧回合。编辑/撤回/重试 = 截断后续消息（pending 提案一并撤销）后重跑。
class AssistantService {
  AssistantService._();

  static final AssistantService instance = AssistantService._();

  static const _uuid = Uuid();

  /// 通道覆盖（测试注入用）；null = 每回合创建独立通道（并行互不干扰）。
  AssistantClient? _clientOverride;

  /// 测试兼容：读取默认通道 / 注入 mock。
  AssistantClient get client => _clientOverride ?? AssistantClient.instance;
  set client(AssistantClient c) => _clientOverride = c;

  AssistantClient _newChannel() =>
      _clientOverride ?? AssistantClient.independent();

  /// 在途回合表（conversationId → handle）。
  final Map<String, AssistantTurnHandle> activeTurns = {};

  /// 回合表/阶段任何变化都 +1（对话列表一个 Listenable 就够）。
  final ValueNotifier<int> turnsVersion = ValueNotifier(0);

  AssistantTurnHandle? turnOf(String conversationId) =>
      activeTurns[conversationId];

  // ---- 对话管理 ----

  Future<Conversation> createConversation({String? modelConfigId}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final conv = Conversation(
      id: _uuid.v4(),
      title: '新对话',
      modelConfigId: modelConfigId,
      createdAt: now,
      updatedAt: now,
    );
    await AppDatabase.instance.insertConversation(conv);
    return conv;
  }

  // ---- 附件展开（design-v3 §3.6：请求前展开为上下文块） ----

  static const _attachmentMaxChars = 8000;

  /// 把消息级附件引用展开为带引用头的正文块（[#note:标题] 等）。
  /// 文本类文件做正文抽取（截断）；图片文件在 [visionCapable] 时内联
  /// 缩放后的 PNG（[ChatAttachment.dataBase64]），否则只在头部声明
  /// 「未附带图像内容」——避免非多模态模型误以为能看图。
  Future<List<ChatAttachment>> expandAttachments(List<ChatAttachment> refs,
      {bool visionCapable = false}) async {
    final db = AppDatabase.instance;
    final out = <ChatAttachment>[];
    for (final ref in refs) {
      switch (ref.type) {
        case ChatAttachmentType.note:
          final note = await db.getNoteById(ref.id);
          if (note == null) break;
          out.add(ChatAttachment(
            type: ref.type,
            id: ref.id,
            content: _cap('[#note:${note.title}]\n${note.content}'),
          ));
        case ChatAttachmentType.message:
          final msg = await db.getMessageById(ref.id);
          if (msg == null) break;
          out.add(ChatAttachment(
            type: ref.type,
            id: ref.id,
            content: _cap('[#message:${msg.title}]\n${msg.body}'),
          ));
        case ChatAttachmentType.file:
          final file = await db.getFileById(ref.id);
          if (file == null) break;
          var header = '[#file:${file.name}]（${file.mimeType ?? '未知类型'}）';
          final mime = file.mimeType ?? '';
          String? dataBase64;
          if (mime.startsWith('image/')) {
            if (visionCapable) {
              final inline = await encodeInlineImage(file.localPath);
              if (inline != null) {
                dataBase64 = inline.dataBase64;
                header =
                    '$header\n[图像已内联：${inline.width}×${inline.height} PNG]';
              } else {
                header = '$header\n（图像读取失败，未附带图像内容）';
              }
            } else {
              header = '$header\n（当前模型不支持图像输入，未附带图像内容）';
            }
          } else if ((mime.startsWith('text/') || mime.endsWith('json')) &&
              (file.size ?? 0) < 256 * 1024) {
            try {
              final text = await File(file.localPath).readAsString();
              header = '$header\n$text';
            } catch (_) {
              // 读不出来就只给头部元信息
            }
          }
          out.add(ChatAttachment(
            type: ref.type,
            id: ref.id,
            content: _cap(header),
            // dataBase64 固定是 PNG 重编码产物，mimeType 描述的是它而非原文件
            mimeType: dataBase64 != null ? 'image/png' : null,
            dataBase64: dataBase64,
          ));
      }
    }
    return out;
  }

  /// F03 Step3：本回合附件里是否含**截图**（图片文件）。
  ///
  /// 与 [visionCapable] 解耦：非 vision 模型看不到图，但用户「整理截图」的
  /// 意图仍成立，整理约定照样要注入系统前言，避免模型按纯文本瞎猜。
  /// 只看 `file` 类型引用（笔记/消息引用不可能是截图）。
  Future<bool> attachmentsContainScreenshot(List<ChatAttachment> refs) async {
    final db = AppDatabase.instance;
    for (final ref in refs) {
      if (ref.type != ChatAttachmentType.file) continue;
      final file = await db.getFileById(ref.id);
      if ((file?.mimeType ?? '').startsWith('image/')) return true;
    }
    return false;
  }

  static String _cap(String text) => text.length > _attachmentMaxChars
      ? '${text.substring(0, _attachmentMaxChars)}…（已截断）'
      : text;

  // ---- 回合发起 / 取消 ----

  /// 兼容旧调用（测试与 chat_page 之外的消费方）：
  /// 启动回合并以流形式返回事件。
  Stream<AssistantEvent> sendTurn({
    required Conversation conversation,
    required String text,
    List<ChatAttachment> attachments = const [],
  }) =>
      startTurn(
              conversation: conversation,
              text: text,
              attachments: attachments)
          .events;

  /// 发起一个回合（立即返回 handle，pump 后台自持）。
  /// 同对话已有在途回合时先取消（重试/编辑/连点发送的兜底）。
  AssistantTurnHandle startTurn({
    required Conversation conversation,
    required String text,
    List<ChatAttachment> attachments = const [],
  }) {
    cancelTurn(conversation.id);
    final handle = AssistantTurnHandle._(
        conversation: conversation, text: text, attachments: attachments)
      ..channel = _newChannel();
    // 阶段变化同步通知（对话列表指示：思考中 → 回复中 → 工具执行中）
    handle.phase.addListener(() => turnsVersion.value++);
    activeTurns[conversation.id] = handle;
    turnsVersion.value++;
    unawaited(_runTurn(handle));
    return handle;
  }

  /// 取消指定对话的在途回合（无则静默）。
  void cancelTurn(String conversationId) {
    final handle = activeTurns[conversationId];
    if (handle == null) return;
    handle.cancelledByUser = true;
    handle.channel.cancelActive();
  }

  /// 中断全部在途回合（旧 API；未闭合工具块丢弃，已落库提案保留）。
  void cancelActive() {
    for (final h in activeTurns.values) {
      h.cancelledByUser = true;
      h.channel.cancelActive();
    }
  }

  @visibleForTesting
  void debugReset() {
    cancelActive();
    for (final h in activeTurns.values) {
      h._close();
    }
    activeTurns.clear();
    turnsVersion.value++;
  }

  // ---- 消息操作：重试 / 编辑 / 撤回（2026-11-01） ----

  /// 重试一条 assistant 回复：删除自触发它的用户消息起的全部后续消息
  /// （pending 提案一并撤销），用原用户消息内容/附件重跑回合。
  Future<AssistantTurnHandle?> retryAssistantMessage(
      Conversation conversation, String assistantMessageId) async {
    final db = AppDatabase.instance;
    final messages = await db.getChatMessages(conversation.id);
    final idx = messages.indexWhere((m) => m.id == assistantMessageId);
    if (idx < 0) return null;
    ChatMessage? userMsg;
    for (var i = idx - 1; i >= 0; i--) {
      if (messages[i].role == ChatRole.user) {
        userMsg = messages[i];
        break;
      }
    }
    if (userMsg == null) return null;
    await _truncateFrom(conversation.id, userMsg.id);
    return startTurn(
        conversation: conversation,
        text: userMsg.content,
        attachments: userMsg.attachments);
  }

  /// 编辑用户消息：删除该消息及后续（pending 提案撤销），用新文本
  /// （沿用原附件）重跑回合。
  Future<AssistantTurnHandle?> editUserMessage(
      Conversation conversation, String messageId, String newText) async {
    final db = AppDatabase.instance;
    final messages = await db.getChatMessages(conversation.id);
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx < 0 || messages[idx].role != ChatRole.user) return null;
    final original = messages[idx];
    await _truncateFrom(conversation.id, messageId);
    return startTurn(
        conversation: conversation,
        text: newText,
        attachments: original.attachments);
  }

  /// 撤回用户消息：删除该消息及后续（pending 提案撤销），不重跑。
  Future<void> recallUserMessage(
          Conversation conversation, String messageId) =>
      _truncateFrom(conversation.id, messageId);

  /// 截断：删除自 [messageId]（含）起的全部消息；这些消息里 assistant
  /// 批次产出的 pending 提案一并置 rejected（applied 的走撤销队列，
  /// 不在此处回滚）。
  Future<void> _truncateFrom(String conversationId, String messageId) async {
    final db = AppDatabase.instance;
    final messages = await db.getChatMessages(conversationId);
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    final doomed = messages.sublist(idx);
    final batchIds = [
      for (final m in doomed)
        if (m.role == ChatRole.assistant) m.id,
    ];
    if (batchIds.isNotEmpty) {
      await db.rejectPendingProposalsByBatchIds(batchIds);
    }
    await db.deleteChatMessages([for (final m in doomed) m.id]);
    await db.touchConversation(conversationId);
  }

  // ---- 回合 pump（服务自持） ----

  /// 执行一个回合：落用户消息（首条消息生成对话标题）→ 建 streaming 状态的
  /// assistant 占位消息 → 组装请求 → 流式消费 → 文本增量、工具块落提案/回注 →
  /// 结束时把可见文本与状态写回 assistant 消息。全程事件经 [handle._emit] 广播。
  Future<void> _runTurn(AssistantTurnHandle handle) async {
    final conversation = handle.conversation;
    final db = AppDatabase.instance;
    final now = DateTime.now().millisecondsSinceEpoch;

    final userMsg = ChatMessage(
      id: _uuid.v4(),
      conversationId: conversation.id,
      role: ChatRole.user,
      content: handle.text,
      attachments: handle.attachments,
      status: ChatMessageStatus.done,
      createdAt: now,
    );
    await db.insertChatMessage(userMsg);
    // 首条用户消息截断生成对话标题（design-v3 §1.4）
    if (conversation.title == '新对话') {
      final title = deriveConversationTitle(handle.text);
      // 纯附件回合没有文本：保留「新对话」，等第一条有文本的消息再命名
      if (title.isNotEmpty) {
        await db.renameConversation(conversation.id, title);
      }
    }
    await db.touchConversation(conversation.id);

    final assistantMsg = ChatMessage(
      id: _uuid.v4(),
      conversationId: conversation.id,
      role: ChatRole.assistant,
      content: '',
      status: ChatMessageStatus.streaming,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await db.insertChatMessage(assistantMsg);
    // 用户消息与占位已落库：让对话页立即刷新上屏（不等首个 token）
    handle._emit(const AssistantTurnStarted());

    final vision = await handle.channel.isVisionCapable(conversation.modelConfigId);
    final expanded =
        await expandAttachments(handle.attachments, visionCapable: vision);
    // F03 Step3/4：有截图时把「整理约定」注入系统前言（唯一拼接点见
    // screenshot_convention.dart）。约定**只进模型侧**：用户消息正文仍是
    // handle.text 原文（或 UI 的默认指令），不受影响、也不会重复拼。
    final hasScreenshot =
        await attachmentsContainScreenshot(handle.attachments);

    // B15：本回合用户**选中**的消息（附件里的 message 引用）= inbox.triage 范围。
    // 未选中的消息不进 triage、不产提案。
    final selectedMessageIds = selectedMessageIdsOf(handle.attachments);

    final visible = StringBuffer();
    var interrupted = false;
    String? errorText;

    // B19（2026-11-10）：只读工具回注后的**有界续跑**。
    //
    // 背景：一个回合原本只发一次请求，而工具结果是以 role=tool 的消息落库的
    // （ProposalExecutor.reportToolMessage）。若不在此刻再请求一次，模型要等
    // 用户下一句话才看得到「[工具执行结果]」——表现出来就是「工具回注后
    // Agent 停住，需要用户再问一句」。
    //
    // 规则（用户批准的最小方案）：
    // 1. 只有**只读工具结果**（ReadToolResult）触发续跑；本轮一旦产出待审批
    //    提案（ProposalCreated / ProposalDuplicate）立刻停止，等审批；
    // 2. 每轮**重建历史与请求**（否则第二轮看不到上一轮的 [工具执行结果]）；
    // 3. 续跑上限 [maxToolContinuations] 轮（首轮之外），防连环只读烧额度；
    // 4. 出错 / 中断早退；**审批通过后的续跑属 Q13，本轮不做**。
    const maxToolContinuations = 2;
    var continuationRound = 0;

    while (true) {
      final isContinuation = continuationRound > 0;
      if (isContinuation) {
        // 续跑前把本轮已生成的正文先落库：第二轮请求要带上这段 narration，
        // 否则模型看不到自己上一轮说过什么，容易重复生成同一段。
        await db.updateChatMessageContent(assistantMsg.id, visible.toString());
      }
      // ---- 每轮：重建历史与请求（续跑必须看到上一轮回注的工具结果）----
      final history = (await db.getChatMessages(conversation.id))
          .where((m) {
            if (m.content.isEmpty) return false;
            // 本回合的 assistant 消息在 DB 里仍是 streaming（收尾才置 done）：
            // 首轮按既有规则排除；续跑轮**纳入**，且时间戳早于工具消息，
            // 顺序天然是 [user] → [assistant 正文] → [tool 结果]。
            if (m.id == assistantMsg.id) return isContinuation;
            return m.status == ChatMessageStatus.done;
          })
          .map((m) => ChatMessageModel(
              role: m.role, content: m.content, attachments: m.attachments))
          .toList();
      // 请求消息序列：说明书前言（schema 的 role 枚举无 system，前言作为
      // 首条 user 消息注入，details §2.4 说明书由 mobile 组装）+ 历史
      // （streaming/error 占位与空消息不进上下文）。
      final requestMessages = [
        ChatMessageModel(
            role: ChatRole.user,
            content: systemPreambleWithConvention(
              buildToolSpecPrompt(DateTime.now()),
              hasScreenshots: hasScreenshot)),
        ...history,
      ];

      final thinkParser = ThinkTagParser();
      final parser = ToolBlockParser();

      /// 本轮只读工具结果条数 / 本轮待审批提案条数（B19 续跑判据）。
      var readResultsThisRound = 0;
      var proposalsThisRound = 0;

      /// 已播报「开始流入」的工具块序号（parser 只在块闭合时产出块，
      /// 开始状态靠 inBlock + blockCount 组合探测）。
      int announcedBlockStart = -1;

      /// 闭包产出的事件中转队列（每回合独立，并行回合互不串扰）。
      final pendingEvents = <AssistantEvent>[];

      Future<void> handleBlock(ParsedToolBlock block) async {
        final outcome = await ProposalService.instance.handleToolBlock(
          conversationId: conversation.id,
          batchId: assistantMsg.id,
          block: block,
          selectedMessageIds: selectedMessageIds,
        );
        switch (outcome) {
          case ProposalCreated():
            proposalsThisRound++;
            pendingEvents.add(AssistantProposalCreated(outcome.proposal));
          case ProposalDuplicate():
            // 重放命中去重键：已有待确认项，等同于「本轮有提案」→ 不续跑。
            proposalsThisRound++;
            break;
          case ProposalValidationFailure():
            final content = '一个动作未能理解，已跳过：${outcome.reason}';
            await ProposalExecutor.instance
                .reportToolMessage(conversation.id, content);
            pendingEvents.add(AssistantToolMessage(block.index, content));
          case ReadToolResult():
            readResultsThisRound++;
            // F31：回注正文带上工具名，历史回合的过程步骤才能显示
            // 「读取任务列表」而不是笼统的「工具回注」。
            final tool = block.tool ?? 'tool';
            final resultText = outcome.text;
            final content = '[$tool] $resultText';
            await ProposalExecutor.instance
                .reportToolMessage(conversation.id, content);
            pendingEvents.add(AssistantToolMessage(block.index, content));
        }
      }

    try {
      await for (final ev in handle.channel.chat(
        conversationId: conversation.id,
        messages: requestMessages,
        attachments: expanded,
        modelConfigId: conversation.modelConfigId,
      )) {
        switch (ev) {
          case ChatTokenDelta():
            // 先剥思考块（<think> 标签），剩余文本再过工具块解析
            final thinkRes = thinkParser.feed(ev.delta);
            if (thinkRes.thinkingChanged || thinkRes.stateChanged) {
              handle._emit(AssistantThinkingDelta(thinkParser.sectionIndex,
                  thinkParser.sectionThinking, thinkParser.inThinking));
            }
            final res = parser.feed(thinkRes.text);
            // 工具块开始流入：先出占位（闭合后由提案/回注事件落定状态）
            if (parser.inBlock && parser.blockCount != announcedBlockStart) {
              announcedBlockStart = parser.blockCount;
              handle._emit(AssistantToolBlockStarted(parser.blockCount));
            }
            if (res.text.isNotEmpty) {
              visible.write(res.text);
              handle._emit(AssistantTextDelta(res.text, visible.toString()));
            }
            for (final block in res.blocks) {
              await handleBlock(block);
            }
          case ChatProposalEvent():
            // desktop 不透传 proposal 事件（提案由手机端落库）；忽略。
            break;
          case ChatDone():
            break;
          case ChatError():
            errorText = ev.error;
        }
        // 中转闭包产出的事件
        while (pendingEvents.isNotEmpty) {
          handle._emit(pendingEvents.removeAt(0));
        }
        if (errorText != null) break;
      }
    } catch (e) {
      errorText = '$e';
    }

    // 流收尾：先冲思考解析器的暂存（标签前缀残段按普通内容落出），
    // 未闭合工具块整体丢弃（details §2.2），尾行文本仍上屏
    final thinkTail = thinkParser.finish();
    if (thinkTail.thinkingChanged || thinkTail.stateChanged) {
      handle._emit(AssistantThinkingDelta(
          thinkParser.sectionIndex, thinkParser.sectionThinking, false));
    }
    final toolTail = parser.feed(thinkTail.text);
    if (toolTail.text.isNotEmpty) {
      visible.write(toolTail.text);
      handle._emit(AssistantTextDelta(toolTail.text, visible.toString()));
    }
    for (final block in toolTail.blocks) {
      await handleBlock(block);
    }
    final tail = parser.finish(interrupted: interrupted || errorText != null);
    if (tail.text.isNotEmpty) {
      visible.write(tail.text);
      handle._emit(AssistantTextDelta(tail.text, visible.toString()));
    }
    for (final block in tail.blocks) {
      await handleBlock(block);
    }
      while (pendingEvents.isNotEmpty) {
        handle._emit(pendingEvents.removeAt(0));
      }

      // ---- B19 续跑判定 ----
      // 只读回注过（readResultsThisRound > 0）、本轮没有待审批提案、
      // 还有轮数余额、且没有错误/中断时才继续。
      final shouldContinue = errorText == null &&
          !interrupted &&
          !handle.cancelledByUser &&
          readResultsThisRound > 0 &&
          proposalsThisRound == 0 &&
          continuationRound < maxToolContinuations;
      if (!shouldContinue) break;
      continuationRound++;
      // 续跑沿用**同一个** handle 与 assistantMsg：阶段拨回「思考中」，
      // 界面继续显示同一个进行态；不新增事件类型（避免 UI 改动）。
      handle.phase.value = TurnPhase.thinking;
    }

    if (errorText != null) {
      await db.updateChatMessageContent(assistantMsg.id, visible.toString());
      await db.updateChatMessageStatus(
          assistantMsg.id, ChatMessageStatus.error);
      handle._emit(AssistantTurnError(errorText));
    } else {
      await db.updateChatMessageContent(assistantMsg.id, visible.toString());
      await db.updateChatMessageStatus(
          assistantMsg.id, ChatMessageStatus.done);
      handle._emit(const AssistantTurnDone());
    }

    // 回合收尾：移出在途表并通知（对话列表状态指示熄灭）
    if (activeTurns[conversation.id] == handle) {
      activeTurns.remove(conversation.id);
    }
    turnsVersion.value++;
    handle._close();
  }
}
