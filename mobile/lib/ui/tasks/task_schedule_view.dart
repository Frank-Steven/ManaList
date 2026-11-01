import 'package:flutter/material.dart';

import '../../models/task.dart';
import '../../services/database.dart';
import '../../services/task_scale.dart';
import '../../services/undo_service.dart';
import '../messages/message_widgets.dart';
import 'task_detail_panel.dart';
import 'task_editor.dart';
import 'task_tile.dart';
import 'views/day_view.dart';
import 'views/month_view.dart';
import 'views/schedule_shared.dart';
import 'views/year_view.dart';
import 'views/yearly_view.dart';

/// 任务页·甘特视图宿主（原日程页 SchedulePage，v3 阶段 4 改造；设计 §2，v2.3/v2.4 修订）：
/// 年度/年/月/日四级视图均无限滚动。
///
/// v3 阶段 4 变更：
/// - 粒度不再由本组件内的段选器控制，改由 [granularity] 构造参数下发
///   （任务页顶部「列表/日/月/年/年度」切换）；
/// - 详情面板跳父/子任务需要跨粒度时经 [onSwitchGranularity] 回调请求
///   宿主（任务页）切换视图模式。
///
/// ui-structure §3/§6.2 收编：本视图不持有 AppBar（由任务页容器统一持有）；
/// 期导航（上一期/标题/下一期）降级为内容首行工具条，「现在」定位上收任务页
/// AppBar actions（经 [goNow] 调用）。
///
/// 历史行为（保持不变）：
/// - 任务加载按可视窗口增量缓存（[onVisibleWindowChanged] 驱动），
///   视图滚动即加载，不再按"当前期"整期重查；
/// - 各视图 onVisibleWindowChanged 上报**精确可视范围**（加载提前量在
///   [_ensureRange] 内统一加），底部任务面板 = 可视范围 ∩ scalesForView
///   放行集合的全部任务；
/// - 标题：年 = 「2026」、月 = 「2026-10」、日 = 「2026-10-14 周三」。
///
/// 尺度过滤表（§2）：年视图 = quarterly/monthly/weekly；
/// 月视图 = weekly/daily；日视图 = timed；不定时不进甘特视图。
class TaskScheduleView extends StatefulWidget {
  /// 0=年度 1=年 2=月 3=日（由任务页视图切换器下发）。
  final int granularity;

  /// 详情面板跳转需要切到别的粒度时回调（宿主负责换 mode 并重建本组件）。
  final ValueChanged<int>? onSwitchGranularity;

  const TaskScheduleView({
    super.key,
    required this.granularity,
    this.onSwitchGranularity,
  });

  @override
  State<TaskScheduleView> createState() => TaskScheduleViewState();
}

class TaskScheduleViewState extends State<TaskScheduleView>
    with SingleTickerProviderStateMixin {
  /// 当前视图的可视中心（由各视图 onCenterChanged 回写）。
  DateTime _anchor = DateTime.now();

  Task? _selectedTask;

  /// 底部面板模式（v2.5）：false=任务列表（默认），true=任务详情。
  /// 图表点选只选中（列表高亮定位），不直接进详情；列表行点击才进详情。
  bool _detailMode = false;

  /// _jumpToTask 主动换粒度时置位：didUpdateWidget 不重置选中/详情。
  bool _pendingJump = false;

  /// 底部列表行 key（选中任务滚动定位用）。
  final Map<String, GlobalKey> _bottomRowKeys = {};

  /// 当前视图的精确可视范围（各视图 onVisibleWindowChanged 上报，v2.4）——
  /// 用于底部任务面板与标题。
  int? _visStartMs;
  int? _visEndMs;

  /// 增量任务缓存：覆盖 [_cacheStart, _cacheEnd] 区间（按 id 覆盖式合并）。
  final Map<String, Task> _cache = {};
  int? _cacheStart;
  int? _cacheEnd;
  bool _loading = true;

  // ---- P1 性能：_cache 派生列表缓存 ----
  /// _cache 内容版本：任何写入（清空/合并）都递增，用于失效派生列表。
  int _cacheRevision = 0;

  /// 甘特区任务列表缓存（键 = _cache 版本 + 当前粒度）。
  ///
  /// 注意：读取端 [_ganttTasks] 必须 lazy memo —— 未命中就**现算并回填**，
  /// 绝不能返回默认空列表，否则会静默降级成「图表整块没任务」。
  List<Task>? _ganttCache;
  int _ganttCacheRevision = -1;
  int _ganttCacheGranularity = -1;

  final _yearlyKey = GlobalKey<YearlyViewState>();
  final _yearKey = GlobalKey<YearViewState>();
  final _monthKey = GlobalKey<MonthViewState>();
  final _dayKey = GlobalKey<DayViewState>();

  // ---- 甘特 / 底部任务列表分栏：展开/收起双模态（2026-11-01 改为跟随拖拽）----
  //
  // 交互（2026-11-01 改版，替代期导航工具条上的展开/收起按钮）：
  //  · 展开态：列表内容滚动到顶部后继续向下拖拽，面板高度跟随手指，
  //    松手按位置/速度决定收起还是回弹展开（标题行本身也可直接拖拽）；
  //  · 收起态：点击标题行展开，或向上拖拽，松手按位置/速度决定；
  //  · 展开态高度 = 分栏视口的 [_barExpandedRatio]（约屏高 35%），
  //    收起态 = 只留列表标题行（[_barCollapsedH]，含该期任务数）；
  //  · 状态按粒度记忆在 State 内（[_barExpandedByGranularity]），不持久化。
  static const _barCollapsedH = 40.0;
  static const _barExpandedRatio = 0.35;

  /// 各粒度下底部任务列表是否展开（缺省 = 展开）。
  final Map<int, bool> _barExpandedByGranularity = {};

  bool get _barExpanded =>
      _barExpandedByGranularity[widget.granularity] ?? true;

  set _barExpanded(bool v) =>
      _barExpandedByGranularity[widget.granularity] = v;

  /// 拖拽中的面板高度（null = 未拖拽，高度由 [_barExpanded] 推导）。
  double? _dragBarH;

  /// 松手后的吸附动画。
  AnimationController? _barAnim;

  /// 当前面板高度（拖拽中取 [_dragBarH]，否则按展开状态推导）。
  double _barHeight(double vp) {
    final expandedH = vp * _barExpandedRatio;
    final drag = _dragBarH;
    if (drag != null) return drag.clamp(_barCollapsedH, expandedH);
    return _barExpanded ? expandedH : _barCollapsedH;
  }

  void _barDragStart(double vp) {
    _barAnim?.stop();
    _dragBarH = _barHeight(vp);
  }

  /// [dy] 为手指纵向位移（正 = 向下，面板变矮）。
  void _barDragUpdate(double dy, double vp) {
    final expandedH = vp * _barExpandedRatio;
    setState(() =>
        _dragBarH = (_dragBarH! - dy).clamp(_barCollapsedH, expandedH));
  }

  /// 松手：只看松手位置——面板顶边落在展开区域的上半（高度超过展开
  /// 高度的一半）则吸附展开，否则收起；随后动画吸附到稳定态。
  void _barDragEnd(double vp) {
    final expandedH = vp * _barExpandedRatio;
    final h = _dragBarH ?? _barHeight(vp);
    _snapBarTo(vp, h > expandedH / 2);
  }

  /// 动画吸附到展开/收起稳定态（松手吸附与点击切换共用同一条路径，
  /// 保证面板只有两种稳定状态，拖拽中间值永远不会停留）。
  void _snapBarTo(double vp, bool expand) {
    final expandedH = vp * _barExpandedRatio;
    final target = expand ? expandedH : _barCollapsedH;
    final h = _dragBarH ?? _barHeight(vp);
    setState(() => _barExpanded = expand);
    if ((h - target).abs() < 0.5) {
      _dragBarH = null;
      return;
    }
    _barAnim?.dispose();
    final ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 180));
    final anim = Tween(begin: h, end: target)
        .animate(CurvedAnimation(parent: ctrl, curve: Curves.easeOut));
    ctrl.addListener(() {
      if (mounted) setState(() => _dragBarH = anim.value);
    });
    ctrl.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        setState(() => _dragBarH = null);
        ctrl.dispose();
        if (_barAnim == ctrl) _barAnim = null;
      }
    });
    _barAnim = ctrl;
    ctrl.forward();
  }

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void dispose() {
    _barAnim?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TaskScheduleView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.granularity == widget.granularity) return;
    if (_pendingJump) {
      // _jumpToTask 主动换粒度：选中/详情保留，滚动由 _jumpToTask 自己安排
      _pendingJump = false;
      return;
    }
    // 宿主切换视图模式（纯 Tab 切换）：清选中，锚点重置到现在——
    // 新挂载的视图会自行定位到当前（月/年 scrollToNow、日首帧居中），
    // 不要再跳到旧锚点（2026-11-01 修复：原先这里两帧后 _scrollCurrentTo
    // 旧锚点，视图先正确定位到「现在」又被跳走）。
    setState(() {
      _selectedTask = null;
      _detailMode = false;
      _anchor = DateTime.now();
    });
  }

  /// 布局：**永远铺满屏幕**，自由度只有「底部任务列表展开 / 收起」两态。
  /// 图表 = 视口 − 列表区，不再有页面滚动，也不再有手动拖拽分割线。
  Widget _splitBody(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final vp = constraints.maxHeight;
      if (!vp.isFinite || vp <= 0) {
        return Column(children: [
          Expanded(flex: 3, child: _ganttView()),
          Expanded(flex: 2, child: _bottomSection(context, vp)),
        ]);
      }
      final barH = _barHeight(vp);
      return Column(children: [
        // 粒度切换：淡出淡入 + 轻微横移过渡。时长与任务页 TabBar 指示器
        // 动画（kTabScrollDuration 300ms）一致，两者同步起跑同步结束。
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                        begin: const Offset(0.04, 0), end: Offset.zero)
                    .animate(anim),
                child: child,
              ),
            ),
            child: KeyedSubtree(
              key: ValueKey('gantt-${widget.granularity}'),
              // 任务数据变化（拖放/新建/编辑/删除落库后 reload）时，
              // 图形层做一次快速 settle 过渡，替代生硬跳变
              child: _GanttSettleTransition(
                revision: _cacheRevision,
                child: _ganttView(),
              ),
            ),
          ),
        ),
        // 列表/详情内容滚到顶部后继续下拉 → 面板跟随手指变矮（收起手势）
        NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is OverscrollNotification &&
                n.overscroll < 0 &&
                n.metrics.axis == Axis.vertical) {
              // 顶部继续下拉且面板还有高度可让：overscroll 为负，累减到面板高度
              if (_barHeight(vp) > _barCollapsedH + 1) {
                _dragBarH ??= _barHeight(vp);
                _barDragUpdate(-n.overscroll, vp);
              }
            } else if (n is ScrollEndNotification && _dragBarH != null) {
              // 松手必须吸附（修复：旧守卫按高度拦截，拖到底时把
              // ScrollEnd 一并挡掉，面板卡在 40px 的压缩中间态）
              _barDragEnd(vp);
            }
            return false;
          },
          child: SizedBox(height: barH, child: _bottomSection(context, vp)),
        ),
      ]);
    });
  }

  /// _cache 内容变了：递增版本，派生列表（[_ganttTasks]）下次读到时按需重算。
  void _markCacheDirty() => _cacheRevision++;

  /// 初始/全量刷新：清空缓存，加载可视中心 ±2 年。
  Future<void> reload() async {
    _cache.clear();
    _markCacheDirty();
    _cacheStart = null;
    _cacheEnd = null;
    final y = _anchor.year;
    await _ensureRange(
      DateTime(y - 2).millisecondsSinceEpoch,
      DateTime(y + 3).millisecondsSinceEpoch,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      final sel = _selectedTask;
      if (sel != null) _selectedTask = _cache[sel.id] ?? sel;
    });
  }

  /// 视口超出缓存范围时增量加载（向两侧各扩一个窗口宽做提前量）。
  Future<void> _ensureRange(int startMs, int endMs) async {
    final cs = _cacheStart, ce = _cacheEnd;
    if (cs != null && ce != null && startMs >= cs && endMs <= ce) return;
    final span = endMs - startMs;
    final ns = (cs == null
            ? startMs
            : (startMs < cs ? startMs : cs)) -
        span;
    final ne =
        (ce == null ? endMs : (endMs > ce ? endMs : ce)) + span;
    final db = AppDatabase.instance;
    // active 为主，done 淡色/划线展示；archived 不显示。
    // getTasksOverlapping 无条件包含年度任务，这里按平移后的发生年过滤。
    final results = await Future.wait([
      db.getTasksOverlapping(ns, ne),
      db.getTasksOverlapping(ns, ne, status: TaskStatus.done),
    ]);
    final tasks = [...results[0], ...results[1]]
        .where((t) => occurrenceOverlapping(t, ns, ne) != null);
    if (!mounted) return;
    setState(() {
      for (final t in tasks) {
        _cache[t.id] = t;
      }
      _cacheStart =
          _cacheStart == null ? ns : (_cacheStart! < ns ? _cacheStart! : ns);
      _cacheEnd = _cacheEnd == null ? ne : (_cacheEnd! > ne ? _cacheEnd! : ne);
      _markCacheDirty(); // 合并进 _cache 后派生列表失效
    });
  }

  /// 甘特区任务：按当前粒度的尺度过滤表过滤（v2.4：不再对 is_annual
  /// 特判——该概念 UI 下线，老数据按派生尺度进各视图）。
  ///
  /// P1：按（_cache 版本, 粒度）lazy 缓存。原来每次 build 都会对全量 _cache
  /// 重跑 scalesForView + 全表 filter + toList：可视窗口滚动
  /// [_onWindowChanged] 每次 setState 都重来一遍，且下发给子视图的列表
  /// 每帧都是新实例（子视图还得逐项比内容）。命中时直接返回同一个 List。
  List<Task> get _ganttTasks {
    final cached = _ganttCache;
    if (cached != null &&
        _ganttCacheRevision == _cacheRevision &&
        _ganttCacheGranularity == widget.granularity) {
      return cached;
    }
    // 未命中：现算并回填（禁止返回默认空列表）
    final tasks = _filterByScales(_ganttScaleView);
    _ganttCache = tasks;
    _ganttCacheRevision = _cacheRevision;
    _ganttCacheGranularity = widget.granularity;
    return tasks;
  }

  /// 当前粒度对应的尺度放行集合名（与 [_filterByScales] 入参同一套映射）。
  String get _ganttScaleView => switch (widget.granularity) {
        0 => 'yearly',
        1 => 'year',
        2 => 'month',
        _ => 'day',
      };

  List<Task> _filterByScales(String view) {
    final scales = scalesForView(view);
    return _cache.values
        .where((t) =>
              scales.contains(deriveTaskScale(t.startAt, t.endAt, kind: t.kind)))
        .toList();
  }

  /// 底部任务列表板块（v2.4 §13 修订）：当前**可视时间范围**内、且尺度在
  /// 当前视图放行集合（scalesForView）内的全部任务，不再限定单一尺度。
  List<Task> get _bottomTasks {
    final viewName =
        const ['yearly', 'year', 'month', 'day'][widget.granularity];
    final scales = scalesForView(viewName);
    final vs = _visStartMs, ve = _visEndMs;
    if (vs == null || ve == null) return const [];
    return _cache.values
        .where((t) =>
            t.status == TaskStatus.active &&
            t.startAt != null &&
            scales.contains(deriveTaskScale(t.startAt, t.endAt, kind: t.kind)) &&
            occurrenceOverlapping(t, vs, ve) != null)
        .toList()
      ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
  }

  void _showUndoSnack(String label) {
    showUndoSnackBar(context, label, onUndone: () async => reload());
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
      if (!mounted) return; // P3-5：删除后可能已离开页面
      setState(() => _selectedTask = null);
      _detailMode = false;
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
          await db.updateTask(task);
          if (parentBefore != null) await db.updateTask(parentBefore);
        },
      );
      await reload();
      if (mounted) _showUndoSnack('已保存');
    }
  }

  Future<void> _createTask({int? seedStartAt, String? seedKind}) async {
    final result = await showTaskEditor(context,
        seedStartAt: seedStartAt, seedKind: seedKind);
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

  /// 拖拽落库：更新时间 + 撤销（恢复旧任务）+ 刷新。
  Future<void> _moveTask(Task task, int newStartMs, int? newEndMs) async {
    final updated = task.copyWith(
      startAt: () => newStartMs,
      endAt: () => newEndMs,
    );
    final db = AppDatabase.instance;
    await db.updateTask(updated);
    UndoService.instance.register(
      label: '已调整时间',
      undo: () => db.updateTask(task),
    );
    await reload();
    if (mounted) _showUndoSnack('已调整时间');
  }

  /// 勾选完成/取消完成（底部板块，设计 §2 行 UI 照搬待办列表）。
  Future<void> _toggleDone(Task task) =>
      toggleTaskDoneWithUndo(context, task, onChanged: reload);

  /// 详情面板中点父/子任务：按目标任务的尺度切换到能展示它的粒度并定位，
  /// 选中并展示其详情。跨粒度时经 [TaskScheduleView.onSwitchGranularity]
  /// 请宿主换 mode（v3 阶段 4；年度尺度任务落到年度视图）。
  void _jumpToTask(Task t) {
    final s = t.startAt;
    if (s == null) return; // 不定时任务在甘特无视图可跳
    final g = switch (deriveTaskScale(t.startAt, t.endAt, kind: t.kind)) {
      'yearly' => 0,
      'quarterly' || 'monthly' => 1,
      'weekly' || 'daily' => 2,
      _ => 3,
    };
    setState(() {
      _selectedTask = t;
      _detailMode = true;
      _anchor = DateTime.fromMillisecondsSinceEpoch(s);
      _barExpandedByGranularity[g] = true; // 详情需要列表区空间，强制展开
    });
    if (g != widget.granularity) {
      _pendingJump = true;
      widget.onSwitchGranularity?.call(g);
    }
    _afterTwoFrames(() {
      switch (g) {
        case 0:
          _yearlyKey.currentState?.scrollToTask(t);
        case 1:
          _yearKey.currentState?.scrollToTask(t);
        case 2:
          _monthKey.currentState?.scrollToTask(t);
        case 3:
          _dayKey.currentState?.scrollToTask(t);
      }
    });
  }

  /// 等两帧再定位：第一帧新视图挂载（其首帧 scrollToNow），第二帧覆盖到目标。
  void _afterTwoFrames(VoidCallback fn) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) => fn());
    });
  }

  /// 图表点选（v2.5）：只选中——图表描边 + 底部列表滚动高亮定位，
  /// 不直接打开详情；空白取消选中时详情模式一并退出。
  void _onTaskSelected(Task? t) {
    setState(() {
      _selectedTask = t;
      if (t == null) {
        _detailMode = false;
      }
    });
    if (t == null) return;
    // 选中的任务应当就在底部列表（同一可视范围 ∩ 尺度集合）；
    // 边界情况（拖拽出可视范围等）给短暂提示
    if (!_bottomTasks.any((e) => e.id == t.id)) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('该任务不在当前可视范围的任务列表中'),
            duration: Duration(seconds: 2)));
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _bottomRowKeys[t.id]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          alignment: 0.5,
        );
      }
    });
  }

  /// 可视窗口变化：记录精确可视范围（底部面板/标题用）+ 增量加载。
  void _onWindowChanged(int startMs, int endMs) {
    setState(() {
      _visStartMs = startMs;
      _visEndMs = endMs;
    });
    _ensureRange(startMs, endMs);
  }

  /// 兜底窗口（B01，2026-10-20）：各视图的可视范围是首帧 post-frame 才上报的，
  /// 在那之前 `_visStartMs/_visEndMs` 为 null，`_bottomTasks` 直接返回空数组 ——
  /// 表现就是「刚进视图，底部显示任务 0，图上明明有任务」。
  /// 这里按当前粒度与锚点推算一个合理的默认窗口，视图上报后再被真实值覆盖。
  String _windowSeedKey = '';

  void _maybeSeedWindow() {
    final key =
        '${widget.granularity}|${_anchor.year}-${_anchor.month}-${_anchor.day}';
    if (_visStartMs != null && _windowSeedKey == key) return;
    _windowSeedKey = key;
    final a = _anchor;
    late DateTime s, e;
    switch (widget.granularity) {
      case 0: // 年度视图：±20 年（与标题区间一致）
        s = DateTime(a.year - 20);
        e = DateTime(a.year + 21);
      case 1: // 年视图
        s = DateTime(a.year);
        e = DateTime(a.year + 1);
      case 2: // 月视图
        s = DateTime(a.year, a.month);
        e = DateTime(a.year, a.month + 1);
      default: // 日视图
        s = DateTime(a.year, a.month, a.day);
        e = DateTime(a.year, a.month, a.day + 1);
    }
    _visStartMs = s.millisecondsSinceEpoch;
    _visEndMs = e.millisecondsSinceEpoch;
  }

  /// 标题栏箭头平移：年度 ±20 年、年 ±1 年、月 ±1 月、日 ±1 天。
  /// 按钮触发的定位平滑滚动（2026-11-01：原先硬跳，图形位置突变）。
  void _shiftPeriod(int delta) {
    final target = switch (widget.granularity) {
      0 => DateTime(_anchor.year + delta * 20, _anchor.month),
      1 => DateTime(_anchor.year + delta, _anchor.month),
      2 => DateTime(_anchor.year, _anchor.month + delta),
      _ => DateTime(_anchor.year, _anchor.month, _anchor.day + delta),
    };
    setState(() => _anchor = target);
    _scrollCurrentTo(target, animated: true);
  }

  /// 滚动当前粒度视图到指定日期（[animated] = 平滑滚动，按钮定位用）。
  void _scrollCurrentTo(DateTime target, {bool animated = false}) {
    switch (widget.granularity) {
      case 0:
        _yearlyKey.currentState?.scrollTo(target, animated: animated);
      case 1:
        _yearKey.currentState?.scrollTo(target, animated: animated);
      case 2:
        _monthKey.currentState?.scrollTo(target, animated: animated);
      case 3:
        _dayKey.currentState?.scrollTo(target, animated: animated);
    }
  }

  /// 任务页 AppBar「现在」入口（ui-structure §6.2：仅甘特模式显示）。
  void goNow() => _goNow();

  void _goNow() {
    switch (widget.granularity) {
      case 0:
        _yearlyKey.currentState?.scrollToNow(animated: true);
      case 1:
        _yearKey.currentState?.scrollToNow(animated: true);
      case 2:
        _monthKey.currentState?.scrollToNow(animated: true);
      case 3:
        _dayKey.currentState?.scrollToNow(animated: true);
    }
  }

  /// AppBar 标题（v2.4）：年 = 「2026」；月 = 「2026-10」；日 = 「2026-10-14 周三」。
  String get _title {
    switch (widget.granularity) {
      case 0:
        final vs = _visStartMs, ve = _visEndMs;
        if (vs != null && ve != null) {
          final first = DateTime.fromMillisecondsSinceEpoch(vs).year;
          final last =
              DateTime.fromMillisecondsSinceEpoch(ve - 1).year;
          return '$first–$last';
        }
        return '${_anchor.year - 10}–${_anchor.year + 9}';
      case 2:
        final m = _anchor.month.toString().padLeft(2, '0');
        return '${_anchor.year}-$m';
      case 3:
        const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
        final mo = _anchor.month.toString().padLeft(2, '0');
        final d = _anchor.day.toString().padLeft(2, '0');
        return '${_anchor.year}-$mo-$d ${weekdays[_anchor.weekday - 1]}';
      default:
        return '${_anchor.year}';
    }
  }

  Widget _ganttView() {
    final tasks = _ganttTasks;
    switch (widget.granularity) {
      case 0:
        return YearlyView(
          key: _yearlyKey,
          tasks: tasks,
          selectedTaskId: _selectedTask?.id,
          onTaskSelected: _onTaskSelected,
          onTaskMoved: _moveTask,
          onYearTap: (year) {
            final target = DateTime(year, 7);
            setState(() => _anchor = target);
            _pendingJump = true; // 下钻自带定位（下方 scrollTo），跳过 didUpdateWidget
            widget.onSwitchGranularity?.call(1);
            _afterTwoFrames(() => _yearKey.currentState?.scrollTo(target));
          },
          onVisibleWindowChanged: _onWindowChanged,
          onCenterChanged: (c) => setState(() => _anchor = c),
        );
      case 2:
        return MonthView(
          key: _monthKey,
          tasks: tasks,
          selectedTaskId: _selectedTask?.id,
          onTaskSelected: _onTaskSelected,
          onDayTap: (ms) {
            final d = DateTime.fromMillisecondsSinceEpoch(ms);
            final target = DateTime(d.year, d.month, d.day);
            setState(() => _anchor = target);
            _pendingJump = true;
            widget.onSwitchGranularity?.call(3);
            _afterTwoFrames(() => _dayKey.currentState?.scrollTo(target));
          },
          onTaskMoved: _moveTask,
          onBlankLongPress: (ms) => _createTask(
            seedStartAt: ms + const Duration(hours: 9).inMilliseconds,
            seedKind: TaskKind.point,
          ),
          onVisibleWindowChanged: _onWindowChanged,
          onCenterChanged: (c) => setState(() => _anchor = c),
        );
      case 3:
        return DayView(
          key: _dayKey,
          tasks: tasks,
          selectedTaskId: _selectedTask?.id,
          onTaskSelected: _onTaskSelected,
          onTaskMoved: _moveTask,
          onBlankLongPress: (ms) => _createTask(
            seedStartAt: ms,
            seedKind: TaskKind.point,
          ),
          onVisibleWindowChanged: _onWindowChanged,
          onCenterChanged: (c) => setState(() => _anchor = c),
        );
      default:
        return YearView(
          key: _yearKey,
          tasks: tasks,
          selectedTaskId: _selectedTask?.id,
          onTaskSelected: _onTaskSelected,
          onMonthTap: (ms) {
            final m = DateTime.fromMillisecondsSinceEpoch(ms);
            final target = DateTime(m.year, m.month, 15);
            setState(() => _anchor = target);
            _pendingJump = true;
            widget.onSwitchGranularity?.call(2);
            _afterTwoFrames(() => _monthKey.currentState?.scrollTo(target));
          },
          onTaskMoved: _moveTask,
          onBlankLongPress: (ms) {
            final m = DateTime.fromMillisecondsSinceEpoch(ms);
            _createTask(
              seedStartAt:
                  DateTime(m.year, m.month, 1, 9).millisecondsSinceEpoch,
              seedKind: TaskKind.range,
            );
          },
          onVisibleWindowChanged: _onWindowChanged,
          onCenterChanged: (c) => setState(() => _anchor = c),
        );
    }
  }

  /// 底部板块（2026-11-01 拖拽版）：收起态只留标题行（点击展开 / 上拖跟随）；
  /// 展开态 = 详情模式 TaskDetailPanel（带返回按钮）或可视范围任务列表
  /// （选中行高亮，点击行进详情），内容滚到顶部后继续下拉 = 面板跟随手指收起。
  Widget _bottomSection(BuildContext context, double vp) {
    if (!_barExpanded && _dragBarH == null) {
      return Column(children: [
        const Divider(height: 1),
        _dragHandleHeader(context, vp, _bottomTasks.length),
      ]);
    }
    final selected = _selectedTask;
    if (_detailMode && selected != null) {
      return Column(children: [
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            // Clamping：顶部继续下拉时发 OverscrollNotification（收起手势）
            physics: const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics()),
            child: TaskDetailPanel(
              key: ValueKey(selected.id),
              task: selected,
              onClose: () => setState(() => _detailMode = false),
              onEdit: () => _editTask(selected),
              onOpenTask: _jumpToTask,
            ),
          ),
        ),
      ]);
    }
    final tasks = _bottomTasks;
    return Column(
      children: [
        const Divider(height: 1),
        _dragHandleHeader(context, vp, tasks.length),
        Expanded(
          child: tasks.isEmpty
              ? Center(
                  child: Text('无',
                      style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant)),
                )
              : ListView.builder(
                  // AlwaysScrollable + Clamping：短列表滚到顶部继续下拉时
                  // 也能发 OverscrollNotification（面板跟随手指收起）
                  physics: const AlwaysScrollableScrollPhysics(
                      parent: ClampingScrollPhysics()),
                  itemCount: tasks.length,
                  itemBuilder: (context, i) {
                    final task = tasks[i];
                    return TaskTile(
                      key: _bottomRowKeys.putIfAbsent(
                          task.id, () => GlobalKey()),
                      task: task,
                      selected: task.id == _selectedTask?.id,
                      onTap: () => setState(() {
                        // 详情需要列表区空间：若当前收起则顺手展开
                        _barExpandedByGranularity[widget.granularity] = true;
                        _selectedTask = task;
                        _detailMode = true;
                      }),
                      onToggleDone: () => _toggleDone(task),
                      onShowSource: task.sourceMessageId == null
                          ? null
                          : () => _showSourceMessage(task.sourceMessageId!),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 列表标题行：整行点击 = 展开/收起切换；纵向拖拽跟随手指调面板高度，
  /// 松手按位置吸附（展开区域上半 → 展开，否则收起）。
  Widget _dragHandleHeader(BuildContext context, double vp, int count) {
    final draggable = vp.isFinite && vp > 0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 两态都响应点击：收起态展开、展开态收起（吸附动画与拖拽松手同路径）
      onTap: () => _snapBarTo(vp, !_barExpanded),
      onVerticalDragStart: draggable ? (_) => _barDragStart(vp) : null,
      onVerticalDragUpdate:
          draggable ? (d) => _barDragUpdate(d.delta.dy, vp) : null,
      onVerticalDragEnd: draggable ? (d) => _barDragEnd(vp) : null,
      // 手势被抢走（系统手势/多指）也要吸附回稳定态，不留中间高度
      onVerticalDragCancel:
          draggable && _dragBarH != null ? () => _barDragEnd(vp) : null,
      child: SizedBox(
        height: _barCollapsedH,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
          child: Row(
            children: [
              Text('任务', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(width: 8),
              Text('$count',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant)),
              const Spacer(),
              Icon(
                _barExpanded ? Icons.expand_more : Icons.expand_less,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
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

  /// 期导航首行工具条（原 AppBar 标题 Row 降级而来）：上一期/标题/下一期。
  /// 底部任务列表的展开/收起改为面板自身拖拽手势（2026-11-01），
  /// 「现在」已上收任务页 AppBar actions（ui-structure §6.2）。
  Widget _buildPeriodHeader() {
    return SizedBox(
      height: 48,
      child: Row(children: [
        IconButton(
          tooltip: '上一期',
          visualDensity: VisualDensity.compact,
          onPressed: () => _shiftPeriod(-1),
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(child: Center(child: Text(_title))),
        IconButton(
          tooltip: '下一期',
          visualDensity: VisualDensity.compact,
          onPressed: () => _shiftPeriod(1),
          icon: const Icon(Icons.chevron_right),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    // B01：视图还没上报可视窗口时，先用推算窗口，避免底部「任务 0」闪一下
    _maybeSeedWindow();

    // ui-structure §3：内嵌视图不持有 AppBar（由任务页容器统一持有）。
    return Scaffold(
      body: Column(
        children: [
          _buildPeriodHeader(),
          const Divider(height: 1),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else
            // 甘特图 + 底部任务列表（展开/收起双模态，无拖拽分割线）。
            Expanded(child: _splitBody(context)),
        ],
      ),
    );
  }
}

/// 甘特图形层的数据变化过渡（2026-11-01）：任务拖放/新建/编辑落库后
/// 任务条会跳到新位置——视图是 CustomPainter 渲染，逐条任务插值成本
/// 高，这里对整层做一次快速「淡入 + 轻微上移」settle 动画，让图形
/// 变化读起来是连续过渡而不是生硬跳变。[revision] 变化时重放一次。
class _GanttSettleTransition extends StatefulWidget {
  final int revision;
  final Widget child;

  const _GanttSettleTransition({required this.revision, required this.child});

  @override
  State<_GanttSettleTransition> createState() =>
      _GanttSettleTransitionState();
}

class _GanttSettleTransitionState extends State<_GanttSettleTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 200), value: 1);

  @override
  void didUpdateWidget(_GanttSettleTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) {
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) => Opacity(
        opacity: 0.55 + 0.45 * _ctrl.value,
        child: Transform.translate(
          offset: Offset(0, 6 * (1 - _ctrl.value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}
