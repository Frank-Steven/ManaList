import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/ui/tasks/views/yearly_view.dart';
import 'package:msgrepo_mobile/ui/tasks/views/day_view.dart';

/// v2.5 回归：fling 惯性滚动在第一次甩动后必须持续有效。
/// 根因：fling 动画用 SingleTickerProviderStateMixin 反复新建
/// AnimationController，第二次 createTicker 触发断言（debug 下抛异常，
/// fling 静默失效）。修复为 TickerProviderStateMixin + 帧末回收。
void main() {
  Widget yearly() => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: YearlyView(
              tasks: const [],
              selectedTaskId: null,
              onTaskSelected: (_) {},
              onTaskMoved: (_, __, ___) {},
              onYearTap: (_) {},
              onVisibleWindowChanged: (_, __) {},
              onCenterChanged: (_) {},
            ),
          ),
        ),
      );

  Widget day() => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: DayView(
              tasks: const [],
              selectedTaskId: null,
              onTaskSelected: (_) {},
              onTaskMoved: (_, __, ___) {},
              onBlankLongPress: (_) {},
              onVisibleWindowChanged: (_, __) {},
              onCenterChanged: (_) {},
            ),
          ),
        ),
      );

  testWidgets('年度视图连续两次 fling 均有惯性（无断言异常）', (tester) async {
    await tester.pumpWidget(yearly());
    await tester.pump();
    final target = find.byType(YearlyView);

    await tester.fling(target, const Offset(-300, 0), 1200);
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);

    // 第二次 fling：修复前在此处抛 SingleTickerProviderStateMixin 断言
    await tester.fling(target, const Offset(-300, 0), 1200);
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);

    // 动画自然衰减结束也不应再有异常
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('日视图连续两次 fling 均有惯性（无断言异常）', (tester) async {
    await tester.pumpWidget(day());
    await tester.pump();
    final target = find.byType(DayView);

    await tester.fling(target, const Offset(-300, 0), 1200);
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);

    await tester.fling(target, const Offset(300, 0), 1200);
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  // ---- v2.6.1：fling 进行中点「现在」必须先停动画再定位 ----

  testWidgets('年度视图 fling 进行中 scrollToNow：动画取消、定位当前年不漂移',
      (tester) async {
    final key = GlobalKey<YearlyViewState>();
    final centers = <DateTime>[];
    final windows = <(int, int)>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: YearlyView(
            key: key,
            tasks: const [],
            selectedTaskId: null,
            onTaskSelected: (_) {},
            onTaskMoved: (_, __, ___) {},
            onYearTap: (_) {},
            onVisibleWindowChanged: (a, b) => windows.add((a, b)),
            onCenterChanged: centers.add,
          ),
        ),
      ),
    ));
    await tester.pump();

    // 强 fling 让惯性持续足够久
    await tester.fling(find.byType(YearlyView), const Offset(-500, 0), 2500);
    await tester.pump(const Duration(milliseconds: 100)); // fling 进行中

    key.currentState!.scrollToNow();
    await tester.pump(const Duration(milliseconds: 50));
    expect(windows, isNotEmpty);
    final w1 = windows.last;

    // 若 fling 未取消，后续帧会继续改写滚动位置
    await tester.pump(const Duration(seconds: 2));
    expect(windows.last, w1, reason: 'scrollToNow 后位置仍在漂移（fling 未取消）');
    expect(centers.last.year, DateTime.now().year);

    await tester.pump(const Duration(seconds: 2)); // 排空脉冲计时器
    expect(tester.takeException(), isNull);
  });

  testWidgets('日视图 fling 进行中 scrollToNow：动画取消、定位当前时刻不漂移',
      (tester) async {
    final key = GlobalKey<DayViewState>();
    final centers = <DateTime>[];
    final windows = <(int, int)>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: DayView(
            key: key,
            tasks: const [],
            selectedTaskId: null,
            onTaskSelected: (_) {},
            onTaskMoved: (_, __, ___) {},
            onBlankLongPress: (_) {},
            onVisibleWindowChanged: (a, b) => windows.add((a, b)),
            onCenterChanged: centers.add,
          ),
        ),
      ),
    ));
    await tester.pump();

    await tester.fling(find.byType(DayView), const Offset(-500, 0), 2500);
    await tester.pump(const Duration(milliseconds: 100)); // fling 进行中

    key.currentState!.scrollToNow();
    await tester.pump(const Duration(milliseconds: 50));
    expect(windows, isNotEmpty);
    final w1 = windows.last;

    await tester.pump(const Duration(seconds: 2));
    expect(windows.last, w1, reason: 'scrollToNow 后位置仍在漂移（fling 未取消）');
    // 中心 = 当前时刻（分钟级容差）
    expect((centers.last.difference(DateTime.now()).inMinutes).abs(),
        lessThanOrEqualTo(1));

    await tester.pump(const Duration(seconds: 2)); // 排空脉冲计时器
    expect(tester.takeException(), isNull);
  });

  // ---- v2.6.1：拖动/惯性过程中标题（可视中心）实时跟随 ----

  testWidgets('年度视图拖动过程中可视中心上报跟随（不等手势结束）', (tester) async {
    final centers = <DateTime>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: YearlyView(
            tasks: const [],
            selectedTaskId: null,
            onTaskSelected: (_) {},
            onTaskMoved: (_, __, ___) {},
            onYearTap: (_) {},
            onVisibleWindowChanged: (_, __) {},
            onCenterChanged: centers.add,
          ),
        ),
      ),
    ));
    await tester.pump();
    final before = centers.length;

    // 慢拖（不产生 fling）：修复前全程不上报、手势结束低速也不上报
    await tester.drag(find.byType(YearlyView), const Offset(-300, 0));
    await tester.pump();
    expect(centers.length, greaterThan(before), reason: '拖动中应实时上报可视中心');
    expect(tester.takeException(), isNull);
  });

  testWidgets('日视图慢拖（低速不触发惯性）后标题窗口仍更新', (tester) async {
    final windows = <(int, int)>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: DayView(
            tasks: const [],
            selectedTaskId: null,
            onTaskSelected: (_) {},
            onTaskMoved: (_, __, ___) {},
            onBlankLongPress: (_) {},
            onVisibleWindowChanged: (a, b) => windows.add((a, b)),
            onCenterChanged: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(windows, isNotEmpty);
    final w0 = windows.last;

    // 慢拖半天宽（12h）：结束速度低于 120px/s 阈值，不触发 fling
    await tester.drag(find.byType(DayView), const Offset(-200, 0),
        touchSlopY: 0);
    await tester.pump(const Duration(milliseconds: 300));
    expect(windows.last, isNot(w0), reason: '慢拖后可视窗口应已更新');
    expect(tester.takeException(), isNull);
  });
}
