import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/ui/tasks/views/layout.dart';

/// U11 回归：时间几乎重合的节点要聚成一组（画一个点 + 合并标题）。
void main() {
  List<NodePos> nodes(List<(String, double, double)> raw) => [
        for (final (id, x, y) in raw) (id: id, x: x, y: y),
      ];

  test('两个点几乎重合 → 合成一组', () {
    final groups = clusterOverlappingNodes(nodes([
      ('a', 100.0, 50.0),
      ('b', 102.0, 50.5),
    ]));
    expect(groups.length, 1);
    expect(groups.single, ['a', 'b']);
  });

  test('相距较远 → 各自成组', () {
    final groups = clusterOverlappingNodes(nodes([
      ('a', 100.0, 50.0),
      ('b', 200.0, 50.0),
    ]));
    expect(groups.length, 2);
  });

  test('同一时刻但不同泳道（不同优先级）→ 默认仍合并（用户追加需求）', () {
    final groups = clusterOverlappingNodes(nodes([
      ('a', 100.0, 50.0),
      ('b', 100.0, 80.0),
    ]));
    expect(groups.length, 1, reason: '跨泳道同一时刻也要合成一个点');
  });

  test('两级阈值：跨泳道 10px 不合并（防止把相隔半小时的任务并成一个点）', () {
    final groups = clusterOverlappingNodes(
      nodes([('a', 100.0, 50.0), ('b', 110.0, 80.0)]),
      thresholdPx: 12,
      crossLaneThresholdPx: 6,
    );
    expect(groups.length, 2);
  });

  test('两级阈值：同泳道 10px 合并（两个点会相碰）', () {
    final groups = clusterOverlappingNodes(
      nodes([('a', 100.0, 50.0), ('b', 110.0, 52.0)]),
      thresholdPx: 12,
      crossLaneThresholdPx: 6,
    );
    expect(groups.length, 1);
  });

  test('两级阈值：跨泳道 3px 合并（同一时刻不同优先级）', () {
    final groups = clusterOverlappingNodes(
      nodes([('a', 100.0, 50.0), ('b', 103.0, 80.0)]),
      thresholdPx: 12,
      crossLaneThresholdPx: 6,
    );
    expect(groups.length, 1);
  });

  test('三个点一簇，组内保持输入顺序、组间按 x 升序', () {
    final groups = clusterOverlappingNodes(nodes([
      ('b', 300.0, 10.0),
      ('a1', 100.0, 10.0),
      ('a2', 103.0, 11.0),
    ]));
    expect(groups.length, 2);
    expect(groups[0], ['a1', 'a2']);
    expect(groups[1], ['b']);
  });

  test('真机场景：08:40 与 09:00 相距约 10px → 合并（阈值 12）', () {
    final groups = clusterOverlappingNodes(
      nodes([('t22', 345.0, 100.0), ('t11', 355.0, 100.0)]),
      thresholdPx: 12,
    );
    expect(groups.length, 1, reason: '两个点视觉上已经相碰，应合并');
    expect(groups.single.length, 2);
  });

  test('阈值 12 下相距 30px 仍是两个点', () {
    final groups = clusterOverlappingNodes(
      nodes([('a', 100.0, 10.0), ('b', 130.0, 10.0)]),
      thresholdPx: 12,
    );
    expect(groups.length, 2);
  });

  test('U15：拖动量化到 1 分钟（不再按 5 分钟跳格）', () {
    expect(snapToMinutes(0.4), 0);
    expect(snapToMinutes(0.6), 1);
    expect(snapToMinutes(12.4), 12);
    expect(snapToMinutes(12.6), 13);
    // 旧行为对照：同样输入按 5 分钟会被吃掉
    expect(snapToMinutes(12.6, stepMinutes: 5), 15);
  });

  test('U15：负方向、零步长安全', () {
    expect(snapToMinutes(-2.4), -2);
    expect(snapToMinutes(-2.6), -3);
    expect(snapToMinutes(5.5, stepMinutes: 0), 5.5);
  });

  test('标签放置优先级：重要 < 一般 < 不重要', () {
    Task mk(String id, String priority) => Task(
          id: id,
          title: id,
          kind: TaskKind.point,
          priority: priority,
          createdAt: 0,
          updatedAt: 0,
        );
    expect(taskLabelPriorityRank(mk('a', 'important')), 0);
    expect(taskLabelPriorityRank(mk('b', 'normal')), 1);
    expect(taskLabelPriorityRank(mk('c', 'minor')), 2);
  });

  test('assignAngledNames 先放高优先级：普通任务挤不掉重要任务', () {
    Task mk(String id, String priority, int startMin) => Task(
          id: id,
          title: id,
          kind: TaskKind.point,
          priority: priority,
          startAt: startMin * 60000,
          createdAt: 0,
          updatedAt: 0,
        );
    // 22 在前 2 分钟但优先级普通；33 稍晚但重要
    final slots = assignDayNames(
      [mk('22', 'normal', 747), mk('33', 'important', 749)],
      pxPerMinute: 1.0,
      measureText: (s) => 40,
    );
    final byId = {for (final s in slots) s.taskId: s};
    expect(byId['33']!.visible, isTrue, reason: '重要任务应优先占位');
  });

  test('空输入安全', () {
    expect(clusterOverlappingNodes(const []), isEmpty);
  });
}
