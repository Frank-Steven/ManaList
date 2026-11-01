import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/services/reminder_service.dart';

/// P1-5 回归：精确闹钟不可用时必须降级；「该不该排提醒」的判定可独立验证。
void main() {
  Task task({String status = TaskStatus.active, int? startAt}) => Task(
        id: 't1',
        title: '提醒测试',
        kind: TaskKind.point,
        startAt: startAt,
        status: status,
        createdAt: 0,
        updatedAt: 0,
      );

  group('shouldScheduleReminder', () {
    test('active + 未来时间 → 需要排', () {
      expect(shouldScheduleReminder(task(startAt: 2000), nowMs: 1000), isTrue);
    });

    test('时间已过 → 不排', () {
      expect(shouldScheduleReminder(task(startAt: 1000), nowMs: 1000), isFalse);
      expect(shouldScheduleReminder(task(startAt: 500), nowMs: 1000), isFalse);
    });

    test('无 startAt（不定时任务）→ 不排', () {
      expect(shouldScheduleReminder(task(), nowMs: 1000), isFalse);
    });

    test('非 active（done / archived）→ 不排', () {
      expect(
          shouldScheduleReminder(task(status: TaskStatus.done, startAt: 2000),
              nowMs: 1000),
          isFalse);
      expect(
          shouldScheduleReminder(
              task(status: TaskStatus.archived, startAt: 2000),
              nowMs: 1000),
          isFalse);
    });
  });

  group('scheduleModeFor（精确闹钟降级）', () {
    test('有权限 → exactAllowWhileIdle', () {
      expect(scheduleModeFor(exactAllowed: true),
          AndroidScheduleMode.exactAllowWhileIdle);
    });

    test('无权限 → 降级为 inexactAllowWhileIdle（不抛异常、仍会响）', () {
      expect(scheduleModeFor(exactAllowed: false),
          AndroidScheduleMode.inexactAllowWhileIdle);
    });
  });
}
