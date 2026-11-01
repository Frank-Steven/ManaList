import 'dart:math' as math;

import 'package:characters/characters.dart';

import '../../../models/task.dart';
import '../../../services/text_width.dart';

/// 年视图泳道布局项（设计 §2.1 填充算法）。
class YearLaneItem {
  final String taskId;

  /// 钳制到当前年后的起止月（1-12）。
  final int startMonth;
  final int endMonth;

  /// 任务实际起点/终点不在当前年（截断端不画端点，不为跨年部分保留槽位）。
  final bool extendsBefore;
  final bool extendsAfter;

  /// 泳道内槽位，0 起往下。
  final int slot;

  /// 子任务（设计 §1.2/§3）：父任务在同泳道时与父同槽，画更小节点/更细线段。
  final bool isSubtask;

  const YearLaneItem({
    required this.taskId,
    required this.startMonth,
    required this.endMonth,
    required this.extendsBefore,
    required this.extendsAfter,
    required this.slot,
    this.isSubtask = false,
  });
}

/// 年视图单条优先级泳道的槽位填充（设计 §2.1）：
/// 槽位先到先得，填充顺序 = **优先级优先**（important 红 → normal → minor 绿），
/// 同优先级内按开始时间升序 —— 同一槽位可放多个任务竞争时，红色靠上、
/// 绿色靠下、normal 居中（2026-10-28 分行优先级规则，日/年度视图行分配同）。
/// 每个任务从 slot 0 起找第一个月份区间无重叠的槽位放下；
/// 被先放任务占据的槽位跳过继续往下。跨年任务按钳制后的范围占位
/// （每年独立调用本函数，跨年部分自然落到相邻年泳道的最上面槽位）。
/// 子任务（parent_id 非空）在其父任务位于本泳道时占用与父相同的槽位
/// （isSubtask=true，叠加绘制更小节点/更细线段，不做冲突检查）；
/// 父不在本泳道时按普通任务参与填充。
List<YearLaneItem> layoutYearLane(List<Task> tasks, int year) {
  final yearStart = DateTime(year).millisecondsSinceEpoch;
  final yearEnd = DateTime(year + 1).millisecondsSinceEpoch;
  final entries = <_LaneEntry>[];
  for (final t in tasks) {
    final s = t.startAt;
    if (s == null) continue;
    final e = t.endAt ?? s;
    // 与本年无交集则跳过：时间点需落在年内，区间需与年内有正长度交集
    if (s >= yearEnd) continue;
    if (t.endAt == null ? e < yearStart : e <= yearStart) continue;
    final cs = math.max(s, yearStart);
    // 结束时刻恰为月/年边界时归前一月/年（e-1），保证落在年内且语义正确
    final ce = math.max(cs, math.min(e - 1, yearEnd - 1));
    entries.add(_LaneEntry(
      taskId: t.id,
      parentId: t.parentId,
      priorityRank: taskLabelPriorityRank(t),
      startMs: s,
      startMonth: DateTime.fromMillisecondsSinceEpoch(cs).month,
      endMonth: DateTime.fromMillisecondsSinceEpoch(ce).month,
      extendsBefore: s < yearStart,
      extendsAfter: e >= yearEnd,
    ));
  }
  int byStart(_LaneEntry a, _LaneEntry b) {
    // 优先级优先（红靠上、绿靠下），同优先级再按开始时间
    final r = a.priorityRank.compareTo(b.priorityRank);
    if (r != 0) return r;
    final c = a.startMs.compareTo(b.startMs);
    return c != 0 ? c : a.taskId.compareTo(b.taskId);
  }

  final parents = entries.where((e) => e.parentId == null).toList()
    ..sort(byStart);
  final subtasks = entries.where((e) => e.parentId != null).toList()
    ..sort(byStart);
  final slots = <List<(int, int)>>[];
  final result = <YearLaneItem>[];

  int placeNormally(_LaneEntry en) {
    var slot = 0;
    while (true) {
      if (slot == slots.length) slots.add([]);
      final occupied = slots[slot];
      final clash = occupied
          .any((iv) => en.startMonth <= iv.$2 && iv.$1 <= en.endMonth);
      if (!clash) {
        occupied.add((en.startMonth, en.endMonth));
        return slot;
      }
      slot++;
    }
  }

  YearLaneItem toItem(_LaneEntry en, int slot, {bool isSubtask = false}) =>
      YearLaneItem(
        taskId: en.taskId,
        startMonth: en.startMonth,
        endMonth: en.endMonth,
        extendsBefore: en.extendsBefore,
        extendsAfter: en.extendsAfter,
        slot: slot,
        isSubtask: isSubtask,
      );

  final parentSlot = <String, int>{};
  for (final en in parents) {
    final slot = placeNormally(en);
    parentSlot[en.taskId] = slot;
    result.add(toItem(en, slot));
  }
  for (final en in subtasks) {
    final ps = parentSlot[en.parentId!];
    if (ps != null) {
      result.add(toItem(en, ps, isSubtask: true));
    } else {
      result.add(toItem(en, placeNormally(en)));
    }
  }
  return result;
}

class _LaneEntry {
  final String taskId;
  final String? parentId;
  final int priorityRank;
  final int startMs;
  final int startMonth;
  final int endMonth;
  final bool extendsBefore;
  final bool extendsAfter;

  const _LaneEntry({
    required this.taskId,
    required this.parentId,
    required this.priorityRank,
    required this.startMs,
    required this.startMonth,
    required this.endMonth,
    required this.extendsBefore,
    required this.extendsAfter,
  });
}

/// 年度视图刻度档位（设计 §2.1，v2.2）：与 [dayTickInterval] 同思路。
///
/// 返回 (主刻度间隔年数, 次刻度间隔年数?, 年份标注隔几个显示)：
/// - 主刻度 = 候选 1/5/10 年中「相邻标注间距 ≥ [labelSpacingPx]」的最密档，
///   都不满足时取 10 年；
/// - 次刻度 = 下一更密档，间距不足 [minorSpacingPx] 时省略（null）；
/// - 标注按 2 的幂隔一个显示（stride=1 即每个主刻度都标）。
(int, int?, int) yearTickInterval(
  double pxPerYear, {
  double labelSpacingPx = 64,
  double minorSpacingPx = 6,
}) {
  final ppy = math.max(pxPerYear, 1e-6);
  const candidates = [1, 5, 10];
  var majorIdx = candidates.indexWhere((c) => c * ppy >= labelSpacingPx);
  if (majorIdx < 0) majorIdx = candidates.length - 1;
  final major = candidates[majorIdx];
  final minor =
      majorIdx > 0 && candidates[majorIdx - 1] * ppy >= minorSpacingPx
          ? candidates[majorIdx - 1]
          : null;
  var stride = 1;
  while (major * ppy * stride < labelSpacingPx) {
    stride *= 2;
  }
  return (major, minor, stride);
}

/// 日视图刻度档位（设计 §2.3，v2.1 修订）。
///
/// 返回 (主刻度间隔分钟, 次刻度间隔分钟?, 时间标注隔几个显示)：
/// - 主刻度 = 候选 5/15/30/60/120 中「相邻标注间距 ≥ [labelSpacingPx]」的最密档，
///   都不满足时取 120 分钟；
/// - 次刻度 = 下一更密档，间距不足 [minorSpacingPx] 时省略（null）；
/// - 标注按 2 的幂隔一个显示（stride=1 即每个主刻度都标），保证实际标注
///   间距 ≥ [labelSpacingPx]。
(int, int?, int) dayTickInterval(
  double pxPerMinute, {
  double labelSpacingPx = 64,
  double minorSpacingPx = 6,
}) {
  final ppm = math.max(pxPerMinute, 1e-6);
  const candidates = [5, 15, 30, 60, 120];
  var majorIdx = candidates.indexWhere((c) => c * ppm >= labelSpacingPx);
  if (majorIdx < 0) majorIdx = candidates.length - 1;
  final major = candidates[majorIdx];
  final minor = majorIdx > 0 &&
          candidates[majorIdx - 1] * ppm >= minorSpacingPx
      ? candidates[majorIdx - 1]
      : null;
  var stride = 1;
  while (major * ppm * stride < labelSpacingPx) {
    stride *= 2;
  }
  return (major, minor, stride);
}

/// 斜 45° 名称空位分配结果（设计 §2.3 名称层；日/年度视图共用）。
/// 标签放置的优先级权重：重要 < 一般 < 不重要（数值越小越先放、越容易被保留）。
int taskLabelPriorityRank(Task t) {
  switch (t.priority) {
    case 'important':
      return 0;
    case 'minor':
      return 2;
    default:
      return 1;
  }
}

/// 拖动/新建时把时间量化到 [stepMinutes] 的整数倍。
///
/// U15：用户要求拖动最小单位 = **1 分钟**（原先是 5 分钟，手指小幅移动时节点不动，手感卡顿）。
/// 抽成纯函数便于单测；年度/月视图按天/月量化，不走这里。
double snapToMinutes(double rawMinutes, {double stepMinutes = 1}) {
  if (stepMinutes <= 0) return rawMinutes;
  return (rawMinutes / stepMinutes).roundToDouble() * stepMinutes;
}

/// 一个节点的位置（U11 聚类用）。
typedef NodePos = ({String id, double x, double y});

/// 把时间位置几乎重合的节点聚成若干组（U11）。
///
/// 判定：x 差 ≤ [thresholdPx] 即视为「同一时刻」。**默认忽略 y** —— 不同优先级的任务
/// 在不同泳道，但同一时刻的两个点上下叠着，仍然应合并成一个点（用户 2026-10-18 追加）。
/// 需要区分泳道时可传 yTolerancePx（小于容器高度即可）。
/// 纯函数，便于单测（画布逻辑不参与）。
List<List<String>> clusterOverlappingNodes(
  List<NodePos> nodes, {
  double thresholdPx = 6,
  /// 跨泳道（不同优先级）时的阈值：两条泳道上下分开，视觉上本来不挤，
  /// 只有「几乎同一时刻」才合并，否则会把相隔半小时的任务并成一个点。
  double crossLaneThresholdPx = 6,
  /// y 差在此以内算同一泳道。
  double laneTolerancePx = 6,
}) {
  final groups = <List<NodePos>>[];
  for (final n in nodes) {
    List<NodePos>? hit;
    for (final g in groups) {
      final dx = (g.first.x - n.x).abs();
      final dy = (g.first.y - n.y).abs();
      final limit = dy <= laneTolerancePx ? thresholdPx : crossLaneThresholdPx;
      if (dx <= limit) {
        hit = g;
        break;
      }
    }
    if (hit != null) {
      hit.add(n);
    } else {
      groups.add([n]);
    }
  }
  groups.sort((a, b) => a.first.x.compareTo(b.first.x));
  return [
    for (final g in groups) [for (final n in g) n.id],
  ];
}
/// 节点聚类的查询封装（U11）：画笔用它判断「谁是代表点、点画多大、标题怎么合并」。
class NodeClusters {
  final List<List<NodePos>> groups;
  final Map<String, int> _index;

  NodeClusters._(this.groups, this._index);

  factory NodeClusters.build(
    List<NodePos> nodes, {
    double thresholdPx = 12,
    double crossLaneThresholdPx = 6,
    double laneTolerancePx = 6,
  }) {
    final idGroups = clusterOverlappingNodes(
      nodes,
      thresholdPx: thresholdPx,
      crossLaneThresholdPx: crossLaneThresholdPx,
      laneTolerancePx: laneTolerancePx,
    );
    final byId = {for (final n in nodes) n.id: n};
    final groups = <List<NodePos>>[
      for (final g in idGroups) [for (final id in g) if (byId[id] != null) byId[id]!],
    ];
    final index = <String, int>{};
    for (var i = 0; i < groups.length; i++) {
      for (final n in groups[i]) {
        index[n.id] = i;
      }
    }
    return NodeClusters._(groups, index);
  }

  int? indexOfId(String id) => _index[id];

  List<String> ids(int i) => groups[i].map((n) => n.id).toList();

  int count(int i) => groups[i].length;

  /// 代表点：y 最小的那个（泳道越靠上优先级越高），保留最高优先级的颜色与泳道。
  String representativeId(int i) {
    var best = groups[i].first;
    for (final n in groups[i]) {
      if (n.y < best.y) best = n;
    }
    return best.id;
  }

  bool isRepresentative(String id) {
    final i = _index[id];
    return i != null && representativeId(i) == id;
  }

  /// 合并点的绘制位置：直接用**代表点自己的位置**（不取平均）。
  /// 取平均会让点和上方虚线错开 —— 用户 2026-10-18 报过这个问题。
  (double, double) anchor(int i) {
    var best = groups[i].first;
    for (final n in groups[i]) {
      if (n.y < best.y) best = n;
    }
    return (best.x, best.y);
  }
}
class DayNameSlot {
  final String taskId;

  /// 名称锚点（轴单位：日视图=当天分钟数，年度视图=年小数）：
  /// 虚线从节点/线段向上连到该位置。
  final double centerMinutes;

  /// 参与碰撞的文本宽（px，估算或调用方测量）。
  final double textWidth;

  /// 找不到不碰撞的空位时为 false（节点/线段仍照常绘制）。
  final bool visible;

  const DayNameSlot({
    required this.taskId,
    required this.centerMinutes,
    required this.textWidth,
    required this.visible,
  });
}

/// 45° 斜文本名称贪心放置（设计 §2.1/§2.3，v2.3）：取消固定比例尺阈值，
/// 纯碰撞决定可见性——按开始时间升序依次为每个任务找不碰撞的锚点；
/// 时间段任务在自身范围内按 [anchorStep] 步长（轴单位）从前往后找最靠前
/// 的空位；时间点任务（零长度区间）允许从节点位置起向后漂移最多
/// [pointDriftSteps] 步找空位（虚线随之拉长），仍放不下（碰撞或超出名称层
/// 高度）则不显示该名称。
///
/// [axisOf] 给出任务在轴上的起止坐标（日视图=当天分钟数，
/// 年度视图=相对年小数）；[axisPerPx] = 轴单位 / px。
///
/// 碰撞检测取舍：所有文本带共享同一 45° 旋转角，把坐标系旋转 -45° 后
/// 每个 OBB 变成 AABB（沿文本方向 u ∈ [a/√2, a/√2 + L]，垂直方向
/// v = -a/√2 ± 厚度/2），两盒相交 = u 区间相交且 v 间距小于厚度和的
/// 一半。这比通用分离轴简单且对本场景精确；不检查名称层外的遮挡
/// （超过 [maxHeightPx] 的文本判为放不下）。
// ---------------------------------------------------------------------------
// R1-A：标签组 + 唯一那次贪心
//
// 以前是两套决策：assignAngledNames 先决定每条任务名放哪（放不下就不画），
// 画笔再用 NodeClusters 决定哪些点合并、谁画名字 —— 两个贪心互相不知道对方在干什么。
// 现在合并成一次：先把「开始时间相近」的任务分组（点任务与时段任务一视同仁），
// 再对这**一组**做一次贪心放置。画笔只负责画。
// ---------------------------------------------------------------------------

/// 一个标签组：开始时间相近的任务合成一组，只画一个标题、一个点。
class LabelGroup {
  /// 代表任务的 id（组的标识，也是写进 nameSlots 的 key）。
  final String id;

  /// 组内任务 id，已按优先级排序（重要的在前）。
  final List<String> taskIds;

  /// 合并后的标题（已折行、任务名之间用「；」分隔，末尾不加）。
  final String title;

  /// 组内最早开始 / 最晚结束（轴的坐标）。全是点任务时两者相等。
  final double startAxis;
  final double endAxis;

  /// 组内最高优先级（0 最重要）。
  final int priorityRank;

  const LabelGroup({
    required this.id,
    required this.taskIds,
    required this.title,
    required this.startAxis,
    required this.endAxis,
    required this.priorityRank,
  });

  bool get isPoint => (endAxis - startAxis).abs() < 0.0001;
  int get size => taskIds.length;
}

/// 标签折行：每行最多 8 个字符，**不截断**（用户 2026-10-18 要求）。
String wrapLabelTitle(String title, {int charsPerLine = 8}) {
  final chars = title.trim().characters.toList();
  if (chars.isEmpty) return '';
  final lines = <String>[];
  for (var i = 0; i < chars.length; i += charsPerLine) {
    final end =
        (i + charsPerLine) > chars.length ? chars.length : i + charsPerLine;
    lines.add(chars.sublist(i, end).join());
  }
  return lines.join('\n');
}

/// 合并标题：每个任务名结尾加「；」再接下一个，**最后一个不加**（用户指定）。
String mergeLabelTitles(List<String> titles) {
  final list = [for (final s in titles) s.trim()].where((s) => s.isNotEmpty).toList();
  if (list.isEmpty) return '';
  final lines = <String>[];
  for (var i = 0; i < list.length; i++) {
    final wrapped = wrapLabelTitle(list[i]).split('\n');
    if (i < list.length - 1) {
      wrapped[wrapped.length - 1] = '${wrapped.last}；';
    }
    lines.addAll(wrapped);
  }
  return lines.join('\n');
}

/// 按「开始时间相距 ≤ thresholdPx」分组（点任务与时段任务一视同仁）。
/// 组内按优先级排序（important → normal → minor），时间次之。
List<LabelGroup> buildLabelGroups(
  List<Task> tasks, {
  required (double, double) Function(Task t) axisOf,
  required double axisPerPx,
  double thresholdPx = 12,
}) {
  if (tasks.isEmpty) return const [];
  final thresholdAxis = thresholdPx * axisPerPx;
  // 分组：仅按开始时间（与优先级/泳道无关）
  final positions = [
    for (final t in tasks) (id: t.id, x: axisOf(t).$1, y: 0.0),
  ];
  final clusters = clusterOverlappingNodes(
    positions,
    thresholdPx: thresholdAxis,
    crossLaneThresholdPx: thresholdAxis,
    laneTolerancePx: double.infinity,
  );
  final byId = {for (final t in tasks) t.id: t};
  final groups = <LabelGroup>[];
  for (final ids in clusters) {
    final members = [for (final id in ids) if (byId[id] != null) byId[id]!];
    if (members.isEmpty) continue;
    // 优先级优先，其次时间
    members.sort((a, b) {
      final r = taskLabelPriorityRank(a).compareTo(taskLabelPriorityRank(b));
      if (r != 0) return r;
      final c = (a.startAt ?? 0).compareTo(b.startAt ?? 0);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    var startAxis = double.infinity;
    var endAxis = double.negativeInfinity;
    for (final m in members) {
      final (s, e) = axisOf(m);
      if (s < startAxis) startAxis = s;
      if (e > endAxis) endAxis = e;
    }
    groups.add(LabelGroup(
      id: members.first.id,
      taskIds: [for (final m in members) m.id],
      title: mergeLabelTitles([for (final m in members) m.title]),
      startAxis: startAxis,
      endAxis: endAxis,
      priorityRank: taskLabelPriorityRank(members.first),
    ));
  }
  groups.sort((a, b) {
    final r = a.priorityRank.compareTo(b.priorityRank);
    return r != 0 ? r : a.startAxis.compareTo(b.startAxis);
  });
  return groups;
}

/// 唯一那次贪心：为每个**组**找标签位置（放不下 → visible=false，不画）。
Map<String, DayNameSlot> assignGroupNames(
  List<LabelGroup> groups, {
  required double axisPerPx,
  double anchorStep = 5,
  double fontPx = 12,
  double maxHeightPx = 96,
  int pointDriftSteps = 12,
  double Function(String title)? measureText,
}) {
  final measure = measureText ?? (title) => displayWidth(title) * fontPx / 2;
  final k = axisPerPx;
  const sqrt2 = math.sqrt2;
  // 组已按优先级排好序：重要的先占位（用户 2026-10-18 要求）
  final sorted = [...groups]..sort((a, b) {
      final r = a.priorityRank.compareTo(b.priorityRank);
      return r != 0 ? r : a.startAxis.compareTo(b.startAxis);
    });

  final placedU = <(double, double)>[];
  final placedV = <double>[];
  final placedW = <double>[];
  final slots = <String, DayNameSlot>{};

  for (final g in sorted) {
    // 标题是多行时按最长一行算宽度
    final textWidth = [
      for (final line in g.title.split('\n')) measure(line),
    ].fold<double>(0, (a, b) => a > b ? a : b);
    final lengthAxis = textWidth * k;
    final thicknessAxis = fontPx * 1.2 * k;
    final fitsHeight = lengthAxis / sqrt2 <= maxHeightPx * k;

    var anchor = g.startAxis;
    var visible = false;
    if (fitsHeight) {
      final limit = g.isPoint
          ? g.startAxis + anchorStep * pointDriftSteps
          : (g.endAxis > g.startAxis ? g.endAxis : g.startAxis);
      for (var a = g.startAxis; a <= limit + 0.0001; a += anchorStep) {
        if (_fits(a, lengthAxis, thicknessAxis, placedU, placedV, placedW)) {
          anchor = a;
          visible = true;
          placedU.add((a / sqrt2, a / sqrt2 + lengthAxis));
          placedV.add(-a / sqrt2);
          placedW.add(thicknessAxis);
          break;
        }
      }
    }
    slots[g.id] = DayNameSlot(
      taskId: g.id,
      centerMinutes: anchor,
      textWidth: textWidth,
      visible: visible,
    );
  }
  return slots;
}
List<DayNameSlot> assignAngledNames(
  List<Task> tasks, {
  required (double, double) Function(Task t) axisOf,
  required double axisPerPx,
  double anchorStep = 5,
  double fontPx = 12,
  double maxHeightPx = 96,
  int pointDriftSteps = 12,
  double Function(String title)? measureText,
}) {
  final measure = measureText ??
      // 全角字符约等于字宽，ASCII 约为一半（与 displayWidth 的 2/1 计量对应）
      (title) => displayWidth(title) * fontPx / 2;
  final k = axisPerPx;
  const sqrt2 = math.sqrt2;

  // 放置顺序：**优先级优先**（important → normal → minor），同一优先级内再按时间。
  // 标签位置是先到先得，后来者会被判「放不下」而隐藏；
  // 所以优先级必须排在时间前面，否则时间早 2 分钟的普通任务会挤掉重要任务的名字
  // （用户 2026-10-18 用 22:12:27(普通) vs 33:12:29(重要) 的情况指出）。
  final sorted = [...tasks]..sort((a, b) {
      final r = taskLabelPriorityRank(a).compareTo(taskLabelPriorityRank(b));
      if (r != 0) return r;
      final c = (a.startAt ?? 0).compareTo(b.startAt ?? 0);
      return c != 0 ? c : a.id.compareTo(b.id);
    });

  final placedU = <(double, double)>[];
  final placedV = <double>[];
  final placedW = <double>[];
  final byId = <String, DayNameSlot>{};

  for (final t in sorted) {
    if (t.startAt == null) continue;
    final (startAxis, endAxis) = axisOf(t);
    final textWidth = measure(t.title);
    final lengthAxis = textWidth * k;
    final thicknessAxis = fontPx * 1.2 * k;
    final fitsHeight = lengthAxis / sqrt2 <= maxHeightPx * k;

    var anchor = startAxis;
    var visible = false;
    if (fitsHeight) {
      // 候选锚点：时间段在自身范围内按步长前移；时间点（零长度区间）
      // 从节点位置起向后漂移最多 pointDriftSteps 步（v2.4：修复相邻
      // 时间点任务名称被先放置者挤掉后完全不显示的问题）
      final isPoint = endAxis - startAxis < 0.0001;
      final limit =
          isPoint ? startAxis + anchorStep * pointDriftSteps : endAxis;
      for (var a = startAxis; a <= limit + 0.0001; a += anchorStep) {
        if (_fits(a, lengthAxis, thicknessAxis, placedU, placedV, placedW)) {
          anchor = a;
          visible = true;
          placedU.add((a / sqrt2, a / sqrt2 + lengthAxis));
          placedV.add(-a / sqrt2);
          placedW.add(thicknessAxis);
          break;
        }
      }
    }
    byId[t.id] = DayNameSlot(
      taskId: t.id,
      centerMinutes: anchor,
      textWidth: textWidth,
      visible: visible,
    );
  }
  // 按输入顺序返回
  return [for (final t in tasks) if (byId.containsKey(t.id)) byId[t.id]!];
}

/// 日视图名称空位分配（设计 §2.3）：轴 = 当天分钟数（跨日钳到 24:00）。
List<DayNameSlot> assignDayNames(
  List<Task> tasks, {
  required double pxPerMinute,
  double fontPx = 12,
  double maxHeightPx = 96,
  int pointDriftSteps = 12,
  double Function(String title)? measureText,
}) {
  return assignAngledNames(
    tasks,
    axisOf: (t) {
      final startMin = _minuteOfDay(t.startAt!);
      final endMin = t.endAt == null
          ? startMin
          : math.max(startMin, math.min(1440.0, _minuteOfDay(t.endAt!)));
      return (startMin, endMin);
    },
    axisPerPx: 1 / pxPerMinute,
    anchorStep: 5,
    fontPx: fontPx,
    maxHeightPx: maxHeightPx,
    pointDriftSteps: pointDriftSteps,
    measureText: measureText,
  );
}

/// 无限滚动「大初始偏移」索引映射（设计 §2，v2.3）：
/// ListView itemIndex = [infiniteScrollOffset] + 单位序号（如相对某基准年的
/// 年偏移、相对基准日的日偏移），双向无限。
const int infiniteScrollOffset = 1 << 20;

/// itemIndex → 相对基准的单位序号（可正可负）。
int unitIndexForItem(int itemIndex) => itemIndex - infiniteScrollOffset;

/// 单位序号 → itemIndex。
int itemIndexForUnit(int unitIndex) => unitIndex + infiniteScrollOffset;

double _minuteOfDay(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return d.hour * 60 + d.minute + d.second / 60.0;
}

bool _fits(
  double anchorMin,
  double lengthMin,
  double thicknessMin,
  List<(double, double)> placedU,
  List<double> placedV,
  List<double> placedW,
) {
  const sqrt2 = math.sqrt2;
  final u0 = anchorMin / sqrt2;
  final u1 = anchorMin / sqrt2 + lengthMin;
  final v = -anchorMin / sqrt2;
  for (var i = 0; i < placedU.length; i++) {
    final (pu0, pu1) = placedU[i];
    final vGap = (v - placedV[i]).abs();
    if (u1 > pu0 && u0 < pu1 && vGap < (thicknessMin + placedW[i]) / 2) {
      return false;
    }
  }
  return true;
}
