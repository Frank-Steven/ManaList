import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/reminder_service.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// P3-6 / P3-7 回归：时区挑选要排除 DST 规则不同的地区；通知 id 不得互相覆盖。
void main() {
  setUpAll(tzdata.initializeTimeZones);

  final service = ReminderService.instance;

  group('pickLocalZoneName（P3-6）', () {
    test('东八区无夏令时：选中地区的两个时点偏移都与系统一致', () {
      final now = DateTime.utc(2026, 10, 17, 12);
      final name = service.pickLocalZoneName(
        now: now,
        offsetNow: const Duration(hours: 8),
        offsetLater: const Duration(hours: 8),
        abbreviation: 'CST',
      );
      final loc = tz.getLocation(name);
      expect(tz.TZDateTime.from(now, loc).timeZoneOffset,
          const Duration(hours: 8));
      expect(
          tz.TZDateTime.from(now.add(const Duration(days: 180)), loc)
              .timeZoneOffset,
          const Duration(hours: 8));
    });

    test('有夏令时的地区：也必须挑到冬夏偏移都匹配的区（而非只看当前偏移）', () {
      final now = DateTime.utc(2026, 7, 1, 12); // 伦敦夏季 +1，半年后冬季 0
      final name = service.pickLocalZoneName(
        now: now,
        offsetNow: const Duration(hours: 1),
        offsetLater: Duration.zero,
        abbreviation: 'BST',
      );
      final loc = tz.getLocation(name);
      expect(tz.TZDateTime.from(now, loc).timeZoneOffset,
          const Duration(hours: 1));
      expect(
          tz.TZDateTime.from(now.add(const Duration(days: 180)), loc)
              .timeZoneOffset,
          Duration.zero);
    });

    test('现实中不存在的偏移 → 回退 UTC', () {
      final name = service.pickLocalZoneName(
        now: DateTime.utc(2026, 7, 1),
        offsetNow: const Duration(hours: 13, minutes: 37),
        offsetLater: const Duration(hours: 13, minutes: 37),
        abbreviation: 'XXX',
      );
      expect(name, 'UTC');
    });
  });

  group('assignNotificationIds（P3-7）', () {
    test('批量分配互不重复，且不占用 AI 通知 id', () {
      final ids = List.generate(500, (i) => 'task-$i');
      final map = service.assignNotificationIds(ids);
      expect(map.length, ids.length);
      expect(map.values.toSet().length, ids.length, reason: '不应出现重复 id');
      expect(map.values.contains(0xA1), isFalse, reason: 'AI 通知 id 必须避开');
      expect(map.values.every((v) => v > 0), isTrue);
    });

    test('单任务时沿用 hashCode 稳定值', () {
      final map = service.assignNotificationIds(['only-one']);
      expect(map['only-one'], 'only-one'.hashCode & 0x7fffffff);
    });
  });
}
