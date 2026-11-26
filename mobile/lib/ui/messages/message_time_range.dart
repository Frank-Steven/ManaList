import 'package:flutter/material.dart' show DateTimeRange;

/// F18（方案 A）：消息页「按时间段选择」的**纯本地**时间条件。
///
/// 口径（用户已拍板）：
/// - 本地时区，半开区间 **[start, end)**：含起始日 00:00，不含结束日 00:00；
/// - 「今天」= 今天 00:00 → 明天 00:00；「昨天」= 昨天 00:00 → 今天 00:00；
/// - 「近 7 天」= 今天往前 6 个**日历日** 00:00 → 明天 00:00（含今天共 7 天）；
/// - 「自定义起止」：同样半开 —— **含起始日 00:00、不含结束日 00:00**，
///   且必须「起始日 < 结束日」（同日 = 空区间，非法）。
///
/// 该文件只做区间计算与判定，不碰 DB/UI，便于纯函数测试。
class MessageTimeRange {
  const MessageTimeRange({
    required this.start,
    required this.end,
    this.preset,
  });

  /// 区间起点（含）。
  final DateTime start;

  /// 区间终点（不含）。
  final DateTime end;

  /// 来源预设：today / yesterday / last7 / custom。
  final String? preset;

  /// 半开区间判定：start <= postedAt < end。
  bool containsPostedAt(int postedAtMs) =>
      postedAtMs >= start.millisecondsSinceEpoch &&
      postedAtMs < end.millisecondsSinceEpoch;

  /// chip 文案（激活态）：MM/dd-MM/dd（结束日按「含」显示 → end-1ms 所在日）。
  String get label {
    final lastDay = DateTime(end.year, end.month, end.day)
        .subtract(const Duration(milliseconds: 1));
    return '${_mmdd(start)}-${_mmdd(lastDay)}';
  }

  static String _mmdd(DateTime d) =>
      '${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

  @override
  bool operator ==(Object other) =>
      other is MessageTimeRange &&
      other.start == start &&
      other.end == end &&
      other.preset == preset;

  @override
  int get hashCode => Object.hash(start, end, preset);

  @override
  String toString() => 'MessageTimeRange($start → $end, preset=$preset)';
}

/// 某一天的 00:00（本地时区）。
DateTime timeRangeDayStart(DateTime d) => DateTime(d.year, d.month, d.day);

/// 某天的次日 00:00（本地时区）。
DateTime timeRangeNextDayStart(DateTime d) => DateTime(d.year, d.month, d.day + 1);

/// 今天：今天 00:00 → 明天 00:00。
MessageTimeRange messageTimeRangeToday([DateTime? now]) {
  final start = timeRangeDayStart(now ?? DateTime.now());
  return MessageTimeRange(
      start: start, end: _addDays(start, 1), preset: 'today');
}

/// 昨天：昨天 00:00 → 今天 00:00。
MessageTimeRange messageTimeRangeYesterday([DateTime? now]) {
  final today = timeRangeDayStart(now ?? DateTime.now());
  return MessageTimeRange(
      start: _addDays(today, -1), end: today, preset: 'yesterday');
}

/// 近 7 天：今天往前 6 个日历日 00:00 → 明天 00:00。
MessageTimeRange messageTimeRangeLast7Days([DateTime? now]) {
  final today = timeRangeDayStart(now ?? DateTime.now());
  return MessageTimeRange(
      start: _addDays(today, -6),
      end: _addDays(today, 1),
      preset: 'last7');
}

/// 自定义：**[起始日 00:00, 结束日 00:00)** —— 与获批原型一致（结束日当天不含）。
///
/// 例：03/10 → 03/12 表示 [03/10 00:00, 03/12 00:00)，03/12 当天消息不命中；
/// label 仍按 end-1ms 显示，因此该例显示 03/10-03/11。
/// 调用方须先校验 startDay **严格早于** endDay（同日也是空区间，非法）。
MessageTimeRange messageTimeRangeCustom(DateTime startDay, DateTime endDay) =>
    MessageTimeRange(
      start: timeRangeDayStart(startDay),
      end: timeRangeDayStart(endDay),
      preset: 'custom',
    );

/// 把 DateTimeRange（日期选择器的闭区间日）转成半开区间条件。
MessageTimeRange messageTimeRangeFromDateRange(DateTimeRange r) =>
    messageTimeRangeCustom(r.start, r.end);

/// 自定义起止的合法性：起始日必须**严格早于**结束日（半开区间，同日 = 空区间，非法）。
bool isMessageTimeRangeCustomValid(DateTime startDay, DateTime endDay) {
  final s = timeRangeDayStart(startDay);
  final e = timeRangeDayStart(endDay);
  return s.isBefore(e);
}

DateTime _addDays(DateTime day, int days) =>
    DateTime(day.year, day.month, day.day + days);
