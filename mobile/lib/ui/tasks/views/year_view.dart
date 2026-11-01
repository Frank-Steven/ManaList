import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/task.dart';
import 'layout.dart';
import 'schedule_shared.dart';

enum _DragMode { move, resizeStart, resizeEnd }

/// P1：任务列表内容是否未变（Task 不可变，逐项 identity 比较即足够）。
bool _sameTasks(List<Task> a, List<Task> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!identical(a[i], b[i])) return false;
  }
  return true;
}


/// 年视图（设计 §2.2，v2.3 修订）：纵向**无限滚动**——年份网格
/// （4 行季度 × 3 块月）按年无缝上下衔接（ListView 大初始偏移法）。
/// 月块为格线风格（v2.3 §13-8：不填充底色，只画淡分隔线；当前月描边高亮），
/// 无泳道底纹。块内三条优先级泳道全图垂直对齐。
///
/// 选中-调整（v2.3 §13-6）：点按任务出现描边选中态，仅选中任务可拖拽
/// （吸附月界）；有选中时点空白 = 取消选中，无选中时点空白月块 = 下钻月视图。
/// 未选中时纵向滚动手势不被抢占。
class YearView extends StatefulWidget {
  final List<Task> tasks;
  final String? selectedTaskId;
  final ValueChanged<Task?> onTaskSelected;
  final ValueChanged<int> onMonthTap; // 参数：月份时间戳（所在月 1 日）
  final void Function(Task task, int newStartMs, int? newEndMs) onTaskMoved;
  final ValueChanged<int> onBlankLongPress; // 参数：月份时间戳
  final void Function(int startMs, int endMs) onVisibleWindowChanged;
  final ValueChanged<DateTime> onCenterChanged;

  const YearView({
    super.key,
    required this.tasks,
    required this.selectedTaskId,
    required this.onTaskSelected,
    required this.onMonthTap,
    required this.onTaskMoved,
    required this.onBlankLongPress,
    required this.onVisibleWindowChanged,
    required this.onCenterChanged,
  });

  @override
  State<YearView> createState() => YearViewState();
}

class YearViewState extends State<YearView> {
  static const _baseYear = 2000; // 索引基准年
  static const _yearLabelH = 24.0;

  final ScrollController _scroll = ScrollController();
  double _itemExtent = 0; // 首帧由宽度计算
  double _gridWidth = 0; // 首帧 LayoutBuilder 记录（月块定位用）

  /// 「现在」脉冲目标（年, 月），1.5 秒后恢复。
  (int, int)? _pulse;
  Timer? _pulseTimer;

  /// 可视中心的年（由滚动位置推导）。
  int get _centerYear {
    if (!_scroll.hasClients || _itemExtent <= 0) return DateTime.now().year;
    return _baseYear +
        unitIndexForItem(
            ((_scroll.offset + _scroll.position.viewportDimension / 2) /
                    _itemExtent)
                .floor());
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    // 滚动停止附近才上报（用通知层的 ScrollEndNotification 也可，这里按帧节流：
    // 仅在像素落整时无动画期间变化上报，由父级去重）
    _reportDebounced();
  }

  Timer? _reportTimer;
  void _reportDebounced() {
    _reportTimer?.cancel();
    _reportTimer = Timer(const Duration(milliseconds: 150), _reportWindow);
  }

  void _reportWindow() {
    if (!mounted || !_scroll.hasClients || _itemExtent <= 0) return;
    // 精确可视范围（v2.4：加载提前量由父级 _ensureRange 负责）
    final firstIdx = (_scroll.offset / _itemExtent).floor();
    final lastIdx =
        ((_scroll.offset + _scroll.position.viewportDimension) / _itemExtent)
            .floor();
    final firstYear = _baseYear + unitIndexForItem(firstIdx);
    final lastYear = _baseYear + unitIndexForItem(lastIdx);
    widget.onVisibleWindowChanged(
      DateTime(firstYear).millisecondsSinceEpoch,
      DateTime(lastYear + 1).millisecondsSinceEpoch,
    );
    widget.onCenterChanged(DateTime(_centerYear, 7));
  }

  /// 滚动到当前年、把当月块在可视区垂直居中，脉冲高亮当月块（设计 §13-10，v2.6）。
  /// [animated]：按钮触发的定位平滑滚动，首帧自动定位保持硬跳。
  void scrollToNow({bool animated = false}) {
    final now = DateTime.now();
    _jumpToMonthBlock(now.year, now.month, animated: animated);
    setState(() {
      _pulse = (now.year, now.month);
    });
    _pulseTimer?.cancel();
    _pulseTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _pulse = null);
    });
    widget.onCenterChanged(now);
  }

  /// 滚动到指定年并把锚点所在月块在可视区垂直居中（期移箭头用；
  /// 2026-10-28：原先是顶对齐年初，期移后当月块常被顶出屏幕）。
  void scrollTo(DateTime anchor, {bool animated = false}) =>
      _jumpToMonthBlock(anchor.year, anchor.month, animated: animated);

  /// 滚动到任务所在年（详情面板跳转用）。
  void scrollToTask(Task t) {
    final s = t.startAt;
    if (s == null) return;
    _jumpToYear(DateTime.fromMillisecondsSinceEpoch(s).year);
  }

  /// 定位滚动：按钮触发（animated）平滑滚动 300ms，否则硬跳。
  /// 平滑滚动结束的 ScrollEndNotification 会触发上报（见 build 的监听）。
  void _scrollToOffset(double offset, bool animated) {
    if (animated) {
      _scroll.animateTo(offset,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic);
    } else {
      _scroll.jumpTo(offset);
      _reportWindow();
    }
  }

  void _jumpToYear(int year, {bool animated = false}) {
    if (!_scroll.hasClients || _itemExtent <= 0) return;
    final idx = itemIndexForUnit(year - _baseYear);
    // 顶对齐（留 4px 边距）：itemExtent 常大于视口高，居中会把
    // 年网格第一行顶出屏幕（首行被裁）
    final target = idx * _itemExtent - 4;
    _scrollToOffset(
        target.clamp(0.0, _scroll.position.maxScrollExtent), animated);
  }

  /// 滚动到指定年并把指定月块在可视区垂直居中（v2.6「现在」定位加深）。
  void _jumpToMonthBlock(int year, int month, {bool animated = false}) {
    if (!_scroll.hasClients || _itemExtent <= 0 || _gridWidth <= 0) return;
    final itemTop = itemIndexForUnit(year - _baseYear) * _itemExtent;
    // 与网格布局同一套公式：3 列方块月块，行 = (month-1)~/3
    final block = (_gridWidth - 2 * _YearLayout.pad - 2 * _YearLayout.gap) / 3;
    final blockTop =
        _YearLayout.pad + ((month - 1) ~/ 3) * (block + _YearLayout.gap);
    final center = itemTop + _yearLabelH + blockTop + block / 2;
    final dim = _scroll.position.viewportDimension;
    _scrollToOffset(
        (center - dim / 2).clamp(0.0, _scroll.position.maxScrollExtent),
        animated);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        _gridWidth = constraints.maxWidth;
        // 年网格高度：约 4/3 宽度 + 年份标签；固定 itemExtent 保证 jumpTo 准确
        final gridH = (constraints.maxWidth - 2 * _YearLayout.pad - 2 * _YearLayout.gap) /
                3 *
                4 +
            3 * _YearLayout.gap +
            2 * _YearLayout.pad;
        _itemExtent = gridH + _yearLabelH + 8;
        if (!_scroll.hasClients) {
          // 首帧前定位到当前月块（垂直居中，与 scrollToNow 同一套公式；
          // 2026-10-28：原先是顶对齐当前年，即「年初位置」）
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) {
              final now = DateTime.now();
              _jumpToMonthBlock(now.year, now.month);
            }
          });
        }
        return NotificationListener<ScrollEndNotification>(
          onNotification: (_) {
            _reportWindow();
            return false;
          },
          child: ListView.builder(
            controller: _scroll,
            itemExtent: _itemExtent,
            itemBuilder: (context, index) {
              final year = _baseYear + unitIndexForItem(index);
              return _YearGridItem(
                key: ValueKey(year),
                year: year,
                tasks: widget.tasks,
                gridHeight: gridH,
                labelHeight: _yearLabelH,
                selectedTaskId: widget.selectedTaskId,
                pulseMonth: _pulse != null && _pulse!.$1 == year
                    ? _pulse!.$2
                    : null,
                scheme: scheme,
                onTaskSelected: widget.onTaskSelected,
                onMonthTap: (month) => widget
                    .onMonthTap(DateTime(year, month).millisecondsSinceEpoch),
                onTaskMoved: widget.onTaskMoved,
                onBlankLongPress: (month) => widget.onBlankLongPress(
                    DateTime(year, month, 1, 9).millisecondsSinceEpoch),
              );
            },
          ),
        );
      },
    );
  }
}

/// 单一年份的网格项（4×3 月块 + 泳道任务层），持有自身拖拽预览状态。
class _YearGridItem extends StatefulWidget {
  final int year;
  final List<Task> tasks;
  final double gridHeight;
  final double labelHeight;
  final String? selectedTaskId;
  final int? pulseMonth;
  final ColorScheme scheme;
  final ValueChanged<Task?> onTaskSelected;
  final ValueChanged<int> onMonthTap;
  final void Function(Task task, int newStartMs, int? newEndMs) onTaskMoved;
  final ValueChanged<int> onBlankLongPress;

  const _YearGridItem({
    super.key,
    required this.year,
    required this.tasks,
    required this.gridHeight,
    required this.labelHeight,
    required this.selectedTaskId,
    required this.pulseMonth,
    required this.scheme,
    required this.onTaskSelected,
    required this.onMonthTap,
    required this.onTaskMoved,
    required this.onBlankLongPress,
  });

  @override
  State<_YearGridItem> createState() => _YearGridItemState();
}

class _YearGridItemState extends State<_YearGridItem> {
  Task? _dragOriginal;
  _DragMode? _dragMode;
  int _dragStartMonth = 1;
  int _dragEndMonth = 1;
  int _origStartMonth = 1;
  int _origEndMonth = 1;
  double _grabOffset = 0;

  /// P1：名称/月份 TextPainter 缓存（挂在 State 上跨帧复用）。
  final _YearTextCache _texts = _YearTextCache();

  /// P1：非拖拽时的展示任务列表缓存（只取决于 widget.tasks 内容）。
  List<Task>? _displayCache;
  List<Task> _displayCacheSrc = const <Task>[];

  /// P1：originals 映射缓存（与拖拽预览无关，只取决于 widget.tasks 内容）。
  Map<String, Task>? _originalsCache;
  List<Task> _originalsCacheSrc = const <Task>[];

  (int, int) get _yearRange => (
        DateTime(widget.year).millisecondsSinceEpoch,
        DateTime(widget.year + 1).millisecondsSinceEpoch,
      );

  List<Task> _displayTasks() {
    // P1：拖拽中随预览变化必须重算；否则按任务列表实例缓存。
    if (_dragOriginal == null) {
      final cached = _displayCache;
      if (cached != null && _sameTasks(_displayCacheSrc, widget.tasks)) {
        return cached;
      }
      final list = _computeDisplayTasks();
      _displayCache = list;
      _displayCacheSrc = widget.tasks;
      return list;
    }
    return _computeDisplayTasks();
  }

  /// P1：originals 映射只取决于任务列表实例，拖拽预览不改它。
  Map<String, Task> _originals() {
    final cached = _originalsCache;
    if (cached != null && _sameTasks(_originalsCacheSrc, widget.tasks)) {
      return cached;
    }
    final map = {for (final t in widget.tasks) t.id: t};
    _originalsCache = map;
    _originalsCacheSrc = widget.tasks;
    return map;
  }

  List<Task> _computeDisplayTasks() {
    final (startMs, endMs) = _yearRange;
    final list = <Task>[];
    for (final t in widget.tasks) {
      var d = displayOccurrence(t, startMs, endMs);
      if (d == null) continue;
      if (_dragOriginal?.id == t.id) d = _previewTask(d);
      list.add(d);
    }
    return list;
  }

  /// 拖拽预览：吸附月边界（起点到 1 日，终点到月末，时间保留原时分）。
  Task _previewTask(Task display) {
    final s = DateTime.fromMillisecondsSinceEpoch(display.startAt!);
    final newStart =
        DateTime(widget.year, _dragStartMonth, 1, s.hour, s.minute);
    int? newEnd;
    final e = display.endAt;
    if (e != null) {
      final ed = DateTime.fromMillisecondsSinceEpoch(e);
      newEnd = DateTime(widget.year, _dragEndMonth + 1, 1, ed.hour, ed.minute)
          .millisecondsSinceEpoch;
    }
    return display.copyWith(
      startAt: () => newStart.millisecondsSinceEpoch,
      endAt: () => newEnd,
    );
  }

  void _onTapUp(TapUpDetails d, _YearLayout layout) {
    final hit = layout.hitTest(d.localPosition);
    if (hit != null) {
      final original = layout.originals[hit.taskId];
      if (original != null) widget.onTaskSelected(original);
      return;
    }
    if (widget.selectedTaskId != null) {
      widget.onTaskSelected(null); // 有选中时点空白 = 取消选中
      return;
    }
    final month = layout.monthAt(d.localPosition);
    if (month != null) widget.onMonthTap(month);
  }

  void _onLongPress(LongPressStartDetails d, _YearLayout layout) {
    if (layout.hitTest(d.localPosition) != null) return;
    final month = layout.monthAt(d.localPosition);
    if (month != null) widget.onBlankLongPress(month);
  }

  void _onPanStart(DragStartDetails d, _YearLayout layout) {
    final hit = layout.hitTest(d.localPosition);
    // 仅选中任务可拖拽（v2.3 选中-调整）
    if (hit == null || hit.taskId != widget.selectedTaskId) return;
    final item = layout.itemById(hit.taskId);
    final original = layout.originals[hit.taskId];
    if (item == null || original == null) return;
    setState(() {
      _dragOriginal = original;
      _dragMode = hit.mode;
      _origStartMonth = item.lane.startMonth;
      _origEndMonth = item.lane.endMonth;
      _dragStartMonth = item.lane.startMonth;
      _dragEndMonth = item.lane.endMonth;
      _grabOffset =
          layout.monthPosAt(d.localPosition) - (item.lane.startMonth - 1);
    });
  }

  void _onPanUpdate(DragUpdateDetails d, _YearLayout layout) {
    if (_dragOriginal == null) return;
    final mp = layout.monthPosAt(d.localPosition);
    final span = _origEndMonth - _origStartMonth; // 0 = 月内节点
    setState(() {
      switch (_dragMode!) {
        case _DragMode.move:
          final start0 = (mp - _grabOffset).round().clamp(0, 11 - span);
          _dragStartMonth = start0 + 1;
          _dragEndMonth = start0 + 1 + span;
        case _DragMode.resizeStart:
          final start0 = mp.round().clamp(0, _origEndMonth - 1);
          _dragStartMonth = start0 + 1;
        case _DragMode.resizeEnd:
          final end0 = mp.round().clamp(_origStartMonth - 1, 12);
          _dragEndMonth = end0.clamp(0, 11) + 1;
      }
    });
  }

  void _onPanEnd() {
    final original = _dragOriginal;
    final mode = _dragMode;
    if (original != null && mode != null) {
      final deltaStartM = _dragStartMonth - _origStartMonth;
      final deltaEndM = _dragEndMonth - _origEndMonth;
      if (deltaStartM != 0 || deltaEndM != 0) {
        final os = DateTime.fromMillisecondsSinceEpoch(original.startAt!);
        final newStart = DateTime(
                os.year, os.month + deltaStartM, 1, os.hour, os.minute)
            .millisecondsSinceEpoch;
        int? newEnd;
        final oe = original.endAt;
        if (oe != null) {
          final ed = DateTime.fromMillisecondsSinceEpoch(oe);
          final deltaM = switch (mode) {
            _DragMode.resizeEnd => deltaEndM,
            _DragMode.resizeStart => 0,
            _DragMode.move => deltaStartM,
          };
          // 终点吸附到月末：取下月 1 日（查询/展示按半开区间处理）
          newEnd = DateTime(
                  ed.year, ed.month + deltaM + 1, 1, ed.hour, ed.minute)
              .millisecondsSinceEpoch;
        }
        widget.onTaskMoved(original, newStart, newEnd);
      }
    }
    setState(() {
      _dragOriginal = null;
      _dragMode = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    _texts.syncScheme(widget.scheme); // 主题变化时清掉旧的文本缓存
    final display = _displayTasks();
    final layout = _YearLayout.build(
      width: MediaQuery.of(context).size.width,
      maxHeight: widget.gridHeight,
      year: widget.year,
      tasks: display,
      originals: _originals(),
      textCache: _texts,
      scheme: widget.scheme,
      now: DateTime.now(),
      selectedTaskId: widget.selectedTaskId,
      pulseMonth: widget.pulseMonth,
    );
    return Column(
      children: [
        SizedBox(
          height: widget.labelHeight,
          child: Padding(
            padding: const EdgeInsets.only(left: 12, top: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${widget.year}年',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: widget.scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _onTapUp(d, layout),
          onLongPressStart: (d) => _onLongPress(d, layout),
          onPanStart: (d) => _onPanStart(d, layout),
          onPanUpdate: (d) => _onPanUpdate(d, layout),
          onPanEnd: (_) => _onPanEnd(),
          onPanCancel: _onPanEnd,
          child: CustomPaint(
            size: Size(MediaQuery.of(context).size.width, widget.gridHeight),
            painter: _YearPainter(layout, _texts),
          ),
        ),
      ],
    );
  }
}

class _HitRegion {
  final Rect rect;
  final String taskId;
  final _DragMode mode;

  const _HitRegion(this.rect, this.taskId, this.mode);
}

class _YearItem {
  final Task task;
  final YearLaneItem lane;
  final double x1;
  final double x2;
  final double y;
  final Color color;
  final double nameX; // 名称锚点（节点取 x1，线段取 x2）
  final TextPainter? name; // 放得下才非空

  const _YearItem({
    required this.task,
    required this.lane,
    required this.x1,
    required this.x2,
    required this.y,
    required this.color,
    required this.nameX,
    this.name,
  });
}

class _YearLayout {
  static const pad = 8.0;
  static const gap = 6.0;
  static const labelH = 20.0;
  static const _naturalSlotH = 16.0;
  static const blockVPad = 4.0;

  final double width;
  final double height;
  final double blockW;
  final double blockH;
  final double slotH;
  final int year;
  final Map<String, int> laneSlotCounts; // priority -> 槽位数
  final List<Rect> monthBlocks; // 12 块，索引 = 月-1
  final List<_YearItem> items;
  final List<_HitRegion> hitRegions;
  final Map<String, Task> originals;
  final ColorScheme scheme;
  final int currentMonth; // 0 = 当前年不在今年
  final String? selectedTaskId;
  final int? pulseMonth;

  _YearLayout._({
    required this.width,
    required this.height,
    required this.blockW,
    required this.blockH,
    required this.slotH,
    required this.year,
    required this.laneSlotCounts,
    required this.monthBlocks,
    required this.items,
    required this.hitRegions,
    required this.originals,
    required this.scheme,
    required this.currentMonth,
    required this.selectedTaskId,
    required this.pulseMonth,
  });

  static const _priorities = [
    TaskPriority.important,
    TaskPriority.normal,
    TaskPriority.minor,
  ];

  static double _fracInMonth(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final days = DateTime(d.year, d.month + 1, 0).day;
    return ((d.day - 1) + (d.hour * 60 + d.minute) / 1440.0) / days;
  }

  static _YearLayout build({
    required double width,
    required double maxHeight,
    required int year,
    required List<Task> tasks,
    required Map<String, Task> originals,
    required _YearTextCache textCache,
    required ColorScheme scheme,
    required DateTime now,
    String? selectedTaskId,
    int? pulseMonth,
  }) {
    final blockW = (width - 2 * pad - 2 * gap) / 3;
    final byId = {for (final t in tasks) t.id: t};
    final laneItems = <String, List<YearLaneItem>>{};
    final laneSlotCounts = <String, int>{};
    for (final p in _priorities) {
      final items =
          layoutYearLane(tasks.where((t) => t.priority == p).toList(), year);
      laneItems[p] = items;
      // 空泳道不占槽位（v2.4：无任务的优先级不再保留一条空泳道高度）
      laneSlotCounts[p] =
          items.fold(0, (m, e) => e.slot + 1 > m ? e.slot + 1 : m);
    }

    // 槽位过高时整体压缩 slotH，保证 12 块在给定高度内绘完
    var slotH = _naturalSlotH;
    double totalH(double sh) {
      final blockH =
          labelH + sh * laneSlotCounts.values.fold(0, (a, b) => a + b) +
              2 * blockVPad;
      return 4 * blockH + 3 * gap + 2 * pad;
    }

    final lanesTotalRaw = laneSlotCounts.values.fold(0, (a, b) => a + b);
    if (maxHeight.isFinite &&
        lanesTotalRaw > 0 &&
        totalH(slotH) > maxHeight) {
      final blockH = (maxHeight - 3 * gap - 2 * pad) / 4;
      slotH = ((blockH - labelH - 2 * blockVPad) / lanesTotalRaw)
          .clamp(8.0, _naturalSlotH);
    }
    final height = maxHeight.isFinite ? maxHeight : totalH(slotH);
    final blockH = (height - 3 * gap - 2 * pad) / 4;

    double blockLeft(int month) => pad + ((month - 1) % 3) * (blockW + gap);
    double blockTop(int month) => pad + ((month - 1) ~/ 3) * (blockH + gap);

    final monthBlocks = [
      for (var m = 1; m <= 12; m++)
        Rect.fromLTWH(blockLeft(m), blockTop(m), blockW, blockH),
    ];

    // 泳道在块内的 y 偏移：由优先级决定，全图对齐
    final laneTopInBlock = <String, double>{};
    var acc = labelH;
    for (final p in _priorities) {
      laneTopInBlock[p] = acc;
      acc += laneSlotCounts[p]! * slotH;
    }

    final items = <_YearItem>[];
    final nameStyle = TextStyle(fontSize: 10, color: scheme.onSurfaceVariant);
    final doneNameStyle = nameStyle.copyWith(
      decoration: TextDecoration.lineThrough,
    );

    for (final p in _priorities) {
      final lane = laneItems[p]!;
      // 同槽位按 x 排序，用于计算名称可用宽度
      final slotNextX = <String, double>{};
      final sorted = [...lane]..sort((a, b) {
          final c = a.slot.compareTo(b.slot);
          return c != 0 ? c : a.startMonth.compareTo(b.startMonth);
        });
      for (var i = 0; i < sorted.length; i++) {
        if (i + 1 < sorted.length && sorted[i + 1].slot == sorted[i].slot) {
          final n = sorted[i + 1];
          slotNextX[sorted[i].taskId] = n.extendsBefore
              ? blockLeft(n.startMonth)
              : blockLeft(n.startMonth) +
                  blockW * _fracInMonth(byId[n.taskId]!.startAt!);
        }
      }
      final color = priorityColor(scheme, p);
      // 名称可用宽度的行右缘：名称不跨季度行（v2.4 标准样式）
      double rowRight(int month) =>
          blockLeft(((month - 1) ~/ 3) * 3 + 3) + blockW;
      for (final li in lane) {
        final task = byId[li.taskId];
        if (task == null) continue;
        final startMs = task.startAt!;
        final endMs = task.endAt;
        final x1 = li.extendsBefore
            ? blockLeft(li.startMonth)
            : blockLeft(li.startMonth) + blockW * _fracInMonth(startMs);
        // 月内线段的右端点钳到当月内（结束时刻恰为次月 1 日零点时
        // 不归到下月块左缘）；跨年延伸保持旧行为
        double endX() {
          if (li.extendsAfter) return blockLeft(li.endMonth) + blockW;
          final ex = blockLeft(li.endMonth) +
              blockW * _fracInMonth(endMs ?? startMs);
          final maxX = blockLeft(li.endMonth) + blockW;
          return ex > maxX ? maxX : ex;
        }

        final isNode =
            li.startMonth == li.endMonth && !li.extendsBefore && !li.extendsAfter;
        final x2 = isNode && endMs == null ? x1 : endX();
        final y = blockTop(li.startMonth) +
            laneTopInBlock[p]! +
            li.slot * slotH +
            slotH / 2;
        final nameX = (isNode ? x1 : x2) + 9;
        // 名称可用宽度：同槽下一任务的 x 或本行右缘，取小（v2.4 修复：
        // 旧逻辑在下一任务跨行回绕时 avail 变负导致名称消失）
        final nextX = slotNextX[li.taskId];
        final rightBound =
            nextX != null && nextX > nameX ? nextX : rowRight(li.startMonth);
        final avail = rightBound - nameX - 2;
        final done = task.status == TaskStatus.done;
        // 子任务（与父同槽叠加）不画名称
        // P1：名称排版按 title + 是否完成缓存（以前每条任务都新建 TextPainter）
        final tp = li.isSubtask
            ? null
            : textCache.name(
                task.title, done ? doneNameStyle : nameStyle, done: done);
        items.add(_YearItem(
          task: task,
          lane: li,
          x1: x1,
          x2: x2,
          y: y,
          color: color,
          nameX: nameX,
          name: tp != null && tp.width <= avail ? tp : null,
        ));
      }
    }

    // 命中区域：子任务在前（与父同槽叠加时优先命中子任务）
    final hitRegions = <_HitRegion>[];
    final hitOrdered = [
      ...items.where((i) => i.lane.isSubtask),
      ...items.where((i) => !i.lane.isSubtask),
    ];
    for (final it in hitOrdered) {
      final isSegment = it.lane.startMonth != it.lane.endMonth ||
          it.lane.extendsBefore ||
          it.lane.extendsAfter;
      if (isSegment) {
        hitRegions.add(
            _HitRegion(Rect.fromCircle(center: Offset(it.x2, it.y), radius: 14),
                it.task.id, _DragMode.resizeEnd));
        hitRegions.add(
            _HitRegion(Rect.fromCircle(center: Offset(it.x1, it.y), radius: 14),
                it.task.id, _DragMode.resizeStart));
        hitRegions.add(_HitRegion(
            Rect.fromLTRB(it.x1, it.y - 10, it.x2, it.y + 10),
            it.task.id,
            _DragMode.move));
      } else {
        hitRegions.add(_HitRegion(
            Rect.fromCircle(center: Offset(it.x1, it.y), radius: 14),
            it.task.id,
            _DragMode.move));
      }
    }

    return _YearLayout._(
      width: width,
      height: height,
      blockW: blockW,
      blockH: blockH,
      slotH: slotH,
      year: year,
      laneSlotCounts: laneSlotCounts,
      monthBlocks: monthBlocks,
      items: items,
      hitRegions: hitRegions,
      originals: originals,
      scheme: scheme,
      currentMonth: now.year == year ? now.month : 0,
      selectedTaskId: selectedTaskId,
      pulseMonth: pulseMonth,
    );
  }

  /// P1：paint 真正消费的字段是否全部相同（相同就跳过重绘）。
  /// 命中区域 / spans 只服务手势，不影响画面，故不参与比较。
  bool samePaintContent(_YearLayout o) {
    if (identical(this, o)) return true;
    return width == o.width &&
        height == o.height &&
        blockW == o.blockW &&
        blockH == o.blockH &&
        slotH == o.slotH &&
        year == o.year &&
        scheme == o.scheme &&
        currentMonth == o.currentMonth &&
        selectedTaskId == o.selectedTaskId &&
        pulseMonth == o.pulseMonth &&
        _sameMonthBlocks(monthBlocks, o.monthBlocks) &&
        _sameItems(items, o.items);
  }

  static bool _sameMonthBlocks(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameItems(List<_YearItem> a, List<_YearItem> b) {
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
          x.nameX != y.nameX ||
          !identical(x.name, y.name) ||
          x.lane.startMonth != y.lane.startMonth ||
          x.lane.endMonth != y.lane.endMonth ||
          x.lane.extendsBefore != y.lane.extendsBefore ||
          x.lane.extendsAfter != y.lane.extendsAfter ||
          x.lane.isSubtask != y.lane.isSubtask) {
        return false;
      }
    }
    return true;
  }

  _YearItem? itemById(String taskId) {
    for (final it in items) {
      if (it.task.id == taskId) return it;
    }
    return null;
  }

  /// 命中任务元素（端点优先于线段中段）。
  _HitRegion? hitTest(Offset p) {
    for (final r in hitRegions) {
      if (r.rect.contains(p)) return r;
    }
    return null;
  }

  /// 位置所在月块（1-12），不在任何块内返回 null。
  int? monthAt(Offset p) {
    for (var i = 0; i < 12; i++) {
      if (monthBlocks[i].contains(p)) return i + 1;
    }
    return null;
  }

  /// 位置对应的连续月坐标（0.0-12.0），拖拽吸附取整用；纵向跨行有效。
  double monthPosAt(Offset p) {
    final col = ((p.dx - pad) / (blockW + gap)).floor().clamp(0, 2);
    final fracX =
        ((p.dx - pad - col * (blockW + gap)) / blockW).clamp(0.0, 1.0);
    final row = ((p.dy - pad) / (blockH + gap)).floor().clamp(0, 3);
    return (row * 3 + col + fracX).clamp(0.0, 12.0);
  }
}

/// P1：名称/月份 TextPainter 缓存（挂在 State 上，跨帧复用）。
/// 主题（ColorScheme）变化时整体清空；名称键含 title + 是否完成，
/// 条目数设上限，任务标题频繁变化时不至于无限增长。
class _YearTextCache {
  static const _cap = 512;

  final Map<String, TextPainter> _painters = <String, TextPainter>{};
  ColorScheme? _scheme;

  /// 每帧 build 调用一次：主题变化则清空缓存。
  void syncScheme(ColorScheme scheme) {
    if (_scheme == scheme) return;
    _scheme = scheme;
    _painters.clear();
  }

  TextPainter get(String key, String text, TextStyle style,
      {int? maxLines}) {
    final cached = _painters[key];
    if (cached != null) return cached;
    if (_painters.length >= _cap) _painters.clear();
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
    )..layout();
    return _painters[key] = tp;
  }

  /// 任务名称（年视图泳道内，单行）。
  TextPainter name(String title, TextStyle style, {required bool done}) =>
      get('n${done ? 1 : 0}:$title', title, style, maxLines: 1);

  /// 月块标签（1-12 月，当前月样式不同）。
  TextPainter monthLabel(int month, ColorScheme scheme,
          {required bool isCurrent}) =>
      get(
        'm$month-${isCurrent ? 1 : 0}',
        '$month月',
        TextStyle(
          fontSize: 11,
          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
          color: isCurrent ? scheme.primary : scheme.onSurfaceVariant,
        ),
      );
}

class _YearPainter extends CustomPainter {
  final _YearLayout layout;
  final _YearTextCache texts;

  _YearPainter(this.layout, this.texts);

  static const _nodeR = 4.5;

  @override
  void paint(Canvas canvas, Size size) {
    final scheme = layout.scheme;
    final gridPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = scheme.outlineVariant.withValues(alpha: 0.7);
    // 月块：格线风格（v2.3 §13-8）——不填充底色，只画分隔细线；
    // 当前月/脉冲月保留描边高亮
    for (var m = 1; m <= 12; m++) {
      final rect = layout.monthBlocks[m - 1];
      final isCurrent = m == layout.currentMonth;
      final isPulse = m == layout.pulseMonth;
      canvas.drawRect(rect, gridPaint);
      if (isCurrent || isPulse) {
        canvas.drawRect(
          rect,
          Paint()
            ..color = scheme.primary
                .withValues(alpha: isPulse ? 0.18 : 0.08),
        );
        canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = scheme.primary,
        );
      }
      // P1：月块标签 TextPainter 缓存（以前每帧新建 12 个）
      final tp = texts.monthLabel(m, scheme, isCurrent: isCurrent);
      tp.paint(canvas, Offset(rect.left + 6, rect.top + 3));
    }

    // 任务节点/线段/名称；子任务画更小节点/更细线段（与父同槽叠加）；
    // 选中任务加描边（v2.3 选中-调整）
    for (final it in layout.items) {
      final done = it.task.status == TaskStatus.done;
      final color = it.color.withValues(alpha: done ? doneTaskOpacity : 1.0);
      final isSegment = it.lane.startMonth != it.lane.endMonth ||
          it.lane.extendsBefore ||
          it.lane.extendsAfter;
      if (isSegment) {
        canvas.drawLine(
          Offset(it.x1, it.y),
          Offset(it.x2, it.y),
          Paint()
            ..color = color
            ..strokeWidth = it.lane.isSubtask ? 1.5 : 2.5
            ..strokeCap = StrokeCap.round,
        );
        _drawEnd(canvas, it.x1, it.y, color, it.lane.extendsBefore,
            it.lane.isSubtask);
        _drawEnd(canvas, it.x2, it.y, color, it.lane.extendsAfter,
            it.lane.isSubtask);
      } else {
        canvas.drawCircle(Offset(it.x1, it.y),
            it.lane.isSubtask ? _nodeR - 1.5 : _nodeR, Paint()..color = color);
      }
      if (it.task.id == layout.selectedTaskId) {
        _drawSelection(canvas, it, scheme);
      }
      final name = it.name;
      if (name != null) {
        name.paint(canvas, Offset(it.nameX, it.y - name.height / 2));
      }
    }
  }

  void _drawSelection(Canvas canvas, _YearItem it, ColorScheme scheme) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = scheme.primary;
    final isSegment = it.lane.startMonth != it.lane.endMonth ||
        it.lane.extendsBefore ||
        it.lane.extendsAfter;
    if (isSegment) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(it.x1 - 6, it.y - 8, it.x2 + 6, it.y + 8),
          const Radius.circular(5),
        ),
        paint,
      );
    } else {
      canvas.drawCircle(Offset(it.x1, it.y), _nodeR + 4, paint);
    }
  }

  /// 端点：真实起终点画圆点；延伸出年边界的截断端不画任何端点
  /// （v2.5：取消斜切箭头，线段直接截断在网格边界）。
  void _drawEnd(
      Canvas canvas, double x, double y, Color color, bool extendsOut,
      [bool isSubtask = false]) {
    if (extendsOut) return;
    canvas.drawCircle(Offset(x, y), isSubtask ? _nodeR - 1.5 : _nodeR,
        Paint()..color = color);
  }

  @override
  bool shouldRepaint(_YearPainter oldDelegate) =>
      !oldDelegate.layout.samePaintContent(layout);
}
