import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/ui/tasks/views/layout.dart';

Task _task(String id, int startMs,
        {int? endMs,
        String title = '任务',
        String? parentId,
        String priority = TaskPriority.normal}) =>
    Task(
      id: id,
      title: title,
      kind: endMs == null ? TaskKind.point : TaskKind.range,
      startAt: startMs,
      endAt: endMs,
      createdAt: 0,
      updatedAt: 0,
      parentId: parentId,
      priority: priority,
    );

int _ms(int year, int month, [int day = 1, int hour = 9, int minute = 0]) =>
    DateTime(year, month, day, hour, minute).millisecondsSinceEpoch;

void main() {
  group('layoutYearLane', () {
    test('泳道内按开始时间排序返回', () {
      final items = layoutYearLane([
        _task('b', _ms(2026, 6)),
        _task('a', _ms(2026, 2)),
        _task('c', _ms(2026, 10)),
      ], 2026);
      expect(items.map((e) => e.taskId), ['a', 'b', 'c']);
      // 互不重叠，全部占 slot 0
      expect(items.every((e) => e.slot == 0), isTrue);
    });

    test('被更早跨月线段占据的槽位跳过，继续往下排', () {
      final items = layoutYearLane([
        _task('line', _ms(2026, 1), endMs: _ms(2026, 4)), // 1-3 月线段
        _task('n1', _ms(2026, 2), endMs: _ms(2026, 3, 15)), // 2-3 月线段
        _task('n2', _ms(2026, 3)),
        _task('after', _ms(2026, 5)),
      ], 2026);
      final byId = {for (final e in items) e.taskId: e};
      expect(byId['line']!.slot, 0);
      expect(byId['n1']!.slot, 1); // slot 0 的 2 月被线段占据
      expect(byId['n2']!.slot, 2); // slot 0/1 的 3 月均被占据
      expect(byId['after']!.slot, 0); // 5 月空出，回到最上槽位
    });

    test('起点在上一年：钳制到 1 月并标记 extendsBefore', () {
      final items = layoutYearLane([
        _task('cross', _ms(2025, 11), endMs: _ms(2026, 3)),
      ], 2026);
      final e = items.single;
      expect(e.startMonth, 1);
      expect(e.endMonth, 3); // 结束于 3 月 1 日 09:00，覆盖进 3 月
      expect(e.extendsBefore, isTrue);
      expect(e.extendsAfter, isFalse);
    });

    test('终点在下一年：钳制到 12 月并标记 extendsAfter，本年不为其保留槽位', () {
      final items = layoutYearLane([
        _task('cross', _ms(2026, 10), endMs: _ms(2027, 3)),
        _task('nov', _ms(2026, 11)),
      ], 2026);
      final byId = {for (final e in items) e.taskId: e};
      expect(byId['cross']!.endMonth, 12);
      expect(byId['cross']!.extendsAfter, isTrue);
      // 11 月被本年钳制范围（10-12 月）占据，排到下一槽位
      expect(byId['nov']!.slot, 1);
      // 同一任务在 2027 年独立布局：占据最上面槽位
      final next = layoutYearLane([
        _task('cross', _ms(2026, 10), endMs: _ms(2027, 3)),
      ], 2027);
      expect(next.single.slot, 0);
      expect(next.single.extendsBefore, isTrue);
    });

    test('与本年无交集的任务不出现；时间点用起止同月节点语义', () {
      final items = layoutYearLane([
        _task('other', _ms(2025, 6)),
        _task('point', _ms(2026, 7, 15)),
      ], 2026);
      expect(items, hasLength(1));
      expect(items.single.startMonth, 7);
      expect(items.single.endMonth, 7);
    });

    test('结束恰为月初边界时归前一月', () {
      final items = layoutYearLane([
        _task('t', _ms(2026, 1, 10, 0, 0), endMs: _ms(2026, 3, 1, 0, 0)),
      ], 2026);
      expect(items.single.startMonth, 1);
      expect(items.single.endMonth, 2);
    });

    test('子任务与父任务同槽并标记 isSubtask，其他任务槽位不受影响', () {
      final items = layoutYearLane([
        _task('parent', _ms(2026, 1), endMs: _ms(2026, 6)),
        _task('sub', _ms(2026, 2), endMs: _ms(2026, 3), parentId: 'parent'),
        // 与 parent 重叠的普通任务：若无子任务逻辑本应占 slot 1
        _task('other', _ms(2026, 3), endMs: _ms(2026, 5)),
      ], 2026);
      final byId = {for (final e in items) e.taskId: e};
      expect(byId['parent']!.slot, 0);
      expect(byId['sub']!.slot, 0); // 与父同槽，不占新槽位
      expect(byId['sub']!.isSubtask, isTrue);
      expect(byId['parent']!.isSubtask, isFalse);
      expect(byId['other']!.slot, 1);
    });

    test('父任务不在本泳道时子任务按普通任务填充', () {
      final items = layoutYearLane([
        _task('blocker', _ms(2026, 2), endMs: _ms(2026, 4)),
        _task('sub', _ms(2026, 3), parentId: 'absent-parent'),
      ], 2026);
      final byId = {for (final e in items) e.taskId: e};
      expect(byId['blocker']!.slot, 0);
      expect(byId['sub']!.slot, 1); // 3 月被 blocker 占据
      expect(byId['sub']!.isSubtask, isFalse);
    });

    test('父任务与本年无交集时子任务按普通任务填充', () {
      final items = layoutYearLane([
        _task('parent', _ms(2025, 6)), // 不在 2026 年
        _task('sub', _ms(2026, 3), parentId: 'parent'),
      ], 2026);
      expect(items.single.taskId, 'sub');
      expect(items.single.slot, 0);
      expect(items.single.isSubtask, isFalse);
    });

    // 2026-10-28 分行优先级规则：同一槽位可放多个任务竞争时，
    // important（红）先放靠上、minor（绿）最后放靠下、normal 居中，
    // 优先级优先于开始时间。
    test('槽位竞争时 important 靠上、normal 居中、minor 靠下', () {
      final items = layoutYearLane([
        // 开始最早但优先级最低：最后放，被挤到最下
        _task('minor-line', _ms(2026, 1),
            endMs: _ms(2026, 4), priority: TaskPriority.minor), // 1-3 月
        _task('imp', _ms(2026, 2),
            endMs: _ms(2026, 3, 15), priority: TaskPriority.important), // 2-3 月
        _task('norm', _ms(2026, 3), priority: TaskPriority.normal), // 3 月
      ], 2026);
      final byId = {for (final e in items) e.taskId: e};
      expect(byId['imp']!.slot, 0); // 最重要：先放最上槽
      expect(byId['norm']!.slot, 1); // 3 月被 imp 占据
      expect(byId['minor-line']!.slot, 2); // 1-3 月与 imp/norm 均冲突，落最下
    });

    test('同优先级内仍按开始时间填充（跳位规则不变）', () {
      final items = layoutYearLane([
        _task('line', _ms(2026, 1),
            endMs: _ms(2026, 4), priority: TaskPriority.important),
        _task('n1', _ms(2026, 2),
            endMs: _ms(2026, 3, 15), priority: TaskPriority.important),
        _task('n2', _ms(2026, 3), priority: TaskPriority.important),
      ], 2026);
      final byId = {for (final e in items) e.taskId: e};
      expect(byId['line']!.slot, 0);
      expect(byId['n1']!.slot, 1);
      expect(byId['n2']!.slot, 2);
    });

    test('优先级只影响填充顺序，不相交时仍共享最上槽位', () {
      final items = layoutYearLane([
        _task('minor', _ms(2026, 6), priority: TaskPriority.minor),
        _task('imp', _ms(2026, 10), priority: TaskPriority.important),
      ], 2026);
      // 互不重叠：都占 slot 0
      expect(items.every((e) => e.slot == 0), isTrue);
    });
  });

  group('assignDayNames（v2.3 贪心：无比例尺阈值）', () {
    final day = DateTime(2026, 10, 12);
    int at(int hour, [int minute = 0]) =>
        DateTime(day.year, day.month, day.day, hour, minute)
            .millisecondsSinceEpoch;

    test('低缩放但互不碰撞时仍可见（贪心无阈值）', () {
      final slots = assignDayNames(
        [_task('a', at(9), title: '站会'), _task('b', at(14), title: '评审')],
        pxPerMinute: 14 / 10, // 每 10 分钟一个节点的密度（旧阈值下全隐藏）
      );
      expect(slots.every((e) => e.visible), isTrue);
    });

    test('互不碰撞时可见', () {
      final slots = assignDayNames(
        [_task('a', at(9), title: '站会'), _task('b', at(14), title: '评审')],
        pxPerMinute: 2.8,
      );
      expect(slots.every((e) => e.visible), isTrue);
      expect(slots[0].centerMinutes, 9 * 60);
      expect(slots[1].centerMinutes, 14 * 60);
    });

    test('时间点任务锚点可向后漂移（v2.4）：碰撞时推后找空位', () {
      final slots = assignDayNames(
        [
          _task('a', at(9, 0), title: '晨会'),
          _task('b', at(9, 2), title: '讨论'), // 2 分钟后，原位必然碰撞
        ],
        pxPerMinute: 2.8,
      );
      final byId = {for (final e in slots) e.taskId: e};
      expect(byId['a']!.visible, isTrue);
      expect(byId['a']!.centerMinutes, 9 * 60);
      // b 不再直接隐藏，而是向后漂移（≥7.3 分钟才能脱离 a 的斜文本带）
      expect(byId['b']!.visible, isTrue);
      expect(byId['b']!.centerMinutes, greaterThan(9 * 60 + 5));
    });

    test('时间点任务漂移步数耗尽仍碰撞则隐藏', () {
      final slots = assignDayNames(
        [
          _task('a', at(9, 0), title: '晨会'),
          _task('b', at(9, 2), title: '讨论'),
        ],
        pxPerMinute: 2.8,
        // 通过 assignAngledNames 直接控制漂移步数
      );
      final byId = {for (final e in slots) e.taskId: e};
      expect(byId['b']!.visible, isTrue); // 默认 12 步内可找到空位
      final noDrift = assignAngledNames(
        [_task('a', at(9, 0), title: '晨会'), _task('b', at(9, 2), title: '讨论')],
        axisOf: (t) {
          final d = DateTime.fromMillisecondsSinceEpoch(t.startAt!);
          final m = d.hour * 60 + d.minute.toDouble();
          return (m, m);
        },
        axisPerPx: 1 / 2.8,
        anchorStep: 5,
        pointDriftSteps: 0,
      );
      expect(noDrift[1].visible, isFalse);
    });

    test('时间段任务在范围内找靠前空位', () {
      final slots = assignDayNames(
        [
          _task('a', at(9, 0), title: '晨会'),
          // 覆盖 09:00-10:00：锚点从 09:00 起按 5 分钟步进，09:00/09:05 均被
          // 晨会的斜文本带挡住，09:10 放得下
          _task('b', at(9, 0), endMs: at(10, 0), title: ' workshops '),
        ],
        pxPerMinute: 2.8,
      );
      final b = slots.firstWhere((e) => e.taskId == 'b');
      expect(b.visible, isTrue);
      expect(b.centerMinutes, 9 * 60 + 10);
    });

    test('标题过长超出名称层高度时不显示', () {
      final slots = assignDayNames(
        [_task('a', at(9), title: '这是一个名字特别特别长的任务标题啊啊啊')],
        pxPerMinute: 2.8,
      );
      expect(slots.single.visible, isFalse);
    });
  });

  group('assignAngledNames（年度视图轴=年小数）', () {
    test('同年两个节点任务：先放下的可见，后到的漂移找空位（v2.4）', () {
      final slots = assignAngledNames(
        [_task('a', _ms(2026, 3)), _task('b', _ms(2026, 4))],
        axisOf: (t) {
          final d = DateTime.fromMillisecondsSinceEpoch(t.startAt!);
          final y = d.year +
              (t.startAt! - DateTime(d.year).millisecondsSinceEpoch) /
                  (DateTime(d.year + 1).millisecondsSinceEpoch -
                      DateTime(d.year).millisecondsSinceEpoch);
          return (y, y);
        },
        axisPerPx: 1 / 100, // 每年 100px
        anchorStep: 1 / 12,
      );
      expect(slots[0].visible, isTrue);
      // v2.4：时间点任务允许向后漂移找空位，b 可见且锚点被推后
      expect(slots[1].visible, isTrue);
      expect(slots[1].centerMinutes, greaterThan(slots[0].centerMinutes));
    });

    test('漂移步数耗尽仍碰撞则隐藏（pointDriftSteps=0 退化为固定锚点）', () {
      final slots = assignAngledNames(
        [_task('a', _ms(2026, 3)), _task('b', _ms(2026, 4))],
        axisOf: (t) {
          final d = DateTime.fromMillisecondsSinceEpoch(t.startAt!);
          return (d.year + (d.month - 1) / 12, d.year + (d.month - 1) / 12);
        },
        axisPerPx: 1 / 100,
        anchorStep: 1 / 12,
        pointDriftSteps: 0,
      );
      expect(slots[0].visible, isTrue);
      expect(slots[1].visible, isFalse);
    });

    test('相距足够远的年份都可见', () {
      final slots = assignAngledNames(
        [_task('a', _ms(2026, 3), title: '甲'), _task('b', _ms(2030, 3), title: '乙')],
        axisOf: (t) {
          final d = DateTime.fromMillisecondsSinceEpoch(t.startAt!);
          return (d.year.toDouble(), d.year.toDouble());
        },
        axisPerPx: 1 / 100,
        anchorStep: 1 / 12,
      );
      expect(slots.every((e) => e.visible), isTrue);
    });

    test('缩放变密（每年 px 变小）时碰撞增多、可见名减少', () {
      final tasks = [
        _task('a', _ms(2026, 1), title: '任务甲'),
        _task('b', _ms(2026, 4), title: '任务乙'),
        _task('c', _ms(2026, 7), title: '任务丙'),
      ];
      double yearOf(Task t) =>
          DateTime.fromMillisecondsSinceEpoch(t.startAt!).year.toDouble() +
          (DateTime.fromMillisecondsSinceEpoch(t.startAt!).month - 1) / 12;
      final dense = assignAngledNames(tasks,
          axisOf: (t) => (yearOf(t), yearOf(t)),
          axisPerPx: 1 / 100,
          anchorStep: 1 / 12);
      final sparse = assignAngledNames(tasks,
          axisOf: (t) => (yearOf(t), yearOf(t)),
          axisPerPx: 1 / 20,
          anchorStep: 1 / 12);
      final denseVisible = dense.where((e) => e.visible).length;
      final sparseVisible = sparse.where((e) => e.visible).length;
      expect(sparseVisible, lessThan(denseVisible));
    });
  });

  group('无限滚动索引映射（v2.3）', () {
    test('itemIndex ↔ 单位序号往返一致（含负序号）', () {
      for (final u in [-10000, -5, 0, 7, 99999]) {
        expect(unitIndexForItem(itemIndexForUnit(u)), u);
      }
    });

    test('基准单位落在大初始偏移处', () {
      expect(itemIndexForUnit(0), infiniteScrollOffset);
      expect(unitIndexForItem(infiniteScrollOffset), 0);
    });
  });

  group('dayTickInterval', () {
    test('最大缩放（每 5 分钟 48dp）：主刻度 15 分钟 + 5 分钟次刻度', () {
      final (major, minor, stride) = dayTickInterval(48 / 5);
      // 5*9.6=48 <64，15*9.6=144 ≥64
      expect(major, 15);
      expect(minor, 5);
      expect(stride, 1);
    });

    test('中等缩放：选「间距 ≥64dp」的最密档', () {
      // 15*2.8=42 <64，30*2.8=84 ≥64
      final (major, minor, stride) = dayTickInterval(2.8);
      expect(major, 30);
      expect(minor, 15);
      expect(stride, 1);
    });

    test('24h 恰好一屏：主刻度 120 分钟，标注隔一个显示', () {
      const ppm = 390 / 1440; // 120*ppm≈32.5 <64
      final (major, minor, stride) = dayTickInterval(ppm);
      expect(major, 120);
      expect(minor, 60);
      expect(stride, 2); // 2 的幂：32.5*2=65 ≥64
    });

    test('比例尺极小时次刻度省略、标注按 2 的幂继续隔档', () {
      final (major, minor, stride) = dayTickInterval(0.05);
      expect(major, 120);
      expect(minor, isNull); // 60*0.05=3 <6
      expect(stride, 16); // 120*0.05*16=96 ≥64
    });
  });

  group('yearTickInterval', () {
    test('最大缩放（每年 320px）：主刻度 1 年', () {
      final (major, minor, stride) = yearTickInterval(320);
      expect(major, 1);
      expect(minor, isNull); // 1 年已是最密档
      expect(stride, 1);
    });

    test('中等缩放（每年 20px）：主刻度 5 年 + 1 年次刻度', () {
      // 1*20=20 <64，5*20=100 ≥64
      final (major, minor, stride) = yearTickInterval(20);
      expect(major, 5);
      expect(minor, 1);
      expect(stride, 1);
    });

    test('每年 8px：主刻度 10 年，标注隔一个显示', () {
      // 5*8=40 <64 → 主刻度 10 年；10*8=80 ≥64
      final (major, minor, stride) = yearTickInterval(8);
      expect(major, 10);
      expect(minor, 5);
      expect(stride, 1);
    });

    test('比例尺极小时次刻度省略、标注按 2 的幂隔档', () {
      final (major, minor, stride) = yearTickInterval(0.5);
      expect(major, 10);
      expect(minor, isNull); // 5*0.5=2.5 <6
      expect(stride, 16); // 10*0.5*16=80 ≥64
    });
  });
}
