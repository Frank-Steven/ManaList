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
import '../assistant/send_to_assistant.dart';
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
  const MessagesPage({super.key, this.onSelectionChanged});

  /// 多选态变化回调：库页容器用来在多选时隐藏 FAB（避免遮挡底部操作条）。
  final ValueChanged<bool>? onSelectionChanged;

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

  /// 截断提示只提示一次/会话（P3-8）
  bool _limitHintShown = false;

  /// 状态分组多选筛选（默认全选）；另含特殊键 [kFilterDone]（已完成）。
  final Set<String> _groupFilter = Set.of(kGroupOrder);
  String? _appFilter; // null = 全部应用

  bool _selecting = false;
  final Set<String> _selected = {};

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
    reload();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
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
  /// v2.5：消息与来源是关键路径；任务表（绑定色点/「已完成」筛选/划线用）
  /// 失败不阻塞列表展示——此前三者同处一个 Future.wait，任一路失败会让列表
  /// 永远停在「加载中…」（表现为"消息抓取失效"）。
  Future<void> reload() async {
    try {
      final results = await Future.wait([
        _db.getMessages(packageName: _appFilter),
        _db.getDistinctMessageSources(),
        _db.countMessages(packageName: _appFilter),
        _db.messageAnchorTaskIds(),
      ]);
      if (!mounted) return;
      // P3-8：超过默认上限时提示一次，不再静默截断
      final total = results[2] as int;
      final fetched = (results[0] as List<Message>).length;
      if (fetched < total && !_limitHintShown) {
        _limitHintShown = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('消息较多：仅显示最近 $fetched 条（共 $total 条），更早的未加载'),
            duration: const Duration(seconds: 4),
          ));
        });
      }
      setState(() {
        _messages = (results[0] as List<Message>)
            .where((m) => m.status != MessageStatus.archived)
            .toList();
        _sources = results[1] as List<SourceApp>;
        _taskLinks = results[3] as Map<String, List<String>>;
        _loading = false;
        // 所选应用的消息可能已不存在，回退到全部
        if (_appFilter != null &&
            !_sources.any((s) => s.packageName == _appFilter)) {
          _appFilter = null;
        }
        _selected.removeWhere((id) => !_messages.any((m) => m.id == id));
        if (_selected.isEmpty) _selecting = false;
      });
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

  /// 任一关联任务已完成即视为「已完成」（用于筛选与划线）。
  bool _isLinkedDone(Message m) =>
      _linkedTaskIds(m).any((id) => _tasksById[id]?.status == TaskStatus.done);

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
    final visible = _messages.where((m) {
      if (_groupFilter.contains(messageGroupKey(m))) return true;
      // 「已完成」筛选：额外放行关联任务已完成的消息（不占分组）
      return _groupFilter.contains(kFilterDone) && _isLinkedDone(m);
    }).toList();
    _visibleCache = visible;
    _sourceCache = null;
    _conversationCache.clear();
    _cacheKeyMessages = _messages;
    _cacheKeyTasks = _tasksById;
    _cacheKeyFilter = Set.of(_groupFilter);
    return visible;
  }

  /// 条数 / 最新时间 / 未处理数（两级组头共用口径）。
  /// 「未处理」与顶部 chip 同口径：messageGroupKey == pending。
  (int, int, int) _groupStats(List<Message> msgs) {
    var latest = 0;
    var pending = 0;
    for (final m in msgs) {
      if (m.postedAt > latest) latest = m.postedAt;
      if (messageGroupKey(m) == kGroupPending) pending++;
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

  // ---- 多选模式 ----

  List<Message> get _selectedMessages =>
      _messages.where((m) => _selected.contains(m.id)).toList();

  void _toggleSelect(Message m) {
    setState(() {
      if (!_selected.remove(m.id)) _selected.add(m.id);
      if (_selected.isEmpty) _selecting = false;
    });
    widget.onSelectionChanged?.call(_selecting);
  }

  void _exitSelection() {
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

  // ---- 归档入口 ----

  Future<void> _openArchived() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ArchivedMessagesPage()));
    await reload();
  }

  /// 库页 AppBar「归档箱」入口（ui-structure §6.1：消息分区时显示）。
  Future<void> openArchived() => _openArchived();

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
            onPressed: () => setState(
                () => _selected.addAll(_visible.map((m) => m.id))),
            child: const Text('全选'),
          ),
          TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () => setState(() => _selected.clear()),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterRow(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    BorderSide chipSide(bool selected) => selected
        ? BorderSide.none
        : BorderSide(color: cs.outlineVariant);
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final key in kGroupOrder)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text(messageGroupLabel(key)),
                  selected: _groupFilter.contains(key),
                  showCheckmark: false,
                  selectedColor: cs.secondaryContainer,
                  backgroundColor: cs.surfaceContainerHighest,
                  side: chipSide(_groupFilter.contains(key)),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (sel) => setState(() {
                    if (sel) {
                      _groupFilter.add(key);
                    } else {
                      _groupFilter.remove(key);
                    }
                  }),
                ),
              ),
            ),
          // 「已完成」（v2.4）：不占分组，额外显示关联任务已完成的消息
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(messageGroupLabel(kFilterDone)),
                selected: _groupFilter.contains(kFilterDone),
                showCheckmark: false,
                selectedColor: cs.secondaryContainer,
                backgroundColor: cs.surfaceContainerHighest,
                side: chipSide(_groupFilter.contains(kFilterDone)),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onSelected: (sel) => setState(() {
                  if (sel) {
                    _groupFilter.add(kFilterDone);
                  } else {
                    _groupFilter.remove(kFilterDone);
                  }
                }),
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
          if (_sources.isNotEmpty) ...[
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: const Text('全部'),
                  selected: _appFilter == null,
                  showCheckmark: false,
                  selectedColor: cs.secondaryContainer,
                  backgroundColor: cs.surfaceContainerHighest,
                  side: chipSide(_appFilter == null),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (_) {
                    setState(() => _appFilter = null);
                    reload();
                  },
                ),
              ),
            ),
            for (final s in _sources)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(s.displayName),
                    selected: _appFilter == s.packageName,
                    showCheckmark: false,
                    selectedColor: cs.secondaryContainer,
                    backgroundColor: cs.surfaceContainerHighest,
                    side: chipSide(_appFilter == s.packageName),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) {
                      setState(() => _appFilter = s.packageName);
                      reload();
                    },
                  ),
                ),
              ),
          ],
        ],
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
  Widget _buildTile(Message m) {
    return MessageTile(
      key: ValueKey(m.id),
      message: m,
      selecting: _selecting,
      selected: _selected.contains(m.id),
      linkedTaskDone: _isLinkedDone(m),
      linkedTaskPriority: _linkedTaskPriority(m),
      linkedTaskCount: _linkedTaskIds(m).length,
      actions: _actionsFor(m),
      onTap: () {
        if (_selecting) {
          _toggleSelect(m);
        } else {
          // P3-2：点开详情看正文与附件（图片可放大）
          showMessageDetail(context, m);
        }
      },
      onLongPress: () {
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
    final slivers = <Widget>[];
    for (final s in sources) {
      final sourceExpanded = _expandedSources.contains(s.key);
      // 一级：来源应用。不用 pinned: 多个固定吸顶头挤在视口顶部会产生非法
      // SliverGeometry（layoutExtent > paintExtent）导致整个视口不绘制。
      slivers.add(SliverPersistentHeader(
        delegate: _SourceHeaderDelegate(
          sourceKey: s.key,
          title: s.title,
          count: s.count,
          pendingCount: s.pendingCount,
          expanded: sourceExpanded,
          onToggle: () => setState(() {
            if (!_expandedSources.remove(s.key)) _expandedSources.add(s.key);
          }),
        ),
      ));
      // 一级折叠：二级一个都不建（chat 与否都不用算）——这是避免 O(n²) 的关键
      if (!sourceExpanded) continue;
      if (!s.chat) {
        // 非聊天类来源：不建二级，消息直接列在一级下面
        slivers.add(SliverList.builder(
          itemCount: s.messages.length,
          itemBuilder: (context, i) => _buildTile(s.messages[i]),
        ));
        continue;
      }
      // 二级：会话（仅聊天类来源），同样默认折叠
      for (final c in _conversationGroupsOf(s)) {
        final convExpanded = _expandedConversations.contains(c.key);
        slivers.add(SliverPersistentHeader(
          delegate: _ConversationHeaderDelegate(
            conversationKey: c.key,
            title: c.title,
            count: c.count,
            latestAt: c.latestAt,
            pendingCount: c.pendingCount,
            expanded: convExpanded,
            onToggle: () => setState(() {
              if (!_expandedConversations.remove(c.key)) {
                _expandedConversations.add(c.key);
              }
            }),
          ),
        ));
        if (convExpanded) {
          slivers.add(SliverList.builder(
            itemCount: c.messages.length,
            itemBuilder: (context, i) => _buildTile(c.messages[i]),
          ));
        }
      }
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 80)));
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: slivers,
    );
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
          if (_selecting) _buildSelectionHeader() else _buildFilterRow(context),
          const Divider(height: 1),
          Expanded(
            child: RefreshIndicator(
              onRefresh: reload,
              child: _buildList(),
            ),
          ),
          if (_selecting) _buildSelectionBar(),
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
class _SourceHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String sourceKey;
  final String title;
  final int count;
  final int pendingCount;
  final bool expanded;
  final VoidCallback onToggle;

  const _SourceHeaderDelegate({
    required this.sourceKey,
    required this.title,
    required this.count,
    required this.pendingCount,
    required this.expanded,
    required this.onToggle,
  });

  /// 单行：8 + 24 + 8 + 余量。
  static const double kHeight = 46;

  @override
  double get minExtent => kHeight;

  @override
  double get maxExtent => kHeight;

  @override
  bool shouldRebuild(_SourceHeaderDelegate oldDelegate) =>
      sourceKey != oldDelegate.sourceKey ||
      title != oldDelegate.title ||
      count != oldDelegate.count ||
      pendingCount != oldDelegate.pendingCount ||
      expanded != oldDelegate.expanded;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final cs = Theme.of(context).colorScheme;
    final meta = <String>['$count 条'];
    if (pendingCount > 0) meta.add('未处理 $pendingCount');
    return Material(
      color: cs.surface,
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                size: 22,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14.5,
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
      ),
    );
  }
}

/// F02 二级组头（会话）：缩进 32dp 显示层级，会话名（主）+
/// 「条数 · 最新时间 · 未处理 N」（次），整行点击切换展开/折叠。
class _ConversationHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String conversationKey;
  final String title;
  final int count;
  final int latestAt;
  final int pendingCount;
  final bool expanded;
  final VoidCallback onToggle;

  const _ConversationHeaderDelegate({
    required this.conversationKey,
    required this.title,
    required this.count,
    required this.latestAt,
    required this.pendingCount,
    required this.expanded,
    required this.onToggle,
  });

  /// 两行（会话名 + 元信息），44 放不下；58 = 8 + 20 + 2 + 16 + 8 + 余量。
  static const double kHeight = 58;

  @override
  double get minExtent => kHeight;

  @override
  double get maxExtent => kHeight;

  @override
  bool shouldRebuild(_ConversationHeaderDelegate oldDelegate) =>
      conversationKey != oldDelegate.conversationKey ||
      title != oldDelegate.title ||
      count != oldDelegate.count ||
      latestAt != oldDelegate.latestAt ||
      pendingCount != oldDelegate.pendingCount ||
      expanded != oldDelegate.expanded;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final cs = Theme.of(context).colorScheme;
    final meta = <String>['$count 条', formatMessageTime(latestAt)];
    if (pendingCount > 0) meta.add('未处理 $pendingCount');
    return Material(
      color: cs.surfaceContainerLow,
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 16, 0),
          child: Row(
            children: [
              Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                size: 20,
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
                    const SizedBox(height: 2),
                    Text(
                      meta.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
