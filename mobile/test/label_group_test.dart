import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/ui/tasks/views/layout.dart';

/// R1-A 回归：标签分组 + 唯一一次贪心（点任务与时段任务一视同仁）。
void main() {
  Task task(String id, {
    String title = 't',
    String priority = 'normal',
    int startMin = 0,
    int? endMin,
  }) =>
      Task(
        id: id,
        title: title,
        kind: endMin == null ? TaskKind.point : TaskKind.range,
        priority: priority,
        startAt: startMin * 60000,
        endAt: endMin == null ? null : endMin * 60000,
        createdAt: 0,
        updatedAt: 0,
      );

  (double, double) axis(Task t) => (
        (t.startAt! ~/ 60000).toDouble(),
        t.endAt == null ? (t.startAt! ~/ 60000).toDouble() : (t.endAt! / 60000),
      );

  group('标题', () {
    test('wrapLabelTitle 每行 8 字、不截断', () {
      // 20 个字符 → 8 + 8 + 4，按原顺序切分
      expect(wrapLabelTitle('12345678901234567890'), '12345678\n90123456\n7890');
      expect(wrapLabelTitle('短名字'), '短名字');
      expect(wrapLabelTitle('   '), '');
    });

    test('mergeLabelTitles：名字末尾加「；」，最后一个不加', () {
      expect(mergeLabelTitles(['22', '33']), '22；\n33');
      expect(mergeLabelTitles(['甲', '乙', '丙']), '甲；\n乙；\n丙');
      expect(mergeLabelTitles(['单独']), '单独');
      expect(mergeLabelTitles([]), '');
    });
  });

  group('分组', () {
    test('开始时间相近的点任务合成一组（高优先级排第一）', () {
      final groups = buildLabelGroups(
        [
          task('a', title: '普通', startMin: 100),
          task('b', title: '重要', priority: 'important', startMin: 102),
        ],
        axisOf: axis,
        axisPerPx: 1.0,
        thresholdPx: 12,
      );
      expect(groups.length, 1);
      expect(groups.single.taskIds, ['b', 'a'], reason: '重要任务在前');
      expect(groups.single.title, '重要；\n普通');
    });

    test('时段任务与点任务一起参与分组（Frank 提醒的点）', () {
      final groups = buildLabelGroups(
        [
          task('p', title: '点', startMin: 100),
          task('r', title: '段', startMin: 104, endMin: 200),
        ],
        axisOf: axis,
        axisPerPx: 1.0,
        thresholdPx: 12,
      );
      expect(groups.length, 1, reason: '点任务与时段任务也要能合并');
      expect(groups.single.taskIds.length, 2);
    });

    test('相距超过阈值 → 各自成组', () {
      final groups = buildLabelGroups(
        [task('a', startMin: 0), task('b', startMin: 100)],
        axisOf: axis,
        axisPerPx: 1.0,
        thresholdPx: 12,
      );
      expect(groups.length, 2);
    });
  });

  group('贪心放置', () {
    test('拥挤时优先保留高优先级组的标签', () {
      final groups = buildLabelGroups(
        [
          task('low', title: '普通任务', startMin: 100),
          task('high', title: '重要任务', priority: 'important', startMin: 101),
        ],
        axisOf: axis,
        axisPerPx: 1.0,
        thresholdPx: 0, // 强制分成两组，让它们争同一个位置
      );
      expect(groups.length, 2);
      final slots = assignGroupNames(
        groups,
        axisPerPx: 1.0,
        measureText: (s) => 40,
        pointDriftSteps: 0, // 不允许漂移：两组争同一个锚点，先放者赢
      );
      expect(slots['high']!.visible, isTrue, reason: '重要任务先占位');
      expect(slots['low']!.visible, isFalse, reason: '普通任务被让位');
    });
  });
}
