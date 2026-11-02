import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/services/task_scale.dart';
import 'package:msgrepo_mobile/ui/tasks/task_schedule_view.dart';
import 'package:msgrepo_mobile/ui/tasks/views/day_view.dart';
import 'package:msgrepo_mobile/ui/tasks/views/schedule_shared.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables;

/// B14 回归：日视图「非当天日期 + 部分相交时段」任务可见性。
///
/// 现象（2026-10-21 真机）：日视图可视窗 22:30–次日 01:30，任务 R6 为当日
/// 20:00–23:00（只相交 30 分钟），图上不显示；冷启动无效；列表视图同批数据正常。
///
/// 真机 V0 证据（2026-11-02，由 Lead 提供）：R6 在列表「全部 133」中可见，
/// UI 尺度徽标为「定时」，DB 行为 id=demo-r4-6 / kind=range /
/// 2026-10-21 20:00–23:00（同日）。
/// ⇒ **「尺度被剔除」已不是 B14 成因**，本文件的 ③ 只作机制留档，⑤-c 才是复现核心。
///
/// 只读定位结论见 work/reports/B14-task4-根因定位.md，可执行链路为：
///   1. DayView 收到的列表 = _ganttTasks（task_schedule_view.dart:439-452）
///      = _filterByScales('day')（:462-468），只按派生尺度过滤，不看可视窗；
///   2. scalesForView('day') 仅放行 'timed'（task_scale.dart:95-101）；
///   3. 「与可视窗相交」只作用于 _ensureRange（:400-430，决定缓存内容）
///      与底部面板 _bottomTasks（:474-493），不决定甘特图画不画；
///   4. 【已修复 2026-11-02】_maybeSeedWindow 原先在 anchor 换日时会用
///      「anchor 当天整日」覆盖视图上报的精确窗口（build 开头无条件调用）。
///      修法是记下「最近一次真实上报所属的粒度」，同粒度上报后不再播种；
///      粒度切换后新粒度首帧仍可播种（B01 兜底保留）。
///
/// 底部标题行同时渲染「可视窗口文本 + 任务计数」（:1022-1038，日粒度格式
/// HH:mm – HH:mm），是本文件观察窗口与底部面板的唯一公开可观测面。
///
/// 注：本文件只含测试；B14 的生产修复是 task_schedule_view.dart 的 3 处小改
/// （_windowReportedGranularity 字段 + _onWindowChanged 记录 + _maybeSeedWindow 早退）。
/// ⑤-c 由「复现用例」转为**回归守卫**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final appDb = AppDatabase.instance;

  // B14 现场的可视窗：2026-10-21 22:30 → 2026-10-22 01:30（跨午夜）。
  final int winStartMs = _ms(2026, 10, 21, 22, 30);
  final int winEndMs = _ms(2026, 10, 22, 1, 30);

  /// 与 tasks_page_yearly_test 同一范式：不用 pumpAndSettle（视图有周期 Timer），
  /// 用固定拍数等真实异步 DB 读取落定。
  Future<void> settle(WidgetTester tester, [int times = 20]) async {
    for (var i = 0; i < times; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// 宽松匹配底部标题行的窗口文本：忽略空白与各类横线字形差异，
  /// 只比较「左缘时刻 + 右缘时刻」是否出现在同一个 Text 里。
  bool hasWindow(List<String> texts, String left, String right) {
    final lite = RegExp(r'[\s\u2013\u2014-]');
    return texts.any((t) {
      final c = t.replaceAll(lite, '');
      return c.contains(left) && c.contains(right);
    });
  }

  // -------------------------------------------------------------------------
  // 尺度 / 相交回归（V0 已证明 R6 尺度 = timed，本组用于防回归）
  // -------------------------------------------------------------------------
  group('① B14 现场数据：尺度与相交判定（回归）', () {
    test('同日 20:00–23:00 的 range 任务派生 timed，且与 22:30–01:30 相交 30 分钟',
        () {
      final r6 = _r6();

      // V0 真机已确认 kind=range、同日 → 尺度必为 timed
      expect(r6.kind, TaskKind.range);
      expect(deriveTaskScale(r6.startAt, r6.endAt, kind: r6.kind), 'timed');
      expect(scalesForView('day'), contains('timed'));

      // 半开区间相交判定正确（跨午夜不失效）
      expect(r6.overlaps(winStartMs, winEndMs), isTrue,
          reason: '20:00–23:00 与 22:30–01:30 非空，且窗口跨午夜');
      final occ = occurrenceOverlapping(r6, winStartMs, winEndMs);
      expect(occ, isNotNull);
      // Dart 的感叹号断言不提升局部变量类型，显式取非空局部量
      final occSpan = occ!;
      expect(occSpan.$1, r6.startAt, reason: '不做窗口裁剪，返回任务自身起点');
      expect(occSpan.$2, r6.endAt, reason: '不做窗口裁剪，返回任务自身终点');

      // 相交时长恰好 30 分钟（钉死现象描述）
      final overlapMs =
          math.min(r6.endAt!, winEndMs) - math.max(r6.startAt!, winStartMs);
      expect(overlapMs, const Duration(minutes: 30).inMilliseconds);
    });
  });

  group('② 尺度推导与「当前日期 / 非当天锚点」无关（回归）', () {
    test('同一「同日 3 小时」形状放在任何日期都派生 timed', () {
      for (final day in [
        DateTime(2026, 11, 2), // 今天
        DateTime(2026, 10, 21), // B14 的非当天锚点
        DateTime(2026, 7, 15), // 更早的非当天
      ]) {
        final t = _task(
          'x',
          startAt: _ms(day.year, day.month, day.day, 20),
          endAt: _ms(day.year, day.month, day.day, 23),
        );
        expect(
          deriveTaskScale(t.startAt, t.endAt, kind: t.kind),
          'timed',
          reason: '日期不同不应改变派生尺度',
        );
      }
    });

    test('日视图放行的尺度集合是与日期无关的常量', () {
      // scalesForView 只按 view 名查表（task_scale.dart:95-101），不读时钟。
      expect(scalesForView('day'), {'timed'});
      expect(scalesForView('month').contains('timed'), isFalse);
      expect(scalesForView('year').contains('timed'), isFalse);
      expect(scalesForView('yearly').contains('timed'), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // 机制留档：尺度剔除确实存在，但 V0 已排除它是 B14 的成因
  // -------------------------------------------------------------------------
  group('③ 机制留档（非 B14 主因）：跨多天 → daily → 被日视图尺度剔除', () {
    test('跨 3 天（10-21 → 10-24）派生 daily，日视图不放行，但相交判定仍为真', () {
      // 注意：相邻两天（10-21 → 10-22）仍派生 timed（task_scale.dart:26
      // 的 (ed - sd).abs() <= 1），必须跨 >=2 天才落到 daily。
      final span = _task(
        'SPAN3',
        startAt: _ms(2026, 10, 21, 20),
        endAt: _ms(2026, 10, 24, 20),
      );
      expect(deriveTaskScale(span.startAt, span.endAt, kind: span.kind), 'daily');
      expect(scalesForView('day').contains('daily'), isFalse,
          reason: '即 _filterByScales 会把它整条滤掉');
      // 对照：相交判定对它仍为真 → 「相交却消失」不能由相交算法解释
      expect(span.overlaps(winStartMs, winEndMs), isTrue);
    });

    test('相邻两天（10-21 → 10-22）仍是 timed（防止把反例日期选错）', () {
      final adjacent = _task(
        'ADJ',
        startAt: _ms(2026, 10, 21, 20),
        endAt: _ms(2026, 10, 22, 23),
      );
      expect(
        deriveTaskScale(adjacent.startAt, adjacent.endAt, kind: adjacent.kind),
        'timed',
        reason: '派生链第 2 条：起止同一天或相邻两天 → timed',
      );
    });
  });

  group('④ 刻画现状：point + 残留 end_at 的 model/DB 语义差异（不改语义）', () {
    test('point 任务尺度仍是 timed，但 overlaps 只按 start 单点判', () {
      final p = _task(
        'P',
        kind: TaskKind.point,
        startAt: _ms(2026, 10, 21, 20),
        endAt: _ms(2026, 10, 21, 23), // 残留 end_at（历史脏数据形态）
      );

      // 尺度：point 归一化为单个时刻 → timed → 能过日视图尺度集合
      expect(deriveTaskScale(p.startAt, p.endAt, kind: p.kind), 'timed');
      expect(scalesForView('day').contains('timed'), isTrue);

      // 相交：point 只按 start（models/task.dart:72-73），窗口不含 20:00
      expect(p.overlaps(winStartMs, winEndMs), isFalse);
      expect(occurrenceOverlapping(p, winStartMs, winEndMs), isNull);

      // 窗口一旦覆盖 20:00 就相交 —— 差异只来自窗口位置
      expect(
        p.overlaps(_ms(2026, 10, 21, 19, 30), _ms(2026, 10, 21, 21)),
        isTrue,
      );

      // 现存不对称（仅刻画，不修改）：database.dart:1184 的 SQL 只按
      // end_at > startMs 判会放行这条，再由 task_schedule_view.dart:419 的
      // occurrenceOverlapping 按 point 单点剔除。
      // V0 已证 R6 的 kind=range，故本形态不适用于 B14，仅作留档。
    });
  });

  // -------------------------------------------------------------------------
  // 渲染 / 窗口上报（V0 排除尺度后，这几条是定位主战场）
  // -------------------------------------------------------------------------
  group('⑤-a DayView 渲染与窗口上报', () {
    testWidgets('锚到非当天午夜 → 上报 22:30–01:30；R6 只有 30 分钟在视口内仍可命中',
        (tester) async {
      final key = GlobalKey<DayViewState>();
      int? reportedStart;
      int? reportedEnd;
      Task? selected;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: DayView(
              key: key,
              tasks: [
                _r6(),
                // 完全落在窗口内的对照任务（10-22 00:10–00:40）
                _task(
                  'MID',
                  startAt: _ms(2026, 10, 22, 0, 10),
                  endAt: _ms(2026, 10, 22, 0, 40),
                ),
              ],
              // 构建这一刻 selected 必为 null（只有回调才会写它），写死 null 即可。
              selectedTaskId: null,
              onTaskSelected: (t) => selected = t,
              onTaskMoved: (t, s, e) {},
              onBlankLongPress: (ms) {},
              onVisibleWindowChanged: (s, e) {
                reportedStart = s;
                reportedEnd = e;
              },
              onCenterChanged: (c) {},
            ),
          ),
        ),
      ));
      await tester.pump();

      // 非当天锚点：可视中心 2026-10-22 00:00（B14 现场）
      key.currentState!.scrollTo(DateTime(2026, 10, 22, 0, 0));
      await tester.pump();

      expect(reportedStart, isNotNull, reason: '_reportWindow 应已上报');
      // 尺寸 400 / 默认一屏 180 分钟 → 窗口恰好 22:30–01:30
      expect((reportedStart! - winStartMs).abs(), lessThanOrEqualTo(60000),
          reason: '窗口左缘应约为 2026-10-21 22:30');
      expect((reportedEnd! - winEndMs).abs(), lessThanOrEqualTo(60000),
          reason: '窗口右缘应约为 2026-10-22 01:30');
      expect(DateTime.fromMillisecondsSinceEpoch(reportedStart!).day, 21);
      expect(DateTime.fromMillisecondsSinceEpoch(reportedEnd!).day, 22,
          reason: '窗口跨午夜');

      // R6 起点 20:00 在视口左侧之外，只有 22:30–23:00 这 30 分钟落在视口内：
      // ppm = 400/180 = 2.222 px/min → x1 约 -333px、x2 约 +67px。
      // 行 0 的 y = namesH(100) + headerH(44) + laneH(34)/2 = 161（day_view.dart 常量）。
      final origin = tester.getTopLeft(find.byType(DayView));
      await tester.tapAt(origin + const Offset(30, 161));
      await tester.pump();

      expect(selected?.id, 'R6',
          reason: '部分相交任务仍在布局中且可命中 ⇒ 日视图布局/绘制没有丢弃它');
    });

    testWidgets('把窗口滚到 R6 全可见处 → 仍可命中（隔离渲染层）', (tester) async {
      final key = GlobalKey<DayViewState>();
      Task? selected;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: DayView(
              key: key,
              tasks: [_r6()],
              selectedTaskId: null,
              onTaskSelected: (t) => selected = t,
              onTaskMoved: (t, s, e) {},
              onBlankLongPress: (ms) {},
              onVisibleWindowChanged: (s, e) {},
              onCenterChanged: (c) {},
            ),
          ),
        ),
      ));
      await tester.pump();

      // 中心 21:30 → 窗口 20:00–23:00，R6 横跨整屏
      key.currentState!.scrollTo(DateTime(2026, 10, 21, 21, 30));
      await tester.pump();

      final origin = tester.getTopLeft(find.byType(DayView));
      await tester.tapAt(origin + const Offset(200, 161));
      await tester.pump();

      expect(selected?.id, 'R6', reason: 'R6 完全在窗口内时必须可命中');
    });
  });

  // -------------------------------------------------------------------------
  // 集成层：日视图收到的任务集（尺度层回归）+ 底部面板（B14 复现）
  // -------------------------------------------------------------------------
  group('⑤-b TaskScheduleView(day) 集成：日视图实际收到的任务集', () {
    testWidgets('非当天 20:00–23:00 的 range 任务会进入 DayView.tasks；跨多天任务被剔除',
        (tester) async {
      await tester.runAsync(() async {
        final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        await createBaseTables(db);
        appDb.debugAttachDatabase(db);

        await db.insert('tasks', _r6().toRow());
        await db.insert(
            'tasks',
            _task(
              'SPAN3', // 跨 3 天 → daily → 应被日视图剔除
              startAt: _ms(2026, 10, 21, 20),
              endAt: _ms(2026, 10, 24, 20),
            ).toRow());

        await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: TaskScheduleView(granularity: 3)),
        ));
        await settle(tester);

        expect(find.byType(DayView), findsOneWidget,
            reason: 'granularity=3 应挂载 DayView');
        final dayTasks = tester.widget<DayView>(find.byType(DayView)).tasks;
        final ids = dayTasks.map((t) => t.id).toSet();

        // 这条通过即证明：尺度过滤不会剔除「同日部分相交」的 R6
        //（与 V0 真机结论一致）→ B14 成因不在尺度层。
        expect(ids, contains('R6'),
            reason: 'timed 尺度应被日视图放行（task_schedule_view.dart:462-468）');
        expect(ids, isNot(contains('SPAN3')),
            reason: 'daily 尺度不在日视图放行集合内，应被剔除');

        for (final t in dayTasks) {
          expect(
            scalesForView('day')
                .contains(deriveTaskScale(t.startAt, t.endAt, kind: t.kind)),
            isTrue,
            reason: 'DayView.tasks 不应包含非 timed 尺度的任务：${t.id}',
          );
        }

        appDb.debugDetachDatabase();
        await db.close();
      });
    });
  });

  group('⑤-c 【B14 回归】底部面板窗口与任务集（保持 22:30–01:30 + R6 + 计数 2）', () {
    testWidgets('日视图窗口被滚到 22:30–01:30 时，底部面板应显示该窗口并含 R6',
        (tester) async {
      await tester.runAsync(() async {
        final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        await createBaseTables(db);
        appDb.debugAttachDatabase(db);

        // R6：10-21 20:00–23:00（与 22:30–01:30 相交 30 分钟）
        await db.insert('tasks', _r6().toRow());
        // MID：10-22 00:10–00:40（完全在窗口内）
        await db.insert(
            'tasks',
            _task(
              'MID',
              startAt: _ms(2026, 10, 22, 0, 10),
              endAt: _ms(2026, 10, 22, 0, 40),
            ).toRow());

        await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: TaskScheduleView(granularity: 3)),
        ));
        await settle(tester);

        // 把日视图窗口滚到 B14 现场：可视中心 = 2026-10-22 00:00
        final dayState = tester.state<DayViewState>(find.byType(DayView));
        dayState.scrollTo(DateTime(2026, 10, 22, 0, 0));
        await tester.pump();
        await tester.pump();

        // 收集底部标题行渲染出的全部文本（可见窗口 + 任务计数）
        final texts = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .whereType<String>()
            .toList();
        debugPrint('底部面板文本 = $texts');

        // 回归 C：面板默认展开（_barExpanded 默认 true，:132-133），
        // 列表行会渲染任务标题 —— 应能直接看到 R6。
        expect(texts, contains('R6'),
            reason: '底部面板渲染的是可视窗口内的任务行；'
                '看不到 R6 说明它又被窗口过滤掉了（B14 回归）');

        // 回归 A：标题行时间范围 = 真实可视窗口（_panelRangeLabel，日粒度）
        expect(hasWindow(texts, '22:30', '01:30'), isTrue,
            reason: '窗口上报的 22:30–01:30 必须被保留；'
                '若变成 00:00–00:00，说明 _maybeSeedWindow 又用'
                '「anchor 当天整日」覆盖了真实窗口（task_schedule_view.dart）');

        // 回归 B：底部任务数 = 2（R6 + MID 都与窗口相交）
        expect(texts, contains('2'),
            reason: 'R6 与 MID 均与 22:30–01:30 相交，底部计数应为 2；'
                '若为 1 说明 R6 被窗口过滤掉了');

        // 回归 D（B14 修复点本身）：同一粒度内再换一次 anchor 日，窗口必须继续
        // 跟真实可视范围走，不能被「anchor 当天整日」重新播种。
        // 中心 2026-10-21 12:00 → 窗 10:30–13:30（默认一屏 180 分钟）。
        dayState.scrollTo(DateTime(2026, 10, 21, 12, 0));
        await tester.pump();
        await tester.pump();
        final texts2 = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .whereType<String>()
            .toList();
        expect(hasWindow(texts2, '10:30', '13:30'), isTrue,
            reason: '同粒度换日不得重新播种：窗口应随真实可视范围变为 10:30–13:30，'
                '而不是整日推算的 00:00–00:00');

        appDb.debugDetachDatabase();
        await db.close();
      });
    });
  });
}

// ---------------------------------------------------------------------------
// 测试内 helper（与 task_scale_test / schedule_layout_test 保持同一写法）
// ---------------------------------------------------------------------------

int _ms(int year, int month, [int day = 1, int hour = 9, int minute = 0]) =>
    DateTime(year, month, day, hour, minute).millisecondsSinceEpoch;

Task _task(
  String id, {
  String title = '任务',
  String kind = TaskKind.range,
  int? startAt,
  int? endAt,
  String priority = TaskPriority.normal,
  String status = TaskStatus.active,
}) =>
    Task(
      id: id,
      title: title,
      kind: kind,
      startAt: startAt,
      endAt: endAt,
      priority: priority,
      status: status,
      createdAt: 0,
      updatedAt: 0,
    );

/// B14 现场那条任务：2026-10-21 20:00–23:00，range（与 V0 真机 DB 行一致）。
Task _r6() => _task(
      'R6',
      title: 'R6',
      startAt: _ms(2026, 10, 21, 20),
      endAt: _ms(2026, 10, 21, 23),
    );
