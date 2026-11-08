import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/services/app_ui_state.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/ui/messages/message_detail_sheet.dart';
import 'package:msgrepo_mobile/ui/notes/chapters_page.dart';
import 'package:msgrepo_mobile/ui/shared/linked_tasks_section.dart';
import 'package:msgrepo_mobile/ui/tasks/task_detail_panel.dart';
import 'package:msgrepo_mobile/ui/tasks/task_list_view.dart';
import 'package:msgrepo_mobile/ui/tasks/tasks_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'anchor_service_test.dart' show createSchema;

/// 锚点双向跳转回归（anchors-v2.md §3，v12 对象级重写）：
/// - 正向：对象详情「关联任务」区 chip 点击 → 任务详情面板（bottom sheet）；
/// - 反向：任务详情「来源锚点」列表（图标区分 message/chapter/file）点击 →
///   章节跳笔记列表页 / 消息跳详情 / 文件跳库·文件区。
///
/// 全部用例在 tester.runAsync 真异步区里跑：widget 测试默认的 FakeAsync
/// 区会让 sqflite_ffi 的 DB 调用挂死。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const anchorChapterId = '11111111-1111-1111-1111-111111111111';
  const anchorMsgId = '22222222-2222-2222-2222-222222222222';
  const anchorFileId = '33333333-3333-3333-3333-333333333333';

  final appDb = AppDatabase.instance;

  Task task() => const Task(
        id: 't1',
        title: '买菜',
        kind: 'point',
        priority: 'normal',
        status: 'active',
        createdAt: 1000,
        updatedAt: 1000,
      );

  Future<void> insertAnchor(Database db, String id, String type, String targetId) =>
      db.insert('task_anchors', {
        'id': id,
        'task_id': 't1',
        'target_type': type,
        'target_id': targetId,
        'label': '买菜',
        'created_by': 'user',
        'created_at': 1000,
      });

  /// runAsync 区内：真实延时让 DB 等真异步落地，pump(duration)
  /// 推进 fake 动画时钟（底部弹层/页面转场靠它）。
  Future<void> settle(WidgetTester tester, [int times = 10]) async {
    for (var i = 0; i < times; i++) {
      await Future.delayed(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pump();
  }

  Future<Database> setupDb() async {
    // 每条用例必须拿到**独立**的内存库：sqflite 默认 singleInstance: true 会按
    // 路径（':memory:' 是常量）复用同一个连接，于是第二条用例起 createSchema
    // 会撞 "table messages already exists"。单例关闭后每次 open 都是全新空库。
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await createSchema(db);
    appDb.debugAttachDatabase(db);
    AppUiState.instance.setTab(AppUiState.tasksTabIndex);
    AppUiState.instance.setLibrarySection(AppUiState.librarySectionNotes);
    await db.insert('tasks', {
      'id': 't1',
      'title': '买菜',
      'kind': 'point',
      'priority': 'normal',
      'status': 'active',
      'created_at': 1000,
      'updated_at': 1000,
    });
    return db;
  }

  testWidgets('正向：「关联任务」区 chip 点击弹出任务详情', (tester) async {
    await tester.runAsync(() async {
      final db = await setupDb();
      await insertAnchor(db, anchorMsgId, AnchorTargetType.message, 'm1');
      await db.insert('messages', {
        'id': 'm1',
        'package_name': 'com.test',
        'title': '家庭群',
        'body': '下班记得买菜',
        'posted_at': 2000,
        'capture_type': 'notification',
        'content_hash': 'h-m1',
        'created_at': 2000,
      });

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: LinkedTasksSection(
            targetType: AnchorTargetType.message,
            targetId: 'm1',
          ),
        ),
      ));
      await settle(tester);

      await tester.tap(find.text('买菜'));
      await settle(tester);

      expect(find.byType(TaskDetailPanel), findsOneWidget,
          reason: 'chip 点击应弹出任务详情');

      appDb.debugDetachDatabase();
      await db.close();
    });
  });

  testWidgets('反向：详情面板列出三类来源锚点，点击各自跳转', (tester) async {
    await tester.runAsync(() async {
      final db = await setupDb();
      await insertAnchor(db, anchorChapterId, AnchorTargetType.chapter, 'c1');
      await insertAnchor(db, anchorMsgId, AnchorTargetType.message, 'm1');
      await insertAnchor(db, anchorFileId, AnchorTargetType.file, 'f1');
      await db.insert('chapters', {
        'id': 'c1',
        'notebook_id': 'nb1',
        'name': '购物清单',
        'sort': 0,
        'created_at': 1000,
      });
      await db.insert('messages', {
        'id': 'm1',
        'package_name': 'com.test',
        'title': '家庭群',
        'body': '下班记得买菜',
        'posted_at': 2000,
        'capture_type': 'notification',
        'content_hash': 'h-m1',
        'created_at': 2000,
      });
      await db.insert('files', {
        'id': 'f1',
        'name': '清单.pdf',
        'mime_type': 'application/pdf',
        'local_path': '/nonexistent/f1.pdf',
        'source': 'user_upload',
        'created_at': 1000,
      });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: TaskDetailPanel(task: task(), onEdit: () {})),
      ));
      await settle(tester);

      // 来源锚点列表：三类目标标题 + 图标区分
      expect(find.text('来源锚点（3）'), findsOneWidget);
      expect(find.text('购物清单'), findsOneWidget);
      expect(find.text('家庭群'), findsOneWidget);
      expect(find.text('清单.pdf'), findsOneWidget);
      expect(find.byIcon(Icons.edit_note), findsOneWidget);
      expect(find.byIcon(Icons.message_outlined), findsOneWidget);
      expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);

      // 章节 → 章节笔记列表页
      await tester.tap(find.text('购物清单'));
      await settle(tester);
      expect(find.byType(NotesListPage), findsOneWidget,
          reason: '章节锚点反向跳转落到章节笔记列表');
      await tester.pageBack();
      await settle(tester);

      // 消息 → 消息详情面板（底部弹出，含「关联任务」区）
      await tester.tap(find.text('家庭群'));
      await settle(tester);
      expect(find.textContaining('下班', findRichText: true), findsOneWidget,
          reason: '消息详情正文已显示');
      expect(
          find.descendant(
              of: find.byType(BottomSheet), matching: find.text('买菜')),
          findsOneWidget,
          reason: '「关联任务」区 chip（正文里不再有锚点 chip）');
      // 底部弹层没有返回按钮，pageBack 不适用，直接 pop 掉
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settle(tester);

      // 文件 → 库页文件区（AppUiState 定位）
      await tester.tap(find.text('清单.pdf'));
      await settle(tester);
      expect(AppUiState.instance.tabIndex, AppUiState.libraryTabIndex);
      expect(AppUiState.instance.librarySection,
          AppUiState.librarySectionFiles);

      appDb.debugDetachDatabase();
      await db.close();
    });
  });

  // ---- F14：消息关联待办 → 任务页定位（切视图 + 顶部对齐 + 约 1 秒高亮） ----

  Message linkedMessage() => const Message(
        id: 'm1',
        packageName: 'com.test',
        title: '家庭群',
        body: '下班记得买菜',
        postedAt: 2000,
        captureType: 'notification',
        contentHash: 'h-m1',
        createdAt: 2000,
      );

  Future<Database> seedLinkedMessage(Database db) async {
    await insertAnchor(db, anchorMsgId, AnchorTargetType.message, 'm1');
    await db.insert('messages', {
      'id': 'm1',
      'package_name': 'com.test',
      'title': '家庭群',
      'body': '下班记得买菜',
      'posted_at': 2000,
      'capture_type': 'notification',
      'content_hash': 'h-m1',
      'created_at': 2000,
    });
    return db;
  }

  testWidgets('消息详情「关联任务」chip 点击 → 弹任务详情（v12 对象级）',
      (tester) async {
    await tester.runAsync(() async {
      final db = await seedLinkedMessage(await setupDb());

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showMessageDetail(context, linkedMessage()),
              child: const Text('打开详情'),
            ),
          ),
        ),
      ));
      await settle(tester);
      await tester.tap(find.text('打开详情'));
      await settle(tester);

      expect(find.text('关联任务'), findsOneWidget, reason: '消息详情有关联任务区');

      await tester.tap(find.text('买菜').first);
      await settle(tester);

      expect(find.byType(TaskDetailPanel), findsOneWidget,
          reason: 'chip 点击弹任务详情（anchors-v2 §3 双向跳转）');

      appDb.debugDetachDatabase();
      await db.close();
    });
  });

  testWidgets('F14：任务页消费定位请求 → 切列表视图并显示目标任务', (tester) async {
    await tester.runAsync(() async {
      final db = await setupDb();
      // 先停在「日」视图，验证定位会切回列表视图
      AppUiState.instance.setTasksViewMode(1);
      AppUiState.instance.clearTaskFocus();

      await tester.pumpWidget(const MaterialApp(home: TasksPage()));
      await settle(tester);
      expect(AppUiState.instance.tasksViewMode, 1, reason: '初始按记忆停在日视图');

      AppUiState.instance.requestTaskFocus('t1');
      await settle(tester);

      expect(AppUiState.instance.pendingTaskFocusId, isNull,
          reason: '任务页必须把请求消费掉');
      expect(AppUiState.instance.tasksViewMode, 0,
          reason: '定位任务会切到列表视图（页签覆盖全部尺度/状态）');
      expect(find.text('买菜'), findsWidgets, reason: '目标任务行出现在列表里');

      appDb.debugDetachDatabase();
      await db.close();
    });
  });

  testWidgets('F14：focusTask 滚到目标行（顶部对齐）+ 约 1 秒临时高亮后清除',
      (tester) async {
    await tester.runAsync(() async {
      final db = await setupDb();
      // 60 条不定时任务，目标放中后段（x30）：既远在初始视口外（懒构建列表里
      // 初始根本没有这一行，必须真的滚动才能让它出现），下方又留有足够行数
      // 支撑「顶对齐」——若目标是最后一行，列表滚到底也无法把它顶到视口顶部。
      for (var i = 0; i < 60; i++) {
        await db.insert('tasks', {
          'id': 'x$i',
          'title': '任务$i',
          'kind': 'point',
          'priority': 'normal',
          'status': 'active',
          'created_at': 2000,
          'updated_at': 2000,
        });
      }
      AppUiState.instance.setTab(AppUiState.tasksTabIndex);

      final listKey = GlobalKey<TaskListViewState>();
      await tester
          .pumpWidget(MaterialApp(home: Scaffold(body: TaskListView(key: listKey))));
      await settle(tester);

      expect(find.text('任务30'), findsNothing,
          reason: '目标在视口之外，初始未构建（确实需要滚动）');

      final target = (await appDb.getTaskById('x30'))!;
      await listKey.currentState!.focusTask(target);
      // 14 帧：换页 → 粗定位 → 顶对齐动画(250ms) 需要多帧推进；
      // 这里只放宽「等动画跑完」的帧预算，断言条件不变。
      await settle(tester, 14);

      expect(find.text('任务30'), findsOneWidget, reason: '已滚动到目标行');
      final top = tester.getTopLeft(find.text('任务30')).dy;
      expect(top, lessThan(200), reason: '顶部对齐：目标行落在视口上部');
      expect(find.byKey(const ValueKey('task-row-flash-x30')), findsOneWidget,
          reason: '临时高亮应出现');

      // 真异步区：flash 的 Timer 走真实时钟，等过 1 秒窗口再断言清除
      await Future.delayed(const Duration(milliseconds: 1200));
      await tester.pump();
      expect(find.byKey(const ValueKey('task-row-flash-x30')), findsNothing,
          reason: '约 1 秒后临时高亮清除');
      expect(find.text('任务30'), findsOneWidget, reason: '清除高亮不影响定位结果');

      appDb.debugDetachDatabase();
      await db.close();
    });
  });

  // ---- B09：详情面板点父/子任务 → 页签值必须换算成 PageView 页码（非恒等映射） ----
  //
  // _tabOrder = [9, 0, 1, 2, 3, 4, 5, 6, 7, 8]（"全部"排第一，其余按下标）：
  // 「已完成」页签值 7 对应 PageView 页码 8；修复前直接把页签值当页码跳，
  // 会停在页码 7 = 页签 6「不定时」，用户看不到刚点的子任务。
  testWidgets('B09：详情面板点子任务 → 落到「已完成」页（页码 8），不是「不定时」页（页码 7）',
      (tester) async {
    await tester.runAsync(() async {
      final db = await setupDb();
      // 父任务：不定时 active（页签 6，页码 7）；子任务：不定时 done（页签 7，页码 8）
      await db.insert('tasks', {
        'id': 'p1',
        'title': '父任务',
        'kind': 'point',
        'priority': 'normal',
        'status': 'active',
        'created_at': 1000,
        'updated_at': 1000,
      });
      await db.insert('tasks', {
        'id': 'c1',
        'title': '子任务',
        'kind': 'point',
        'priority': 'normal',
        'status': 'done',
        'parent_id': 'p1',
        'created_at': 1000,
        'updated_at': 1000,
      });

      final listKey = GlobalKey<TaskListViewState>();
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TaskListView(key: listKey))));
      await settle(tester);

      // 点父任务行 → 进详情模式
      await tester.tap(find.text('父任务'));
      await settle(tester);
      expect(find.byType(TaskDetailPanel), findsOneWidget, reason: '已进入详情模式');

      // 详情面板里点子任务 → _jumpToTask(子任务)
      await tester.tap(find.descendant(
          of: find.byType(TaskDetailPanel), matching: find.text('子任务')));
      await settle(tester);

      expect(find.byType(TaskDetailPanel), findsNothing, reason: '跳转后退出详情模式');

      final pageView = tester.widget<PageView>(find.byType(PageView));
      final page = pageView.controller!.page!.round();
      expect(page, 8,
          reason: 'B09：页签 7 必须换算成页码 8（_tabOrder.indexOf(7)），不能直接用页签值');
      expect(page, isNot(7),
          reason: '回归判据：修复前把页签值当页码跳，会停在页码 7');

      // 内容级证据：页码 7 =「不定时」页（父任务所在），页码 8 =「已完成」页（子任务所在）
      expect(find.text('子任务'), findsWidgets, reason: '已完成页应展示刚点的子任务行');
      expect(find.text('父任务'), findsNothing,
          reason: '父任务是 active 不定时任务，只会在「不定时」页出现；出现即说明跳错了页');

      appDb.debugDetachDatabase();
      await db.close();
    });
  });

  // ---- F14：并发定位 latest-wins（旧请求不得覆盖新请求的页签/高亮/滚动） ----

  testWidgets('F14：TaskListView 并发 focusTask → 最终落在最后一次请求（旧请求不换页/不高亮）',
      (tester) async {
    await tester.runAsync(() async {
      final db = await setupDb();
      // A：已完成任务（落在「已完成」页签 7）；B：不定时长列表里的中后段任务
      await db.insert('tasks', {
        'id': 'doneA',
        'title': '完成任务A',
        'kind': 'point',
        'priority': 'normal',
        'status': 'done',
        'created_at': 2000,
        'updated_at': 2000,
      });
      for (var i = 0; i < 60; i++) {
        await db.insert('tasks', {
          'id': 'x$i',
          'title': '任务$i',
          'kind': 'point',
          'priority': 'normal',
          'status': 'active',
          'created_at': 2000,
          'updated_at': 2000,
        });
      }
      AppUiState.instance.setTab(AppUiState.tasksTabIndex);

      final listKey = GlobalKey<TaskListViewState>();
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TaskListView(key: listKey))));
      await settle(tester);

      final first = (await appDb.getTaskById('doneA'))!;
      final last = (await appDb.getTaskById('x40'))!;

      // 故意不 await 第一个：它在 reload / 延迟帧里时第二个请求插进来（真实竞态）
      final f1 = listKey.currentState!.focusTask(first);
      final f2 = listKey.currentState!.focusTask(last);
      await f1;
      await f2;
      await settle(tester, 14);

      expect(find.text('任务40'), findsOneWidget,
          reason: '最终必须落在最后一次请求的任务');
      expect(tester.getTopLeft(find.text('任务40')).dy, lessThan(200),
          reason: '最后一次请求要顶对齐');
      expect(find.byKey(const ValueKey('task-row-flash-x40')), findsOneWidget,
          reason: '高亮属于最后一次请求');
      expect(find.text('完成任务A'), findsNothing,
          reason: '旧请求的「已完成」页签不得覆盖新请求');
      expect(find.byKey(const ValueKey('task-row-flash-doneA')), findsNothing,
          reason: '旧请求不得再挂高亮');

      appDb.debugDetachDatabase();
      await db.close();
    });
  });

  testWidgets('F14：TasksPage 并发消费 → 只落到最后一次请求的任务', (tester) async {
    await tester.runAsync(() async {
      final db = await setupDb(); // t1「买菜」= 不定时 active
      await db.insert('tasks', {
        'id': 'doneA',
        'title': '完成任务A',
        'kind': 'point',
        'priority': 'normal',
        'status': 'done',
        'created_at': 2000,
        'updated_at': 2000,
      });
      AppUiState.instance.setTasksViewMode(0);
      AppUiState.instance.clearTaskFocus();

      await tester.pumpWidget(const MaterialApp(home: TasksPage()));
      await settle(tester);

      // 两次请求在同一同步块里发出：第一次的 getTaskById/focusTask 尚未回来
      AppUiState.instance.requestTaskFocus('t1');
      AppUiState.instance.requestTaskFocus('doneA');
      await settle(tester, 14);

      expect(AppUiState.instance.pendingTaskFocusId, isNull,
          reason: '请求必须被消费掉');
      expect(find.text('完成任务A'), findsOneWidget,
          reason: '最终必须落在最后一次请求（已完成页签）');
      expect(find.byKey(const ValueKey('task-row-flash-doneA')), findsOneWidget,
          reason: '高亮属于最后一次请求');
      expect(find.text('买菜'), findsNothing,
          reason: '旧请求的「不定时」页签不得覆盖新请求');

      appDb.debugDetachDatabase();
      await db.close();
    });
  });
}
