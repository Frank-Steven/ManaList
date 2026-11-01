import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/services/anchor_service.dart';
import 'package:msgrepo_mobile/services/app_ui_state.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/ui/notes/note_editor_page.dart';
import 'package:msgrepo_mobile/ui/shared/anchored_markdown.dart';
import 'package:msgrepo_mobile/ui/tasks/task_detail_panel.dart';
import 'package:msgrepo_mobile/ui/tasks/task_navigation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'anchor_service_test.dart' show createSchema;

/// 锚点双向跳转回归（design-v3 §3.4）：
/// - 正向：锚点 chip 点击 → 任务详情面板（bottom sheet）；
/// - 反向：任务详情「来源锚点」列表（图标区分 message/note/file）点击 →
///   笔记跳编辑器（预览态高亮该 chip）/ 消息跳详情 / 文件跳库·文件区。
///
/// 全部用例在 tester.runAsync 真异步区里跑：widget 测试默认的 FakeAsync
/// 区会让 sqflite_ffi 的 DB 调用挂死。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const anchorNoteId = '11111111-1111-1111-1111-111111111111';
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
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createSchema(db);
    appDb.debugAttachDatabase(db);
    AnchorService.instance.clearCache();
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

  testWidgets('正向：chip 点击弹出任务详情', (tester) async {
    await tester.runAsync(() async {
      final db = await setupDb();
      await insertAnchor(db, anchorMsgId, AnchorTargetType.message, 'm1');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => AnchoredMarkdownBody(
              data: '今天要 ⟦task:$anchorMsgId⟧',
              onOpenTask: (t) => showTaskDetailSheet(context, t),
            ),
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
      await insertAnchor(db, anchorNoteId, AnchorTargetType.note, 'n1');
      await insertAnchor(db, anchorMsgId, AnchorTargetType.message, 'm1');
      await insertAnchor(db, anchorFileId, AnchorTargetType.file, 'f1');
      await db.insert('notes', {
        'id': 'n1',
        'chapter_id': 'c1',
        'title': '购物清单',
        'content': '记得 ⟦task:$anchorNoteId⟧ 别忘',
        'content_format': 'markdown',
        'attachments': '[]',
        'created_at': 1000,
        'updated_at': 1000,
      });
      await db.insert('messages', {
        'id': 'm1',
        'package_name': 'com.test',
        'title': '家庭群',
        'body': '下班 ⟦task:$anchorMsgId⟧',
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

      // 笔记 → 编辑器（预览态 + 锚点 chip 已渲染）
      await tester.tap(find.text('购物清单'));
      await settle(tester);
      expect(find.byType(NoteEditorPage), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(NoteEditorPage),
              matching: find.byType(AnchoredMarkdownBody)),
          findsOneWidget,
          reason: '反向跳转落到预览态');
      expect(
          find.descendant(
              of: find.byType(NoteEditorPage), matching: find.text('买菜')),
          findsOneWidget,
          reason: '编辑器预览里的锚点 chip');
      await tester.pageBack();
      await settle(tester);

      // 消息 → 消息详情面板（底部弹出，正文走锚点渲染管线）
      await tester.tap(find.text('家庭群'));
      await settle(tester);
      expect(find.textContaining('下班', findRichText: true), findsOneWidget,
          reason: '消息详情正文已显示');
      expect(
          find.descendant(
              of: find.byType(BottomSheet), matching: find.text('买菜')),
          findsNWidgets(2),
          reason: '正文锚点 chip + 关联待办行各一处');
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
}
