import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/conversation.dart';
import '../../services/ai_client.dart';
import '../../services/assistant/assistant_client.dart';
import '../../services/assistant/assistant_service.dart';
import '../../services/database.dart';
import 'approvals_page.dart';
import 'demo/assistant_components_demo_page.dart';
import 'chat_page.dart';
import 'conversation_export.dart';
import 'model_picker.dart';
import 'widgets/assistant_loading_indicator.dart';
import 'widgets/assistant_logo.dart';
import 'widgets/streaming_blocks.dart';

/// 通道状态（assistant-v4-ui §2.2 状态点，全助理域同一语义）：
/// online = LinkModel 在线（绿）；standby = 远程/离线待命（灰）；
/// broken = 配置失效或端点最近测试失败（红）。
enum ChannelStatus { online, standby, broken }

/// 对话绑定模型的通道状态判定（纯函数便于单测）。
ChannelStatus conversationChannelStatus({
  required String? modelConfigId,
  required bool desktopOnline,
  required bool isKnownDesktopModel,
  required AiEndpoint? boundRemote,
  required bool hasDefaultRemote,
}) {
  final id = modelConfigId ?? '';
  if (id.isEmpty) {
    if (desktopOnline) return ChannelStatus.online;
    return hasDefaultRemote ? ChannelStatus.standby : ChannelStatus.broken;
  }
  if (boundRemote != null) {
    return boundRemote.lastError != null
        ? ChannelStatus.broken
        : ChannelStatus.standby;
  }
  // 绑定的是桌面模型：在线绿；离线时无法确认，按待命灰（不是失效）
  if (isKnownDesktopModel || !desktopOnline) {
    return desktopOnline ? ChannelStatus.online : ChannelStatus.standby;
  }
  return ChannelStatus.broken; // 桌面在线但模型列表里已没有 → 失效
}

/// 相对时间（§2.2）：当天 HH:mm、昨天、N 天前（<7）、更早 MM-dd。
String relativeConversationTime(int ms, DateTime now) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  final diff = DateTime(now.year, now.month, now.day)
      .difference(DateTime(d.year, d.month, d.day))
      .inDays;
  if (diff <= 0) return '${two(d.hour)}:${two(d.minute)}';
  if (diff == 1) return '昨天';
  if (diff < 7) return '$diff 天前';
  return '${two(d.month)}-${two(d.day)}';
}

/// 命中片段高亮（§2.3）：把 text 按 query（大小写不敏感）切段，
/// 命中段套 hitStyle。空 query 原样返回。
List<TextSpan> highlightSpans(String text, String query, TextStyle hitStyle) {
  if (query.isEmpty) return [TextSpan(text: text)];
  final spans = <TextSpan>[];
  var rest = text;
  final lowerQuery = query.toLowerCase();
  while (true) {
    final idx = rest.toLowerCase().indexOf(lowerQuery);
    if (idx < 0) {
      spans.add(TextSpan(text: rest));
      break;
    }
    if (idx > 0) spans.add(TextSpan(text: rest.substring(0, idx)));
    spans.add(TextSpan(
        text: rest.substring(idx, idx + query.length), style: hitStyle));
    rest = rest.substring(idx + query.length);
  }
  return spans;
}

/// B43：助理页一次数据快照（首次加载的新旧判定与串行保护用的载体）。
///
/// 生产由 DB / AI 的既有 await 顺序填充；测试可经
/// [ConversationsPageState.debugLoaderOverride] 注入可控数据。
class ConversationsLoadResult {
  const ConversationsLoadResult({
    required this.conversations,
    this.pendingCounts = const {},
    this.desktopOnline = false,
    this.remotesById = const {},
    this.desktopModelNames = const {},
    this.defaultEndpointId,
  });

  final List<Conversation> conversations;
  final Map<String, int> pendingCounts;
  final bool desktopOnline;
  final Map<String, AiEndpoint> remotesById;
  final Map<String, String> desktopModelNames;
  final String? defaultEndpointId;
}

/// 助理主 Tab（design-v3 §5.1 → assistant-v4-ui §2）：
/// 对话列表（搜索/置顶/三态副标题/状态点/左滑手势），
/// AppBar 一级入口：搜索、待确认区（角标）、模型配置。
/// 2026-11-01 多 Agent 并行：在途回合的对话在列表里指示工作状态
/// （阶段 + 呼吸圆点 + 秒数），回合由服务自持、跨页面存活。
class ConversationsPage extends StatefulWidget {
  const ConversationsPage({super.key});

  @override
  State<ConversationsPage> createState() => ConversationsPageState();
}

class ConversationsPageState extends State<ConversationsPage> {
  List<Conversation> _conversations = [];
  Map<String, int> _pendingCounts = {};
  bool _desktopOnline = false;
  Map<String, AiEndpoint> _remotesById = {};
  Map<String, String> _desktopModelNames = {};
  String? _defaultEndpointId;

  bool _searching = false;
  final _searchCtrl = TextEditingController();
  List<ConversationSearchHit>? _searchHits;

  /// 有在途回合时每秒刷新一次副标题秒数；没有在途回合不挂定时器。
  Timer? _ticker;

  // ---- B43 首次加载动画（用户 2026-11-22 双重批准：T=800ms，opacity 0.35–1）----

  /// 首次加载延迟显示阈值：极短加载不闪屏（用户已批准 200ms）。
  static const Duration _loadingDelay = Duration(milliseconds: 200);

  /// 首次加载尚未完成（一旦完成即永久置 false：后续 reload 保留列表、不闪空白）。
  bool _initialLoadPending = true;

  /// 延迟计时到点后是否显示加载指示。
  bool _showLoading = false;

  /// 首次加载的 200ms 延迟计时器。
  Timer? _loadingTimer;

  /// reload 串行号：旧请求完成时若号已变，则不覆盖新快照。
  int _reloadSerial = 0;

  /// 测试注入点：非 null 时 `reload()` 用它替代真实 DB/AI 读取（生产恒为 null）。
  @visibleForTesting
  static Future<ConversationsLoadResult> Function()? debugLoaderOverride;

  @override
  void initState() {
    super.initState();
    // 在途回合的开始/阶段变化/结束都会 bump turnsVersion
    AssistantService.instance.turnsVersion.addListener(_onTurnsChange);
    reload();
  }

  @override
  void dispose() {
    AssistantService.instance.turnsVersion.removeListener(_onTurnsChange);
    _reloadSerial++; // 让在途请求失效
    _loadingTimer?.cancel();
    _ticker?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onTurnsChange() {
    if (mounted) setState(() {});
    _syncTicker();
  }

  void _syncTicker() {
    final anyActive = _conversations
        .any((c) => AssistantService.instance.turnOf(c.id) != null);
    if (anyActive && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!anyActive) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// 读取一次列表快照（DB / AI 的既有 await 顺序保持不变）。
  ///
  /// B43：每个 await 之后都检查 mounted 与串行号 —— 旧请求不再写 UI，
  /// 也不会覆盖更新的快照。返回 null 表示本次已被更新的请求取代。
  Future<ConversationsLoadResult?> _loadFromServices(int serial) async {
    final db = AppDatabase.instance;
    final ai = AiClient.instance;
    bool stale() => !mounted || serial != _reloadSerial;

    final list = await db.getConversations();
    if (stale()) return null;
    final pending = await db.pendingProposalCountsByConversation();
    if (stale()) return null;
    final remotes = await ai.getRemoteEndpoints();
    if (stale()) return null;
    final defaultId = await ai.getDefaultEndpointId();
    if (stale()) return null;
    final online = await ai.isDesktopOnline();
    if (stale()) return null;
    Map<String, String> desktopNames = {};
    if (online) {
      try {
        final r = await AssistantClient.instance.getDesktopModels();
        desktopNames = {for (final m in r.models) m.id: m.name};
      } catch (_) {
        // 模型名只是副标题展示，拉取失败按「LinkModel 模型」兜底
      }
      if (stale()) return null;
    }
    return ConversationsLoadResult(
      conversations: list,
      pendingCounts: pending,
      desktopOnline: online,
      remotesById: {for (final e in remotes) e.id: e},
      desktopModelNames: desktopNames,
      defaultEndpointId: defaultId,
    );
  }

  Future<void> reload() async {
    final serial = ++_reloadSerial;
    if (_initialLoadPending) _armLoadingTimer(serial);
    try {
      final result = debugLoaderOverride != null
          ? await debugLoaderOverride!()
          : await _loadFromServices(serial);
      if (result == null || !mounted || serial != _reloadSerial) return;
      setState(() {
        _conversations = result.conversations;
        _pendingCounts = result.pendingCounts;
        _desktopOnline = result.desktopOnline;
        _remotesById = result.remotesById;
        _desktopModelNames = result.desktopModelNames;
        _defaultEndpointId = result.defaultEndpointId;
        _initialLoadPending = false;
        _showLoading = false;
      });
      _loadingTimer?.cancel();
      _loadingTimer = null;
      _syncTicker();
    } finally {
      // 异常/提前返回：结束「最新」那次加载态并取消计时器，避免永久空白；
      // 旧请求（serial 已变）不动新请求的状态。异常本身仍向上抛（不吞错）。
      if (mounted && serial == _reloadSerial && _initialLoadPending) {
        _loadingTimer?.cancel();
        _loadingTimer = null;
        setState(() {
          _initialLoadPending = false;
          _showLoading = false;
        });
        _syncTicker();
      }
    }
  }

  /// 首次加载：延迟 [_loadingDelay] 后，若仍是最新请求且尚未完成，才显示加载指示。
  void _armLoadingTimer(int serial) {
    _loadingTimer?.cancel();
    _loadingTimer = Timer(_loadingDelay, () {
      if (!mounted || serial != _reloadSerial || !_initialLoadPending) return;
      setState(() => _showLoading = true);
    });
  }

  // ---- 动作 ----

  Future<void> _newConversation() async {
    final conv = await AssistantService.instance.createConversation();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatPage(conversation: conv)),
    );
    await reload();
  }

  Future<void> _open(Conversation conv) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatPage(conversation: conv)),
    );
    await reload();
  }

  Future<void> _rename(Conversation conv) async {
    final controller = TextEditingController(text: conv.title);
    final saved = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名对话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '标题'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == null || saved.isEmpty) return;
    await AppDatabase.instance.renameConversation(conv.id, saved);
    await reload();
  }

  Future<void> _togglePin(Conversation conv) async {
    await AppDatabase.instance.setConversationPinned(conv.id, !conv.pinned);
    await reload();
  }

  Future<void> _export(Conversation conv) async {
    try {
      final name = await exportConversationToMarkdown(conv);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('已导出到文件区：$name'),
            duration: const Duration(seconds: 2)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('导出失败：$e'), duration: const Duration(seconds: 2)));
      }
    }
  }

  Future<bool> _confirmDelete(Conversation conv) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除对话'),
        content: Text('删除「${conv.title}」？其待确认提案会保留在待确认区。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              // F3 §3.1-4：破坏性操作确认 = 一次重振
              HapticFeedback.heavyImpact();
              Navigator.of(context).pop(true);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return confirm == true;
  }

  Future<void> _deleteConfirmed(Conversation conv) async {
    await AppDatabase.instance.deleteConversation(conv.id);
    await reload();
  }

  void _showContextMenu(Conversation conv) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重命名'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _rename(conv);
              },
            ),
            ListTile(
              leading:
                  Icon(conv.pinned ? Icons.push_pin_outlined : Icons.push_pin),
              title: Text(conv.pinned ? '取消置顶' : '置顶'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _togglePin(conv);
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share_outlined),
              title: const Text('导出对话'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _export(conv);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(sheetContext).colorScheme.error),
              title: Text('删除',
                  style: TextStyle(
                      color: Theme.of(sheetContext).colorScheme.error)),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                if (await _confirmDelete(conv)) {
                  await _deleteConfirmed(conv);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---- 搜索（§2.3） ----

  void _setSearching(bool v) {
    setState(() {
      _searching = v;
      if (!v) {
        _searchCtrl.clear();
        _searchHits = null;
      }
    });
  }

  Future<void> _runSearch(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _searchHits = null);
      return;
    }
    final hits = await AppDatabase.instance.searchConversations(q);
    // 晚返回的结果不得覆盖更新的查询
    if (mounted && _searching && _searchCtrl.text == q) {
      setState(() => _searchHits = hits);
    }
  }

  // ---- UI ----

  String _modelName(Conversation c) {
    final id = c.modelConfigId ?? '';
    if (id.isEmpty) return '默认模型';
    final ep = _remotesById[id];
    if (ep != null) return ep.name;
    final desktop = _desktopModelNames[id];
    if (desktop != null) return desktop;
    return _desktopOnline ? '配置已失效' : 'LinkModel 模型';
  }

  ChannelStatus _channelStatus(Conversation c) => conversationChannelStatus(
        modelConfigId: c.modelConfigId,
        desktopOnline: _desktopOnline,
        isKnownDesktopModel: _desktopModelNames.containsKey(c.modelConfigId),
        boundRemote: _remotesById[c.modelConfigId],
        hasDefaultRemote: _defaultEndpointId != null,
      );

  Color _channelColor(ChannelStatus s, ColorScheme cs) => switch (s) {
        ChannelStatus.online => Colors.green.shade600,
        ChannelStatus.standby => cs.onSurfaceVariant,
        ChannelStatus.broken => cs.error,
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final totalPending = _pendingCounts.values.fold<int>(0, (a, b) => a + b);
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索对话标题与消息内容',
                  border: InputBorder.none,
                ),
                onChanged: _runSearch,
              )
            : const Text('助理'),
        actions: [
          if (_searching)
            IconButton(
              tooltip: '退出搜索',
              icon: const Icon(Icons.close),
              onPressed: () => _setSearching(false),
            )
          else ...[
            IconButton(
              tooltip: '搜索',
              icon: const Icon(Icons.search),
              onPressed: () => _setSearching(true),
            ),
            IconButton(
              tooltip: '待确认区',
              icon: Badge(
                label: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: Text('$totalPending', key: ValueKey(totalPending)),
                ),
                isLabelVisible: totalPending > 0,
                child: const Icon(Icons.fact_check_outlined),
              ),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ApprovalsPage()),
              ),
            ),
            IconButton(
              tooltip: '模型配置',
              icon: const Icon(Icons.model_training),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ModelPickerPage()),
              ),
            ),
            // F31：组件展示页入口（debug/调试用）
            IconButton(
              tooltip: '组件展示',
              icon: const Icon(Icons.widgets_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const AssistantComponentsDemoPage()),
              ),
            ),
          ],
        ],
      ),
      body: _searching ? _buildSearchResults(cs) : _buildList(cs),
      // B43：首次加载未完成时（含 0–200ms 与 >200ms 两段）不显示新建引导 ——
      // 用户批准的加载逻辑要求「加载中不出现空态/新建引导」；完成后恢复。
      floatingActionButton: (_searching || _initialLoadPending)
          ? null
          : FloatingActionButton(
              // B44：与库页/任务页 FAB 并存，无共享元素转场 → 显式 null
              heroTag: null,
              tooltip: '新建对话',
              onPressed: _newConversation,
              child: const Icon(Icons.add),
            ),
    );
  }

  Widget _buildList(ColorScheme cs) {
    if (_showLoading) {
      // B43：首次加载（延迟 200ms 后才出现）。加载中不出现空态文案/新建引导。
      return const AssistantLoadingIndicator();
    }
    if (_initialLoadPending) {
      // 首次加载的 0–200ms 窗口：不显示任何内容，避免先闪一下「无任何会话」空态。
      return const SizedBox.shrink();
    }
    if (_conversations.isEmpty) {
      // 标准空态（§2.1）
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // F45：新双星（48px，空态用 onSurfaceVariant）。
            AssistantLogo(size: 48, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('和助理一起整理你的库', style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _newConversation,
              icon: const Icon(Icons.add),
              label: const Text('新建对话'),
            ),
          ],
        ),
      );
    }
    final pinned = _conversations.where((c) => c.pinned).toList();
    final rest = _conversations.where((c) => !c.pinned).toList();
    final twoSections = pinned.isNotEmpty && rest.isNotEmpty;
    return ListView(
      children: [
        if (twoSections) _sectionHeader('置顶', cs),
        for (final c in pinned) _buildTile(c, cs),
        if (twoSections) _sectionHeader('全部', cs),
        for (final c in rest) _buildTile(c, cs),
      ],
    );
  }

  Widget _sectionHeader(String text, ColorScheme cs) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      );

  Widget _buildTile(Conversation c, ColorScheme cs) {
    return Dismissible(
      key: ValueKey('conv:${c.id}'),
      // 右滑 = 置顶/取消置顶（确认后弹回，不删条目）；左滑 = 删除（确认 dialog）。
      // F3 §3.1-3：触发距离标定为行宽 40%，途中可回弹取消
      dismissThresholds: const {
        DismissDirection.startToEnd: 0.4,
        DismissDirection.endToStart: 0.4,
      },
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          await _togglePin(c);
          return false;
        }
        return _confirmDelete(c);
      },
      onDismissed: (_) => _deleteConfirmed(c),
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 16),
        color: cs.primaryContainer,
        child: Icon(c.pinned ? Icons.push_pin_outlined : Icons.push_pin,
            color: cs.onPrimaryContainer),
      ),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: cs.errorContainer,
        child: Icon(Icons.delete_outline, color: cs.onErrorContainer),
      ),
      child: ListTile(
        leading: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _channelColor(_channelStatus(c), cs),
            ),
          ),
        ),
        title: Row(
          children: [
            Flexible(
              child:
                  Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (c.pinned) ...[
              const SizedBox(width: 4),
              Icon(Icons.push_pin, size: 14, color: cs.onSurfaceVariant),
            ],
          ],
        ),
        subtitle: _buildSubtitle(c, cs),
        onTap: () => _open(c),
        onLongPress: () => _showContextMenu(c),
      ),
    );
  }

  /// 副标题三态（§2.2）：在途回合 > 待审批 > 模型名 · 相对时间。
  Widget? _buildSubtitle(Conversation c, ColorScheme cs) {
    final turn = AssistantService.instance.turnOf(c.id);
    if (turn != null) {
      final secs = DateTime.now().difference(turn.startedAt).inSeconds;
      return Row(
        children: [
          const BreathingDot(size: 6),
          const SizedBox(width: 6),
          Text('${turnPhaseLabel(turn.phase.value)} ${secs}s',
              style: TextStyle(
                  fontSize: 12,
                  color: cs.primary,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      );
    }
    final pending = _pendingCounts[c.id] ?? 0;
    if (pending > 0) {
      return Text('◔ $pending 项待你审批',
          style: TextStyle(fontSize: 12, color: Colors.amber.shade800));
    }
    return Text(
        '${_modelName(c)} · ${relativeConversationTime(c.updatedAt, DateTime.now())}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant));
  }

  Widget _buildSearchResults(ColorScheme cs) {
    final q = _searchCtrl.text.trim();
    final hitStyle = TextStyle(color: cs.primary, fontWeight: FontWeight.w600);
    if (q.isEmpty) {
      return Center(
        child: Text('输入关键字，匹配对话标题与消息全文',
            style: TextStyle(color: cs.onSurfaceVariant)),
      );
    }
    final hits = _searchHits;
    if (hits == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (hits.isEmpty) {
      return Center(
        child:
            Text('没有找到「$q」相关的内容', style: TextStyle(color: cs.onSurfaceVariant)),
      );
    }
    return ListView(
      children: [
        for (final h in hits)
          ListTile(
            leading: Icon(
                h.matchedMessageId == null
                    ? Icons.chat_bubble_outline
                    : Icons.format_quote,
                color: cs.onSurfaceVariant),
            title: Text.rich(
              TextSpan(
                  children: highlightSpans(h.conversation.title, q, hitStyle)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: h.snippet != null
                ? Text.rich(
                    TextSpan(children: highlightSpans(h.snippet!, q, hitStyle)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  )
                : Text(
                    relativeConversationTime(
                        h.conversation.updatedAt, DateTime.now()),
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ChatPage(
                    conversation: h.conversation,
                    initialScrollToMessageId: h.matchedMessageId,
                  ),
                ),
              );
              await reload();
            },
          ),
      ],
    );
  }
}
