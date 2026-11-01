import 'package:flutter/material.dart';

import '../../../models/task.dart';

/// 优先级配色（设计 §10.3：自绘视图颜色随深色模式适配）。
Color priorityColor(ColorScheme scheme, String priority) {
  final dark = scheme.brightness == Brightness.dark;
  return switch (priority) {
    TaskPriority.important =>
      dark ? Colors.red.shade300 : Colors.red.shade600,
    TaskPriority.minor =>
      dark ? Colors.green.shade300 : Colors.green.shade600,
    _ => dark ? Colors.amber.shade300 : Colors.amber.shade700,
  };
}

/// 已完成任务的降不透明度（淡色 + 名称划线由绘制方处理）。
const double doneTaskOpacity = 0.38;

/// 任务在半开区间 [startMs, endMs) 内的展示时间：相交返回 (startAt, endAt)，
/// 否则 null。（v2.4：is_annual 逐年平移下线，一律按普通区间判断。）
(int, int?)? occurrenceOverlapping(Task t, int startMs, int endMs) {
  final s = t.startAt;
  if (s == null) return null;
  return t.overlaps(startMs, endMs) ? (s, t.endAt) : null;
}

/// 构建展示副本：与区间相交返回任务本身，否则 null（调用方据此过滤）。
Task? displayOccurrence(Task t, int startMs, int endMs) {
  return occurrenceOverlapping(t, startMs, endMs) == null ? null : t;
}

