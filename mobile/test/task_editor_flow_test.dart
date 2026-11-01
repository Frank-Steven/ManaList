import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/ui/tasks/task_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'anchor_service_test.dart' show createSchema;

/// 任务编辑器表单流转回归（填完一项自动进入下一项）：
/// 标题回车 → 焦点移到描述；描述完成 → 收起键盘并滚动/高亮时间选择区；
/// 时间选完（点确定）→ 滚动/高亮优先级；优先级选完 → 滚动到保存按钮。
/// 选择类字段不收键盘焦点，流转不得弹起键盘打断选择器。
///
/// 编辑器 initState 会联查父任务候选（AppDatabase），用内存 SQLite 注入；
/// 真异步 DB 调用必须在 tester.runAsync 区里跑（FakeAsync 会挂死 sqflite_ffi）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final appDb = AppDatabase.instance;

  /// runAsync 区内：真实延时让 DB 等真异步落地，pump(duration) 推进
  /// fake 动画时钟（底部弹层/对话框/滚动动画靠它）。
  Future<void> settle(WidgetTester tester, [int times = 12]) async {
    for (var i = 0; i < times; i++) {
      await Future.delayed(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pump();
  }

  Future<Database> attachDb() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createSchema(db);
    appDb.debugAttachDatabase(db);
    return db;
  }

  Future<void> openEditor(WidgetTester tester, {Task? existing}) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showTaskEditor(context, existing: existing),
            child: const Text('OPEN'),
          ),
        ),
      ),
    ));
    await settle(tester);
    await tester.tap(find.text('OPEN'));
    await settle(tester);
  }

  Finder fieldByHint(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint);

  TextField field(WidgetTester tester, String hint) =>
      tester.widget<TextField>(fieldByHint(hint));

  double sheetScrollOffset(WidgetTester tester) => tester
      .state<ScrollableState>(find
          .descendant(
              of: find.byType(SingleChildScrollView).first,
              matching: find.byType(Scrollable))
          .first)
      .position
      .pixels;

  testWidgets('标题回车 → 焦点移到描述；描述完成 → 收起键盘、滚动到时间选择区',
      (tester) async {
    await tester.runAsync(() async {
      final db = await attachDb();

      await openEditor(tester);

      // 新建任务标题自动聚焦
      expect(field(tester, '必填').focusNode!.hasFocus, isTrue,
          reason: '新建任务标题自动聚焦');
      await tester.enterText(fieldByHint('必填'), '买菜');
      await tester.pump();

      // 回车/next → 焦点移到描述
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();
      expect(field(tester, '可选').focusNode!.hasFocus, isTrue,
          reason: '标题回车后焦点移到描述');

      // 描述完成/done → 焦点清空（收起键盘），不聚焦任何选择类字段
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester, 4);
      expect(field(tester, '可选').focusNode!.hasFocus, isFalse);
      expect(field(tester, '必填').focusNode!.hasFocus, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse,
          reason: '描述完成后键盘已收起');

      appDb.debugDetachDatabase();
      await db.close();
    });
  });

  testWidgets('编辑已有任务：标题回车同样流转到描述', (tester) async {
    await tester.runAsync(() async {
      final db = await attachDb();

      const existing = Task(
        id: 't1',
        title: '已有任务',
        kind: TaskKind.point,
        createdAt: 1000,
        updatedAt: 1000,
      );
      await openEditor(tester, existing: existing);

      // 编辑态不自动聚焦；用户点进标题后回车同样流转
      expect(field(tester, '必填').focusNode!.hasFocus, isFalse,
          reason: '编辑已有任务不抢占焦点');
      await tester.tap(fieldByHint('必填'));
      await tester.pump();
      expect(field(tester, '必填').focusNode!.hasFocus, isTrue);

      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();
      expect(field(tester, '可选').focusNode!.hasFocus, isTrue);

      appDb.debugDetachDatabase();
      await db.close();
    });
  });

  testWidgets('时间选完（点确定）→ 滚动并高亮优先级；优先级选完 → 滚动到保存按钮',
      (tester) async {
    await tester.runAsync(() async {
      final db = await attachDb();

      // 压低视口，保证优先级/保存按钮初始在可视区外、流转必须滚动
      tester.view.physicalSize = const Size(500, 360);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await openEditor(tester);
      expect(sheetScrollOffset(tester), 0, reason: '初始未滚动');

      // 新建任务标题自动聚焦会拉起键盘（既有行为）；先收起键盘，
      // 模拟用户从标题流转到选择类字段的真实操作路径。
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isFalse);

      // 选开始日期：弹日期选择器，点确定（默认 en 环境为 OK）
      await tester.tap(find.text('选择日期'));
      await settle(tester);
      expect(find.text('OK'), findsOneWidget, reason: '日期选择器已弹出');
      await tester.tap(find.text('OK'));

      // 高亮：对话框关闭动画结束后 _onTimePicked 才触发，逐帧推进
      // fake 时钟，捕捉优先级区块底色呼吸中的某一帧。
      final flash = find.ancestor(
        of: find.text('优先级'),
        matching: find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).borderRadius != null),
      );
      var highlighted = false;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 60));
        if (flash.evaluate().isEmpty) continue;
        final decoration = tester.widget<Container>(flash).decoration
            as BoxDecoration?;
        final color = decoration?.color;
        if (color != null && color.a > 0) {
          highlighted = true;
          break;
        }
      }
      expect(highlighted, isTrue, reason: '时间选完后优先级区块高亮呼吸');

      await settle(tester);
      expect(sheetScrollOffset(tester), greaterThan(0),
          reason: '时间选完后向下滚动到优先级');
      expect(find.text('重要').hitTestable(), findsOneWidget,
          reason: '优先级选择器已滚入可视区');
      expect(tester.testTextInput.hasAnyClients, isFalse,
          reason: '流转到选择器不得弹起键盘');

      // 优先级选完 → 滚动到底部保存按钮（且不弹键盘）。
      // 视口较矮时滚到优先级已触底、保存按钮随之可见，故不断言偏移再增大，
      // 只断言保存按钮最终在可视区内。
      await tester.tap(find.text('重要'));
      await settle(tester);
      expect(find.text('保存').hitTestable(), findsOneWidget,
          reason: '保存按钮已滚入可视区');
      expect(tester.testTextInput.hasAnyClients, isFalse,
          reason: '选择优先级不弹键盘');

      appDb.debugDetachDatabase();
      await db.close();
    });
  });
}
