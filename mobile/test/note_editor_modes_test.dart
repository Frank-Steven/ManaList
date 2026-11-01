import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/note.dart';
import 'package:msgrepo_mobile/services/anchor_service.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/ui/notes/note_editor_page.dart';
import 'package:msgrepo_mobile/ui/shared/anchored_markdown.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'anchor_service_test.dart' show createSchema;

/// 笔记编辑器双模式回归（design-v3 §3.3、details §1.3）：
/// - markdown 笔记：编辑态 TextField ↔ 预览态锚点渲染管线切换；
/// - plain 笔记预览维持纯文本（星号原文显示）；
/// - plain 笔记加锚点先弹「转为 Markdown」一次性确认，转换后插 marker + 写表；
/// - 新建笔记 content_format 默认 markdown。
///
/// 说明：纯 UI 用例用 [AnchoredMarkdownBody.debugData] 注入联查数据；
/// 涉及真实 DB 的用例必须在 tester.runAsync 真异步区里跑
/// （widget 测试的 FakeAsync 区会让 sqflite_ffi 调用挂死）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  Note note(String id, String content, {String format = 'markdown'}) => Note(
        id: id,
        chapterId: 'c1',
        title: '笔记$id',
        content: content,
        contentFormat: format,
        createdAt: 1000,
        updatedAt: 1000,
      );

  group('纯 UI（联查数据注入，不碰 DB）', () {
    setUp(() {
      AnchoredMarkdownBody.debugData =
          (anchors: const {}, tasks: const {}, files: const {});
    });

    tearDown(() => AnchoredMarkdownBody.debugData = null);

    testWidgets('markdown 笔记：编辑/预览切换，预览按 markdown 渲染',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: NoteEditorPage(existing: note('n1', '前文 **加粗** 后文'))));
      await tester.pumpAndSettle();

      // 编辑态：正文是原文（含星号）
      expect(find.byType(AnchoredMarkdownBody), findsNothing);
      expect(find.textContaining('**加粗**'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.visibility_outlined));
      await tester.pumpAndSettle();

      // 预览态：markdown 渲染，星号消失、文字保留
      expect(find.byType(AnchoredMarkdownBody), findsOneWidget);
      expect(find.textContaining('加粗', findRichText: true), findsOneWidget);
      expect(find.textContaining('**', findRichText: true), findsNothing);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      expect(find.byType(AnchoredMarkdownBody), findsNothing,
          reason: '切回编辑态');
    });

    testWidgets('plain 笔记预览维持纯文本渲染（不解析 markdown）', (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: NoteEditorPage(existing: note('n2', '**不是加粗**', format: 'plain'))));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.visibility_outlined));
      await tester.pumpAndSettle();

      expect(find.byType(AnchoredMarkdownBody), findsNothing);
      expect(find.text('**不是加粗**'), findsOneWidget, reason: 'plain 原文显示');
    });
  });

  group('真实 DB（runAsync 真异步区）', () {
    late Database db;
    final appDb = AppDatabase.instance;

    Future<void> insertNote(Note n) => db.insert('notes', n.toRow());

    Future<Note> noteFromDb(String id) async => (await appDb.getNoteById(id))!;

    /// runAsync 区内没有 fake clock，pumpAndSettle 不可用；
    /// 用 pump + 真实延时让异步落库/底部弹层动画落地。
    /// runAsync 区内：真实延时让 DB 等真异步落地，pump(duration)
    /// 推进 fake 动画时钟（底部弹层/页面转场靠它）。
    Future<void> settle(WidgetTester tester,
        [int times = 10]) async {
      for (var i = 0; i < times; i++) {
        await Future.delayed(const Duration(milliseconds: 30));
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pump();
    }

    testWidgets('plain 笔记加锚点：先确认转 Markdown，再插 marker 写表',
        (tester) async {
      await tester.runAsync(() async {
        db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        await createSchema(db);
        appDb.debugAttachDatabase(db);
        AnchorService.instance.clearCache();
        await db.insert('tasks', {
          'id': 't1',
          'title': '买菜',
          'kind': 'point',
          'priority': 'normal',
          'status': 'active',
          'created_at': 1000,
          'updated_at': 1000,
        });
        await insertNote(note('n3', '记得买菜', format: 'plain'));

        await tester.pumpWidget(MaterialApp(
            home: NoteEditorPage(existing: await noteFromDb('n3'))));
        await settle(tester);

        // 编辑态工具栏「添加任务锚点」（无选中 → 追加正文末尾）
        await tester.tap(find.byIcon(Icons.add_link));
        await settle(tester);

        // 一次性确认「转为 Markdown」
        expect(find.text('转为 Markdown'), findsOneWidget);
        await tester.tap(find.text('转换'));
        await settle(tester);

        // 任务选择器：选已有任务「买菜」
        expect(find.text('买菜'), findsOneWidget, reason: '选择器列出活动任务');
        await tester.tap(find.text('买菜'));
        await settle(tester);

        final saved = await noteFromDb('n3');
        expect(saved.contentFormat, 'markdown', reason: '已确认转换格式');
        final m =
            RegExp(r'⟦task:([0-9a-f-]{36})⟧').firstMatch(saved.content);
        expect(m, isNotNull, reason: '正文末尾追加了 marker');
        expect(saved.content, startsWith('记得买菜'));

        final anchor = await appDb.getAnchorById(m!.group(1)!);
        expect(anchor, isNotNull);
        expect(anchor!.taskId, 't1');
        expect(anchor.targetType, 'note');
        expect(anchor.targetId, 'n3');

        // 编辑器正文与库内同步（含 marker）
        expect(find.textContaining('⟦task:'), findsOneWidget);

        appDb.debugDetachDatabase();
        await db.close();
      });
    });

    testWidgets('markdown 笔记加锚点：不弹转换确认，直接进任务选择器',
        (tester) async {
      await tester.runAsync(() async {
        db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        await createSchema(db);
        appDb.debugAttachDatabase(db);
        AnchorService.instance.clearCache();
        await db.insert('tasks', {
          'id': 't1',
          'title': '买菜',
          'kind': 'point',
          'priority': 'normal',
          'status': 'active',
          'created_at': 1000,
          'updated_at': 1000,
        });
        await insertNote(note('n4', '记得买菜'));

        await tester.pumpWidget(MaterialApp(
            home: NoteEditorPage(existing: await noteFromDb('n4'))));
        await settle(tester);

        await tester.tap(find.byIcon(Icons.add_link));
        await settle(tester);

        expect(find.text('转为 Markdown'), findsNothing);
        expect(find.text('买菜'), findsOneWidget);
        await tester.tap(find.text('买菜'));
        await settle(tester);

        final saved = await noteFromDb('n4');
        expect(saved.contentFormat, 'markdown');
        expect(saved.content, contains('⟦task:'));

        appDb.debugDetachDatabase();
        await db.close();
      });
    });

    testWidgets('新建笔记默认 content_format = markdown', (tester) async {
      await tester.runAsync(() async {
        db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        await createSchema(db);
        appDb.debugAttachDatabase(db);

        // 从宿主页推入编辑器（home 直挂没有返回键，pageBack 无法触发退出保存）
        await tester.pumpWidget(MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const NoteEditorPage(chapterId: 'c1'))),
                child: const Text('OPEN'),
              ),
            ),
          ),
        ));
        await settle(tester);
        await tester.tap(find.text('OPEN'));
        await settle(tester);
        await tester.enterText(
            find.byWidgetPredicate((w) =>
                w is TextField &&
                (w.decoration?.hintText ?? '').startsWith('正文')),
            '第一条笔记内容');
        await tester.pump();
        // 触发退出保存（PopScope → 自动保存 → pop）
        await tester.pageBack();
        await settle(tester);

        final rows = await db.query('notes');
        expect(rows, hasLength(1));
        expect(rows.single['content_format'], 'markdown');
        expect(rows.single['content'], '第一条笔记内容');

        appDb.debugDetachDatabase();
        await db.close();
      });
    });
  });
}
