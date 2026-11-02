import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/note.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/ui/assistant/attachment_pick_controller.dart';
import 'package:msgrepo_mobile/ui/notes/chapters_page.dart';
import 'package:msgrepo_mobile/ui/notes/notes_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'anchor_service_test.dart' show createSchema;

/// B13 回归：附件选择器里「笔记 → 章节 → 章节内笔记列表」是**独立路由**。
/// 原先 pickMode 下 bottomNavigationBar 条件 `_selecting && !widget.pickMode` 恒假，
/// 深层页没有任何确认入口；AppBar 左侧又被「×（退出多选）」占据，按它等于清空选择
/// → 真机表现为「深层无确认、返回丢选择」。
///
/// 修复约定（与消息/文件分区一致）：深层页给「已选 N + 确认」，确认 = 带着选择
/// （存于 AttachmentPickController，跨路由不丢）回到附件选择页，由它统一确认并返回结果。
///
/// 本文件用只依赖笔记三级页的宿主来跑：真实 NotesPage / ChaptersPage / NotesListPage
/// + 真实 AttachmentPickController；宿主底栏镜像 attachment_picker.dart 的
/// 「确认（N）」契约（那份实现本次未改动，不应被测试重复覆盖）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final appDb = AppDatabase.instance;
  late Database db;

  Future<void> settle(WidgetTester tester, [int times = 12]) async {
    for (var i = 0; i < times; i++) {
      await Future.delayed(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pump();
  }

  Future<Database> setupDb() async {
    // 每条用例独立内存库（沿用 B09 教训：默认 singleInstance 会复用同一连接）
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await createSchema(db);
    // createSchema 只建 messages/tasks/notes(+v8)，笔记三级还缺 notebooks/chapters
    await db.execute('''CREATE TABLE IF NOT EXISTS notebooks(
      id TEXT PRIMARY KEY, name TEXT NOT NULL,
      sort INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS chapters(
      id TEXT PRIMARY KEY, notebook_id TEXT NOT NULL, name TEXT NOT NULL,
      sort INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)''');
    await db.insert('notebooks', {
      'id': 'n1', 'name': '笔记本A', 'sort': 0, 'created_at': 1000,
    });
    await db.insert('chapters', {
      'id': 'c1', 'notebook_id': 'n1', 'name': '章节A', 'sort': 0,
      'created_at': 1000,
    });
    for (final row in [
      {'id': 'note-a', 'title': '笔记甲'},
      {'id': 'note-b', 'title': '笔记乙'},
    ]) {
      await db.insert('notes', {
        'id': row['id'],
        'chapter_id': 'c1',
        'title': row['title'],
        'content': '正文',
        'content_format': 'plain',
        'attachments': '[]',
        'created_at': 1000,
        'updated_at': 1000,
      });
    }
    appDb.debugAttachDatabase(db);
    return db;
  }

  tearDown(() async {
    appDb.debugDetachDatabase();
    await db.close();
  });

  /// 宿主：真实 NotesPage(pickMode) + 镜像附件选择页的「确认（N）」底栏。
  Widget host(AttachmentPickController ctrl, void Function(List<ChatAttachment>) onConfirm) {
    return MaterialApp(
      home: Scaffold(
        body: NotesPage(pickMode: true, pickController: ctrl),
        bottomNavigationBar: AnimatedBuilder(
          animation: ctrl,
          builder: (context, _) => SafeArea(
            top: false,
            child: Row(
              children: [
                Expanded(child: Text('已选附件 ${ctrl.length}')),
                FilledButton(
                  onPressed: () => onConfirm(ctrl.attachments),
                  child: Text('确认（${ctrl.length}）'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('B13 pickMode：深层笔记列表有确认；确认回到选择层且选择不丢；最终返回所选结果',
      (tester) async {
    await tester.runAsync(() async {
      db = await setupDb();
      final ctrl = AttachmentPickController();
      List<ChatAttachment>? picked;
      await tester.pumpWidget(host(ctrl, (list) => picked = list));
      await settle(tester);

      // 笔记本 → 章节 → 章节内笔记列表（后两跳都是独立路由）
      await tester.tap(find.text('笔记本A'));
      await settle(tester);
      await tester.tap(find.text('章节A'));
      await settle(tester);

      await tester.tap(find.text('笔记甲'));
      await settle(tester);
      expect(find.text('已选 1 项笔记'), findsOneWidget,
          reason: 'B13：深层页要显示已选计数');
      expect(find.text('确认（1）'), findsOneWidget,
          reason: 'B13：深层页必须有确认按钮（修复前恒为 null）');

      // 深层确认 → 回到笔记列表层（笔记页），选择仍在控制器里
      await tester.tap(find.text('确认（1）'));
      await settle(tester);
      expect(find.text('笔记本A'), findsOneWidget, reason: '确认后回到上一层');
      expect(ctrl.length, 1, reason: 'B13：返回不丢选择');
      expect(find.text('已选附件 1'), findsOneWidget);

      // 选择层确认 → 把所选笔记返回给调用方
      await tester.tap(find.text('确认（1）'));
      await settle(tester);
      expect(picked, isNotNull, reason: '确认后应返回所选附件');
      expect(picked!.map((a) => a.id), contains('note-a'));
      expect(picked!.map((a) => a.type), everyElement(ChatAttachmentType.note));
      // 不在这里 dispose 控制器：宿主里的 AnimatedBuilder 仍挂在树上，
      // ChangeNotifier.dispose 后再 removeListener 会触发 used-after-dispose 断言。
    });
  });

  testWidgets('B13 pickMode：深层 AppBar 返回不清空选择（再进入仍是已选）', (tester) async {
    await tester.runAsync(() async {
      db = await setupDb();
      final ctrl = AttachmentPickController();
      await tester.pumpWidget(host(ctrl, (_) {}));
      await settle(tester);
      await tester.tap(find.text('笔记本A'));
      await settle(tester);
      await tester.tap(find.text('章节A'));
      await settle(tester);
      await tester.tap(find.text('笔记甲'));
      await settle(tester);

      // 用 AppBar 的返回箭头（不是「× 退出多选」）
      await tester.tap(find.byTooltip('返回（已选保留）'));
      await settle(tester);
      expect(ctrl.length, 1, reason: 'B13：返回不清空选择');

      // 重新进入同一章节：选择仍在（确认栏计数为 1）
      await tester.tap(find.text('章节A'));
      await settle(tester);
      expect(find.text('确认（1）'), findsOneWidget,
          reason: 'B13：深层再进入，选择不丢');
    });
  });

  testWidgets('B13 普通模式不变：多选态只有「发送给助理」，无 pick 确认栏', (tester) async {
    await tester.runAsync(() async {
      db = await setupDb();
      const chapter =
          Chapter(id: 'c1', notebookId: 'n1', name: '章节A', createdAt: 1000);
      await tester.pumpWidget(const MaterialApp(
        home: NotesListPage(chapter: chapter),
      ));
      await settle(tester);

      // 注意：不能直接用 tester.longPress —— 它推进的是**假时钟**（pump 500ms），
      // 而 runAsync 区里手势识别器的长按 Timer 跑在**真实时钟**上，
      // up() 早于 500ms 会让长按永不触发（本用例曾因此 0 命中）。
      // 这里改用真实等待，其余断言保持不变。
      final gesture =
          await tester.startGesture(tester.getCenter(find.text('笔记甲')));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await tester.pump();
      await gesture.up();
      await settle(tester);

      // 先确认确实进入了多选态（失败点更明确），再校验底栏内容
      expect(find.text('已选 1 项'), findsOneWidget,
          reason: '长按应进入多选态');
      expect(find.byTooltip('发送给助理'), findsOneWidget,
          reason: '非 pickMode 的多选条保持原样');
      expect(find.textContaining('确认（'), findsNothing,
          reason: '非 pickMode 不应出现附件选择的确认栏');
    });
  });
}
