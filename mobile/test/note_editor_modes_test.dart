import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/note.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/ui/notes/note_editor_page.dart';
import 'package:msgrepo_mobile/ui/shared/anchored_markdown.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'anchor_service_test.dart' show createSchema;

/// 笔记编辑器双模式回归（anchors-v2 §5 废弃后）：
/// - markdown 笔记：编辑态 TextField ↔ 预览态 markdown 渲染切换；
/// - plain 笔记预览维持纯文本（星号原文显示）；
/// - 新建笔记 content_format 默认 markdown。
///
/// 对象级锚点 UI 在章节列表/任务面板（LinkedTasksSection），
/// 编辑器内不再有锚点入口。
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

  group('纯 UI（不碰 DB）', () {
    setUp(() {
      AnchoredMarkdownBody.debugFiles = const {};
    });

    tearDown(() => AnchoredMarkdownBody.debugFiles = null);

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
          home: NoteEditorPage(
              existing: note('n2', '**不是加粗**', format: 'plain'))));
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

    /// runAsync 区内没有 fake clock，pumpAndSettle 不可用；
    /// 用 pump + 真实延时让异步落库落地。
    Future<void> settle(WidgetTester tester, [int times = 10]) async {
      for (var i = 0; i < times; i++) {
        await Future.delayed(const Duration(milliseconds: 30));
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pump();
    }

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
