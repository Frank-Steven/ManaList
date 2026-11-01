import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/task.dart';

/// P1-1 回归：point 任务只表示单个时刻，带 endAt 也不得被当成时间范围。
void main() {
  group('Task.overlaps', () {
    test('point 任务带脏 endAt 时仍按点判断', () {
      final t = Task(
        id: 't1',
        title: '交报告',
        kind: TaskKind.point,
        startAt: DateTime(2026, 10, 13, 9).millisecondsSinceEpoch,
        endAt: DateTime(2026, 10, 20).millisecondsSinceEpoch, // 脏数据
        createdAt: 0,
        updatedAt: 0,
      );
      final s = DateTime(2026, 10, 14).millisecondsSinceEpoch;
      final e = DateTime(2026, 10, 15).millisecondsSinceEpoch;
      // 按点：10-13 09:00 不在 [10-14, 10-15) 内
      expect(t.overlaps(s, e), isFalse);
      // 若按 range 处理（修复前），这里会为 true
    });

    test('range 任务照常按区间判断', () {
      final t = Task(
        id: 't2',
        title: '出差',
        kind: TaskKind.range,
        startAt: DateTime(2026, 10, 13).millisecondsSinceEpoch,
        endAt: DateTime(2026, 10, 20).millisecondsSinceEpoch,
        createdAt: 0,
        updatedAt: 0,
      );
      final s = DateTime(2026, 10, 14).millisecondsSinceEpoch;
      final e = DateTime(2026, 10, 15).millisecondsSinceEpoch;
      expect(t.overlaps(s, e), isTrue);
    });
  });
}
