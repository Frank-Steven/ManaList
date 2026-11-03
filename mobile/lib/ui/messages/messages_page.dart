import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../models/task.dart';
import '../../services/anchor_service.dart';
import '../../services/assistant/models.dart';
import '../../services/database.dart';
import '../../services/notification_bridge.dart';
import '../../services/undo_service.dart';
import '../add_message_page.dart';
import '../assistant/attachment_pick_controller.dart';
import '../assistant/send_to_assistant.dart';
import '../shared/app_icon.dart';
import '../tasks/task_editor.dart';
import 'archived_page.dart';
import 'message_detail_sheet.dart';
import 'message_widgets.dart';
import '../../services/app_log.dart';
import '../../services/app_ui_state.dart';
import '../../services/fold_markers.dart';

/// v2 消息主列表页（设计 §5.1）：分组吸顶列表 + Chip 筛选行 + 左滑块状菜单
/// + 多选批量操作。归档消息在独立页面（ArchivedMessagesPage）。
/// ui-structure §3 收编：本页不持有 AppBar（由库页容器统一持有）；
/// 多选态的「已选/全选/退出」从 AppBar 降级为内容首行工具条（§4 分区级操作）。
class MessagesPage extends StatefulWidget {
  const MessagesPage({
    super.key,
    this.onSelectionChanged,
    this.pickMode = false,
    this.pickController,
  });

  /// 多选态变化回调：库页容器用来在多选时隐藏 FAB（避免遮挡底部操作条）。
  final ValueChanged<bool>? onSelectionChanged;

  /// 附件选择模式（2026-11-01）：复用本页的多选/筛选器/分类展开，
  /// 选择状态写入 [pickController]（跨分区累积），底部操作条由
  /// 附件选择页统一提供（已选附件列表 + 确认按钮），本页不再渲染操作菜单。
  final bool pickMode;
  final AttachmentPickController? pickController;

  @override
  State<MessagesPage> createState() => MessagesPageState();
}

class MessagesPageState extends State<MessagesPage> {
  final AppDatabase _db = AppDatabase.instance;

  List<Message> _messages = [];
  List<SourceApp> _sources = [];

  /// 全部任务 id → Task（v2.6：绑定消息显示任务优先级色点；
  /// 兼作 v2.4「已完成」筛选与行划线样式数据源）。
  Map<String, Task> _tasksById = {};

  /// messageId → 锚点任务 id 列表（v8 任务锚点）
  Map<String, List<String>> _taskLinks = {};
  bool _loading = true;

  /// 展示分组多选筛选（默认全选；2026-11-01 四分组：未处理/未完成/完成/垃圾）。
  final Set<String> _groupFilter = Set.of(kDisplayGroupOrder);

  /// 应用多选筛选（2026-11-01 下拉复选；空集 = 全部应用）。
  final Set<String> _appFilter = {};

  bool _selecting = false;
  final Set<String> _selected = {};

  /// 各最小分类单元（非聊天来源 / 会话）当前展示的条数
  /// （2026-11-01 分组分页：首屏 10 条，点「显示更多」每次 +5）。
  final Map<String, int> _shownCounts = {};

  /// F02 两级折叠的展开状态（默认全部折叠；只存本页 State，不持久化）。
  /// 一级 = 来源应用（key = packageName）；二级 = 会话（key = packageName + NUL + 会话名，
  /// 仅聊天类来源才有二级）。
  final Set<String> _expandedSources = {};
  final Set<String> _expandedConversations = {};

  /// 通知监听权限（v2.5：null=未知；false 时顶部显示恢复引导横幅）。
  bool? _listenerEnabled;

  StreamSubscription<int>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = NotificationBridge.instance.onNewMessages.listen((_) => reload());
    // pick 模式：本地 _selected 是控制器（唯一事实源）的镜像
    if (widget.pickMode) {
      widget.pickController?.addListener(_syncFromPick);
      _syncFromPick();
    }
    reload();
  }

  @override
  void dispose() {
    if (widget.pickMode) {
      widget.pickController?.removeListener(_syncFromPick);
    }
    _sub?.cancel();
    super.dispose();
  }

  AttachmentPickController? get _pick =>
      widget.pickMode ? widget.pickController : null;

  /// pick 模式：控制器 → 本地多选态回同步（底栏 chip 移除等外部变化）。
  void _syncFromPick() {
    final pick = _pick;
    if (pick == null || !mounted) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(pick
            .idsOfType(ChatAttachmentType.message)
            .where((id) => _messages.any((m) => m.id == id)));
      if (_selected.isEmpty) _selecting = false;
    });
  }

  /// 角标 = DB 里的未处理条数（与页面筛选无关，后台也会被调用）。
  Future<void> _updateBadge() async {
    try {
      final n = await _db.countMessages(status: MessageStatus.pending);
      if (!mounted) return;
      MessageBadges.instance.setPending(n);
    } catch (e, st) {
      AppLog.instance.warn('messages.badge', e, st);
    }
  }

  /// 重新加载列表（供 GlobalKey 外部触发）。
  /// v2.5：消息与来源是关键路径；任务表（绑定色点/状态分组/划线用）
  /// 失败不阻塞列表展示——此前三者同处一个 Future.wait，任一路失败会让列表
  /// 永远停在「加载中…」（表现为"消息抓取失效"）。
  /// 2026-11-01：取消全局 500 条上限，改为分组内分页（每组首屏 10 条、
  /// 「显示更多」每次 +5）；应用筛选为多选，本地过滤不再走 SQL。
  Future<void> reload() async {
    try {
      final results = await Future.wait([
        // 大上限 ≈ 全量：分组分页后不再靠全局限额控制内存
        _db.getMessages(limit: 100000),
        _db.getDistinctMessageSources(),
        _db.messageAnchorTaskIds(),
      ]);
      if (!mounted) return;
      setState(() {
        _messages = (results[0] as List<Message>)
            .where((m) => m.status != MessageStatus.archived)
            .where((m) =>
                _appFilter.isEmpty || _appFilter.contains(m.packageName))
            .toList();
        _sources = results[1] as List<SourceApp>;
        _taskLinks = results[2] as Map<String, List<String>>;
        _loading = false;
        // 所选应用的消息可能已不存在，从筛选集里剔除
        _appFilter.removeWhere(
            (pkg) => !_sources.any((s) => s.packageName == pkg));
        _selected.removeWhere((id) => !_messages.any((m) => m.id == id));
        if (_selected.isEmpty) _selecting = false;
      });
      // pick 模式：为已选条目补充显示名（底栏 chip 用）
      final pick = _pick;
      if (pick != null) {
        for (final m in _messages) {
          if (pick.isSelected(ChatAttachmentType.message, m.id)) {
            pick.registerMeta(
                ChatAttachmentType.message, m.id, m.title, Icons.mail_outline);
          }
        }
      }
      widget.onSelectionChanged?.call(_selecting);
    } catch (e, st) {
      AppLog.instance.warn('messages.reload', e, st);
      if (mounted) setState(() => _loading = false);
    }
    // 尽力加载：任务表（绑定消息的优先级色点 +「已完成」筛选/划线）
    try {
      final tasks = await _db.getTasks();
      if (!mounted) return;
      setState(() => _tasksById = {for (final t in tasks) t.id: t});
    } catch (e, st) { AppLog.instance.warn('messages.done-tasks', e, st); }
    // 通知监听权限状态（v2.5：丢失时页面顶部给恢复引导）
    try {
      final enabled = await NotificationBridge.instance.isListenerEnabled();
      if (mounted) setState(() => _listenerEnabled = enabled);
    } catch (e, st) { AppLog.instance.warn('messages.listener-state', e, st); }
    // U19-B：更新底部导航「消息」角标（取 DB 的未处理数，不受页面 500 条上限影响）
    await _updateBadge();
  }

  /// 某条消息锚点连接的任务 id（v8）：优先锚点表，回退历史只读旧列。
  List<String> _linkedTaskIds(Message m) {
    final ids = _taskLinks[m.id];
    if (ids != null && ids.isNotEmpty) return ids;
    final single = m.linkedTaskId;
    return (single == null || single.isEmpty) ? const [] : [single];
  }

  /// 关联任务**全部**完成（2026-11-01 状态新规：消息「完成」的口径；
  /// 行划线同口径——有未完成任务时不划线）。无关联任务返回 false。
  bool _isLinkedDone(Message m) {
    final ids = _linkedTaskIds(m);
    return ids.isNotEmpty &&
        ids.every((id) => _tasksById[id]?.status == TaskStatus.done);
  }

  /// 展示分组键（2026-11-01 状态新规）：未处理 / 未完成 / 完成 / 垃圾。
  String _displayKey(Message m) => messageDisplayGroupKey(m,
      linkedTaskCount: _linkedTaskIds(m).length,
      linkedAllDone: _isLinkedDone(m));

  /// 主关联任务的优先级（决定消息卡色点）。
  String? _linkedTaskPriority(Message m) {
    final ids = _linkedTaskIds(m);
    if (ids.isEmpty) return null;
    return _tasksById[ids.first]?.priority;
  }

  // 分组结果缓存（2026-10-20 性能）：原来每次 setState（多选一行、折叠、切 chip）
  // 都重跑「全量过滤 + 分组 List 分配」；500 条时每帧都是 O(n) 分配。
  List<Message>? _visibleCache;
  List<_SourceGroup>? _sourceCache;

  /// 二级（会话）分组缓存：来源 key → 会话组。
  /// **只有该来源被展开且是聊天类时才计算**，一级折叠时不建二级，
  /// 展开成本是「该来源的条数」而不是全表，整体仍是 O(n) 而非 O(n²)。
  final Map<String, List<_ConversationGroup>> _conversationCache = {};
  Object? _cacheKeyMessages;
  Object? _cacheKeyTasks;
  Set<String>? _cacheKeyFilter;

  bool _cachesFresh() =>
      _visibleCache != null &&
      identical(_cacheKeyMessages, _messages) &&
      identical(_cacheKeyTasks, _tasksById) &&
      setEquals(_cacheKeyFilter, _groupFilter);

  List<Message> get _visible {
    final cached = _visibleCache;
    if (cached != null && _cachesFresh()) return cached;
    final visible =
        _messages.where((m) => _groupFilter.contains(_displayKey(m))).toList();
    _visibleCache = visible;
    _sourceCache = null;
    _conversationCache.clear();
    _cacheKeyMessages = _messages;
    _cacheKeyTasks = _tasksById;
    _cacheKeyFilter = Set.of(_groupFilter);
    return visible;
  }

  /// 条数 / 最新时间 / 未处理数（两级组头共用口径）。
  /// 「未处理」与顶部 chip 同口径：展示分组键 == pending。
  (int, int, int) _groupStats(List<Message> msgs) {
    var latest = 0;
    var pending = 0;
    for (final m in msgs) {
      if (m.postedAt > latest) latest = m.postedAt;
      if (_displayKey(m) == kGroupPending) pending++;
    }
    return (msgs.length, latest, pending);
  }

  /// F02 一级分组：按**来源应用**聚合（appName 空则 packageName）。
  ///
  /// 与筛选 chip 正交：先由 [_visible] 过滤，再在这里分组。
  /// 组顺序 = 组内最新消息倒序（[_visible] 本身 posted_at DESC，按首次出现插入即满足）。
  ///
  /// 缓存键与 [_visible] 同源（消息集 identity / 任务映射 identity / 筛选集合），
  /// 因此点击展开折叠不会触发 O(n) 重算。
  List<_SourceGroup> get _sourceGroups {
    final cached = _sourceCache;
    if (cached != null && _cachesFresh()) return cached;
    // 一级重算 → 二级全部作废
    _conversationCache.clear();
    final buckets = <String, List<Message>>{};
    final appNames = <String, String>{};
    for (final m in _visible) {
      final pkg = m.packageName;
      (buckets[pkg] ??= <Message>[]).add(m);
      if (!appNames.containsKey(pkg)) {
        final n = m.appName?.trim();
        if (n != null && n.isNotEmpty) appNames[pkg] = n;
      }
    }
    // 消息行上没带 appName 时，退回收件箱来源列表里的名字（只查一次 map）
    final sourceApps = <String, String?>{
      for (final s in _sources) s.packageName: s.appName,
    };
    final groups = <_SourceGroup>[];
    for (final entry in buckets.entries) {
      final pkg = entry.key;
      final msgs = entry.value;
      final fallback = sourceApps[pkg]?.trim();
      final appName = appNames[pkg] ??
          ((fallback != null && fallback.isNotEmpty) ? fallback : null);
      final (count, latest, pending) = _groupStats(msgs);
      groups.add(_SourceGroup(
        key: pkg,
        title: appName ?? pkg,
        messages: msgs,
        count: count,
        latestAt: latest,
        pendingCount: pending,
        // 聊天类来源才建二级：音乐/天气/电商的 title 是歌名/商品名，拆会话只会制造噪音
        chat: isChatSource(pkg, appName),
      ));
    }
    _sourceCache = groups;
    // 防御：单独命中本缓存时也要保证键是最新的（值与本轮 _visible 同源）。
    _cacheKeyMessages = _messages;
    _cacheKeyTasks = _tasksById;
    _cacheKeyFilter = Set.of(_groupFilter);
    return groups;
  }

  /// F02 二级分组：某个来源内的**会话**（群聊/联系人）。
  /// 会话名统一走 [guessConversationName]（conversationTitle → title 剥
  /// 「(N条新消息)」与「群名: 内容」前缀 → sender → 其它），采集端 94.8% 的
  /// conversation_title 是空的，群名实际写在 title 里。
  ///
  /// 惰性 memo：只有该来源已展开时才会被调用；结果按来源缓存，
  /// 折叠/展开其它来源不会重算它。
  List<_ConversationGroup> _conversationGroupsOf(_SourceGroup source) {
    final cached = _conversationCache[source.key];
    if (cached != null && _cachesFresh()) return cached;
    final buckets = <String, List<Message>>{};
    final names = <String, String>{};
    for (final m in source.messages) {
      final name = guessConversationName(
        conversationTitle: m.conversationTitle,
        title: m.title,
        sender: m.sender,
      );
      final key = '${source.key}\u0000$name';
      names[key] = name;
      (buckets[key] ??= <Message>[]).add(m);
    }
    final groups = <_ConversationGroup>[];
    for (final entry in buckets.entries) {
      final msgs = entry.value;
      final (count, latest, pending) = _groupStats(msgs);
      groups.add(_ConversationGroup(
        key: entry.key,
        title: names[entry.key]!,
        messages: msgs,
        count: count,
        latestAt: latest,
        pendingCount: pending,
      ));
    }
    _conversationCache[source.key] = groups;
    return groups;
  }

  Future<void> _addManually() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const AddMessagePage()));
    await reload();
  }

  /// 库页 FAB「手动添加」入口（ui-structure §4：领域主创建统一 FAB）。
  Future<void> addManually() => _addManually();

  // ---- 单条/批量操作（成功后注册撤销，见设计 §6）----

  Future<void> _createTask(Message msg) async {
    final result = await showTaskEditor(
      context,
      seedTitle: msg.title,
      seedDescription: msg.body,
      sourceMessageId: msg.id,
    );
    final task = result?.task;
    if (task == null) return;
    if (result!.parentExpanded != null) {
      await _db.updateTask(result.parentExpanded!);
    }
    await _db.insertTask(task);
    // v8：消息 ↔ 任务关联落为锚点（marker 追加到正文末尾）
    final anchorResult = await AnchorService.instance.insertAnchor(
        taskId: task.id,
        targetType: AnchorTargetType.message,
        targetId: msg.id);
    final anchorId = anchorResult.anchor?.id;
    final parentBefore = result.parentBefore;
    UndoService.instance.register(
      label: '已创建任务',
      undo: () async {
        // 先摘锚点（清 marker），再删任务——避免 deleteTasks 残迹化留文本
        if (anchorId != null) {
          await AnchorService.instance.removeAnchor(anchorId);
        }
        await _db.deleteTasks([task.id]);
        if (parentBefore != null) await _db.updateTask(parentBefore);
      },
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已创建任务', onUndone: reload);
    await reload();
  }

  /// 取消选中消息各自关联的任务（删除任务并清除链接）；撤销整体回滚。
  /// 删父任务前先把其子任务升级为普通任务（parent_id 置空），
  /// 与删除合并为同一个复合撤销（设计 §7）。
  /// 取消选中消息各自关联的**全部**任务（v8：一条消息可被多个锚点连接）。
  /// 删父任务前先把其子任务升级为普通任务（parent_id 置空），与删除合并为同一复合撤销。
  /// deleteTasks 会先残迹化锚点（正文 marker 变 [任务:标题] 纯文本）；
  /// 删除前快照锚点行 + 受影响正文原文，撤销时整体复原（marker 精确回写）。
  Future<void> _deleteLinkedTasks(List<Message> targets) async {
    // (消息, 该消息锚点连接的任务列表)
    final pairs = <(Message, List<Task>)>[];
    for (final m in targets) {
      final ids = _linkedTaskIds(m);
      final tasks = <Task>[];
      for (final id in ids) {
        final t = await _db.getTaskById(id);
        if (t != null) tasks.add(t);
      }
      pairs.add((m, tasks));
    }
    final childrenOf = <String, List<Task>>{};
    for (final (_, tasks) in pairs) {
      for (final t in tasks) {
        final children = await _db.getChildTasks(t.id);
        if (children.isEmpty) continue;
        childrenOf[t.id] = children;
        for (final c in children) {
          await _db.updateTask(c.copyWith(parentId: () => null));
        }
      }
    }
    final allIds = [
      for (final (_, tasks) in pairs)
        for (final t in tasks) t.id,
    ];
    // 删除前完整快照：锚点行 + 受影响正文原文（撤销整体复原）。
    final snapshot = await _db.snapshotTaskDeletion(allIds);
    if (allIds.isNotEmpty) await _db.deleteTasks(allIds);
    UndoService.instance.register(
      label: '已取消任务',
      undo: () async {
        for (final (_, tasks) in pairs) {
          for (final t in tasks) {
            await _db.insertTask(t);
          }
        }
        await _db.restoreTaskDeletionSnapshot(snapshot);
        for (final children in childrenOf.values) {
          for (final c in children) {
            await _db.updateTask(c);
          }
        }
      },
    );
  }

  /// 彻底删除消息（v2.4：垃圾消息左滑「删除」）；撤销 = 整体回插。
  Future<void> _deleteMessagesForever(List<Message> targets) async {
    await _db.deleteMessages([for (final m in targets) m.id]);
    UndoService.instance.register(
      label: '已删除',
      undo: () => _db.restoreMessages(targets),
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已删除', onUndone: reload);
    await reload();
  }

  Future<void> _markJunk(List<Message> targets) async {
    await _db.updateMessagePriority(
        [for (final m in targets) m.id], MessagePriority.junk);
    UndoService.instance.register(
      label: '已标记垃圾',
      undo: () async {
        for (final m in targets) {
          await _db.updateMessagePriority([m.id], m.priority);
        }
      },
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已标记垃圾', onUndone: reload);
    await reload();
  }

  Future<void> _unjunk(List<Message> targets) async {
    await _db.updateMessagePriority(
        [for (final m in targets) m.id], MessagePriority.none);
    UndoService.instance.register(
      label: '已移出垃圾',
      undo: () async {
        await _db.updateMessagePriority(
            [for (final m in targets) m.id], MessagePriority.junk);
      },
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已移出垃圾', onUndone: reload);
    await reload();
  }

  Future<void> _archive(List<Message> targets) async {
    await _db.updateMessageStatus(
        [for (final m in targets) m.id], MessageStatus.archived);
    UndoService.instance.register(
      label: '已归档',
      undo: () async {
        for (final m in targets) {
          await _db.updateMessageStatus([m.id], m.status);
        }
      },
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已归档', onUndone: reload);
    await reload();
  }

  // ---- 归档入口 ----

  Future<void> _openArchived() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ArchivedMessagesPage()));
    await reload();
  }

  /// 库页 AppBar「归档箱」入口（ui-structure §6.1：消息分区时显示）。
  Future<void> openArchived() => _openArchived();

  // ---- 多选模式 ----

  List<Message> get _selectedMessages =>
      _messages.where((m) => _selected.contains(m.id)).toList();

  void _toggleSelect(Message m) {
    final pick = _pick;
    if (pick != null) {
      // pick 模式：写控制器，本地状态由 _syncFromPick 回同步
      pick.toggle(ChatAttachmentType.message, m.id,
          title: m.title, icon: Icons.mail_outline);
      setState(() => _selecting = true);
      return;
    }
    setState(() {
      if (!_selected.remove(m.id)) _selected.add(m.id);
      if (_selected.isEmpty) _selecting = false;
    });
    widget.onSelectionChanged?.call(_selecting);
  }

  void _exitSelection() {
    final pick = _pick;
    if (pick != null) {
      pick.clearType(ChatAttachmentType.message);
      setState(() => _selecting = false);
      return;
    }
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    widget.onSelectionChanged?.call(false);
  }

  Future<void> _runBatch(Future<void> Function(List<Message>) op) async {
    final targets = _selectedMessages;
    _exitSelection();
    if (targets.isNotEmpty) await op(targets);
  }

  // ---- 左滑菜单（按行状态，设计 §5.1）----

  List<SwipeAction> _actionsFor(Message m) {
    final cs = Theme.of(context).colorScheme;
    final isJunk = m.priority == MessagePriority.junk;
    if (isJunk) {
      return [
        SwipeAction(
          icon: Icons.restore,
          label: '移出垃圾',
          color: cs.primary,
          onTap: () => _unjunk([m]),
        ),
        SwipeAction(
          icon: Icons.archive_outlined,
          label: '归档',
          color: cs.secondary,
          onTap: () => _archive([m]),
        ),
        SwipeAction(
          icon: Icons.delete_forever_outlined,
          label: '删除',
          color: cs.error,
          onTap: () => _deleteMessagesForever([m]),
        ),
      ];
    }
    return [
      if (_linkedTaskIds(m).isEmpty)
        SwipeAction(
          icon: Icons.add_task,
          label: '创建任务',
          color: cs.primary,
          onTap: () => _createTask(m),
        )
      else
        SwipeAction(
          icon: Icons.delete_outline,
          label: '取消任务',
          color: cs.error,
          onTap: () => _deleteLinkedTasks([m]),
        ),
      SwipeAction(
        icon: Icons.block,
        label: '标记垃圾',
        color: cs.outline,
        onTap: () => _markJunk([m]),
      ),
      SwipeAction(
        icon: Icons.archive_outlined,
        label: '归档',
        color: cs.secondary,
        onTap: () => _archive([m]),
      ),
    ];
  }

  // ---- UI ----

  /// 多选态首行工具条（ui-structure §4 分区级操作；原多选 AppBar 降级而来）。
  Widget _buildSelectionHeader() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 48,
      color: cs.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: '退出',
            icon: const Icon(Icons.close),
            onPressed: _exitSelection,
          ),
          Text('已选 ${_selected.length} 项'),
          const Spacer(),
          TextButton(
            onPressed: () {
              final pick = _pick;
              if (pick != null) {
                for (final m in _visible) {
                  pick.select(ChatAttachmentType.message, m.id,
                      title: m.title, icon: Icons.mail_outline);
                }
                return;
              }
              setState(() => _selected.addAll(_visible.map((m) => m.id)));
            },
            child: const Text('全选'),
          ),
          TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () {
                      final pick = _pick;
                      if (pick != null) {
                        pick.clearType(ChatAttachmentType.message);
                        return;
                      }
                      setState(() => _selected.clear());
                    },
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterRow(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final key in kDisplayGroupOrder)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                // 纯图标筛选（2026-11-01 第三批）：文字收进 Tooltip
                child: _IconChip(
                  tooltip: messageGroupLabel(key),
                  selected: _groupFilter.contains(key),
                  onTap: () => setState(() {
                    if (_groupFilter.contains(key)) {
                      _groupFilter.remove(key);
                    } else {
                      _groupFilter.add(key);
                    }
                  }),
                  child: Icon(messageGroupIcon(key), size: 18),
                ),
              ),
            ),
          if (_sources.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                    width: 1, height: 24, color: cs.outlineVariant),
              ),
            ),
          // 应用筛选（2026-11-01）：单个下拉按钮 + 多选菜单，
          // 按钮上图标 = 所选应用图标前几个堆叠（第三批：去文字）
          if (_sources.isNotEmpty) _buildAppFilterButton(cs),
        ],
      ),
    );
  }

  /// 应用筛选按钮：堆叠图标 + 下拉箭头（无文字），点击弹多选菜单。
  Widget _buildAppFilterButton(ColorScheme cs) {
    final active = _appFilter.isNotEmpty;
    // 堆叠展示的图标来源：有筛选 = 所选应用（最多 3 个），无筛选 = 全部前 3
    final iconSources = (active
            ? _sources.where((s) => _appFilter.contains(s.packageName))
            : _sources)
        .take(3)
        .toList();
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: _IconChip(
          tooltip: active ? '已选 ${_appFilter.length} 个应用' : '按应用筛选',
          selected: active,
          onTap: _showAppFilterSheet,
          wide: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StackedAppIcons(sources: iconSources),
              const SizedBox(width: 2),
              const Icon(Icons.arrow_drop_down, size: 16),
            ],
          ),
        ),
      ),
    );
  }

  /// 应用多选菜单（底部弹层）：每行 图标 + 应用名 + 勾选；支持清除。
  void _showAppFilterSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          void toggle(String pkg, bool sel) {
            setSheetState(() {
              if (sel) {
                _appFilter.add(pkg);
              } else {
                _appFilter.remove(pkg);
              }
            });
            setState(() {});
            reload();
          }

          final cs = Theme.of(context).colorScheme;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: const Text('按应用筛选',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  trailing: _appFilter.isEmpty
                      ? null
                      : TextButton(
                          onPressed: () {
                            setSheetState(_appFilter.clear);
                            setState(() {});
                            reload();
                          },
                          child: const Text('清除'),
                        ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final s in _sources)
                        CheckboxListTile(
                          value: _appFilter.contains(s.packageName),
                          onChanged: (v) => toggle(s.packageName, v ?? false),
                          secondary: AppIcon(
                              packageName: s.packageName,
                              appName: s.displayName,
                              size: 24),
                          title: Text(s.displayName,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          controlAffinity: ListTileControlAffinity.trailing,
                          activeColor: cs.primary,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 通知监听权限丢失横幅（v2.5）：重装/系统回收权限后用户可自行恢复。
  Widget _buildListenerBanner(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Icon(Icons.notifications_off_outlined,
                size: 18, color: cs.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text('通知监听未授权，无法自动采集消息',
                  style: TextStyle(fontSize: 13, color: cs.onErrorContainer)),
            ),
            TextButton(
              onPressed: () async {
                await NotificationBridge.instance.openListenerSettings();
                await Future.delayed(const Duration(seconds: 1));
                reload();
              },
              child: const Text('去授权'),
            ),
          ],
        ),
      ),
    );
  }

  /// 单条消息行（多选 / 左滑 / 点开详情，能力与改动前一致）。
  /// pick 模式（附件选择）：点击即选中/取消，无左滑菜单、无需先长按进多选。
  /// [embedded] = 嵌在分组卡片里（不再是独立小卡，见 _buildSourceCard）。
  Widget _buildTile(Message m, {bool embedded = false}) {
    final pickUI = widget.pickMode;
    return MessageTile(
      key: ValueKey(m.id),
      message: m,
      selecting: pickUI || _selecting,
      selected: _selected.contains(m.id),
      swipeEnabled: !pickUI,
      embedded: embedded,
      linkedTaskDone: _isLinkedDone(m),
      linkedTaskPriority: _linkedTaskPriority(m),
      linkedTaskCount: _linkedTaskIds(m).length,
      actions: pickUI ? const [] : _actionsFor(m),
      onTap: () {
        if (pickUI || _selecting) {
          _toggleSelect(m);
        } else {
          // P3-2：点开详情看正文与附件（图片可放大）
          showMessageDetail(context, m);
        }
      },
      onLongPress: pickUI
          ? null
          : () {
              if (!_selecting) {
                setState(() {
                  _selecting = true;
                  _selected.add(m.id);
                });
                widget.onSelectionChanged?.call(true);
              }
            },
    );
  }

  /// 多选态下整组选择/取消（类别选择，2026-11-01）：组内消息全选 ⇄ 全不选。
  void _toggleSelectGroup(List<Message> msgs) {
    if (msgs.isEmpty) return;
    final allSelected = msgs.every((m) => _selected.contains(m.id));
    final pick = _pick;
    if (pick != null) {
      for (final m in msgs) {
        final sel = pick.isSelected(ChatAttachmentType.message, m.id);
        if (allSelected ? sel : !sel) {
          pick.toggle(ChatAttachmentType.message, m.id,
              title: m.title, icon: Icons.mail_outline);
        }
      }
      setState(() {});
      return;
    }
    setState(() {
      if (allSelected) {
        _selected.removeAll(msgs.map((m) => m.id));
      } else {
        _selected.addAll(msgs.map((m) => m.id));
      }
    });
    widget.onSelectionChanged?.call(_selecting);
  }

  /// 组头的三态勾选（0 无 / 1 部分 / 2 全部）。
  int _groupSelectState(List<Message> msgs) {
    if (msgs.isEmpty) return 0;
    final n = msgs.where((m) => _selected.contains(m.id)).length;
    if (n == 0) return 0;
    return n == msgs.length ? 2 : 1;
  }

  /// 长按组头：进入多选并选中整组（与长按消息卡同入口）。
  void _startSelectionWithGroup(List<Message> msgs) {
    if (_selecting || widget.pickMode) return;
    setState(() {
      _selecting = true;
      _selected.addAll(msgs.map((m) => m.id));
    });
    widget.onSelectionChanged?.call(true);
  }

  /// 分组分页（2026-11-01）：每组首屏 [kGroupPageInitial] 条，
  /// 点「显示更多」每次 +[kGroupPageStep]（取代原全局最近 500 条）。
  List<Message> _paged(String groupKey, List<Message> all) =>
      pagedPrefix(all, _shownCounts[groupKey] ?? kGroupPageInitial);

  /// 「显示更多」行：还有 N 条未展示时出现在组尾。
  Widget _buildLoadMore(String groupKey, int total) {
    final shown = _shownCounts[groupKey] ?? kGroupPageInitial;
    final remaining = total - shown;
    return Center(
      child: TextButton.icon(
        onPressed: () => setState(
            () => _shownCounts[groupKey] = shown + kGroupPageStep),
        icon: const Icon(Icons.expand_more, size: 16),
        label: Text('显示更多（还有 $remaining 条）',
            style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  /// 嵌套卡片列表（2026-11-01 重构，替代「吸顶组头 + 独立消息小卡」）：
  /// 一级来源 = 外层卡片（头行 + 消息行直接嵌在卡里）；
  /// 聊天类来源的二级会话 = 内层嵌套卡片（更深底色、更窄圆角）。
  /// 卡片内消息行间用发丝分隔线，「显示更多」收在卡片底部。
  /// 组头不再吸顶（卡片是一个整体，吸顶会切断卡片视觉）；
  /// 展开/折叠与整组选择的能力不变。
  Widget _buildList() {
    final sources = _sourceGroups;
    if (sources.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          Center(child: Text(_loading ? '加载中…' : '暂无消息')),
        ],
      );
    }
    final selectable = _selecting || widget.pickMode;
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: sources.length,
      itemBuilder: (context, i) => _buildSourceCard(sources[i], selectable),
    );
  }

  /// 一级分组卡（来源应用）：头行 + （展开时）消息体 / 二级会话卡。
  Widget _buildSourceCard(_SourceGroup s, bool selectable) {
    final cs = Theme.of(context).colorScheme;
    final expanded = _expandedSources.contains(s.key);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Material(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            _SourceGroupHeader(
              packageName: s.key,
              title: s.title,
              count: s.count,
              pendingCount: s.pendingCount,
              expanded: expanded,
              onToggle: () => setState(() {
                if (!_expandedSources.remove(s.key)) {
                  _expandedSources.add(s.key);
                }
              }),
              selectable: selectable,
              selectState: _groupSelectState(s.messages),
              onToggleSelect: () => _toggleSelectGroup(s.messages),
              onLongPress: () => _startSelectionWithGroup(s.messages),
            ),
            // 一级折叠：二级一个都不建（chat 与否都不用算）——这是避免 O(n²) 的关键
            if (expanded)
              if (!s.chat)
                // 非聊天类来源：不建二级，消息直接嵌在一级卡片里
                ..._groupBody(s.key, s.messages)
              else
                for (final c in _conversationGroupsOf(s))
                  _buildConversationCard(c, selectable),
            if (expanded && s.chat) const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  /// 二级嵌套卡（会话）：比一级更矮、底色更深，视觉上嵌在一级卡片内。
  Widget _buildConversationCard(_ConversationGroup c, bool selectable) {
    final cs = Theme.of(context).colorScheme;
    final expanded = _expandedConversations.contains(c.key);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Material(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            _ConversationGroupHeader(
              title: c.title,
              count: c.count,
              latestAt: c.latestAt,
              pendingCount: c.pendingCount,
              expanded: expanded,
              onToggle: () => setState(() {
                if (!_expandedConversations.remove(c.key)) {
                  _expandedConversations.add(c.key);
                }
              }),
              selectable: selectable,
              selectState: _groupSelectState(c.messages),
              onToggleSelect: () => _toggleSelectGroup(c.messages),
              onLongPress: () => _startSelectionWithGroup(c.messages),
            ),
            if (expanded) ..._groupBody(c.key, c.messages),
          ],
        ),
      ),
    );
  }

  /// 卡片内的消息体：头行下发丝分隔线 + 分页消息行（行间缩进分隔线）
  /// + 「显示更多」收尾。
  List<Widget> _groupBody(String groupKey, List<Message> all) {
    final paged = _paged(groupKey, all);
    final hasMore = all.length > paged.length;
    final out = <Widget>[const Divider(height: 1)];
    for (var i = 0; i < paged.length; i++) {
      if (i > 0) {
        out.add(const Divider(height: 1, indent: 44, endIndent: 12));
      }
      out.add(_buildTile(paged[i], embedded: true));
    }
    if (hasMore) {
      out.add(const Divider(height: 1, indent: 44, endIndent: 12));
      out.add(_buildLoadMore(groupKey, all.length));
    }
    return out;
  }

  Widget _buildSelectionBar() {
    final targets = _selectedMessages;
    final hasSelection = targets.isNotEmpty;
    final anyJunk =
        targets.any((m) => m.priority == MessagePriority.junk);
    final allJunk = hasSelection &&
        targets.every((m) => m.priority == MessagePriority.junk);
    final allLinked = hasSelection &&
        targets.every((m) => _linkedTaskIds(m).isNotEmpty);
    return SelectionActionBar(
      actions: [
        SelectionAction(
          icon: Icons.send_outlined,
          tooltip: '发送给助理',
          enabled: hasSelection,
          onTap: () => _runBatch((targets) => sendToAssistant(context, [
                for (final m in targets)
                  ChatAttachment(type: ChatAttachmentType.message, id: m.id),
              ])),
        ),
        SelectionAction(
          icon: Icons.archive_outlined,
          tooltip: '归档',
          enabled: hasSelection,
          onTap: () => _runBatch(_archive),
        ),
        SelectionAction(
          icon: Icons.block,
          tooltip: '标记垃圾',
          enabled: hasSelection && !anyJunk,
          onTap: () => _runBatch(_markJunk),
        ),
        SelectionAction(
          icon: Icons.restore,
          tooltip: '移出垃圾',
          enabled: allJunk,
          onTap: () => _runBatch(_unjunk),
        ),
        SelectionAction(
          icon: Icons.delete_outline,
          tooltip: '取消任务',
          enabled: allLinked,
          onTap: () => _runBatch(_deleteLinkedTasks),
        ),
        SelectionAction(
          icon: Icons.add_task,
          tooltip: '创建任务',
          enabled: targets.length == 1,
          onTap: () {
            final m = targets.first;
            _exitSelection();
            _createTask(m);
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // ui-structure §3：分区页不持有 AppBar（由库页容器统一持有）。
    return Scaffold(
      body: Column(
        children: [
          if (_listenerEnabled == false) _buildListenerBanner(context),
          // 筛选行始终显示；多选态的工具条独立占一行（2026-11-01：
          // 原先多选会顶掉筛选行，筛选器/应用筛选在多选期间不可达）
          _buildFilterRow(context),
          if (_selecting) ...[
            const Divider(height: 1),
            _buildSelectionHeader(),
          ],
          const Divider(height: 1),
          Expanded(
            child: RefreshIndicator(
              onRefresh: reload,
              child: _buildList(),
            ),
          ),
          // pick 模式：底部操作条由附件选择页统一提供（已选附件 + 确认）
          if (_selecting && !widget.pickMode) _buildSelectionBar(),
        ],
      ),
    );
  }
}

/// F02 一级分组：「来源应用」在当前**筛选后**的全部消息。
class _SourceGroup {
  /// 来源标识 = packageName。
  final String key;

  /// 组头显示的应用名（appName，空则 packageName）。
  final String title;

  /// 组内消息，保持列表原有顺序（posted_at 倒序）。
  final List<Message> messages;

  /// 条数（= messages.length，预先算好供组头 shouldRebuild 比较）。
  final int count;

  /// 组内最新一条消息的时间（毫秒）。
  final int latestAt;

  /// 组内仍属「未处理」的条数（与顶部 chip 的未处理口径一致）。
  final int pendingCount;

  /// 是否聊天类来源（只有聊天类才建二级「会话」分组）。
  final bool chat;

  const _SourceGroup({
    required this.key,
    required this.title,
    required this.messages,
    required this.count,
    required this.latestAt,
    required this.pendingCount,
    required this.chat,
  });
}

/// F02：一个「会话组」——同一群聊/私聊在当前**筛选后**的全部消息。
class _ConversationGroup {
  /// 会话标识：来源包名 + NUL + 会话名（避免同名会话被合并）。
  final String key;

  /// 组头显示的会话名（guessConversationName 推导 + 剥折叠后缀）。
  final String title;

  /// 组内消息，保持列表原有顺序（posted_at 倒序）。
  final List<Message> messages;

  /// 条数（= messages.length）。
  final int count;

  /// 组内最新一条消息的时间（毫秒）。
  final int latestAt;

  /// 组内仍属「未处理」的条数（与顶部 chip 的未处理口径一致）。
  final int pendingCount;

  const _ConversationGroup({
    required this.key,
    required this.title,
    required this.messages,
    required this.count,
    required this.latestAt,
    required this.pendingCount,
  });
}

/// F02 一级组头（来源应用）：单行「chevron + 应用名 …… N 条 · 未处理 M」，
/// 字号比二级略大，作为层级锚点。
/// 一级分组头（来源应用，2026-11-01 嵌套卡片版）：应用图标 + 名称 +
/// 「N 条 · 未处理 M」，整行点击 = 展开/折叠；多选态行首换三态勾选框，
/// 点击 = 整组选择/取消，长按进入多选并选中整组。
/// 作为一级卡片的头行渲染（无自身底色/外边距，容器由卡片提供）。
class _SourceGroupHeader extends StatelessWidget {
  final String packageName;
  final String title;
  final int count;
  final int pendingCount;
  final bool expanded;
  final VoidCallback onToggle;

  /// 多选态（2026-11-01 类别选择）：行首换三态勾选框，点击 = 整组选择/取消。
  final bool selectable;

  /// 0 无 / 1 部分 / 2 全部。
  final int selectState;
  final VoidCallback onToggleSelect;
  final VoidCallback onLongPress;

  const _SourceGroupHeader({
    required this.packageName,
    required this.title,
    required this.count,
    required this.pendingCount,
    required this.expanded,
    required this.onToggle,
    this.selectable = false,
    this.selectState = 0,
    required this.onToggleSelect,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final meta = <String>['$count 条'];
    if (pendingCount > 0) meta.add('未处理 $pendingCount');
    return InkWell(
      onTap: selectable ? onToggleSelect : onToggle,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
        child: Row(
          children: [
            if (selectable)
              _GroupCheckbox(state: selectState)
            else
              Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                size: 20,
                color: cs.onSurfaceVariant,
              ),
            const SizedBox(width: 8),
            // 分类后的应用图标收敛到组头（卡片里不再重复显示）
            AppIcon(packageName: packageName, appName: title, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              meta.join(' · '),
              maxLines: 1,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// 组头三态勾选框（多选态）：无 / 部分 / 全部。
class _GroupCheckbox extends StatelessWidget {
  final int state;

  const _GroupCheckbox({required this.state});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color) = switch (state) {
      2 => (Icons.check_box, cs.primary),
      1 => (Icons.indeterminate_check_box, cs.primary),
      _ => (Icons.check_box_outline_blank, cs.outline),
    };
    return Icon(icon, size: 22, color: color);
  }
}

/// 二级分组头（会话，2026-11-01 嵌套卡片版）：会话名（主）+
/// 「条数 · 最新时间 · 未处理 N」（次），整行点击 = 展开/折叠；
/// 多选态点击 = 整组选择/取消。作为二级嵌套卡片的头行渲染。
class _ConversationGroupHeader extends StatelessWidget {
  final String title;
  final int count;
  final int latestAt;
  final int pendingCount;
  final bool expanded;
  final VoidCallback onToggle;

  /// 多选态（2026-11-01 类别选择）：行首换三态勾选框，点击 = 整组选择/取消。
  final bool selectable;

  /// 0 无 / 1 部分 / 2 全部。
  final int selectState;
  final VoidCallback onToggleSelect;
  final VoidCallback onLongPress;

  const _ConversationGroupHeader({
    required this.title,
    required this.count,
    required this.latestAt,
    required this.pendingCount,
    required this.expanded,
    required this.onToggle,
    this.selectable = false,
    this.selectState = 0,
    required this.onToggleSelect,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final meta = <String>['$count 条', formatMessageTime(latestAt)];
    if (pendingCount > 0) meta.add('未处理 $pendingCount');
    return InkWell(
      onTap: selectable ? onToggleSelect : onToggle,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            if (selectable)
              _GroupCheckbox(state: selectState)
            else
              Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                size: 18,
                color: cs.onSurfaceVariant,
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    meta.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 应用图标堆叠（2026-11-01 应用筛选按钮；B17② 方案 B，2026-11-03）：
/// 最多 3 个 16px 圆形图标依次右移层叠，整体宽 16 + 10×(n-1)。
/// 图标本身用 ClipOval 裁圆，**不画描边、不加背景色/阴影**；相邻图标靠
/// 10px 叠压本身区分 —— 任何圆环描边都会与圆角方形源图之间露出白环。
/// 不改 AppIcon 的全局形状（其它调用仍为圆角方形）。
class _StackedAppIcons extends StatelessWidget {
  final List<SourceApp> sources;

  const _StackedAppIcons({required this.sources});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (sources.isEmpty) {
      return Icon(Icons.apps_outlined, size: 16, color: cs.onSurfaceVariant);
    }
    final width = 16.0 + 10.0 * (sources.length - 1);
    return SizedBox(
      width: width,
      height: 16,
      child: Stack(
        children: [
          for (var i = 0; i < sources.length; i++)
            Positioned(
              left: 10.0 * i,
              // B17② 方案 B：直接裁圆，不加 border / padding / 背景 / 阴影；
              // 层叠关系由 10px 重叠本身表达，避免任何新白环。
              child: ClipOval(
                child: AppIcon(
                  packageName: sources[i].packageName,
                  appName: sources[i].displayName,
                  size: 16,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 纯图标筛选 chip（2026-11-01 第三批：筛选栏去文字）：36px 圆形
/// （wide = 胶囊，宽度随内容），选中态 secondaryContainer 实心、
/// 未选态描边；文字说明收进 [tooltip]。
class _IconChip extends StatelessWidget {
  final Widget child;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  /// true 时宽度随内容（堆叠图标 + 箭头的应用筛选按钮用）。
  final bool wide;

  const _IconChip({
    required this.child,
    required this.tooltip,
    required this.selected,
    required this.onTap,
    this.wide = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color:
            selected ? cs.secondaryContainer : cs.surfaceContainerHighest,
        shape: StadiumBorder(
          side: selected
              ? BorderSide.none
              : BorderSide(color: cs.outlineVariant),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Container(
            height: 36,
            width: wide ? null : 36,
            padding: wide ? const EdgeInsets.symmetric(horizontal: 10) : null,
            child: IconTheme.merge(
              data: IconThemeData(
                size: 18,
                color: selected
                    ? cs.onSecondaryContainer
                    : cs.onSurfaceVariant,
              ),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }
}
