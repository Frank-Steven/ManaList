import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/services/task_scale.dart';

DateTime _d(int year, int month, int day, [int hour = 9]) =>
    DateTime(year, month, day, hour);

void main() {
  group('deriveTimeScale', () {
    test('无开始时间 → 不定时', () {
      expect(deriveTimeScale(null, null), 'untimed');
      expect(deriveTimeScale(null, _d(2026, 10, 13)), 'untimed');
    });

    test('同一天 → 定时（含 end=null 的点任务）', () {
      expect(deriveTimeScale(_d(2026, 10, 13), null), 'timed');
      expect(
          deriveTimeScale(_d(2026, 10, 13, 9), _d(2026, 10, 13, 18)), 'timed');
    });

    test('相邻两天 → 定时', () {
      // 周六 → 周日（跨周也先命中"相邻两天"）
      expect(deriveTimeScale(_d(2026, 10, 17), _d(2026, 10, 18)), 'timed');
    });

    test('跨 3 天但在同一自然周 → 整日', () {
      // 周二 → 周五，同在 10-11（周日）起的一周
      expect(deriveTimeScale(_d(2026, 10, 13), _d(2026, 10, 16)), 'daily');
    });

    test('跨相邻两周 → 整日', () {
      // 周五（10-11 周）→ 下周一（10-18 周）
      expect(deriveTimeScale(_d(2026, 10, 16), _d(2026, 10, 19)), 'daily');
    });

    test('跨不相邻两周但同月 → 整周', () {
      // 10-01（9-27 周）→ 10-16（10-11 周），周序号差 2
      expect(deriveTimeScale(_d(2026, 10, 1), _d(2026, 10, 16)), 'weekly');
    });

    test('跨相邻两月 → 整周', () {
      // 10-05（10-04 周）→ 11-01（11-01 周），周不相邻、月相邻
      expect(deriveTimeScale(_d(2026, 10, 5), _d(2026, 11, 1)), 'weekly');
    });

    test('跨不相邻两月但同季度 → 月度', () {
      // 10-01 → 12-31，同在 Q4
      expect(deriveTimeScale(_d(2026, 10, 1), _d(2026, 12, 31)), 'monthly');
    });

    test('跨相邻两季度 → 月度', () {
      // Q4 2026 → Q1 2027，季度序号相邻
      expect(deriveTimeScale(_d(2026, 11, 15), _d(2027, 2, 15)), 'monthly');
    });

    test('跨不相邻两季度但同年 → 季度', () {
      // Q1 → Q4，季度序号差 3
      expect(deriveTimeScale(_d(2026, 2, 1), _d(2026, 10, 1)), 'quarterly');
    });

    test('跨相邻两年 → 季度', () {
      expect(deriveTimeScale(_d(2026, 6, 1), _d(2027, 6, 1)), 'quarterly');
    });

    test('跨多年 → 年度', () {
      expect(deriveTimeScale(_d(2026, 1, 1), _d(2029, 1, 1)), 'yearly');
      expect(deriveTimeScale(_d(2026, 12, 31), _d(2028, 1, 1)), 'yearly');
    });
  });

  group('timeScaleLabel', () {
    test('七级中文名', () {
      expect(timeScaleLabel('yearly'), '年度');
      expect(timeScaleLabel('quarterly'), '季度');
      expect(timeScaleLabel('monthly'), '月度');
      expect(timeScaleLabel('weekly'), '整周');
      expect(timeScaleLabel('daily'), '整日');
      expect(timeScaleLabel('timed'), '定时');
      expect(timeScaleLabel('untimed'), '不定时');
      expect(timeScaleLabel('其他'), '不定时'); // 兜底
    });
  });

  group('deriveTaskScale', () {
    test('毫秒时间戳包装与 deriveTimeScale 一致', () {
      expect(
        deriveTaskScale(
            _d(2026, 1, 1).millisecondsSinceEpoch, null),
        deriveTimeScale(_d(2026, 1, 1), null),
      );
      expect(
        deriveTaskScale(_d(2026, 1, 1).millisecondsSinceEpoch,
            _d(2029, 1, 1).millisecondsSinceEpoch),
        'yearly',
      );
      expect(deriveTaskScale(null, null), 'untimed');
    });
  });

  group('timeScaleRank', () {
    test('从大到小单调，不定时最小', () {
      const order = [
        'yearly',
        'quarterly',
        'monthly',
        'weekly',
        'daily',
        'timed',
      ];
      for (var i = 0; i < order.length - 1; i++) {
        expect(timeScaleRank(order[i]),
            greaterThan(timeScaleRank(order[i + 1])));
      }
      expect(timeScaleRank('timed'), greaterThan(timeScaleRank('untimed')));
      expect(timeScaleRank('未知'), -1);
    });
  });

  group('scalesForView', () {
    test('四个视图按尺度过滤表（设计 §2）', () {
      expect(scalesForView('yearly'), {'yearly'});
      expect(scalesForView('year'), {'quarterly', 'monthly', 'weekly'});
      expect(scalesForView('month'), {'weekly', 'daily'});
      expect(scalesForView('day'), {'timed'});
      expect(scalesForView('其他'), isEmpty);
    });
  });

  group('P1-1：point 任务即使带 endAt 也只按点派生', () {
    test('同日 → timed（与不带 kind 的旧行为一致）', () {
      expect(
          deriveTimeScale(_d(2026, 10, 13, 9), _d(2026, 10, 13, 18),
              kind: TaskKind.point),
          'timed');
    });

    test('跨周 → 仍为 timed（修复前误判 daily）', () {
      final s = _d(2026, 10, 13);
      final e = _d(2026, 10, 20, 9);
      expect(deriveTimeScale(s, e), 'daily', reason: '不传 kind 时保持旧行为');
      expect(deriveTimeScale(s, e, kind: TaskKind.point), 'timed');
    });

    test('跨月 → 仍为 timed（修复前误判 weekly）', () {
      final s = _d(2026, 10, 5);
      final e = _d(2026, 11, 20);
      expect(deriveTimeScale(s, e), 'weekly', reason: '不传 kind 时保持旧行为');
      expect(deriveTimeScale(s, e, kind: TaskKind.point), 'timed');
    });

    test('range 任务不受影响', () {
      expect(
          deriveTimeScale(_d(2026, 10, 13), _d(2026, 11, 20),
              kind: TaskKind.range),
          'weekly');
    });

    test('deriveTaskScale 同样归一化（毫秒时间戳入口）', () {
      final s = _d(2026, 10, 13).millisecondsSinceEpoch;
      final e = _d(2026, 12, 30).millisecondsSinceEpoch;
      expect(deriveTaskScale(s, e), 'monthly');
      expect(deriveTaskScale(s, e, kind: TaskKind.point), 'timed');
    });
  });

}
