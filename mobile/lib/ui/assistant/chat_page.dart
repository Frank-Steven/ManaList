import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/conversation.dart';
import '../../models/message.dart';
import '../../services/assistant/assistant_service.dart';
import '../../services/assistant/models.dart';
import '../../services/app_log.dart';
import '../../services/ai_client.dart';
import '../../services/assistant/assistant_client.dart';
import '../../services/database.dart';
import '../../services/library_file_service.dart';
import '../library/files_page.dart' show libraryFileIcon;
import 'approvals_page.dart';
import 'model_picker.dart';
import 'attachment_picker.dart';
import 'conversation_export.dart';
import 'widgets/attachment_cards.dart';
import 'widgets/chat_appbar.dart';
import 'widgets/input_bar.dart';
import 'widgets/proposal_card.dart';
import 'widgets/streaming_blocks.dart';
import 'widgets/suggestion_chips.dart';

/// F03（2026-11-03）：从相册批量加截图的单批上限。
const int maxScreenshotsPerBatch = 6;

/// F03：超出上限时只取前 [maxScreenshotsPerBatch] 张（纯函数，便于单测）。
List<T> clampScreenshotBatch<T>(List<T> picked) =>
    picked.length <= maxScreenshotsPerBatch
        ? List<T>.of(picked)
        : picked.sublist(0, maxScreenshotsPerBatch);

/// F03 Step2：截图整理约定 + 敏感信息提示（纯函数，测试断言关键片段）。
String screenshotsConventionHint() =>
    '每张截图单独成条：能确定时间的出待办（task.create），纯信息出笔记（note.create），'
    '不跨图合并。截图可能含敏感信息，远程模型会离开设备。';

/// 对话页（assistant-v4-ui §3，2026-11-08 重设计）：
///
/// 呈现：助理消息为**全宽时间线**（不再用气泡），用户消息保留右对齐
/// primary pill；时间戳不常驻，收进长按菜单「详情」。空对话显示情境化
/// 建议 chips（suggestion_chips.dart，按真实数据生成）。
///
/// 结构（组件拆分决策）：壳只持有回合订阅与消息状态，呈现下沉为
/// ChatAppBar（顶栏 + 切模型后果 sheet）/ ChatInputBar（附件条、
/// `/` 指令面板、发送/停止键）/ SuggestionChips 等独立组件。
///
/// 回合 pump 由 AssistantService 自持：离开本页回合继续跑（多对话并行），
/// 回来时经 turnOf 重新订阅在途回合。回合进行中允许切换模型，但先弹
/// 后果说明 sheet（assistant-v4-ui §3.2）。
///
/// 消息操作（长按）：复制 / 详情；Agent 回复可重试；用户消息可编辑/撤回——
/// 三者都删除后续消息（pending 提案一并撤销），编辑/重试随后重跑回合。
///
/// 附件 bar 即草稿附件（DB v9 conversations.draft_attachments）：打开对话时
/// 从草稿加载，附件选择器与 chip 移除都写透到草稿；发送时草稿随消息落
/// chat_messages.attachments 并清空。
class ChatPage extends StatefulWidget {
  final Conversation conversation;

  /// 搜索定位（assistant-v4-ui §2.3）：从对话列表搜索结果进入时，
  /// 首帧后滚动到该消息并高亮。
  final String? initialScrollToMessageId;

  const ChatPage(
      {super.key, required this.conversation, this.initialScrollToMessageId});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// 搜索定位目标（§2.3）：非 null 时在消息流里高亮该条并滚动到位。
  String? _searchHitMessageId;
  final _searchHitKey = GlobalKey();
  bool _searchHitScrolled = false;

  List<ChatMessage> _messages = [];

  /// assistant 消息 id → 该回合落库的提案（内联卡片）。
  Map<String, List<ChangeProposal>> _proposalsByBatch = {};

  /// 当前回合的流式分段（思考块/工具块/正文段，按产生顺序）。
  List<ChatStreamSegment> _segments = [];

  /// 当前文本段在回合累计可见文本中的起点（段间由思考/工具块切分）。
  int _textBaseOffset = 0;
  String _lastFullText = '';
  ChatStreamSegment? _currentTextSeg;

  /// 状态秒数刷新（思考中 Ns / 执行中 Ns，等宽数字）。
  Timer? _statusTimer;

  /// 历史工具消息的展开状态（messageId 集合）。
  final Set<String> _expandedToolMsgIds = {};

  /// 附件展示元数据缓存：'type:id' → 标题/图标/文件实体。
  final Map<String, AttachmentMeta> _attachmentMeta = {};

  /// 在途回合（pump 由服务自持；本页只是事件的订阅者）。
  AssistantTurnHandle? _turn;
  StreamSubscription<AssistantEvent>? _turnSub;

  String? _errorText;

  /// 回合错误时的端点诊断行（assistant-v4-ui §5.3）：
  /// 当前生效端点持久化的上次测试结果，与模型选择器/配置向导同源。
  String? _errorDiag;
  List<ChatAttachment> _pendingAttachments = [];
  late Conversation _conversation;

  /// task-50（2026-11-03）：`modelConfigId` 解析后的可读名称。
  /// null = 还在解析；解析失败/已失效会写成「模型配置已失效」，绝不回退显示 id。
  String? _modelDisplayName;

  /// 空对话建议 chips（assistant-v4-ui §3.8）；非空对话恒为空表。
  List<String> _suggestions = [];

  bool get _busy => _turn != null;

  @override
  void initState() {
    super.initState();
    _conversation = widget.conversation;
    _searchHitMessageId = widget.initialScrollToMessageId;
    _reload();
    // task-50：模型名称异步解析，不阻塞首帧
    unawaited(_refreshModelDisplayName());
    // 多 Agent 并行：离开页面回合不死，回来时重新接上在途回合
    final active =
        AssistantService.instance.turnOf(widget.conversation.id);
    if (active != null) _attachTurn(active);
  }

  @override
  void dispose() {
    // 只退订，不取消回合（服务自持 pump；要取消用停止按钮）
    _turnSub?.cancel();
    _statusTimer?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final db = AppDatabase.instance;
    final messages = await db.getChatMessages(_conversation.id);
    final proposals = await db.proposalsForConversation(_conversation.id);
    final byBatch = <String, List<ChangeProposal>>{};
    for (final p in proposals) {
      if (p.batchId != null) byBatch.putIfAbsent(p.batchId!, () => []).add(p);
    }
    final conv = await db.getConversationById(_conversation.id);
    if (!mounted) return;
    setState(() {
      _messages = messages;
      _proposalsByBatch = byBatch;
      if (conv != null) {
        final prevModelId = _conversation.modelConfigId;
        _conversation = conv;
        // task-50：模型被切换时先清掉旧名称，避免短暂显示上一个接口名
        if (conv.modelConfigId != prevModelId) _modelDisplayName = null;
        // 草稿附件是附件 bar 的唯一事实源（库页「发送给助理」会追加到这里）
        _pendingAttachments = conv.draftAttachments;
      }
    });
    await _resolveAttachmentMeta();
    if (!_maybeScrollToSearchHit()) _scrollToBottom();
    // task-50：模型可能被切换过，重新解析显示名（异步，不影响列表渲染）
    unawaited(_refreshModelDisplayName());
    // 空对话：按真实数据生成建议 chips（§3.8）
    if (messages.isEmpty) {
      unawaited(_refreshSuggestions());
    } else if (_suggestions.isNotEmpty && mounted) {
      setState(() => _suggestions = []);
    }
  }

  /// 建议 chips 数据源：收件箱未处理数 + 今天的进行中任务数。
  Future<void> _refreshSuggestions() async {
    final db = AppDatabase.instance;
    try {
      final pending = await db.countMessages(status: MessageStatus.pending);
      final now = DateTime.now();
      final dayStart = DateTime(now.year, now.month, now.day);
      final todayTasks = await db.getTasksOverlapping(
          dayStart.millisecondsSinceEpoch,
          dayStart.add(const Duration(days: 1)).millisecondsSinceEpoch);
      if (!mounted || _messages.isNotEmpty) return;
      setState(() {
        _suggestions = suggestionPrompts(
            pendingMessages: pending, todayOpenTasks: todayTasks.length);
      });
    } catch (e, st) {
      AppLog.instance.warn('chat.suggestions', e, st);
    }
  }

  /// task-50（2026-11-03）：把 `modelConfigId` 解析成可读名称。
  ///
  /// 顺序：① 本地远程接口（`AiEndpoint.id == id` → `name`）；
  /// ② 桌面在线时 `/v1/models`（`DesktopModelEntry.id == id` → `name`）；
  /// ③ 都找不到 → 「模型配置已失效」。**任何情况下都不显示 id/指纹**。
  Future<void> _refreshModelDisplayName() async {
    final id = _conversation.modelConfigId;
    if (id == null || id.isEmpty) {
      if (!mounted) return;
      setState(() => _modelDisplayName = '默认模型');
      return;
    }
    String? name;
    try {
      for (final e in await AiClient.instance.getRemoteEndpoints()) {
        if (e.id == id) {
          name = e.name;
          break;
        }
      }
      if ((name == null || name.trim().isEmpty) &&
          await AiClient.instance.isDesktopOnline()) {
        final result = await AssistantClient.instance.getDesktopModels();
        for (final m in result.models) {
          if (m.id == id) {
            name = m.name;
            break;
          }
        }
      }
    } catch (e, st) {
      // 解析失败按「未解析出来」处理：不阻塞、不回退显示 id
      AppLog.instance.warn('chat.model-name', e, st);
    }
    if (!mounted) return;
    final trimmed = name?.trim();
    setState(() => _modelDisplayName =
        (trimmed != null && trimmed.isNotEmpty) ? trimmed : '模型配置已失效');
  }

  /// 顶栏模型行文案：解析中先显示占位，**绝不闪现 id**。
  String get _modelLabel {
    if (_conversation.modelConfigId == null ||
        _conversation.modelConfigId!.isEmpty) {
      return '默认模型';
    }
    return _modelDisplayName ?? '加载中…';
  }

  /// 解析消息/草稿附件的展示元数据（标题/图标/文件实体）。
  Future<void> _resolveAttachmentMeta() async {
    final want = <String, ChatAttachment>{};
    void collect(List<ChatAttachment> list) {
      for (final a in list) {
        want.putIfAbsent('${a.type}:${a.id}', () => a);
      }
    }

    for (final m in _messages) {
      collect(m.attachments);
    }
    collect(_pendingAttachments);
    var changed = false;
    for (final e in want.entries) {
      if (_attachmentMeta.containsKey(e.key)) continue;
      _attachmentMeta[e.key] = await _loadAttachmentMeta(e.value);
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  Future<AttachmentMeta> _loadAttachmentMeta(ChatAttachment a) async {
    final db = AppDatabase.instance;
    switch (a.type) {
      case ChatAttachmentType.file:
        final f = await db.getFileById(a.id);
        return AttachmentMeta(
          title: f?.name ?? '文件',
          icon: f != null
              ? libraryFileIcon(f)
              : Icons.insert_drive_file_outlined,
          file: f,
          // 文本文件按字节数近似字符数（预算条保守估算）
          chars: f?.size,
        );
      case ChatAttachmentType.note:
        final n = await db.getNoteById(a.id);
        return AttachmentMeta(
            title: n?.title ?? '笔记',
            icon: Icons.note_outlined,
            chars: n?.content.length);
      default:
        final m = await db.getMessageById(a.id);
        return AttachmentMeta(
            title: m?.title ?? '消息',
            icon: Icons.mail_outline,
            chars: m == null ? null : m.title.length + m.body.length);
    }
  }

  AttachmentMeta? _metaOf(ChatAttachment a) =>
      _attachmentMeta['${a.type}:${a.id}'];

  /// 草稿附件的 token 估算合计（assistant-v4-ui §3.6 预算条）：
  /// 字符数/2（CJK 保守估计）；元数据未解析或对象已删的按 0 计。
  int get _pendingAttachmentTokens {
    var sum = 0;
    for (final a in _pendingAttachments) {
      final chars = _metaOf(a)?.chars;
      if (chars != null) sum += estimateTokensFromChars(chars);
    }
    return sum;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// 搜索定位（§2.3）：命中消息在列表里时接管首屏滚动，滚动到该条。
  /// 返回 true 表示已接管（不再滚到底）。
  bool _maybeScrollToSearchHit() {
    final id = _searchHitMessageId;
    if (id == null || _searchHitScrolled) return false;
    if (!_messages.any((m) => m.id == id)) return false;
    _searchHitScrolled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _searchHitKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            alignment: 0.2);
      }
    });
    return true;
  }

  Future<void> _pickAttachments() async {
    final picked = await Navigator.of(context).push<List<ChatAttachment>>(
      MaterialPageRoute(
          builder: (_) => AttachmentPickerPage(selected: _pendingAttachments)),
    );
    if (picked != null && mounted) {
      setState(() => _pendingAttachments = picked);
      await AppDatabase.instance
          .setConversationDraftAttachments(_conversation.id, picked);
    }
  }

  /// F03 Step1（2026-11-03）：从相册多选截图 → 逐张复制进 attachment_store，
  /// 元数据写入 files 表，再加入当前对话的草稿附件。
  ///
  /// 约束：单批最多 [maxScreenshotsPerBatch] 张（超出部分提示分批添加）；
  /// 逐张失败不阻塞其它图，失败数与超限数都会通过 SnackBar 可见反馈。
  Future<void> _pickScreenshots() async {
    if (_busy) return;
    List<XFile> picked;
    try {
      picked = await ImagePicker().pickMultiImage();
    } catch (e, st) {
      AppLog.instance.warn('chat.pickScreenshots', e, st);
      _showSnack('无法打开相册，请改用「附件」入口选图');
      return;
    }
    if (picked.isEmpty) return; // 用户取消
    final batch = clampScreenshotBatch(picked);
    final overflow = picked.length - batch.length;
    final added = <ChatAttachment>[];
    var failed = 0;
    for (final x in batch) {
      final file = await LibraryFileService.instance.importFromPath(
        x.path,
        name: x.name,
        mimeType: x.mimeType,
      );
      if (file == null) {
        failed++;
        continue;
      }
      added.add(ChatAttachment(type: ChatAttachmentType.file, id: file.id));
    }
    if (!mounted) return;
    if (added.isEmpty) {
      _showSnack('截图导入失败，请重试或改用「附件」入口');
      return;
    }
    setState(() => _pendingAttachments = [..._pendingAttachments, ...added]);
    await AppDatabase.instance
        .setConversationDraftAttachments(_conversation.id, _pendingAttachments);
    await _resolveAttachmentMeta();
    if (!mounted) return;
    final parts = <String>['已加入 ${added.length} 张截图'];
    if (overflow > 0) {
      parts.add('单次最多 $maxScreenshotsPerBatch 张，其余 $overflow 张请分批添加');
    }
    if (failed > 0) parts.add('$failed 张导入失败');
    _showSnack(parts.join('；'));
  }

  void _removeAttachment(ChatAttachment a) {
    setState(() => _pendingAttachments.remove(a));
    AppDatabase.instance.setConversationDraftAttachments(
        _conversation.id, _pendingAttachments);
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// 草稿里是否含图片附件（决定是否显示 F03 的截图约定/敏感信息提示）。
  bool get _hasScreenshotAttachments => _pendingAttachments.any((a) {
        final f = _metaOf(a)?.file;
        return f != null && (f.mimeType ?? '').startsWith('image/');
      });

  Widget _buildScreenshotsHint(ColorScheme cs) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: cs.surfaceContainerHigh,
      child: Text(
        screenshotsConventionHint(),
        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
      ),
    );
  }

  /// 切换模型（assistant-v4-ui §3.2 决策）：回合进行中先弹后果说明
  /// sheet；确认后（或无在途回合时直接）进模型选择器（选择模式）。
  Future<void> _switchModel() async {
    if (_busy) {
      final proceed = await showModelSwitchConsequences(context);
      if (!proceed || !mounted) return;
    }
    final selected = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ModelPickerPage(
          selectionMode: true,
          currentModelConfigId: _conversation.modelConfigId,
        ),
      ),
    );
    if (selected == null || !mounted) return;
    await AppDatabase.instance
        .setConversationModel(_conversation.id, selected.isEmpty ? null : selected);
    await _reload();
    if (mounted) _showSnack('下一条消息起使用 $_modelLabel');
  }

  // ---- 顶栏菜单动作 ----

  Future<void> _rename() async {
    final controller = TextEditingController(text: _conversation.title);
    final saved = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名对话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '标题'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == null || saved.isEmpty || !mounted) return;
    await AppDatabase.instance.renameConversation(_conversation.id, saved);
    await _reload();
  }

  /// 导出对话为 markdown 文件（落文件区，note_export 来源）。
  Future<void> _export() async {
    try {
      final name = await exportConversationToMarkdown(_conversation,
          modelLabel: _modelLabel);
      _showSnack('已导出到文件区：$name');
    } catch (e, st) {
      AppLog.instance.warn('chat.export', e, st);
      _showSnack('导出失败：$e');
    }
  }

  /// 清空上下文重开：删除本对话全部消息记录，待确认提案保留。
  Future<void> _clearAndRestart() async {
    if (_busy) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空重开'),
        content: const Text('删除本对话的全部消息记录？待确认提案会保留在待确认区。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await AppDatabase.instance.deleteChatMessages(
        _messages.map((m) => m.id).toList());
    await _reload();
  }

  Future<void> _deleteConversation() async {
    if (_busy) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除对话'),
        content:
            Text('删除「${_conversation.title}」？其待确认提案会保留在待确认区。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await AppDatabase.instance.deleteConversation(_conversation.id);
    if (mounted) Navigator.of(context).pop();
  }

  // ---- 回合订阅（pump 在服务侧，本页只渲染事件） ----

  void _attachTurn(AssistantTurnHandle handle) {
    _turnSub?.cancel();
    _turn = handle;
    _startStatusTimer();
    _turnSub = handle.events.listen(_onTurnEvent);
  }

  void _detachTurn() {
    _turnSub?.cancel();
    _turnSub = null;
    _turn = null;
    _statusTimer?.cancel();
  }

  void _onTurnEvent(AssistantEvent ev) {
    if (!mounted) return;
    switch (ev) {
      case AssistantTurnStarted():
        // 用户消息与 assistant 占位已落库：立即刷新，自己的消息马上上屏
        _reload();
      case AssistantThinkingDelta():
        setState(() => _updateThinkingSegment(ev));
        _scrollToBottom();
      case AssistantTextDelta():
        setState(() => _updateTextSegment(ev.fullText));
        _scrollToBottom();
      case AssistantToolBlockStarted():
        setState(() {
          _sealTextSegment();
          final seg = ChatStreamSegment(
              kind: ChatStreamSegmentKind.tool, startedAt: DateTime.now())
            ..blockIndex = ev.index;
          _segments.add(seg);
        });
        _scrollToBottom();
      case AssistantProposalCreated():
        setState(() => _settleToolSegment(
              index: _blockIndexOfProposal(ev.proposal),
              toolName: ev.proposal.tool,
              summary: ev.proposal.summary,
              status: '待确认',
            ));
        _reload();
      case AssistantToolMessage():
        final failed = ev.content.startsWith('一个动作未能理解');
        setState(() => _settleToolSegment(
              index: ev.blockIndex,
              status: failed ? '未能理解，已跳过' : '已回注',
              detail: ev.content,
              failed: failed,
            ));
        _reload();
      case AssistantTurnDone():
        _finishTurn();
      case AssistantTurnError():
        setState(() => _errorText = ev.message);
        unawaited(_resolveErrorDiag());
        _finishTurn();
    }
  }

  /// 回合结束（done/error）：段落全部落定，退订并重载。
  void _finishTurn() {
    setState(() {
      for (final s in _segments) {
        s.settle();
      }
    });
    _detachTurn();
    _reload();
  }

  /// 状态秒数（思考中 Ns / 执行中 Ns）随时间刷新。
  void _startStatusTimer() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  /// 思考段增量：按 section 对应到独立思考块（一轮可多次思考）。
  void _updateThinkingSegment(AssistantThinkingDelta ev) {
    ChatStreamSegment? seg;
    for (final s in _segments) {
      if (s.kind == ChatStreamSegmentKind.thinking &&
          s.blockIndex == ev.section) {
        seg = s;
        break;
      }
    }
    if (seg == null) {
      // 新思考段开始：先收掉进行中的正文段
      _sealTextSegment();
      seg = ChatStreamSegment(
          kind: ChatStreamSegmentKind.thinking, startedAt: DateTime.now())
        ..blockIndex = ev.section;
      _segments.add(seg);
    }
    seg.text = ev.text;
    if (!ev.active) seg.settle();
  }

  /// 正文段增量（fullText 为全回合累计，按段起点截取当前段）。
  void _updateTextSegment(String fullText) {
    _lastFullText = fullText;
    final seg = _currentTextSeg ??
        () {
          final s = ChatStreamSegment(
              kind: ChatStreamSegmentKind.text, startedAt: DateTime.now());
          _segments.add(s);
          return s;
        }();
    _currentTextSeg = seg;
    final start = _textBaseOffset.clamp(0, fullText.length);
    seg.text = fullText.substring(start);
  }

  /// 思考/工具块插入前收掉当前正文段（后续文本另起新段）。
  void _sealTextSegment() {
    final seg = _currentTextSeg;
    if (seg != null) {
      seg.settle();
      _currentTextSeg = null;
    }
    _textBaseOffset = _lastFullText.length;
  }

  /// 工具块落定：提案落库（待审批）或结果回注/校验失败。
  void _settleToolSegment({
    int? index,
    String? toolName,
    String? summary,
    required String status,
    String? detail,
    bool failed = false,
  }) {
    ChatStreamSegment? seg;
    for (final s in _segments.reversed) {
      if (s.kind == ChatStreamSegmentKind.tool &&
          s.active &&
          (index == null || s.blockIndex == index)) {
        seg = s;
        break;
      }
    }
    seg ??= () {
      final s = ChatStreamSegment(
          kind: ChatStreamSegmentKind.tool, startedAt: DateTime.now())
        ..blockIndex = index ?? 0;
      _segments.add(s);
      return s;
    }();
    seg.toolName = toolName ?? seg.toolName;
    seg.summary = summary ?? seg.summary;
    seg.status = status;
    seg.detail = detail;
    seg.failed = failed;
    seg.settle();
  }

  /// 提案 id 约定 '<chatMessageId>_b<blockIndex>'（proposal_service）。
  int? _blockIndexOfProposal(ChangeProposal p) {
    final i = p.id.lastIndexOf('_b');
    if (i < 0) return null;
    return int.tryParse(p.id.substring(i + 2));
  }

  // ---- 发送 / 取消 / 消息操作 ----

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    final attachments = List<ChatAttachment>.of(_pendingAttachments);
    setState(() {
      _pendingAttachments = [];
      _segments = [];
      _currentTextSeg = null;
      _textBaseOffset = 0;
      _lastFullText = '';
      _errorText = null;
      _errorDiag = null;
    });
    // 草稿附件随消息落库（startTurn 的 attachments 参数），草稿立即清空
    AppDatabase.instance
        .setConversationDraftAttachments(_conversation.id, const []);
    _attachTurn(AssistantService.instance.startTurn(
      conversation: _conversation,
      text: text,
      attachments: attachments,
    ));
  }

  void _cancel() {
    AssistantService.instance.cancelTurn(_conversation.id);
  }

  /// 消息长按操作：复制 / 详情；Agent 回复可重试；用户消息可编辑/撤回。
  void _showMessageActions(ChatMessage m) {
    final isUser = m.role == ChatRole.user;
    final isAssistant = m.role == ChatRole.assistant;
    if (!isUser && !isAssistant) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('复制'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                Clipboard.setData(ClipboardData(text: m.content));
                _showSnack('已复制');
              },
            ),
            if (isAssistant)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('重试'),
                subtitle: Text(
                    _busy ? '等本回合结束后可用' : '删除该回复及其后内容，重新生成',
                    style: const TextStyle(fontSize: 12)),
                onTap: _busy
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        _retry(m);
                      },
              ),
            if (isUser) ...[
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('编辑'),
                subtitle: Text(
                    _busy ? '等本回合结束后可用' : '修改后从此处重新生成回复',
                    style: const TextStyle(fontSize: 12)),
                onTap: _busy
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        _editUserMessage(m);
                      },
              ),
              ListTile(
                leading: const Icon(Icons.undo),
                title: const Text('撤回'),
                subtitle: Text(
                    _busy ? '等本回合结束后可用' : '删除该消息及其后所有内容',
                    style: const TextStyle(fontSize: 12)),
                onTap: _busy
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        _recall(m);
                      },
              ),
            ],
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('详情'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _showMessageDetail(m);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 消息详情（时间戳不常驻消息流，收在这里；assistant-v4-ui §3.7）。
  void _showMessageDetail(ChatMessage m) {
    final rows = <(String, String)>[
      ('时间', _fmtFullTime(m.createdAt)),
      ('角色', m.role == ChatRole.user ? '我' : '助理'),
      ('字数', '${m.content.length}'),
      if (m.attachments.isNotEmpty) ('附件', '${m.attachments.length} 个'),
      if (m.role == ChatRole.assistant) ('模型', _modelLabel),
      if ((_proposalsByBatch[m.id] ?? []).isNotEmpty)
        ('产出提案', '${_proposalsByBatch[m.id]!.length} 条'),
    ];
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('消息详情'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (k, v) in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('$k：$v'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _retry(ChatMessage m) async {
    if (_busy) return;
    setState(() {
      _segments = [];
      _currentTextSeg = null;
      _textBaseOffset = 0;
      _lastFullText = '';
      _errorText = null;
      _errorDiag = null;
    });
    final handle = await AssistantService.instance
        .retryAssistantMessage(_conversation, m.id);
    if (!mounted) return;
    await _reload();
    if (handle != null) _attachTurn(handle);
  }

  /// 错误横幅的「重试」：重跑最后一条 assistant 消息（无则隐藏按钮）。
  Future<void> _retryLast() async {
    for (final m in _messages.reversed) {
      if (m.role == ChatRole.assistant) {
        await _retry(m);
        return;
      }
    }
  }

  Future<void> _editUserMessage(ChatMessage m) async {
    if (_busy) return;
    final controller = TextEditingController(text: m.content);
    final newText = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑消息'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 6,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (newText == null || newText.isEmpty || !mounted) return;
    setState(() {
      _segments = [];
      _currentTextSeg = null;
      _textBaseOffset = 0;
      _lastFullText = '';
      _errorText = null;
      _errorDiag = null;
    });
    final handle = await AssistantService.instance
        .editUserMessage(_conversation, m.id, newText);
    if (!mounted) return;
    await _reload();
    if (handle != null) _attachTurn(handle);
  }

  Future<void> _recall(ChatMessage m) async {
    if (_busy) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('撤回消息'),
        content: const Text('将删除这条消息及其后的所有内容（未处理的提案一并撤销）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('撤回'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await AssistantService.instance.recallUserMessage(_conversation, m.id);
    if (!mounted) return;
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final empty = _messages.isEmpty && !_busy;
    return Scaffold(
      appBar: ChatAppBar(
        title: _conversation.title,
        modelLabel: _modelLabel,
        onModelTap: _switchModel,
        onRename: _rename,
        onExport: _export,
        onClearAndRestart: _clearAndRestart,
        onDelete: _deleteConversation,
      ),
      body: Column(
        children: [
          Expanded(
            child: empty ? _buildEmpty(cs) : _buildMessageList(cs),
          ),
          // F03 Step2（2026-11-03）：草稿含图片时显示「单张成条 + 敏感信息离设备」提示。
          if (_hasScreenshotAttachments) _buildScreenshotsHint(cs),
          ChatInputBar(
            controller: _input,
            busy: _busy,
            attachments: _pendingAttachments,
            metaOf: _metaOf,
            attachmentTokens:
                _pendingAttachments.isEmpty ? null : _pendingAttachmentTokens,
            onRemoveAttachment: _removeAttachment,
            onAddAttachments: _pickAttachments,
            onPickScreenshots: _pickScreenshots,
            onSend: _send,
            onCancel: _cancel,
          ),
        ],
      ),
    );
  }

  /// 空态（§3.8）：引导语 + 情境化建议 chips。
  Widget _buildEmpty(ColorScheme cs) {
    return Column(
      children: [
        const Spacer(),
        Icon(Icons.smart_toy_outlined, size: 48, color: cs.onSurfaceVariant),
        const SizedBox(height: 12),
        Text('有什么可以帮你？',
            style: TextStyle(fontSize: 16, color: cs.onSurfaceVariant)),
        const SizedBox(height: 16),
        if (_suggestions.isNotEmpty)
          SuggestionChips(
            prompts: _suggestions,
            onPick: (p) {
              _input.text = p;
              _send();
            },
          ),
        const Spacer(flex: 2),
      ],
    );
  }

  Widget _buildMessageList(ColorScheme cs) {
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.all(12),
      children: [
        for (final m in _messages) ..._buildMessageWrapped(m, cs),
        if (_busy) _buildStreaming(cs),
        if (_errorText != null) _buildError(cs),
      ],
    );
  }

  /// 搜索命中的消息条：包一层高亮容器并挂定位 Key（§2.3）。
  List<Widget> _buildMessageWrapped(ChatMessage m, ColorScheme cs) {
    final ws = _buildMessage(m, cs);
    if (m.id != _searchHitMessageId || ws.isEmpty) return ws;
    return [
      Container(
        key: _searchHitKey,
        decoration: BoxDecoration(
          color: cs.primaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: ws,
        ),
      ),
    ];
  }

  /// 用户 pill 装饰：实心 primary 圆角泡（右下小角）。
  /// 助理消息为全宽时间线，不再用气泡（assistant-v4-ui §3.3）。
  BoxDecoration _userPillDecoration(ColorScheme cs) => BoxDecoration(
        color: cs.primary,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(4),
        ),
      );

  /// 用户 pill 最大宽度：不超过屏宽 82%（小屏不溢出，大屏不拉满）。
  double _pillMaxWidth(BuildContext context) =>
      (MediaQuery.of(context).size.width * 0.82).clamp(0.0, 560.0);

  static String _fmtFullTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  /// Agent 正文：Markdown 渲染（代码块/引用/列表）；用户消息保持纯文本。
  Widget _messageText(BuildContext context, ChatMessage m, ColorScheme cs) {
    if (m.role == ChatRole.user) {
      return Text(m.content,
          style: TextStyle(fontSize: 16, height: 1.5, color: cs.onPrimary));
    }
    return MarkdownBody(
      data: m.content,
      selectable: true,
      softLineBreak: true,
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(fontSize: 16, height: 1.6, color: cs.onSurface),
        h1: TextStyle(
            fontSize: 20, fontWeight: FontWeight.w700, color: cs.onSurface),
        h2: TextStyle(
            fontSize: 18, fontWeight: FontWeight.w700, color: cs.onSurface),
        h3: TextStyle(
            fontSize: 17, fontWeight: FontWeight.w600, color: cs.onSurface),
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          color: cs.onSurface,
          backgroundColor: cs.surfaceContainerHighest,
        ),
        codeblockPadding: const EdgeInsets.all(10),
        codeblockDecoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        blockquotePadding: const EdgeInsets.symmetric(horizontal: 10),
        blockquoteDecoration: BoxDecoration(
          border: Border(
              left: BorderSide(color: cs.outlineVariant, width: 3)),
        ),
        listBullet: TextStyle(fontSize: 16, color: cs.onSurface),
        tableBorder: TableBorder.all(color: cs.outlineVariant),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: cs.outlineVariant)),
        ),
      ),
    );
  }

  List<Widget> _buildMessage(ChatMessage m, ColorScheme cs) {
    final isUser = m.role == ChatRole.user;
    final isTool = m.role == ChatRole.tool;
    // 工具消息：渲染为可展开/收起的工具块（历史默认收起），全宽
    if (isTool) {
      final failed = m.content.startsWith('一个动作未能理解');
      final seg = ChatStreamSegment(
          kind: ChatStreamSegmentKind.tool,
          startedAt: DateTime.fromMillisecondsSinceEpoch(m.createdAt))
        ..active = false
        ..endedAt = DateTime.fromMillisecondsSinceEpoch(m.createdAt)
        ..summary = '工具回注'
        ..status = failed ? '未能理解，已跳过' : '已回注'
        ..failed = failed
        ..detail = m.content
        ..expanded = _expandedToolMsgIds.contains(m.id);
      return [
        ToolCallBlock(
          segment: seg,
          onToggle: () => setState(() {
            if (!_expandedToolMsgIds.remove(m.id)) {
              _expandedToolMsgIds.add(m.id);
            }
          }),
        ),
      ];
    }
    final widgets = <Widget>[];
    if (isUser) {
      // 用户消息：右对齐 pill；附件卡栈在 pill 下方独立成行
      widgets.add(Align(
        alignment: Alignment.centerRight,
        child: GestureDetector(
          onLongPress: () => _showMessageActions(m),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            constraints: BoxConstraints(maxWidth: _pillMaxWidth(context)),
            decoration: _userPillDecoration(cs),
            child: m.content.isNotEmpty
                ? _messageText(context, m, cs)
                : const SizedBox.shrink(),
          ),
        ),
      ));
      if (m.attachments.isNotEmpty) {
        widgets.add(Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: _pillMaxWidth(context)),
            child: AttachmentCardStack(
              attachments: m.attachments,
              metaOf: _metaOf,
            ),
          ),
        ));
      }
    } else {
      // 助理消息：全宽时间线，无气泡
      widgets.add(GestureDetector(
        onLongPress: () => _showMessageActions(m),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (m.content.isNotEmpty) _messageText(context, m, cs),
              if (m.status == ChatMessageStatus.error)
                Text('（本回合出错）',
                    style: TextStyle(fontSize: 11, color: cs.error)),
              if (m.attachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: AttachmentCardStack(
                    attachments: m.attachments,
                    metaOf: _metaOf,
                  ),
                ),
            ],
          ),
        ),
      ));
    }
    // 提案卡片内联：挂在产出它们的 assistant 消息后面
    final proposals = _proposalsByBatch[m.id];
    if (proposals != null) {
      for (final p in proposals) {
        widgets.add(_buildProposalCard(p));
      }
    }
    return widgets;
  }

  Widget _buildProposalCard(ChangeProposal p) {
    return ProposalCard(
      proposal: p,
      density: ProposalCardDensity.compact,
      onGoToApprovals: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ApprovalsPage()),
        );
        await _reload();
      },
    );
  }

  /// 流式区：按分段渲染——思考块/工具块（状态 + 可展开收起）、
  /// 正文段直接显示（淡入 + 按住末尾两词）；活动中的尾部文本段
  /// 末尾挂呼吸圆点光标。全宽时间线（与落定的助理消息同一形态）。
  Widget _buildStreaming(ColorScheme cs) {
    ChatStreamSegment? lastText;
    for (final s in _segments.reversed) {
      if (s.kind == ChatStreamSegmentKind.text) {
        lastText = s;
        break;
      }
    }
    final cursorInText = lastText != null && lastText.active;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final seg in _segments)
            switch (seg.kind) {
              ChatStreamSegmentKind.text => FadeInStreamingText(
                  text: seg.text,
                  settled: !seg.active,
                  showCursor: identical(seg, lastText) && cursorInText,
                ),
              ChatStreamSegmentKind.thinking => ThinkingBlock(
                  segment: seg,
                  onToggle: () =>
                      setState(() => seg.expanded = !seg.expanded),
                ),
              ChatStreamSegmentKind.tool => ToolCallBlock(
                  segment: seg,
                  onToggle: () =>
                      setState(() => seg.expanded = !seg.expanded),
                ),
            },
          // 回合进行中但尾部不是正文段（思考中/工具中/等首个 token）：
          // 光标单独成行
          if (!cursorInText)
            const Padding(
              padding: EdgeInsets.only(top: 6, left: 2),
              child: BreathingDot(),
            ),
        ],
      ),
    );
  }

  /// 解析当前生效端点的持久化诊断（§5.3）：绑定接口优先，否则默认路由的
  /// 远程接口；有上次失败记录时在错误横幅里补一行，与选择器/向导读同一份。
  Future<void> _resolveErrorDiag() async {
    String? diag;
    try {
      final ai = AiClient.instance;
      final boundId = _conversation.modelConfigId;
      AiEndpoint? endpoint;
      if (boundId != null && boundId.isNotEmpty) {
        for (final e in await ai.getRemoteEndpoints()) {
          if (e.id == boundId) {
            endpoint = e;
            break;
          }
        }
      } else {
        endpoint = await ai.defaultRemoteEndpoint();
      }
      final err = endpoint?.lastError;
      if (endpoint != null && err != null && err.isNotEmpty) {
        diag = '端点「${endpoint.name}」上次测试：$err';
      }
    } catch (_) {
      // 诊断是锦上添花，读取失败不影响主错误文案
    }
    if (!mounted || diag == null) return;
    setState(() => _errorDiag = diag);
  }

  Widget _buildError(ColorScheme cs) {
    final canRetry =
        _messages.any((m) => m.role == ChatRole.assistant);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 16, color: cs.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text('回合出错：$_errorText',
                    style:
                        TextStyle(fontSize: 12, color: cs.onErrorContainer)),
              ),
              if (canRetry)
                TextButton(
                  onPressed: _busy ? null : _retryLast,
                  child: const Text('重试'),
                ),
            ],
          ),
          if (_errorDiag != null)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 2),
              child: Text(_errorDiag!,
                  style:
                      TextStyle(fontSize: 12, color: cs.onErrorContainer)),
            ),
        ],
      ),
    );
  }
}
