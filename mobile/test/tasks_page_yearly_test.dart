import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/ui/tasks/task_list_view.dart';
import 'package:msgrepo_mobile/ui/tasks/task_schedule_view.dart';
import 'package:msgrepo_mobile/ui/tasks/tasks_page.dart';
import 'package:msgrepo_mobile/ui/tasks/views/year_view.dart';
import 'package:msgrepo_mobile/ui/tasks/views/yearly_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables;

/// 任务页视图切换「列表/日/月/年/年度」五档回归（v3 收尾）：
/// 「年度」档 = TaskScheduleView(granularity: 0) 的 YearlyView，
/// 甘特视图懒构建（首次切到才创建）。
/// ui-structure §6.2 收编回归：整屏唯一 AppBar（标题「任务」）由
/// TasksPage 持有，「现在」按视图分显隐（仅甘特模式）。
/// 导航结构调整：切换器改为与库页一致的 AppBar.bottom TabBar。
///
/// 在 tester.runAsync 真异步区里跑：FakeAsync 区会让 sqflite_ffi 的
/// DB 调用挂死（与 anchor_navigation_test 同一范式）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final appDb = AppDatabase.instance;

  Future<void> settle(WidgetTester tester, [int times = 10]) async {
    for (var i = 0; i < times; i++) {
      await Future.delayed(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pump();
  }

  /// 任务页顶部切换器（AppBar.bottom 的 TabBar，5 档）。
  Finder tasksPageSwitcher() => find.byWidgetPredicate(
      (w) => w is TabBar && w.tabs.length == 5);

  Finder switcherLabel(String label) =>
      find.descendant(of: tasksPageSwitcher(), matching: find.text(label));

  testWidgets('切换器含「年度」档，切到后懒构建挂载 YearlyView', (tester) async {
    await tester.runAsync(() async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await createBaseTables(db);
      appDb.debugAttachDatabase(db);

      await tester.pumpWidget(const MaterialApp(home: TasksPage()));
      await settle(tester);

      for (final label in ['列表', '日', '月', '年', '年度']) {
        expect(switcherLabel(label), findsOneWidget);
      }
      expect(find.byType(TaskListView), findsOneWidget);
      expect(find.byType(YearlyView), findsNothing, reason: '甘特懒构建');

      // ui-structure §3/§6.2：整屏唯一 AppBar，标题「任务」；
      // 列表模式不显示「现在」（仅甘特模式的 action）。
      expect(find.byType(AppBar), findsOneWidget);
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('任务')),
        findsOneWidget,
      );
      expect(find.text('待办'), findsNothing, reason: '内层 AppBar 已收编');
      expect(find.text('现在'), findsNothing, reason: '列表模式无「现在」');

      // 切到「年度」：granularity 0 → YearlyView；「现在」出现
      await tester.tap(switcherLabel('年度'));
      await settle(tester);
      expect(find.byType(TaskScheduleView), findsOneWidget);
      expect(find.byType(YearlyView), findsOneWidget);
      expect(find.text('现在'), findsOneWidget, reason: '甘特模式显示「现在」');
      final schedule = tester.widget<TaskScheduleView>(
          find.byType(TaskScheduleView));
      expect(schedule.granularity, 0);

      // 切回「年」：同一宿主换粒度 → YearView
      await tester.tap(switcherLabel('年'));
      // 粒度切换有 AnimatedSwitcher 淡出淡入（220ms）：旧视图过渡期间
      // 仍挂载，多 pump 几拍等动画完成再断言卸载
      await settle(tester, 40);
      expect(find.byType(YearView), findsOneWidget);
      expect(find.byType(YearlyView), findsNothing);
      expect(find.byType(AppBar), findsOneWidget, reason: '换视图后仍唯一 AppBar');

      // 切回「列表」：「现在」随视图隐藏
      await tester.tap(switcherLabel('列表'));
      await settle(tester);
      expect(find.text('现在'), findsNothing);

      appDb.debugDetachDatabase();
      await db.close();
    });
  });
}
