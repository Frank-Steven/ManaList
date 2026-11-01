import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/services/undo_service.dart';
import 'package:msgrepo_mobile/ui/messages/message_widgets.dart';
import 'package:msgrepo_mobile/ui/messages/messages_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart'
    show anchor, anchorId1, createBaseTables, insertTask;

/// 消息页删除任务入口（左滑「取消任务」）的撤销回归（v3 收尾）：
/// 删除前快照锚点行 + 正文原文，撤销后任务行、task_anchors 行、
/// 正文 marker、content_hash、edited_at 全部复原。
///
/// 在 tester.runAsync 真异步区里跑：widget 测试默认的 FakeAsync 区会让
/// sqflite_ffi 的 DB 调用挂死（与 anchor_navigation_test 同一范式）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final appDb = AppDatabase.instance;

  /// runAsync 区内：真实延时让 DB 等真异步落地，pump(duration) 推进 fake 动画时钟。
  Future<void> settle(WidgetTester tester, [int times = 10]) async {
    for (var i = 0; i < times; i++) {
      await Future.delayed(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pump();
  }

  testWidgets('消息页「取消任务」→ 撤销：任务/锚点/正文 marker/content_hash 完整复原',
      (tester) async {
    await tester.runAsync(() async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await createBaseTables(db);
      appDb.debugAttachDatabase(db);
      UndoService.instance.clear();

      const origBody = '记得买菜 ⟦task:$anchorId1⟧';
      final contentHash =
          computeContentHash('com.test', '标题m1', origBody, 2000);
      await db.insert('messages', {
        'id': 'm1',
        'package_name': 'com.test',
        'app_name': '测试应用',
        'title': '标题m1',
        'body': origBody,
        'posted_at': 2000,
        'capture_type': 'notification',
        'content_hash': contentHash,
        'edited_at': 12345,
        'created_at': 2000,
      });
      await insertTask(db, 't1', title: '买菜');
      await appDb.insertAnchor(anchor(anchorId1, 't1', 'm1', label: '买菜'));

      await tester.pumpWidget(const MaterialApp(home: MessagesPage()));
      await settle(tester);

      // 来源分组默认折叠（F02）：展开后消息行才出现（组头标题与筛选行
      // ChoiceChip 同文本，点折叠图标只命中组头）
      await tester.tap(find.byIcon(Icons.expand_more));
      await settle(tester);
      expect(find.byType(MessageTile), findsOneWidget);

      // 左滑消息行 → 点「取消任务」
      await tester.drag(find.byType(MessageTile), const Offset(-200, 0));
      await settle(tester);
      await tester.tap(find.text('取消任务'));
      await settle(tester);

      // 删除生效：任务行/锚点行删除，正文残迹化
      expect(await appDb.getTaskById('t1'), isNull);
      expect(await appDb.anchorsForTask('t1'), isEmpty);
      expect((await appDb.getMessageById('m1'))!.body, '记得买菜 [任务:买菜]');
      expect(UndoService.instance.latest?.label, '已取消任务');

      // 撤销：任务行 + 锚点行 + 正文原文整体复原
      await UndoService.instance.undoLatest();
      await settle(tester);

      expect((await appDb.getTaskById('t1'))?.title, '买菜');
      expect((await appDb.anchorsForTask('t1')).single.id, anchorId1);
      final restored =
          (await db.query('messages', where: 'id = ?', whereArgs: ['m1']))
              .single;
      expect(restored['body'], origBody, reason: 'marker 精确复原');
      expect(restored['content_hash'], contentHash, reason: 'content_hash 一并复原');
      expect(restored['edited_at'], 12345, reason: 'edited_at 复原回删除前的值');

      // deleteTasks/insertTask 会起 400ms 的重排 timer；等它跑完再关内存库
      await Future<void>.delayed(const Duration(milliseconds: 450));
      UndoService.instance.clear();
      appDb.debugDetachDatabase();
      await db.close();
    });
  });
}
