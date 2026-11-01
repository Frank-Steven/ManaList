/// 任务时间尺度（设计 §1.2，v2.1）：派生不落库。
///
/// 推导链（"相邻" = 同一自然单位或紧邻的上一个/下一个，用单位序号差 ≤1 实现）：
/// 1. 无开始时间 → 不定时；
/// 2. 起止同一天或相邻两天 → 定时；
/// 3. 否则同一自然周（周日起）或相邻两周 → 整日；
/// 4. 否则同一/相邻自然月 → 整周；
/// 5. 否则同一/相邻自然季度 → 月度；
/// 6. 否则同一年或相邻两年 → 季度；
/// 7. 否则 → 年度。
///
/// ※ kind 为 point 的任务只表示单个时刻：即使数据里带了 endAt，也一律按
///   start 处理（P1-1 修复；此前仅注释约定、实现里从未归一化）。
library;

import '../models/task.dart' show TaskKind;

/// 七级派生尺度（从大到小）：yearly / quarterly / monthly / weekly / daily /
/// timed / untimed。
String deriveTimeScale(DateTime? start, DateTime? end, {String? kind}) {
  if (start == null) return 'untimed';
  // point 任务只有单个时刻；kind 缺省时保持旧行为（仅 end 为空才按点处理）
  final e = (kind == TaskKind.point || end == null) ? start : end;
  final sd = _dayNumber(start);
  final ed = _dayNumber(e);
  if ((ed - sd).abs() <= 1) return 'timed';
  if ((_weekIndex(ed) - _weekIndex(sd)).abs() <= 1) return 'daily';
  if ((_monthNumber(e) - _monthNumber(start)).abs() <= 1) return 'weekly';
  if ((_quarterNumber(e) - _quarterNumber(start)).abs() <= 1) return 'monthly';
  if ((e.year - start.year).abs() <= 1) return 'quarterly';
  return 'yearly';
}

/// 尺度中文名（徽标/页签/编辑器只读行用）。
String timeScaleLabel(String scale) => switch (scale) {
      'yearly' => '年度',
      'quarterly' => '季度',
      'monthly' => '月度',
      'weekly' => '整周',
      'daily' => '整日',
      'timed' => '定时',
      _ => '不定时',
    };

/// 儒略日数（纯历法计算，不受时区/夏令时影响），作为「天」单位序号。
int _dayNumber(DateTime d) {
  final a = (14 - d.month) ~/ 12;
  final y = d.year + 4800 - a;
  final m = d.month + 12 * a - 3;
  return d.day +
      (153 * m + 2) ~/ 5 +
      365 * y +
      y ~/ 4 -
      y ~/ 100 +
      y ~/ 400 -
      32045;
}

/// 周日起的自然周序号：JDN % 7 == 6 为周日，回退到本周周后累计整除 7。
int _weekIndex(int dayNumber) {
  final daysSinceSunday = (dayNumber % 7 + 1) % 7;
  return (dayNumber - daysSinceSunday) ~/ 7;
}

int _monthNumber(DateTime d) => d.year * 12 + d.month;

int _quarterNumber(DateTime d) => d.year * 4 + (d.month - 1) ~/ 3;

/// 毫秒时间戳包装（Task.startAt/endAt/kind 直接传入）。
/// [kind] 参与归一化：point 任务即使带了 endAt 也只按点计算（P1-1）。
String deriveTaskScale(int? startAt, int? endAt, {String? kind}) =>
    deriveTimeScale(
        startAt == null ? null : DateTime.fromMillisecondsSinceEpoch(startAt),
        endAt == null ? null : DateTime.fromMillisecondsSinceEpoch(endAt),
        kind: kind);

/// 尺度大小序号：yearly 最大、untimed 最小（不定时不参与包含判断时为 -1）。
int timeScaleRank(String scale) => switch (scale) {
      'yearly' => 6,
      'quarterly' => 5,
      'monthly' => 4,
      'weekly' => 3,
      'daily' => 2,
      'timed' => 1,
      _ => -1,
    };

/// 各日程视图放行的尺度集合（设计 §2 尺度过滤表）。
///
/// - 'yearly'（年度视图）：yearly 节点/线段；
/// - 'year'（年视图）：quarterly / monthly / weekly；
/// - 'month'（月视图）：weekly / daily；
/// - 'day'（日视图）：timed。
/// 不定时任务不进任何日程视图。
Set<String> scalesForView(String view) => switch (view) {
      'yearly' => {'yearly'},
      'year' => {'quarterly', 'monthly', 'weekly'},
      'month' => {'weekly', 'daily'},
      'day' => {'timed'},
      _ => const {},
    };
