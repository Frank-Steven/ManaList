import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/ui/tasks/views/month_view.dart';

/// v2.5 回归：月视图 index↔月份换算全链路，永不出负数年份。
/// 根因：v2.4 可变行高改造混用了两套坐标系——itemBuilder 按索引空间
/// `i - infiniteScrollOffset` 映射，而 initialScrollOffset/jumpTo 用像素
/// 累计偏移，首屏即落在公元前 8 万年。修复为恒定 itemExtent + 索引空间。
void main() {
  group('rowsOfMonth 网格覆盖', () {
    test('2000-2030 全部月份：4~6 行、恰好覆盖当月、无整行灰格', () {
      for (var y = 2000; y <= 2030; y++) {
        for (var m = 1; m <= 12; m++) {
          final rows = MonthViewState.rowsOfMonth(y, m);
          expect(rows, inInclusiveRange(4, 6), reason: '$y-$m 行数越界');
          final first = DateTime(y, m);
          final startD = first.weekday % 7;
          final days = DateUtils.getDaysInMonth(y, m);
          // 网格恰好容纳 startD 前导格 + 当月天数，且少一行装不下
          expect(startD + days, lessThanOrEqualTo(rows * 7),
              reason: '$y-$m 网格装不下当月');
          expect(startD + days, greaterThan((rows - 1) * 7),
              reason: '$y-$m 存在整行灰格');
        }
      }
    });
  });

  Widget app(GlobalKey<MonthViewState> key) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: MonthView(
              key: key,
              tasks: const [],
              selectedTaskId: null,
              onTaskSelected: (_) {},
              onDayTap: (_) {},
              onTaskMoved: (_, __, ___) {},
              onBlankLongPress: (_) {},
              onVisibleWindowChanged: (_, __) {},
              onCenterChanged: (_) {},
            ),
          ),
        ),
      );

  /// 扫描当前渲染树里所有「年 月」标签的年份。
  List<int> renderedYears(WidgetTester tester) {
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .toList();
    final years = <int>[];
    final re = RegExp(r'^(-?\d+) 年 (\d+) 月$');
    for (final s in texts) {
      final m = re.firstMatch(s);
      if (m != null) years.add(int.parse(m.group(1)!));
    }
    return years;
  }

  testWidgets('首屏落在当前月，无负数年份', (tester) async {
    final key = GlobalKey<MonthViewState>();
    await tester.pumpWidget(app(key));
    await tester.pump();
    final now = DateTime.now();
    expect(find.text('${now.year} 年 ${now.month} 月'), findsOneWidget);
    for (final y in renderedYears(tester)) {
      expect(y, greaterThanOrEqualTo(1900));
    }
    expect(tester.takeException(), isNull);
  });

  /// 2026-10-28：月视图初始位置 = 今天所在周（不再停在月开始位置），
  /// 首帧即与「现在」定位同一偏移。
  testWidgets('初始定位：今天所在周行垂直居中（不点「现在」）', (tester) async {
    final key = GlobalKey<MonthViewState>();
    await tester.pumpWidget(app(key));
    await tester.pump();

    // 与 month_view 同一套公式复核偏移（同 scrollToNow 用例）
    const itemExtent = 24.0 + 20.0 + 6 * 56.0;
    const infiniteScrollOffset = 1 << 20;
    final now = DateTime.now();
    final monthIndex = (now.year - 2000) * 12 + now.month - 1;
    final itemTop = (monthIndex + infiniteScrollOffset) * itemExtent;
    final startD = DateTime(now.year, now.month, 1).weekday % 7;
    final row = (startD + now.day - 1) ~/ 7;
    final cellCenter = 24.0 + 20.0 + row * 56.0 + 28.0;
    final dim = tester.getSize(find.byType(ListView)).height;
    final expected = itemTop + cellCenter - dim / 2;

    final controller = tester.widget<ListView>(find.byType(ListView)).controller!;
    expect(controller.offset, moreOrLessEquals(expected, epsilon: 1.0),
        reason: '首帧即应定位到今天所在周');
    expect(tester.takeException(), isNull);
  });

  testWidgets('快速连续滑动后所有可见标签年份正常（无负数年份）', (tester) async {
    final key = GlobalKey<MonthViewState>();
    await tester.pumpWidget(app(key));
    await tester.pump();
    final list = find.byType(ListView);

    // 向下（未来）快速连滑
    for (var i = 0; i < 5; i++) {
      await tester.fling(list, const Offset(0, -600), 8000);
      await tester.pump(const Duration(milliseconds: 400));
    }
    // 向上（过去）快速连滑
    for (var i = 0; i < 8; i++) {
      await tester.fling(list, const Offset(0, 600), 8000);
      await tester.pump(const Duration(milliseconds: 400));
    }
    await tester.pump(const Duration(seconds: 2));

    final years = renderedYears(tester);
    expect(years, isNotEmpty);
    for (final y in years) {
      expect(y, inInclusiveRange(1900, 2200), reason: '出现越界年份 $y');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrollTo 极端月份（基准月/远端）定位正确', (tester) async {
    final key = GlobalKey<MonthViewState>();
    await tester.pumpWidget(app(key));
    await tester.pump();

    key.currentState!.scrollTo(DateTime(2000, 1, 15)); // unit 0 边界
    await tester.pump();
    expect(find.text('2000 年 1 月'), findsOneWidget);

    key.currentState!.scrollTo(DateTime(2200, 12, 15));
    await tester.pump();
    expect(find.text('2200 年 12 月'), findsOneWidget);

    key.currentState!.scrollToNow();
    await tester.pump();
    final now = DateTime.now();
    expect(find.text('${now.year} 年 ${now.month} 月'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrollToTask 定位到任务所在月', (tester) async {
    final key = GlobalKey<MonthViewState>();
    await tester.pumpWidget(app(key));
    await tester.pump();
    final t = Task(
      id: 't1',
      title: '边界任务',
      kind: TaskKind.point,
      startAt: DateTime(2031, 6, 10).millisecondsSinceEpoch,
      priority: TaskPriority.normal,
      status: TaskStatus.active,
      createdAt: 0,
      updatedAt: 0,
    );
    key.currentState!.scrollToTask(t);
    await tester.pump();
    expect(find.text('2031 年 6 月'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('「现在」定位加深：今天所在周行在可视区垂直居中', (tester) async {
    final key = GlobalKey<MonthViewState>();
    await tester.pumpWidget(app(key));
    await tester.pump();

    key.currentState!.scrollToNow();
    await tester.pump();

    // 与 month_view 同一套公式复核偏移：item 索引空间 × itemExtent(380)
    // + 标签 24 + 头部 20 + 行 × 56 + 半格，减去半个视口。
    const itemExtent = 24.0 + 20.0 + 6 * 56.0;
    const infiniteScrollOffset = 1 << 20;
    final now = DateTime.now();
    final monthIndex = (now.year - 2000) * 12 + now.month - 1;
    final itemTop = (monthIndex + infiniteScrollOffset) * itemExtent;
    final startD = DateTime(now.year, now.month, 1).weekday % 7;
    final row = (startD + now.day - 1) ~/ 7;
    final cellCenter = 24.0 + 20.0 + row * 56.0 + 28.0;
    final dim = tester.getSize(find.byType(ListView)).height;
    final expected = itemTop + cellCenter - dim / 2;

    final controller = tester.widget<ListView>(find.byType(ListView)).controller!;
    expect(controller.offset, moreOrLessEquals(expected, epsilon: 1.0),
        reason: '今天所在周行应垂直居中');
    expect(tester.takeException(), isNull);
  });
}
