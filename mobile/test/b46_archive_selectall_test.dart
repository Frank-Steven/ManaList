import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/services/undo_service.dart';
import 'package:msgrepo_mobile/ui/messages/archived_page.dart';
import 'package:msgrepo_mobile/ui/messages/message_widgets.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables, insertTask;

/// B46（2026-11-25，KIMI task-67）：已归档页「全选 = 全部已归档」+ 分块批量删除 +
/// 一次性撤销（DB v15 备份表）。
///
/// 覆盖：501/1200 全选计数、分块取出/撤销、1200 删除含锚点撤销、字段/附件/状态一致、
/// 第 2 块失败全事务回滚（0 删除 0 备份）、TTL/clear/undo 失败清理、v14→v15 迁移与
/// 新库建表、旧数据不动、页面层「取消 = 0 写 0 备份」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final appDb = AppDatabase.instance;
  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createBaseTables(db);
    // 新库口径：_onCreate 末尾同样会调 migrateToV15；这里显式建出 v15 表。
    await migrateToV15(db);
    appDb.debugAttachDatabase(db);
    UndoService.instance.clear();
  });

  tearDown(() async {
    UndoService.instance.clear();
    appDb.debugDetachDatabase();
    await db.close();
  });

  Future<void> seedArchived(int count,
      {String prefix = 'm', int startAt = 1000}) async {
    final batch = db.batch();
    for (var i = 0; i < count; i++) {
      batch.insert('messages', <String, Object?>{
        'id': '$prefix$i',
        'package_name': 'com.test',
        'app_name': '测试应用',
        'title': '标题$i',
        'body': '正文$i',
        'posted_at': startAt + i,
        'capture_type': 'notification',
        'attachments': '[]',
        'content_hash': 'hash-$prefix$i',
        'status': MessageStatus.archived,
        'priority': 'none',
        'created_at': 2000,
      });
    }
    await batch.commit(noResult: true);
  }

  Future<int> countMessages() async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM messages');
    return (rows.first['c'] as num).toInt();
  }

  Future<int> countUndoRows({String? batchId}) async {
    final where = batchId == null ? '' : ' WHERE batch_id = ?';
    final args = batchId == null ? <Object?>[] : <Object?>[batchId];
    final m = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM undo_deleted_messages$where', args);
    final a = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM undo_deleted_anchors$where', args);
    return (m.first['c'] as num).toInt() + (a.first['c'] as num).toInt();
  }

  Future<List<String>> archivedIds() => appDb.getArchivedMessageIds();

  group('全选范围（ID 快照）', () {
    test('501 条：ID 快照是 501，首屏 getMessages 仍只 500', () async {
      await seedArchived(501);
      expect((await archivedIds()).length, 501, reason: '全选范围必须是全部已归档');
      final firstScreen =
          await appDb.getMessages(status: MessageStatus.archived);
      expect(firstScreen.length, 500,
          reason: '首屏仍受 defaultMessageLimit 500 约束（本次不改）');
    });

    test('1200 条：ID 快照 1200 且不含非归档消息', () async {
      await seedArchived(1200, prefix: 'p');
      await db.insert('messages', <String, Object?>{
        'id': 'pending0',
        'package_name': 'com.test',
        'title': '未归档',
        'body': 'x',
        'posted_at': 1,
        'capture_type': 'notification',
        'content_hash': 'hash-pending0',
        'status': MessageStatus.processed,
        'created_at': 1,
      });
      final ids = await archivedIds();
      expect(ids.length, 1200);
      expect(ids.contains('pending0'), isFalse,
          reason: '只 SELECT archived，非归档不得进入快照');
    });
  });

  group('分块取出与撤销', () {
    test('1200 条按 500 分块取出，一次撤销全部回到 archived', () async {
      await seedArchived(1200, prefix: 'u');
      final ids = await archivedIds();
      await appDb.updateMessageStatusChunked(ids, MessageStatus.processed);
      expect((await archivedIds()).length, 0, reason: '取出后无归档');
      final processed = await db.rawQuery(
          "SELECT COUNT(*) AS c FROM messages WHERE status = 'processed'");
      expect((processed.first['c'] as num).toInt(), 1200);

      // 撤销闭包只持 ID（与页面里的写法一致），一次撤销全部回滚
      await appDb.updateMessageStatusChunked(ids, MessageStatus.archived);
      expect((await archivedIds()).length, 1200, reason: '一次撤销应全部恢复');
      expect(await countUndoRows(), 0, reason: '取出路径不产生撤销备份');
    });
  });

  group('删除 + DB 备份 + 一次撤销', () {
    test('空参数：0 删除 0 备份', () async {
      await seedArchived(10);
      expect(await appDb.deleteArchivedWithBackup(<String>[]), isNull);
      expect(await countMessages(), 10);
      expect(await countUndoRows(), 0);
    });

    test('1200 条删除含锚点：一次撤销恢复消息 + 锚点 + 原字段', () async {
      await seedArchived(1200, prefix: 'd');
      await insertTask(db, 't1');
      for (final mid in <String>['d0', 'd700']) {
        await db.insert('task_anchors', <String, Object?>{
          'id': 'a-$mid',
          'task_id': 't1',
          'target_type': 'message',
          'target_id': mid,
          'label': '锚点-$mid',
          'created_by': 'user',
          'created_at': 1500,
        });
      }
      await db.update(
        'messages',
        <String, Object?>{
          'attachments': jsonEncode(<Map<String, Object?>>[
            <String, Object?>{'name': 'a.png', 'kind': 'image'},
          ]),
        },
        where: 'id = ?',
        whereArgs: <Object?>['d5'],
      );

      final ids = await archivedIds();
      final batchId = await appDb.deleteArchivedWithBackup(ids);
      expect(batchId, isNotNull);
      expect(await countMessages(), 0, reason: '全部删除');
      final anchorsLeft =
          await db.rawQuery('SELECT COUNT(*) AS c FROM task_anchors');
      expect((anchorsLeft.first['c'] as num).toInt(), 0,
          reason: '删除消息时锚点按既有口径级联删除');
      expect(await countUndoRows(batchId: batchId), 1202,
          reason: '1200 条消息 + 2 个锚点全部进备份');

      await appDb.restoreDeletedMessageBatch(batchId!);
      expect(await countMessages(), 1200, reason: '一次撤销恢复全部消息');
      final anchorsBack =
          await db.rawQuery('SELECT COUNT(*) AS c FROM task_anchors');
      expect((anchorsBack.first['c'] as num).toInt(), 2, reason: '锚点一并恢复');

      final restored = await db
          .query('messages', where: 'id = ?', whereArgs: <Object?>['d5']);
      expect(restored.length, 1);
      expect(restored.first['status'], MessageStatus.archived,
          reason: '状态字段恢复为归档');
      expect(restored.first['attachments'], contains('a.png'),
          reason: '附件 JSON 原样恢复');
      expect(restored.first['content_hash'], 'hash-d5', reason: '内容哈希一致');
      final restoredAnchor = await db.query('task_anchors',
          where: 'id = ?', whereArgs: <Object?>['a-d700']);
      expect(restoredAnchor.single['label'], '锚点-d700', reason: '锚点字段原样恢复');

      expect(await countUndoRows(), 0, reason: '恢复后该批备份被清掉（不重复清）');
    });

    test('第 2 块失败：整事务回滚，0 删除 0 备份', () async {
      await seedArchived(800, prefix: 'f');
      final ids = await archivedIds(); // 800 → 2 块（500 + 300）
      await db.execute('''
        CREATE TRIGGER b46_fail_second_chunk BEFORE DELETE ON messages
        WHEN old.id = 'f600'
        BEGIN SELECT RAISE(ABORT, 'b46-second-chunk-boom'); END
      ''');

      await expectLater(appDb.deleteArchivedWithBackup(ids), throwsA(anything));
      expect(await countMessages(), 800, reason: '事务回滚：一条都不能少');
      expect(await countUndoRows(), 0, reason: '事务回滚：备份也不能留');
    });
  });

  group('备份 TTL 清理', () {
    test('10 秒前的备份被清理，新鲜备份保留', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final entry in <(String, int)>[('old', 11000), ('fresh', 0)]) {
        final (id, age) = entry;
        await db.insert('undo_deleted_messages', <String, Object?>{
          'batch_id': id,
          'message_id': 'm-$id',
          'row_json': '{}',
          'created_at': now - age,
        });
        await db.insert('undo_deleted_anchors', <String, Object?>{
          'batch_id': id,
          'anchor_id': 'a-$id',
          'row_json': '{}',
          'created_at': now - age,
        });
      }
      await appDb.cleanupExpiredUndoBackups();
      final left = await db.query('undo_deleted_messages');
      expect(left.map((r) => r['batch_id']).toList(), <String>['fresh'],
          reason: 'TTL 10s：过期批清掉、新批保留（开库/新备份前同一实现）');
      expect((await db.query('undo_deleted_anchors')).length, 1);
    });
  });

  group('迁移', () {
    test('dbVersion 升到 15', () {
      expect(AppDatabase.dbVersion, 15);
    });

    test('v14 老库迁移：缺备份表 → 迁移后建齐，旧数据不动，幂等', () async {
      // 必须与 setUp 里的库**不是同一个实例**：inMemoryDatabasePath 默认
      // singleInstance:true 会复用 setUp 已建好的库（那时 messages 已存在），
      // createBaseTables 会因重复建表失败。这里显式关掉单实例。
      final oldDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await createBaseTables(oldDb);
      await oldDb.insert('messages', <String, Object?>{
        'id': 'legacy1',
        'package_name': 'com.test',
        'title': '老数据',
        'body': 'x',
        'posted_at': 1,
        'capture_type': 'notification',
        'content_hash': 'hash-legacy1',
        'status': MessageStatus.archived,
        'created_at': 1,
      });
      final before =
          await oldDb.rawQuery('PRAGMA table_info(undo_deleted_messages)');
      expect(before, isEmpty, reason: '前提：老库没有 v15 表');

      await migrateToV15(oldDb);
      await migrateToV15(oldDb); // 幂等（onCreate 与迁移共用 IF NOT EXISTS）
      final msgs =
          await oldDb.rawQuery('PRAGMA table_info(undo_deleted_messages)');
      final anchors =
          await oldDb.rawQuery('PRAGMA table_info(undo_deleted_anchors)');
      expect(
          msgs.map((c) => c['name']),
          containsAll(
              <String>['batch_id', 'message_id', 'row_json', 'created_at']));
      expect(
          anchors.map((c) => c['name']),
          containsAll(
              <String>['batch_id', 'anchor_id', 'row_json', 'created_at']));
      final legacy = await oldDb.query('messages');
      expect(legacy.length, 1, reason: '迁移不得动旧数据');
      expect(legacy.single['id'], 'legacy1');
      await oldDb.close();
    });
  });

  group('撤销条目清理（UndoService.onExpire）', () {
    test('clear() 触发 onExpire：该批备份被删除', () async {
      await seedArchived(3);
      final ids = await archivedIds();
      final batchId = await appDb.deleteArchivedWithBackup(ids);
      expect(await countUndoRows(batchId: batchId), 3);

      var expired = false;
      UndoService.instance.register(
        label: '已删除',
        undo: () async {},
        onExpire: () async {
          expired = true;
          await appDb.deleteUndoBackupBatch(batchId!);
        },
      );
      UndoService.instance.clear();
      // clear() 是同步方法 + fire-and-forget 清理：让微任务跑完再断言。
      await Future<void>.delayed(Duration.zero);
      expect(expired, isTrue, reason: 'clear 必须触发 onExpire');
      expect(await countUndoRows(batchId: batchId), 0, reason: '过期清理应删掉该批备份');
    });

    test('undo 抛错也触发 onExpire，且错误原样抛出', () async {
      var expired = false;
      UndoService.instance.register(
        label: '已删除',
        undo: () async => throw StateError('undo-boom'),
        onExpire: () async {
          expired = true;
        },
      );
      await expectLater(
          UndoService.instance.undoLatest(), throwsA(isA<StateError>()));
      expect(expired, isTrue, reason: 'undo 失败要顺手清理附带资源');
      expect(UndoService.instance.latest, isNull, reason: '失败项也要出栈');
    });

    test('成功 undo 不重复调用 onExpire（备份由恢复函数清）', () async {
      await seedArchived(2);
      final ids = await archivedIds();
      final batchId = await appDb.deleteArchivedWithBackup(ids);
      var expiredCalled = false;
      UndoService.instance.register(
        label: '已删除',
        undo: () => appDb.restoreDeletedMessageBatch(batchId!),
        onExpire: () async {
          expiredCalled = true;
        },
      );
      await UndoService.instance.undoLatest();
      expect(expiredCalled, isFalse, reason: '成功 undo 不应再跑 onExpire');
      expect(await countUndoRows(batchId: batchId), 0, reason: '恢复函数已清备份');
      expect(await countMessages(), 2);
    });
  });

  group('页面层：全选 = 全部、取消 = 0 写 0 备份', () {
    setUp(() async {
      // 600 条 > 首屏 500，正好覆盖 B46 的原始症状（旧实现只选首屏）。
      await seedArchived(600, prefix: 'w');
    });

    /// 与 recent_ops_page_test 同款：runAsync 里必须是**真实** await，
    /// 否则 DB 的异步链根本没跑完（fake 时钟空转），断言会读到半成品状态。
    Future<void> settle(WidgetTester tester, [int times = 12]) async {
      for (var i = 0; i < times; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pump();
    }

    testWidgets('长按进入选择 → 全选计数是全部已归档 → 取消后 0 写 0 备份', (tester) async {
      await tester.runAsync(() async {
        await tester
            .pumpWidget(const MaterialApp(home: ArchivedMessagesPage()));
        await settle(tester);
        expect(find.byType(MessageTile), findsWidgets, reason: '首屏应有消息');

        // 进入选择模式：本用例验证的是**真实长按回调的接线与随之而来的状态**，
        // 而不是指针手势本身。
        //
        // 说明（为什么不用 startGesture/longPress 打指针）：
        // 已归档行是 Slidable(SwipeActionRow) + GestureDetector 的组合，本 harness
        // 又把整段跑在 tester.runAsync 里（为了等 DB 异步），指针手势在这个组合下
        // 不稳定：手势竞技场里 Slidable 的水平拖拽识别器会先接走 pointer，
        // 两轮尝试都拿不到 onLongPress，属测试环境限制而非生产缺陷
        // （生产链路见 message_widgets.dart:305-308 GestureDetector + :520 透传）。
        // 真机上的长按手势另做功能级验收，本用例不冒充它。
        //
        // 这里仍然先断言「tile 内确实存在带 onLongPress 的真实手势目标」，
        // 再直接调用**该生产回调**触发，验证 接线 → setState → UI 文案 这条链。
        final longPressTarget = find
            .descendant(
              of: find.byType(MessageTile).first,
              matching: find.byWidgetPredicate(
                  (w) => w is GestureDetector && w.onLongPress != null),
            )
            .first;
        expect(longPressTarget, findsOneWidget,
            reason: 'tile 内应存在带 onLongPress 的手势目标（接线前提）');

        final longPressCallback =
            tester.widget<GestureDetector>(longPressTarget).onLongPress;
        expect(longPressCallback, isNotNull,
            reason: 'tile 内那个 GestureDetector 必须真的接上 onLongPress');
        longPressCallback!();
        await settle(tester);
        expect(find.text('已选 1 项'), findsOneWidget);

        // 全选：应覆盖全部 600（超过首屏 500）
        await tester.tap(find.text('全选'));
        await settle(tester);
        expect(find.text('已选 600 项'), findsOneWidget,
            reason: '全选 = 全部已归档（ID 快照），不再是首屏 500');

        // 取消：不得产生任何写入/备份
        await tester.tap(find.text('取消'));
        await settle(tester);
        expect(await countMessages(), 600, reason: '取消不得删消息');
        expect(await countUndoRows(), 0, reason: '取消不得产生撤销备份');
        final stillArchived = await archivedIds();
        expect(stillArchived.length, 600, reason: '取消不得改变归档状态');

        // 收尾：让页面可能仍在途的 reload 落地，避免 tearDown 关库时还有异步在跑。
        await settle(tester);
        await Future<void>.delayed(Duration.zero);
      });
    });
  });

  // ---- task-77：页面级删除 Snackbar 时序 + 精确锚点备份 / 一次撤销 ----
  //
  // 与上面 DB 级用例的区别：这两个用例**从真实页面入口**走
  // （ArchivedMessagesPage → 选择 → 真实 tap 删除按钮 → 真实 tap 撤销），
  // 验证「备份 + 提示时序 + 一次撤销」整条链路，而不是直接调 DB 函数。
  // 锚点夹具刻意让 target_id **精确等于**被删消息 ID（真机夹具 target_id 错位是主因）。

  group('页面级：删除 Snackbar 时序 + 精确锚点备份 + 一次撤销', () {
    /// 手机尺寸 surface：默认 800x600 会把 SnackBar 的「撤销」放到屏幕外
    /// （center Offset(744,638) 超出 root，tap 命中不到），这里换成竖屏手机比例，
    /// 用例结束恢复默认（等价于把 physicalSize 置回 null）。
    void usePhoneSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
    }

    /// 小泵 + 真实微等待：不用长 settle，避免把 4s SnackBar 窗口等没。
    Future<void> pumpUntil(WidgetTester tester, bool Function() done,
        {int ticks = 60}) async {
      for (var i = 0; i < ticks; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (done()) return;
      }
    }

    /// 3 条归档消息；p0 / p1 各挂一个 target_id 精确匹配的消息锚点。
    Future<void> seedThreeWithExactAnchors() async {
      await seedArchived(3, prefix: 'p');
      await insertTask(db, 't1');
      for (final id in <String>['p0', 'p1']) {
        await db.insert('task_anchors', <String, Object?>{
          'id': 'a-$id',
          'task_id': 't1',
          'target_type': 'message',
          'target_id': id,
          'label': '锚点-$id',
          'created_by': 'user',
          'created_at': 1500,
        });
      }
    }

    /// 装载页面 → 进入选择（真实长按回调接线）→ 真实 tap 选中其余两行。
    Future<void> pumpPageAndSelectAll(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: ArchivedMessagesPage()));
      await pumpUntil(
          tester, () => find.byType(MessageTile).evaluate().length >= 3);
      expect(find.byType(MessageTile), findsNWidgets(3));

      // 指针长按在 Slidable + runAsync 下不稳（文件内已有说明），
      // 这里用该 tile 上**真实生产回调**进入选择；后续点击/删除/撤销都是真实 tap。
      final longPressTarget = find
          .descendant(
            of: find.byType(MessageTile).first,
            matching: find.byWidgetPredicate(
                (w) => w is GestureDetector && w.onLongPress != null),
          )
          .first;
      expect(longPressTarget, findsOneWidget);
      tester.widget<GestureDetector>(longPressTarget).onLongPress!();
      await tester.pump();

      await tester.tap(find.byType(MessageTile).at(1));
      await tester.pump();
      await tester.tap(find.byType(MessageTile).at(2));
      await tester.pump();
      expect(find.text('已选 3 项'), findsOneWidget);
    }

    testWidgets('A 删除后 4 秒内「已删除 + 撤销」同时可见，备份 3 条消息 + 2 个锚点',
        (tester) async {
      await tester.runAsync(() async {
        usePhoneSurface(tester);
        await seedThreeWithExactAnchors();
        await pumpPageAndSelectAll(tester);

        await tester.tap(find.byTooltip('删除')); // 真实 tap 批量删除
        await pumpUntil(
            tester, () => find.text('已删除').evaluate().isNotEmpty);
        // SnackBar 有从底部滑入的入场动画（约 250ms）：刚出文字时仍在动画中。
        // 先推进 ~320ms 让入场完成，再做「同时可见」断言（不用 pumpAndSettle，避免等满 4s 计时器）。
        await tester.pump(const Duration(milliseconds: 320));

        expect(find.text('已删除'), findsOneWidget,
            reason: '删除后 4s 内必须看到「已删除」Snackbar（真机曾 0.3–4.2s 全看不到）');
        expect(find.text('撤销'), findsOneWidget,
            reason: '同一 Snackbar 里「撤销」必须可见且可点');
        expect(await countMessages(), 0, reason: '3 条已删除');
        expect(await countUndoRows(), 5,
            reason: '撤销备份 = 3 条消息 + 2 个 target_id 精确匹配的锚点');
      });
    });

    testWidgets('B 真实 tap「撤销」后消息/锚点全恢复、备份 0、Snackbar 消失',
        (tester) async {
      await tester.runAsync(() async {
        usePhoneSurface(tester);
        await seedThreeWithExactAnchors();
        await pumpPageAndSelectAll(tester);

        await tester.tap(find.byTooltip('删除'));
        await pumpUntil(tester, () => find.text('撤销').evaluate().isNotEmpty);
        // 入场动画（约 250ms）未完成时按钮还在从底部滑入的途中，
        // 立即 tap 会命中动画途中位置（表现为「点不到撤销」）。这里显式推进 320ms。
        await tester.pump(const Duration(milliseconds: 320));
        expect(find.text('撤销'), findsOneWidget);

        await tester.tap(find.text('撤销')); // 真实 tap 撤销（入场动画已结束）
        await pumpUntil(tester, () => find.text('撤销').evaluate().isEmpty);

        expect(find.text('撤销'), findsNothing, reason: '撤销后 SnackBar 应消失');
        expect(await countMessages(), 3, reason: '消息全部恢复');
        final anchors =
            await db.rawQuery('SELECT COUNT(*) AS c FROM task_anchors');
        expect((anchors.first['c'] as num).toInt(), 2, reason: '锚点全部恢复');
        expect(await countUndoRows(), 0, reason: '备份清空');
      });
    });
  });
}
