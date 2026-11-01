import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../models/task.dart';
import '../../services/database.dart';
import '../../services/task_scale.dart';
import '../../services/undo_service.dart';
import '../messages/message_widgets.dart';
import '../shared/segmented_selector.dart';
import 'task_detail_panel.dart';
import 'task_editor.dart';
import 'task_tile.dart';

/// 任务页·列表视图（原待办页 TodosPage，v3 阶段 4 迁入并更名；设计 §3，v2.3；
/// v2.5 内嵌详情）：顶部尺度页签（含计数徽标）+ PageView 滑动翻页。
/// 点击任务行进入详情模式：页面下部内嵌 TaskDetailPanel（与甘特视图共用），
/// 返回按钮/切换页签回列表模式；仅面板右上角编辑图标进编辑器；
/// 有子任务的行尾显示「已完成数/总数」；面板中点击父/子任务跳转到对应
/// 尺度页签并高亮定位。
/// v2.6.1 批量操作：长按进入多选（与消息页同一范式：点选增减、顶部已选数
/// +全选+取消、底部操作条）；已完成页签行尾加「归档」按钮。底部操作按所选
/// 任务状态交集：全部已归档 → 删除/取出；全部未归档且全部 active → 归档/完成；
/// 全部未归档且全部 done → 归档/取消完成；混合（active+done）→ 仅归档。
/// 所有批量操作走 UndoService 可撤销。
/// ui-structure §3 收编：本视图不持有 AppBar（由任务页容器统一持有）；
/// 多选态的「退出/已选 N 项/全选/取消」从 AppBar 降级为内容首行工具条。
class TaskListView extends StatefulWidget {
  const TaskListView({super.key, this.onSelectionChanged});

  /// 多选态变化回调：任务页容器用来在多选时隐藏 FAB（避免遮挡底部操作条）。
  final ValueChanged<bool>? onSelectionChanged;

  @override
  State<TaskListView> createState() => TaskListViewState();
}

class TaskListViewState extends State<TaskListView> {
  static const _recentWindow = Duration(hours: 24);

  /// 页签顺序（设计 §3）：年度/季度/月度/整周/整日/定时/不定时/已完成/已归档。
  static const _scaleTabs = [
    'yearly',
    'quarterly',
    'monthly',
    'weekly',
    'daily',
    'timed',
  ];
  static const _tabLabels = ['年度', '季度', '月度', '整周', '整日', '定时', '不定时', '已完成', '已归档', '全部'];
  /// 页签展示顺序（U8）：「全部」放第一个并作为默认页签；其余顺序不变。
  /// 注意：这里只改**展示顺序**，各页签的 tab 值仍由 _tabLabels 下标决定。
  static const _tabOrder = [9, 0, 1, 2, 3, 4, 5, 6, 7, 8];

  int _tab = 9; // 默认「全部」（U8：一屏看所有状态的任务）

  /// 六个时间尺度各自的 active 任务（按开始时间升序）。
  final Map<String, List<Task>> _byScale = {for (final s in _scaleTabs) s: []};
  List<Task> _untimed = [];
  List<Task> _done = [];
  List<Task> _archived = [];

  /// 各父任务的直接子任务进度（done, total）（v2.3）。
  Map<String, (int, int)> _progress = {};
  bool _loading = true;

  // ---- P1 性能：页签派生数据缓存 ----
  // 以前 build 里为 10 个页签各跑一次 _childrenMap/_visibleRows，
  // 「全部」页签还每次重排 _allTasksSorted、徽标 getter 被取 10 次（每次 O(N)）。
  // 现在数据只在 reload 后算一次；勾选/多选/切换页签不再重算。
  /// 各页签计数徽标（下标 = _tabLabels 下标）。
  List<int> _tabBadges = const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

  /// 页签 → 子任务分组（与折叠状态无关）。
  final Map<int, Map<String, List<Task>>> _tabByParent = {};

  /// 页签 → 展开/折叠后的可见行（折叠变化时只失效这一层）。
  final Map<int, List<Task>> _tabRows = {};

  /// 截断提示只提示一次/会话（P3-8）
  bool _limitHintShown = false;

  /// 折叠的父任务 id（设计 §3：子任务在父行下缩进，默认展开）。
  final Set<String> _collapsedParents = {};

  /// 高亮定位的任务（v2.3：详情面板跳转选中态）。
  String? _selectedTaskId;
  final Map<String, GlobalKey> _rowKeys = {};

  /// 详情模式下展示的任务（v2.5：内嵌 TaskDetailPanel，非空时替换 PageView）。
  Task? _detailTask;

  /// 多选模式（v2.6.1，与消息页同一范式）：长按进入、点选增减。
  bool _selecting = false;
  final Set<String> _selected = {};

  final PageController _pageController = PageController(initialPage: 0);
  final ScrollController _tabScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _tabScrollController.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    final db = AppDatabase.instance;
    final results = await Future.wait([
      db.getTasks(status: TaskStatus.active),
      db.getUntimedTasks(),
      db.getTasks(status: TaskStatus.done),
      db.getTasks(status: TaskStatus.archived),
      db.getSubtaskProgress(),
      db.countTasks(),
    ]);
    final active = results[0] as List<Task>;
    final untimed = results[1] as List<Task>;
    final done = (results[2] as List<Task>)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final archived = (results[3] as List<Task>)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final progress = results[4] as Map<String, (int, int)>;
    final byScale = {for (final s in _scaleTabs) s: <Task>[]};
    for (final t in active) {
      if (t.startAt == null) continue;
      byScale[deriveTaskScale(t.startAt, t.endAt, kind: t.kind)]?.add(t);
    }
    // getTasks 已按 start_at 升序，分组内天然有序
    if (!mounted) return;
      // P3-8：超过默认上限时提示一次（三个状态合计与总数比较）
      final totalTasks = results[5] as int;
      final shownTasks =
          active.length + untimed.length + done.length + archived.length;
      if (shownTasks < totalTasks && !_limitHintShown) {
        _limitHintShown = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '任务较多：仅显示前 $shownTasks 条（共 $totalTasks 条），更早的未加载'),
            duration: const Duration(seconds: 4),
          ));
        });
      }
    setState(() {
      _byScale
        ..clear()
        ..addAll(byScale);
      _untimed = untimed;
      _done = done;
      _archived = archived;
      _progress = progress;
      _loading = false;
      // 清理已不存在任务的多选（v2.6.1）
      _selected.removeWhere((id) => ![
            ...byScale.values,
            untimed,
            done,
            archived,
          ].expand((l) => l).any((t) => t.id == id));
      if (_selected.isEmpty) _selecting = false;
      // 刷新详情模式中的任务（编辑/状态变化后同步；任务消失则退出详情模式）。
      final detail = _detailTask;
      if (detail != null) {
        Task? fresh;
        for (final list in [
          ...byScale.values,
          untimed,
          done,
          archived,
        ]) {
          for (final t in list) {
            if (t.id == detail.id) {
              fresh = t;
              break;
            }
          }
          if (fresh != null) break;
        }
        _detailTask = fresh;
      }
      // P1：派生数据随数据一起刷新，build 里不再逐页签重算。
      _rebuildTabCache();
    });
    widget.onSelectionChanged?.call(_selecting);
  }

  /// P1：一次性重建各页签派生数据（任务排序 + 子任务分组 + 可见行 + 徽标）。
  /// 只在 reload 后调用；勾选完成、多选、切换页签都直接复用。
  /// 页签 → 原始任务列表（不随折叠变化）。
  List<Task> _tabTasks(int tab) {
    switch (tab) {
      case 7:
        return _done;
      case 8:
        return _archived;
      case 9:
        return _allTasksSorted; // 排序只在 reload 后做一次
      case 6:
        return _untimed;
      default:
        return _byScale[_scaleTabs[tab]] ?? const <Task>[];
    }
  }

  void _rebuildTabCache() {
    _tabByParent.clear();
    _tabRows.clear();
    for (final tab in _tabOrder) {
      final tasks = _tabTasks(tab);
      final byParent = _childrenMap(tasks);
      _tabByParent[tab] = byParent;
      _tabRows[tab] = _visibleRows(tasks, byParent);
    }
    _tabBadges = [
      for (final s in _scaleTabs) _byScale[s]!.length,
      _untimed.length,
      _done.length,
      _archived.length,
      _allTasks.length,
    ];
  }

  /// 折叠状态变化：只有「可见行」依赖折叠，分组继续复用，这里只失效可见行。
  void _invalidateRows() => _tabRows.clear();

  /// 取某页签的可见行；被 [_invalidateRows] 清掉时按需补算。
  ///
  /// 2026-10-20 Lead 复核修复：原实现清空后 build 里只读缓存、拿不到就返回空列表，
  /// 表现为「一折叠父任务整页列表变空」，直到下次 reload 才恢复。
  List<Task> _rowsFor(int tab) {
    final cached = _tabRows[tab];
    if (cached != null) return cached;
    final byParent = _tabByParent[tab];
    if (byParent == null) {
      // 连分组都没有（首帧/异常）：整体重建一次
      _rebuildTabCache();
      return _tabRows[tab] ?? const <Task>[];
    }
    final rows = _visibleRows(_tabTasks(tab), byParent);
    _tabRows[tab] = rows;
    return rows;
  }

  void _showUndoSnack(String label) {
    showUndoSnackBar(context, label, onUndone: () async => reload());
  }

  /// 勾选完成/取消完成；有来源消息时联动归档/恢复（设计 §3 行内勾选）。
  Future<void> _toggleDone(Task task) =>
      toggleTaskDoneWithUndo(context, task, onChanged: reload);

  Future<void> _unarchive(Task task) async {
    final db = AppDatabase.instance;
    await db.setTaskStatus([task.id], TaskStatus.active);
    UndoService.instance.register(
      label: '已取出',
      undo: () => db.setTaskStatus([task.id], TaskStatus.archived),
    );
    await reload();
    if (mounted) _showUndoSnack('已取出');
  }

  /// 行内归档（v2.6.1：已完成页签行尾按钮）。
  Future<void> _archiveTask(Task task) async {
    final db = AppDatabase.instance;
    await db.setTaskStatus([task.id], TaskStatus.archived);
    UndoService.instance.register(
      label: '已归档',
      undo: () => db.setTaskStatus([task.id], task.status),
    );
    await reload();
    if (mounted) _showUndoSnack('已归档');
  }

  // ---- 多选模式（v2.6.1，与消息页同一交互范式）----

  List<Task> get _allTasks => [
        for (final l in _byScale.values) ...l,
        ..._untimed,
        ..._done,
        ..._archived,
      ];

  /// 「全部」页签（U8）：活动任务在前（按开始时间，无时间的排后），
  /// 已完成随后、已归档最后（各自按更新时间倒序）。
  List<Task> get _allTasksSorted {
    final active = [
      for (final l in _byScale.values) ...l,
      ..._untimed,
    ]..sort((a, b) {
        final sa = a.startAt;
        final sb = b.startAt;
        if (sa == null && sb == null) return 0;
        if (sa == null) return 1;
        if (sb == null) return -1;
        return sa.compareTo(sb);
      });
    final doneSorted = [..._done]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final archivedSorted = [..._archived]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return [...active, ...doneSorted, ...archivedSorted];
  }

  List<Task> get _selectedTasks =>
      _allTasks.where((t) => _selected.contains(t.id)).toList();

  List<Task> _tasksForTab(int tab) => switch (tab) {
        7 => _done,
        8 => _archived,
        9 => _allTasks,
        6 => _untimed,
        _ => _byScale[_scaleTabs[tab]] ?? const [],
      };

  void _toggleSelect(Task t) {
    setState(() {
      if (!_selected.remove(t.id)) _selected.add(t.id);
      if (_selected.isEmpty) _selecting = false;
    });
    widget.onSelectionChanged?.call(_selecting);
  }

  void _enterSelection(Task t) {
    setState(() {
      _selecting = true;
      _selected.add(t.id);
      _detailTask = null;
    });
    widget.onSelectionChanged?.call(true);
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    widget.onSelectionChanged?.call(false);
  }

  /// 批量置状态（归档/取出），撤销 = 恢复各自原状态（v2.6.1）。
  Future<void> _batchSetStatus(
      List<Task> targets, String status, String label) async {
    final db = AppDatabase.instance;
    await db.setTaskStatus([for (final t in targets) t.id], status);
    UndoService.instance.register(
      label: label,
      undo: () async {
        for (final t in targets) {
          await db.setTaskStatus([t.id], t.status);
        }
      },
    );
    _exitSelection();
    await reload();
    if (mounted) _showUndoSnack(label);
  }

  /// 批量完成/取消完成（v2.6.1）：有来源消息时联动归档/恢复（与单行勾选
  /// toggleTaskDoneWithUndo 同语义），整体复合撤销。
  Future<void> _batchComplete(List<Task> targets, bool completing) async {
    final db = AppDatabase.instance;
    final oldMsgStatus = <String, String?>{};
    for (final t in targets) {
      final msgId = t.sourceMessageId;
      if (msgId != null) {
        oldMsgStatus[msgId] = (await db.getMessageById(msgId))?.status;
      }
    }
    await db.setTaskStatus([for (final t in targets) t.id],
        completing ? TaskStatus.done : TaskStatus.active);
    for (final msgId in oldMsgStatus.keys) {
      await db.updateMessageStatus([msgId],
          completing ? MessageStatus.archived : MessageStatus.processed);
    }
    UndoService.instance.register(
      label: completing ? '已完成' : '已恢复',
      undo: () async {
        for (final t in targets) {
          await db.setTaskStatus([t.id], t.status);
        }
        for (final e in oldMsgStatus.entries) {
          final old = e.value;
          if (old != null) await db.updateMessageStatus([e.key], old);
        }
      },
    );
    _exitSelection();
    await reload();
    if (mounted) _showUndoSnack(completing ? '已完成' : '已恢复');
  }

  /// 批量删除已归档任务（v2.6.1）：删父前子任务先升级为普通任务，
  /// 与单个删除同一复合撤销语义（设计 §7）。
  /// 删除前快照锚点行 + 受影响正文原文，撤销时整体复原（设计 §7 修订）。
  Future<void> _batchDelete(List<Task> targets) async {
    final db = AppDatabase.instance;
    final childrenOf = <String, List<Task>>{};
    for (final t in targets) {
      final children = await db.getChildTasks(t.id);
      if (children.isEmpty) continue;
      childrenOf[t.id] = children;
      for (final c in children) {
        await db.updateTask(c.copyWith(parentId: () => null));
      }
    }
    final snapshot =
        await db.snapshotTaskDeletion([for (final t in targets) t.id]);
    await db.deleteTasks([for (final t in targets) t.id]);
    UndoService.instance.register(
      label: '已删除',
      undo: () async {
        for (final t in targets) {
          await db.insertTask(t);
        }
        await db.restoreTaskDeletionSnapshot(snapshot);
        for (final children in childrenOf.values) {
          for (final c in children) {
            await db.updateTask(c);
          }
        }
      },
    );
    _exitSelection();
    await reload();
    if (mounted) _showUndoSnack('已删除');
  }

  /// 任务页 FAB「新建任务」入口（ui-structure §4：领域主创建统一 FAB）。
  Future<void> createTask() => _createTask();

  Future<void> _createTask() async {
    final result = await showTaskEditor(context);
    final task = result?.task;
    if (result == null || result.deleted || task == null || !mounted) return;
    final db = AppDatabase.instance;
    if (result.parentExpanded != null) {
      await db.updateTask(result.parentExpanded!);
    }
    await db.insertTask(task);
    final parentBefore = result.parentBefore;
    UndoService.instance.register(
      label: '已新建',
      undo: () async {
        await db.deleteTasks([task.id]);
        if (parentBefore != null) await db.updateTask(parentBefore);
      },
    );
    await reload();
    if (mounted) _showUndoSnack('已新建');
  }

  Future<void> _editTask(Task task) async {
    final result = await showTaskEditor(context, existing: task);
    if (result == null || !mounted) return;
    final db = AppDatabase.instance;
    if (result.deleted) {
      // 删父任务前先把子任务升级为普通任务（parent_id 置空），
      // 与删除合并为一个复合撤销（设计 §7）。
      final children = await db.getChildTasks(task.id);
      for (final c in children) {
        await db.updateTask(c.copyWith(parentId: () => null));
      }
      // 删除前快照锚点行 + 受影响正文原文，撤销时整体复原。
      final snapshot = await db.snapshotTaskDeletion([task.id]);
      await db.deleteTasks([task.id]);
      UndoService.instance.register(
        label: '已删除',
        undo: () async {
          await db.insertTask(task);
          await db.restoreTaskDeletionSnapshot(snapshot);
          for (final c in children) {
            await db.updateTask(c);
          }
        },
      );
      await reload();
      if (mounted) _showUndoSnack('已删除');
    } else if (result.task != null) {
      if (result.parentExpanded != null) {
        await db.updateTask(result.parentExpanded!);
      }
      await db.updateTask(result.task!);
      final parentBefore = result.parentBefore;
      UndoService.instance.register(
        label: '已保存',
        undo: () async {
          await db.insertTask(task);
          if (parentBefore != null) await db.updateTask(parentBefore);
        },
      );
      await reload();
      if (mounted) _showUndoSnack('已保存');
    }
  }

  /// 点击任务行：进入详情模式（页面下部内嵌 TaskDetailPanel，v2.5；
  /// 不再弹底部抽屉，也不直接进编辑器）。
  void _showDetail(Task task) {
    setState(() {
      _selectedTaskId = task.id;
      _detailTask = task;
    });
  }

  /// 任务所在页签（v2.3 跳转定位用）。
  int _tabForTask(Task t) {
    if (t.status == TaskStatus.done) return 7;
    if (t.status == TaskStatus.archived) return 8;
    if (t.startAt == null) return 6;
    final idx =
          _scaleTabs.indexOf(deriveTaskScale(t.startAt, t.endAt, kind: t.kind));
    return idx >= 0 ? idx : 6;
  }

  /// 跳转到任务对应尺度页签并高亮定位（滚动到可见 + 选中态）（设计 §3，v2.3）。
  /// v2.5：详情面板中点击父/子任务时调用——退出详情模式，回列表高亮目标行。
  void _jumpToTask(Task t) {
    final tab = _tabForTask(t);
    setState(() {
      _tab = tab;
      _selectedTaskId = t.id;
      _detailTask = null;
      if (t.parentId != null) _collapsedParents.remove(t.parentId);
      _invalidateRows();
    });
    _pageController.jumpToPage(tab);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _rowKeys[t.id]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          alignment: 0.3,
        );
      }
    });
  }

  Future<void> _showSourceMessage(String messageId) async {
    final msg = await AppDatabase.instance.getMessageById(messageId);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(msg?.title ?? '来源消息'),
        content: SingleChildScrollView(
            child: Text(msg == null ? '原文已不存在' : msg.body)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  bool _isRecent(Task task) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return now - task.updatedAt < _recentWindow.inMilliseconds;
  }

  /// 多选态首行工具条（ui-structure §4 视图级操作；原多选 AppBar 降级而来，
  /// 与消息分区 _buildSelectionHeader 同一范式）。
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
                () => _selected.addAll(_tasksForTab(_tab).map((t) => t.id))),
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

  /// 多选底部操作条（v2.6.1）：按所选任务状态交集决定可用项——
  /// 全部已归档 → 删除/取出；全部未归档且全 active → 归档/完成；
  /// 全部未归档且全 done → 归档/取消完成；active+done 混合 → 仅归档。
  Widget _buildSelectionBar() {
    final sel = _selectedTasks;
    final has = sel.isNotEmpty;
    final allArchived =
        has && sel.every((t) => t.status == TaskStatus.archived);
    final noneArchived =
        has && sel.every((t) => t.status != TaskStatus.archived);
    final allDone =
        noneArchived && sel.every((t) => t.status == TaskStatus.done);
    final allActive =
        noneArchived && sel.every((t) => t.status == TaskStatus.active);
    return SelectionActionBar(
      actions: [
        SelectionAction(
          icon: Icons.delete_outline,
          tooltip: '删除',
          enabled: allArchived,
          onTap: () => _batchDelete(sel),
        ),
        SelectionAction(
          icon: Icons.unarchive_outlined,
          tooltip: '取出',
          enabled: allArchived,
          onTap: () => _batchSetStatus(sel, TaskStatus.active, '已取出'),
        ),
        SelectionAction(
          icon: Icons.archive_outlined,
          tooltip: '归档',
          enabled: noneArchived,
          onTap: () => _batchSetStatus(sel, TaskStatus.archived, '已归档'),
        ),
        SelectionAction(
          icon: Icons.check_circle_outline,
          tooltip: '完成',
          enabled: allActive,
          onTap: () => _batchComplete(sel, true),
        ),
        SelectionAction(
          icon: Icons.undo_outlined,
          tooltip: '取消完成',
          enabled: allDone,
          onTap: () => _batchComplete(sel, false),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // ui-structure §3：内嵌视图不持有 AppBar（由任务页容器统一持有）。
    return Scaffold(
      body: Column(
        children: [
          if (_selecting) _buildSelectionHeader(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: SegmentedSelector<int>(
              values: _tabOrder,
              labels: [for (final t in _tabOrder) _tabLabels[t]],
              badges: [for (final t in _tabOrder) _tabBadges[t]],
              selected: _tab,
              equalWidth: false,
              itemWidth: 64,
              scrollController: _tabScrollController,
              onChanged: (i) {
                setState(() {
                  _tab = i;
                  _detailTask = null; // 切换页签自动回列表模式
                });
                _pageController.animateToPage(_tabOrder.indexOf(i),
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut);
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: RefreshIndicator(
              onRefresh: reload,
              child: _loading
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(height: 160),
                        Center(child: CircularProgressIndicator()),
                      ],
                    )
                  : _detailTask != null
                      ? _buildDetailMode(_detailTask!)
                      : PageView(
                          controller: _pageController,
                          onPageChanged: (i) => setState(() {
                            _tab = _tabOrder[i];
                            _detailTask = null; // 滑动翻页自动回列表模式
                          }),
                          children: [
                            for (final t in _tabOrder)
                              _buildTabBody(t),
                          ],
                        ),
            ),
          ),
          if (_selecting) _buildSelectionBar(),
        ],
      ),
    );
  }

  Widget _buildTabBody(int tab) {
    // P1：可见行与子任务分组来自 reload 时的缓存（折叠变化时才重算）。
    final rows = _rowsFor(tab);
    final byParent = _tabByParent[tab] ?? const <String, List<Task>>{};
    switch (tab) {
      case 7:
        return _taskListView(rows, byParent, done: true);
      case 8:
        return _taskListView(rows, byParent, archived: true);
      case 9:
        return _taskListView(rows, byParent, mixed: true);
      default:
        return _taskListView(rows, byParent);
    }
  }

  /// 详情模式（v2.5）：页面下部内嵌 TaskDetailPanel，返回按钮回列表模式。
  Widget _buildDetailMode(Task task) {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: TaskDetailPanel(
        key: ValueKey(task.id),
        task: task,
        onClose: () => setState(() => _detailTask = null),
        onEdit: () => _editTask(task),
        onOpenTask: _jumpToTask,
      ),
    );
  }

  /// 子任务分组（设计 §3）：父任务在同列表时子任务附在父行下缩进，
  /// 父不在本列表的子任务按顶级行平铺；父行可折叠（默认展开）。
  Map<String, List<Task>> _childrenMap(List<Task> tasks) {
    final ids = {for (final t in tasks) t.id};
    final byParent = <String, List<Task>>{};
    for (final t in tasks) {
      final p = t.parentId;
      if (p != null && ids.contains(p)) {
        byParent.putIfAbsent(p, () => []).add(t);
      }
    }
    return byParent;
  }

  List<Task> _visibleRows(List<Task> tasks, Map<String, List<Task>> byParent) {
    final rows = <Task>[];
    for (final t in tasks) {
      final p = t.parentId;
      if (p != null && byParent.containsKey(p)) continue; // 由父行带出
      rows.add(t);
      if (!_collapsedParents.contains(t.id)) {
        rows.addAll(byParent[t.id] ?? const []);
      }
    }
    return rows;
  }

  Widget _tileFor(Task task, Map<String, List<Task>> byParent,
      {bool archived = false, bool recent = false, bool keyed = true}) {
    final isChild =
        task.parentId != null && byParent.containsKey(task.parentId);
    final children = byParent[task.id] ?? const <Task>[];
    final progress = _progress[task.id];
    return TaskTile(
      key: keyed ? _rowKeys.putIfAbsent(task.id, () => GlobalKey()) : null,
      task: task,
      archived: archived,
      recent: recent,
      indent: isChild ? 24 : 0,
      hasChildren: children.isNotEmpty,
      collapsed: _collapsedParents.contains(task.id),
      onToggleCollapse: () => setState(() {
        if (!_collapsedParents.remove(task.id)) {
          _collapsedParents.add(task.id);
        }
        _invalidateRows(); // 折叠只影响可见行
      }),
      progress: (progress != null && progress.$2 > 0) ? progress : null,
      selected: task.id == _selectedTaskId,
      selecting: _selecting,
      multiSelected: _selected.contains(task.id),
      onTap: () {
        if (_selecting) {
          _toggleSelect(task);
        } else {
          _showDetail(task);
        }
      },
      onLongPress: () {
        if (!_selecting) _enterSelection(task);
      },
      onToggleDone:
          archived || _selecting ? null : () => _toggleDone(task),
      onUnarchive:
          archived && !_selecting ? () => _unarchive(task) : null,
      onArchive: task.status == TaskStatus.done && !_selecting
          ? () => _archiveTask(task)
          : null,
      onShowSource: _selecting || task.sourceMessageId == null
          ? null
          : () => _showSourceMessage(task.sourceMessageId!),
    );
  }

  Widget _taskListView(List<Task> rows, Map<String, List<Task>> byParent,
      {bool done = false, bool archived = false, bool mixed = false}) {
    if (rows.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          Center(child: _EmptyHint()),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: rows.length + 1,
      itemBuilder: (context, i) {
        if (i == rows.length) return const SizedBox(height: 32);
        final task = rows[i];
        return _tileFor(task, byParent,
            archived: mixed
                ? task.status == TaskStatus.archived
                : archived,
            recent: mixed
                ? (task.status == TaskStatus.done && _isRecent(task))
                : (done && _isRecent(task)));
      },
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text('无', style: TextStyle(color: scheme.onSurfaceVariant));
  }
}
