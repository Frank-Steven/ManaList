import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../../models/task.dart';
import 'layout.dart';
import 'schedule_shared.dart';

enum _DragMode { move, resizeStart, resizeEnd }

/// 年度视图（设计 §2.1，v2.3 修订）：横向年份轴**双向无限滚动**
/// （坐标 = 2000 年起算的绝对年小数，初始居中当前年），捏合缩放
/// （焦点锚定），刻度档 1/5/10 年，年份标注 -45° 斜向上。
/// 尺度为 yearly 的任务：单年内 = 节点、跨年 = 带端点线段；当前年高亮竖带。
/// （v2.4：is_annual 逐年节点下线，老 is_annual 任务按普通任务画。）
///
/// 选中-调整（v2.3 §13-6）：点按任务出现描边选中态，仅选中任务可拖拽
/// （移动 = 整数年平移保留月日；起止端点吸附年界；无跨度上限）；
/// 有选中时点空白 = 取消选中，无选中时点空白 = 下钻该年的年视图。
///
/// R01 重做（2026-10-20，Frank 算法，用户拍板）：
/// - **行分配**：不再按优先级分泳道。填充顺序 = 优先级优先
///   （important 红靠上 → normal 居中 → minor 绿靠下，2026-10-28 分行规则），
///   同优先级内按开始时间；逐个从第 1 行
///   开始试；该行已有任务与它的**投影间距 < 130px**（≈20 字标签宽）就算占用，
///   换下一行；**行数不限**，按需向下增长（行区可纵向平移）。
/// - **标签**：单行、**不合并不换行**、先到先得；贴在任务节点**正上方**的本行
///   标签线上；线段任务挂在「最左侧能放下的点」正上方；放不下就不显示
///   （不截断、不挤）。不再使用 LabelGroup/assignGroupNames 的分组与 45° 斜排。
/// - 节点**不再合并**：每个任务独立绘制，点按节点 = 选中并显示详情。
class YearlyView extends StatefulWidget {
  /// 已按年度视图尺度过滤的任务（yearly，覆盖可视窗口）。
  final List<Task> tasks;
  final String? selectedTaskId;
  final ValueChanged<Task?> onTaskSelected;

  /// 拖拽落库回调：(原任务, 新 startAt, 新 endAt)。
  final void Function(Task task, int newStartMs, int? newEndMs) onTaskMoved;

  /// 点按空白年格（无选中时）：下钻该年的年视图。
  final ValueChanged<int> onYearTap;

  final void Function(int startMs, int endMs) onVisibleWindowChanged;
  final ValueChanged<DateTime> onCenterChanged;

  const YearlyView({
    super.key,
    required this.tasks,
    required this.selectedTaskId,
    required this.onTaskSelected,
    required this.onTaskMoved,
    required this.onYearTap,
    required this.onVisibleWindowChanged,
    required this.onCenterChanged,
  });

  @override
  State<YearlyView> createState() => YearlyViewState();
}

class YearlyViewState extends State<YearlyView>
    with TickerProviderStateMixin {
  /// 缩放范围：最小 = 20 年铺满可视宽，最大 = 每年 320dp。
  static const _maxPpy = 320.0;

  /// 绝对年小数基准（2000-01-01）。
  static const _epochYear = 2000;

  /// 实际可滚动范围：1900 ~ 2200 年。
  static const _minYear = 1900;
  static const _maxYear = 2200;

  double? _ppy; // null = 未初始化，首帧定位到当前年
  double _scrollYf = 0; // 左边缘的绝对年小数
  bool _positioned = false;
  double _viewW = 0;
  double _startPpy = 0;
  double _startScrollYf = 0;
  double _startFocalX = 0;

  /// R01：标签 TextPainter 缓存（跨帧复用；主题变化清空）。
  final _YearlyTextCache _texts = _YearlyTextCache();

  /// R01：行区纵向平移（行数不限，超出可视高度靠上下拖动看）。
  /// 0 = 顶部对齐；build 内按「行总高 - 可视高」夹紧后回写。
  double _contentY = 0;
  double _startContentY = 0;
  double _startFocalY = 0;

  /// 待纵向定位的任务 id（scrollToTask 登记，build 里按布局换算后消费）。
  String? _pendingRowTarget;

  Task? _dragOriginal;
  _DragMode? _dragMode;
  int _deltaYears = 0; // 预览位移（整数年）
  int _origStartMs = 0;
  int? _origEndMs;

  /// 「现在」脉冲高亮的目标年，1.5 秒后恢复。
  int? _pulseYear;
  Timer? _pulseTimer;

  /// fling 惯性滚动（v2.4）：水平甩动后按摩擦衰减继续平移。
  AnimationController? _flingCtrl;
  double _flingStartYf = 0;

  void _cancelFling() {
    _flingCtrl?.stop();
    _flingCtrl?.dispose();
    _flingCtrl = null;
  }

  void _startFling(double vxPxPerSec) {
    final ppy = _ppy;
    if (ppy == null || vxPxPerSec.abs() < 120) return; // 低速不惯性
    _cancelFling();
    _flingStartYf = _scrollYf;
    // 模拟值 = 像素位移（正 = 手指向右甩）；scrollYf 反向变化
    final sim = FrictionSimulation(0.09, 0, vxPxPerSec);
    final ctrl = AnimationController.unbounded(vsync: this);
    ctrl.addListener(() {
      final next = _flingStartYf - ctrl.value / ppy;
      if (next <= _minScroll || next >= _maxScroll) {
        // 撞边界即停；value 通知循环里不能就地 dispose 自己，帧末回收
        final c = _flingCtrl;
        if (c != null) {
          _flingCtrl = null;
          c.stop();
          WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
        }
        setState(
            () => _scrollYf = next.clamp(_minScroll, _maxScroll));
        _reportWindow();
        return;
      }
      setState(() => _scrollYf = next);
      _reportOnUnitChange(); // v2.6.1：惯性中标题实时跟随（单位变化才上报）
    });
    ctrl.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        _cancelFling();
        _reportWindow();
      }
    });
    _flingCtrl = ctrl;
    ctrl.animateWith(sim);
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    _cancelFling();
    super.dispose();
  }

  /// 毫秒时间戳 → 绝对年小数（按各年实际长度插值）。
  static double _yearFraction(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final y0 = DateTime(d.year).millisecondsSinceEpoch;
    final y1 = DateTime(d.year + 1).millisecondsSinceEpoch;
    return d.year - _epochYear + (ms - y0) / (y1 - y0);
  }

  double get _minScroll => _minYear - _epochYear.toDouble();
  double get _maxScroll => _maxYear - _epochYear.toDouble();

  static int _shiftYears(int ms, int dy) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return DateTime(d.year + dy, d.month, d.day, d.hour, d.minute, d.second)
        .millisecondsSinceEpoch;
  }

  // ---- 供父级调用的定位方法 ----

  /// 按钮定位的平滑滚动（期移箭头/「现在」，2026-11-01）：300ms easeOutCubic
  /// 平移到目标位置。复用 _flingCtrl 槽位，取消/回收路径与 fling 一致。
  void _animateScrollTo(double targetYf) {
    _cancelFling();
    final start = _scrollYf;
    if ((targetYf - start).abs() < 0.0001) {
      setState(() => _scrollYf = targetYf);
      _reportWindow();
      return;
    }
    final ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    final curve = CurvedAnimation(parent: ctrl, curve: Curves.easeOutCubic);
    ctrl.addListener(() {
      setState(() => _scrollYf = start + (targetYf - start) * curve.value);
      _reportOnUnitChange(); // 标题实时跟随（单位变化才上报）
    });
    ctrl.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        _cancelFling();
        _reportWindow();
      }
    });
    _flingCtrl = ctrl;
    ctrl.forward();
  }

  /// 滚动到当前年并居中，短暂脉冲高亮（设计 §13-10）。
  /// v2.6.1：先停掉进行中的 fling 动画，否则动画下一帧会覆盖定位。
  /// [animated]：按钮触发的定位平滑滚动，首帧自动定位保持硬跳。
  void scrollToNow({bool animated = false}) {
    _cancelFling();
    final ppy = _ppy ?? (_viewW > 0 ? _viewW / 20 : 20.0);
    final nowYf = _yearFraction(DateTime.now().millisecondsSinceEpoch);
    final target = (nowYf - _viewW / (2 * ppy)).clamp(_minScroll, _maxScroll);
    if (animated) {
      setState(() {
        _contentY = 0; // 定位语义：回到顶部第一行
        _positioned = true;
      });
      _animateScrollTo(target);
    } else {
      setState(() {
        _scrollYf = target;
        _contentY = 0; // 定位语义：回到顶部第一行
        _positioned = true;
      });
      _reportWindow();
    }
    setState(() => _pulseYear = DateTime.now().year);
    _pulseTimer?.cancel();
    _pulseTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _pulseYear = null);
    });
    widget.onCenterChanged(DateTime.now());
  }

  /// 滚动到指定年并居中（期移箭头用）。
  void scrollTo(DateTime anchor, {bool animated = false}) {
    _cancelFling();
    final ppy = _ppy ?? 20.0;
    final yf = _yearFraction(anchor.millisecondsSinceEpoch);
    final target = (yf - _viewW / (2 * ppy)).clamp(_minScroll, _maxScroll);
    if (animated) {
      setState(() {
        _contentY = 0; // 期移后回到顶部第一行
        _positioned = true;
      });
      _animateScrollTo(target);
      return;
    }
    setState(() {
      _scrollYf = target;
      _contentY = 0; // 期移后回到顶部第一行
      _positioned = true;
    });
    _reportWindow();
  }

  /// 滚动到任务并使其居中（详情面板跳转用）。
  void scrollToTask(Task t) {
    _cancelFling();
    final s = t.startAt;
    if (s == null) return;
    final ppy = _ppy ?? 20.0;
    final f1 = _yearFraction(s);
    final f2 = t.endAt == null ? f1 : _yearFraction(t.endAt!);
    setState(() {
      _scrollYf =
          ((f1 + f2) / 2 - _viewW / (2 * ppy)).clamp(_minScroll, _maxScroll);
      // 行位置由布局决定（行数/缩放都会变），这里只登记目标，
      // 下一帧 build 拿到布局后把该行纵向滚进视野。
      _pendingRowTarget = t.id;
      _positioned = true;
    });
    _reportWindow();
  }

  /// 上次上报的（首可视年, 末可视年, 中心年）——滚动/缩放中只在单位
  /// 变化时上报（v2.6.1：标题实时跟随，又不每帧 setState）。
  (int, int, int)? _lastReportKey;

  void _reportOnUnitChange() {
    if (_viewW <= 0 || _ppy == null) return;
    final ppy = _ppy!;
    final key = (
      _scrollYf.floor(),
      (_scrollYf + _viewW / ppy).floor(),
      (_scrollYf + _viewW / (2 * ppy)).floor(),
    );
    if (key != _lastReportKey) _reportWindow();
  }

  void _reportWindow() {
    if (_viewW <= 0 || _ppy == null) return;
    // 精确可视范围（v2.4：加载提前量由父级 _ensureRange 负责，
    // 这里上报的范围同时用于底部面板与随缩放变化的标题）
    final startMs = DateTime(_epochYear + _scrollYf.floor())
        .millisecondsSinceEpoch;
    // 右缘年小数落在的年 = 最后可视年；区间右端 = 其次年 1 月 1 日
    final lastVisYear = _epochYear + (_scrollYf + _viewW / _ppy!).floor();
    final endMs = DateTime(lastVisYear + 1).millisecondsSinceEpoch;
    final centerYf = _scrollYf + _viewW / (2 * _ppy!);
    _lastReportKey = (
      _scrollYf.floor(),
      (_scrollYf + _viewW / _ppy!).floor(),
      centerYf.floor(),
    );
    widget.onVisibleWindowChanged(startMs, endMs);
    widget.onCenterChanged(
        DateTime(_epochYear + centerYf.floor(), 7));
  }

  List<Task> _displayTasks() {
    if (_dragOriginal == null || _deltaYears == 0) return widget.tasks;
    final list = <Task>[];
    for (final t in widget.tasks) {
      if (t.id == _dragOriginal!.id) {
        // 与 _onScaleEnd 同一套计算：移动 = 整体平移整数年；
        // 起止端点 = 吸附年界
        int? newStart = t.startAt;
        int? newEnd = t.endAt;
        switch (_dragMode!) {
          case _DragMode.move:
            newStart =
                t.startAt == null ? null : _shiftYears(t.startAt!, _deltaYears);
            newEnd =
                t.endAt == null ? null : _shiftYears(t.endAt!, _deltaYears);
          case _DragMode.resizeStart:
            final ty =
                DateTime.fromMillisecondsSinceEpoch(_origStartMs).year +
                    _deltaYears;
            newStart = DateTime(ty).millisecondsSinceEpoch;
          case _DragMode.resizeEnd:
            final ty = DateTime.fromMillisecondsSinceEpoch(_origEndMs!).year +
                _deltaYears;
            newEnd = DateTime(ty + 1).millisecondsSinceEpoch;
        }
        list.add(t.copyWith(startAt: () => newStart, endAt: () => newEnd));
      } else {
        list.add(t);
      }
    }
    return list;
  }

  void _onScaleStart(ScaleStartDetails d, _YearlyLayout layout) {
    _cancelFling();
    final hit = layout.hitTest(d.localFocalPoint);
    _startFocalX = d.localFocalPoint.dx;
    _startFocalY = d.localFocalPoint.dy;
    _startPpy = layout.ppy;
    _startScrollYf = _scrollYf;
    _startContentY = _contentY;
    // 仅选中任务可拖拽（v2.3 选中-调整）
    if (hit != null && hit.taskId == widget.selectedTaskId) {
      final original = layout.originals[hit.taskId];
      final span = layout.spans[hit.taskId];
      if (original != null && span != null) {
        setState(() {
          _dragOriginal = original;
          _dragMode = hit.mode;
          _deltaYears = 0;
          _origStartMs = span.$1;
          _origEndMs = span.$2;
        });
      }
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d, _YearlyLayout layout) {
    if (_dragOriginal != null) {
      final dy = ((d.localFocalPoint.dx - _startFocalX) / layout.ppy).round();
      final origStartYear =
          DateTime.fromMillisecondsSinceEpoch(_origStartMs).year;
      final origEndYear = _origEndMs == null
          ? origStartYear
          : DateTime.fromMillisecondsSinceEpoch(_origEndMs!).year;
      setState(() {
        switch (_dragMode!) {
          case _DragMode.move:
            final span = origEndYear - origStartYear;
            _deltaYears = dy.clamp(_minYear - origStartYear,
                _maxYear - 1 - span - origStartYear);
          case _DragMode.resizeStart:
            _deltaYears =
                dy.clamp(_minYear - origStartYear, origEndYear - origStartYear);
          case _DragMode.resizeEnd:
            _deltaYears = dy.clamp(
                origStartYear - origEndYear, _maxYear - origEndYear);
        }
      });
      return;
    }
    // 平移 + 无级缩放，以双指焦点对应的年份为锚（焦点下年份不动）
    final minPpy = layout.viewW / 20;
    final newPpy = (_startPpy * d.scale).clamp(minPpy, _maxPpy);
    final focalYf = _startScrollYf + _startFocalX / _startPpy;
    setState(() {
      _ppy = newPpy;
      _scrollYf = (focalYf - d.localFocalPoint.dx / newPpy)
          .clamp(_minScroll, _maxScroll);
      // R01：纵向拖动平移行区（行数不限，超出可视高度靠它看）；
      // 具体夹紧在 build 里按行总高做，这里只记请求值。
      _contentY = _startContentY - (d.localFocalPoint.dy - _startFocalY);
    });
    _reportOnUnitChange(); // v2.6.1：拖动/缩放中标题实时跟随
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final original = _dragOriginal;
    final mode = _dragMode;
    if (original != null && mode != null && _deltaYears != 0) {
      final int newStart;
      final int? newEnd;
      switch (mode) {
        case _DragMode.move:
          newStart = _shiftYears(_origStartMs, _deltaYears);
          newEnd =
              _origEndMs == null ? null : _shiftYears(_origEndMs!, _deltaYears);
        case _DragMode.resizeStart:
          // 起点吸附年界（1 月 1 日 00:00）
          final ty = DateTime.fromMillisecondsSinceEpoch(_origStartMs).year +
              _deltaYears;
          newStart = DateTime(ty).millisecondsSinceEpoch;
          newEnd = _origEndMs;
        case _DragMode.resizeEnd:
          // 终点吸附年界（目标年结束 = 下一年 1 月 1 日 00:00，左闭右开）
          final ty = DateTime.fromMillisecondsSinceEpoch(_origEndMs!).year +
              _deltaYears;
          newStart = _origStartMs;
          newEnd = DateTime(ty + 1).millisecondsSinceEpoch;
      }
      widget.onTaskMoved(original, newStart, newEnd);
    }
    final wasDragging = _dragOriginal != null;
    setState(() {
      _dragOriginal = null;
      _dragMode = null;
      _deltaYears = 0;
    });
    if (wasDragging) {
      _reportWindow();
    } else {
      // 平移手势结束：带惯性继续滚动（v2.4）
      _startFling(d.velocity.pixelsPerSecond.dx);
      // 低速不触发惯性时 _startFling 直接返回——这里补一次上报，
      // 否则慢拖后标题/底部面板停在旧值（v2.6.1）
      _reportOnUnitChange();
    }
  }

  void _onTapUp(TapUpDetails d, _YearlyLayout layout) {
    final hit = layout.hitTest(d.localPosition);
    if (hit != null) {
      final original = layout.originals[hit.taskId];
      if (original != null) widget.onTaskSelected(original);
      return;
    }
    if (widget.selectedTaskId != null) {
      // 有选中时点空白 = 取消选中（设计 §13-6）
      widget.onTaskSelected(null);
      return;
    }
    // 无选中时点空白年格 = 下钻该年的年视图（设计 §2.1）
    final year =
        _epochYear + ((d.localPosition.dx / layout.ppy) + _scrollYf).floor();
    widget.onYearTap(year);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    _texts.syncScheme(scheme); // 主题变化时清掉旧的标签排版
    final display = _displayTasks();
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewW = constraints.maxWidth;
        final minPpy = constraints.maxWidth / 20;
        final ppy = (_ppy ?? minPpy).clamp(minPpy, _maxPpy);
        if (!_positioned) {
          final nowYf = _yearFraction(DateTime.now().millisecondsSinceEpoch);
          _scrollYf = (nowYf - constraints.maxWidth / (2 * ppy))
              .clamp(_minScroll, _maxScroll);
          _positioned = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _reportWindow());
        }
        _scrollYf = _scrollYf.clamp(_minScroll, _maxScroll);
        final layout = _YearlyLayout.build(
          viewW: constraints.maxWidth,
          viewH: constraints.maxHeight,
          tasks: display,
          originals: {for (final t in widget.tasks) t.id: t},
          ppy: ppy,
          scrollYf: _scrollYf,
          epochYear: _epochYear,
          scheme: scheme,
          now: DateTime.now(),
          selectedTaskId: widget.selectedTaskId,
          pulseYear: _pulseYear,
          contentY: _contentY,
          textCache: _texts,
        );
        // R01：layout 内已按「行总高 - 可视高」夹紧，回写避免越拖越远
        _contentY = layout.contentY;
        // R01：跳转任务时把该任务所在行纵向滚进视野（行位置只有布局知道）
        final pending = _pendingRowTarget;
        if (pending != null) {
          _pendingRowTarget = null;
          final it = layout.itemById(pending);
          if (it != null) {
            final maxY = math.max(0.0, layout.contentH - constraints.maxHeight);
            final want = (it.y + layout.contentY - _YearlyLayout.headerH - 60)
                .clamp(0.0, maxY);
            if ((want - layout.contentY).abs() > 0.5) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) setState(() => _contentY = want);
              });
            }
          }
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (d) => _onScaleStart(d, layout),
          onScaleUpdate: (d) => _onScaleUpdate(d, layout),
          onScaleEnd: _onScaleEnd,
          onTapUp: (d) => _onTapUp(d, layout),
          child: ClipRect(
            child: CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: _YearlyPainter(layout),
            ),
          ),
        );
      },
    );
  }
}

class _HitRegion {
  final Rect rect;
  final String taskId;
  final _DragMode mode;

  const _HitRegion(this.rect, this.taskId, this.mode);
}

class _YearlyItem {
  final Task task;
  final double x1; // 画布坐标
  final double x2;
  final double y;
  final Color color;
  final bool isPoint;
  final bool isSubtask;

  const _YearlyItem({
    required this.task,
    required this.x1,
    required this.x2,
    required this.y,
    required this.color,
    required this.isPoint,
    required this.isSubtask,
  });
}

/// R01：标签 TextPainter 缓存（挂在 State 上跨帧复用）。
///
/// 键 = 是否完成 + 标题；主题（ColorScheme）变化整体清空，避免沿用旧颜色。
/// 读取端是 lazy memo：未命中就现排并回填，绝不返回默认值。
/// 上限 [_cap] 防止标题频繁变化时无限增长。
class _YearlyTextCache {
  static const _cap = 512;

  final Map<String, TextPainter> _painters = <String, TextPainter>{};
  ColorScheme? _scheme;

  void syncScheme(ColorScheme scheme) {
    if (_scheme == scheme) return;
    _scheme = scheme;
    _painters.clear();
  }

  TextPainter label(String title, TextStyle style, {required bool done}) {
    final key = '${done ? 1 : 0}:$title';
    final cached = _painters[key];
    if (cached != null) return cached;
    if (_painters.length >= _cap) _painters.clear();
    final tp = TextPainter(
      text: TextSpan(text: title, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return _painters[key] = tp;
  }
}

/// R01：一个已放置的标签（单行，贴在本行任务节点正上方）。
class _YearlyLabel {
  final String taskId;
  final String text;
  final double x;
  final double y;
  final bool done;
  final TextPainter painter;

  const _YearlyLabel({
    required this.taskId,
    required this.text,
    required this.x,
    required this.y,
    required this.done,
    required this.painter,
  });
}

class _YearlyLayout {
  /// 刻度表头（固定不随行区纵向平移）。
  static const headerH = 44.0;

  /// R01 行结构：每行 = 一条标签线（标签贴节点正上方）+ 一条标记线。
  /// 这两个值与 day_view 保持同一套（Lead 2026-10-20 要求对齐）。
  static const labelH = 15.0;
  static const markerH = 18.0;
  static const rowH = labelH + markerH;

  /// R01 行内占用判据：投影间距 < 130px（≈20 字标签宽）即算占用。
  /// 方案 B：行占用按「标记不重叠」判定（原 130px ≈ 20 字标签宽，最小缩放下相当于数小时）。
static const _rowGapPx = 18.0;

  /// 同一条标签线上两个标签之间的最小间隙。
  static const _labelGapPx = 6.0;
  static const labelFontSize = 11.0;

  final double viewW;
  final double viewH;
  final double ppy;
  final double scrollYf;
  final int epochYear;
  final int rowCount;
  final double contentH; // 行区总高（表头 + 行数 × 行高）
  final double contentY; // 实际纵向平移（已夹紧到 [0, contentH - 可视高]）
  final int majorTickYears;
  final int? minorTickYears;
  final int labelStride;
  final List<_YearlyItem> items;
  final List<_YearlyLabel> labels;
  final List<_HitRegion> hitRegions;
  final Map<String, Task> originals;
  final Map<String, (int, int?)> spans; // taskId -> (startMs, endMs)
  final ColorScheme scheme;
  final int nowYear;
  final String? selectedTaskId;
  final int? pulseYear;

  _YearlyLayout._({
    required this.viewW,
    required this.viewH,
    required this.ppy,
    required this.scrollYf,
    required this.epochYear,
    required this.rowCount,
    required this.contentH,
    required this.contentY,
    required this.majorTickYears,
    required this.minorTickYears,
    required this.labelStride,
    required this.items,
    required this.labels,
    required this.hitRegions,
    required this.originals,
    required this.spans,
    required this.scheme,
    required this.nowYear,
    required this.selectedTaskId,
    required this.pulseYear,
  });

  static double _yearFraction(int ms, int epochYear) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final y0 = DateTime(d.year).millisecondsSinceEpoch;
    final y1 = DateTime(d.year + 1).millisecondsSinceEpoch;
    return d.year - epochYear + (ms - y0) / (y1 - y0);
  }

  /// R01：本行标签线上 [fromX, toX] 内「最左侧放得下宽 [width] 标签」的锚点。
  ///
  /// 点任务传入 fromX == toX（只能挂节点正上方）；线段任务传入 [x1, x2]
  /// （挂最左侧符合条件的点正上方）。整条线上都不够就返回 null（不显示）。
  static double? _firstFreeAnchor(
      double fromX, double toX, double width, List<(double, double)> line) {
    var x = fromX;
    while (x <= toX) {
      var blocked = false;
      var nextX = x;
      for (final iv in line) {
        if (x < iv.$2 && iv.$1 < x + width) {
          blocked = true;
          if (iv.$2 > nextX) nextX = iv.$2;
        }
      }
      if (!blocked) return x;
      x = nextX + 0.5;
    }
    return null;
  }

  static _YearlyLayout build({
    required double viewW,
    required double viewH,
    required List<Task> tasks,
    required Map<String, Task> originals,
    required double ppy,
    required double scrollYf,
    required int epochYear,
    required ColorScheme scheme,
    required DateTime now,
    required String? selectedTaskId,
    required int? pulseYear,
    required double contentY,
    required _YearlyTextCache textCache,
  }) {
    final (majorTickYears, minorTickYears, labelStride) =
        yearTickInterval(ppy);

    double xOf(double yf) => (yf - scrollYf) * ppy;

    // ---- R01 行分配：优先级优先（红靠上、绿靠下、normal 居中，
    // 2026-10-28 分行优先级规则），同优先级按开始时间；行内「标记不重叠」判定 ----
    final sorted = [
      for (final t in tasks)
        if (t.startAt != null) t,
    ]..sort((a, b) {
        final r = taskLabelPriorityRank(a).compareTo(taskLabelPriorityRank(b));
        if (r != 0) return r;
        final c = a.startAt!.compareTo(b.startAt!);
        return c != 0 ? c : a.id.compareTo(b.id);
      });

    final rowSpans = <List<(double, double)>>[]; // 每行已占用的投影（px）
    final placed = <(Task, int, double, double)>[]; // task, row, x1, x2
    for (final t in sorted) {
      final x1 = xOf(_yearFraction(t.startAt!, epochYear));
      final e = t.endAt;
      final x2 = e == null ? x1 : xOf(_yearFraction(e, epochYear));
      var row = 0;
      while (true) {
        if (row == rowSpans.length) rowSpans.add(<(double, double)>[]);
        final taken = rowSpans[row];
        var clash = false;
        for (final iv in taken) {
          // 投影间距 < 130px（含重叠）= 该行已被占用，换下一行
          if (x1 < iv.$2 + _rowGapPx && iv.$1 < x2 + _rowGapPx) {
            clash = true;
            break;
          }
        }
        if (!clash) {
          taken.add((x1, x2));
          placed.add((t, row, x1, x2));
          break;
        }
        row++; // 行数不限：按需向下增长（超出可视高度靠纵向拖动）
      }
    }

    // ---- 行区几何 + 纵向平移夹紧 ----
    final rowCount = rowSpans.length;
    final contentH = headerH + rowCount * rowH;
    final maxContentY = math.max(0.0, contentH - viewH);
    final clampedY =
        contentY.isFinite ? contentY.clamp(0.0, maxContentY) : 0.0;
    double rowTop(int row) => headerH + row * rowH - clampedY;

    // ---- 任务 + 标签（单行、不合并不换行、先到先得） ----
    final items = <_YearlyItem>[];
    final labels = <_YearlyLabel>[];
    final spans = <String, (int, int?)>{};
    final takenLines = List.generate(rowCount, (_) => <(double, double)>[]);
    final labelStyle = TextStyle(fontSize: labelFontSize, color: scheme.onSurface);
    final doneLabelStyle = labelStyle.copyWith(
      color: scheme.onSurface.withValues(alpha: doneTaskOpacity),
      decoration: TextDecoration.lineThrough,
    );
    for (final (t, row, x1, x2) in placed) {
      final e = t.endAt;
      spans[t.id] = (t.startAt!, e);
      final parentId = t.parentId;
      // R01：子任务不再与父共行（同刻必然 130px 内冲突），只保留「画更小」的视觉差异
      final isSub = parentId != null && originals.containsKey(parentId);
      items.add(_YearlyItem(
        task: t,
        x1: x1,
        x2: x2,
        y: rowTop(row) + labelH + markerH / 2,
        color: priorityColor(scheme, t.priority),
        isPoint: e == null,
        isSubtask: isSub,
      ));

      // 标签：点任务只能挂节点正上方；线段任务挂「最左侧放得下」的点正上方。
      // 宽度上限 20 字由编辑器保证，这里不截断、不换行；放不下就不显示。
      final done = t.status == TaskStatus.done;
      // 标签排版结果缓存（按 完成状态 + 标题），pan/zoom 每帧重建布局时不再重排
      final tp = textCache.label(
        t.title,
        done
            ? doneLabelStyle
            : labelStyle,
        done: done,
      );
      final line = takenLines[row];
      final anchorX = _firstFreeAnchor(x1, e == null ? x1 : x2, tp.width, line);
      if (anchorX == null) continue; // 放不下：不显示（不截断、不挤）
      line.add((anchorX - _labelGapPx, anchorX + tp.width + _labelGapPx));
      labels.add(_YearlyLabel(
        taskId: t.id,
        text: t.title,
        x: anchorX,
        y: rowTop(row) + 1,
        done: done,
        painter: tp,
      ));
    }

    // 命中区域：子任务在前（优先命中），端点优先于中段
    final hitRegions = <_HitRegion>[];
    final ordered = [
      ...items.where((i) => i.isSubtask),
      ...items.where((i) => !i.isSubtask),
    ];
    for (final it in ordered) {
      // 行区纵向平移后，滑到表头下 / 视口外的行不再接收点击（避免点到看不见的任务）
      if (it.y + 12 < headerH || it.y - 12 > viewH) continue;
      if (it.isPoint) {
        hitRegions.add(_HitRegion(
            Rect.fromCircle(center: Offset(it.x1, it.y), radius: 14),
            it.task.id,
            _DragMode.move));
      } else {
        hitRegions.add(_HitRegion(
            Rect.fromCircle(center: Offset(it.x2, it.y), radius: 14),
            it.task.id,
            _DragMode.resizeEnd));
        hitRegions.add(_HitRegion(
            Rect.fromCircle(center: Offset(it.x1, it.y), radius: 14),
            it.task.id,
            _DragMode.resizeStart));
        hitRegions.add(_HitRegion(
            Rect.fromLTRB(it.x1, it.y - 10, it.x2, it.y + 10),
            it.task.id,
            _DragMode.move));
      }
    }
    // R01：标签命中区域 —— 点按标签 = 选中该任务（不再有顶部名称层）
    for (final lb in labels) {
      if (lb.y + lb.painter.height < headerH || lb.y > viewH) continue;
      hitRegions.add(_HitRegion(
        Rect.fromLTWH(lb.x - 2, lb.y, lb.painter.width + 4, lb.painter.height),
        lb.taskId,
        _DragMode.move,
      ));
    }

    return _YearlyLayout._(
      viewW: viewW,
      viewH: viewH,
      ppy: ppy,
      scrollYf: scrollYf,
      epochYear: epochYear,
      rowCount: rowCount,
      contentH: contentH,
      contentY: clampedY,
      majorTickYears: majorTickYears,
      minorTickYears: minorTickYears,
      labelStride: labelStride,
      items: items,
      labels: labels,
      hitRegions: hitRegions,
      originals: originals,
      spans: spans,
      scheme: scheme,
      nowYear: now.year,
      selectedTaskId: selectedTaskId,
      pulseYear: pulseYear,
    );
  }

  /// P1：paint 真正消费的字段是否全部相同（相同就跳过重绘）。
  /// 命中区域 / spans 只服务手势，不影响画面，故不参与比较。
  bool samePaintContent(_YearlyLayout o) {
    if (identical(this, o)) return true;
    return viewW == o.viewW &&
        viewH == o.viewH &&
        ppy == o.ppy &&
        scrollYf == o.scrollYf &&
        epochYear == o.epochYear &&
        rowCount == o.rowCount &&
        contentY == o.contentY &&
        majorTickYears == o.majorTickYears &&
        minorTickYears == o.minorTickYears &&
        labelStride == o.labelStride &&
        scheme == o.scheme &&
        nowYear == o.nowYear &&
        selectedTaskId == o.selectedTaskId &&
        pulseYear == o.pulseYear &&
        _sameItems(items, o.items) &&
        _sameLabels(labels, o.labels);
  }

  static bool _sameItems(List<_YearlyItem> a, List<_YearlyItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.task.id != y.task.id ||
          x.task.status != y.task.status ||
          x.x1 != y.x1 ||
          x.x2 != y.x2 ||
          x.y != y.y ||
          x.color != y.color ||
          x.isPoint != y.isPoint ||
          x.isSubtask != y.isSubtask) {
        return false;
      }
    }
    return true;
  }

  static bool _sameLabels(List<_YearlyLabel> a, List<_YearlyLabel> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.taskId != y.taskId ||
          x.text != y.text ||
          x.x != y.x ||
          x.y != y.y ||
          x.done != y.done) {
        return false;
      }
    }
    return true;
  }

  _HitRegion? hitTest(Offset p) {
    for (final r in hitRegions) {
      if (r.rect.contains(p)) return r;
    }
    return null;
  }

  /// R01：按任务 id 找布局项（跳转任务时纵向定位到所在行）。
  _YearlyItem? itemById(String taskId) {
    for (final it in items) {
      if (it.task.id == taskId) return it;
    }
    return null;
  }
}

class _YearlyPainter extends CustomPainter {
  final _YearlyLayout layout;

  _YearlyPainter(this.layout);

  double _xOf(double yf) => (yf - layout.scrollYf) * layout.ppy;

  @override
  void paint(Canvas canvas, Size size) {
    final scheme = layout.scheme;
    final ppy = layout.ppy;
    // R01：刻度表头固定在顶部，行区在其下方纵向平移
    const top = _YearlyLayout.headerH;

    // 当前年高亮竖带（表头 + 行区通高）
    final nowX = (layout.nowYear - layout.epochYear).toDouble();
    final nowX0 = _xOf(nowX);
    if (nowX0 + ppy >= 0 && nowX0 <= size.width) {
      canvas.drawRect(
        Rect.fromLTWH(nowX0, 0, ppy, size.height),
        Paint()..color = scheme.primary.withValues(alpha: 0.08),
      );
    }

    _drawTicks(canvas, size, 0, top);

    // 行区 clip 在表头下方：纵向平移时不会盖住刻度
    canvas.save();
    canvas.clipRect(
        Rect.fromLTWH(0, top, size.width, math.max(0.0, size.height - top)));

    // 任务：节点 / 带端点圆点的线段；子任务画更小节点/更细线；
    // 选中任务加描边（v2.3 选中-调整）。无泳道底纹（v2.3 §13-8）。
    // R01：节点不再合并 —— 每个任务独立绘制，点按即选中（恢复「选中 + 详情」）。
    for (final it in layout.items) {
      if (it.x2 < -40 || it.x1 > size.width + 40) continue; // 水平裁剪
      final done = it.task.status == TaskStatus.done;
      final color = it.color.withValues(alpha: done ? doneTaskOpacity : 1.0);
      if (it.isPoint) {
        canvas.drawCircle(Offset(it.x1, it.y),
            it.isSubtask ? 3.5 : 5.0, Paint()..color = color);
      } else {
        canvas.drawLine(
          Offset(it.x1, it.y),
          Offset(it.x2, it.y),
          Paint()
            ..color = color
            ..strokeWidth = it.isSubtask ? 1.5 : 3
            ..strokeCap = StrokeCap.round,
        );
        final endR = it.isSubtask ? 3.5 : 5.0;
        _drawBreak(canvas, it.x1, it.y, color, endR);
        _drawBreak(canvas, it.x2, it.y, color, endR);
      }
      if (it.task.id == layout.selectedTaskId) {
        _drawSelection(canvas, it, scheme);
      }
    }

    // 标签：单行、贴在本行节点正上方（先到先得；放不下的布局期已丢弃）
    for (final lb in layout.labels) {
      if (lb.x + lb.painter.width < -40 || lb.x > size.width + 40) continue;
      lb.painter.paint(canvas, Offset(lb.x, lb.y));
    }
    canvas.restore();

    // 「现在」脉冲高亮（1.5 秒）
    final pulseYear = layout.pulseYear;
    if (pulseYear != null) {
      final x = _xOf((pulseYear - layout.epochYear).toDouble());
      if (x + ppy >= 0 && x <= size.width) {
        canvas.drawRect(
          Rect.fromLTWH(x, 0, ppy, size.height),
          Paint()..color = scheme.primary.withValues(alpha: 0.2),
        );
      }
    }
  }

  void _drawSelection(Canvas canvas, _YearlyItem it, ColorScheme scheme) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = scheme.primary;
    if (it.isPoint) {
      canvas.drawCircle(Offset(it.x1, it.y), 9, paint);
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(it.x1 - 6, it.y - 9, it.x2 + 6, it.y + 9),
          const Radius.circular(6),
        ),
        paint,
      );
    }
  }

  /// 动态刻度（设计 §2.1）：主刻度 = 长竖格线 + 刻度短线 + 斜 -45° 年份标注
  /// （过挤按 2 的幂隔档）；次刻度 = 短刻度线。
  void _drawTicks(Canvas canvas, Size size, double top, double ganttTop) {
    final scheme = layout.scheme;
    final ppy = layout.ppy;
    final scrollYf = layout.scrollYf;
    final major = layout.majorTickYears;
    final minor = layout.minorTickYears;
    final gridPaint = Paint()
      ..color = scheme.outlineVariant.withValues(alpha: 0.6)
      ..strokeWidth = 0.5;
    final tickPaint = Paint()
      ..color = scheme.onSurfaceVariant
      ..strokeWidth = 1;
    final labelStyle =
        TextStyle(fontSize: 10, color: scheme.onSurfaceVariant);

    // 可视范围内的刻度序号（刻度序号 = 年 - epochYear，从 0 起对齐 major）
    final firstTick = scrollYf.floor() - major;
    final lastTick = (scrollYf + size.width / ppy).ceil() + major;

    if (minor != null) {
      var t = (firstTick / minor).floor() * minor;
      while (t <= lastTick) {
        if (t % major != 0) {
          final x = _xOf(t.toDouble());
          canvas.drawLine(
              Offset(x, ganttTop - 3), Offset(x, ganttTop), tickPaint);
        }
        t += minor;
      }
    }

    // 主刻度：当前年（nowYear）的 tick 用 primary 标注（v2.4）
    final nowYearTick = DateTime.now().year - layout.epochYear;
    var t = (firstTick / major).floor() * major;
    while (t <= lastTick) {
      final x = _xOf(t.toDouble());
      final isNow = t <= nowYearTick && nowYearTick < t + major;
      canvas.drawLine(Offset(x, top), Offset(x, size.height), gridPaint);
      canvas.drawLine(
          Offset(x, ganttTop - 6),
          Offset(x, ganttTop),
          isNow
              ? (Paint()
                ..color = scheme.primary
                ..strokeWidth = 1.5)
              : tickPaint);
      if ((t ~/ major) % layout.labelStride == 0) {
        final tp = TextPainter(
          text: TextSpan(
              text: '${layout.epochYear + t}',
              style: isNow
                  ? labelStyle.copyWith(
                      color: scheme.primary, fontWeight: FontWeight.w600)
                  : labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        canvas.save();
        canvas.translate(x + 2, ganttTop - 8);
        canvas.rotate(-math.pi / 4);
        tp.paint(canvas, Offset(2, -tp.height + 1));
        canvas.restore();
      }
      t += major;
    }
  }

  /// 时间段端点的圆点（v2.5：方块改圆点，与时间点节点同半径）。
  void _drawBreak(Canvas canvas, double x, double y, Color color,
      [double radius = 5]) {
    canvas.drawCircle(Offset(x, y), radius, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_YearlyPainter oldDelegate) =>
      !oldDelegate.layout.samePaintContent(layout);
}
