import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart'
    show anchor, anchorId1, anchorId2, anchorId3, createBaseTables, insertMessage, insertTask;

/// 删除任务的完整撤销快照（details §1.5 撤销补全，v3 收尾）：
/// deleteTasks 事务内会残迹化锚点（正文 marker → [任务:label] 纯文本、
/// 删锚点行），撤销必须同时恢复 任务行 + task_anchors 行 + 受影响正文原文
/// （marker 精确复原、content_hash 一并复原、edited_at/updated_at 写回原值）。
/// 用 sqflite_common_ffi 跑真 SQLite，不依赖手机。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  final appDb = AppDatabase.instance;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createBaseTables(db);
    appDb.debugAttachDatabase(db);
  });

  tearDown(() async {
    // 任务写操作会起 400ms 的重排 timer；等它跑完再关内存库
    await Future<void>.delayed(const Duration(milliseconds: 450));
    appDb.debugDetachDatabase();
    await db.close();
  });

  Future<Map<String, Object?>> messageRow(String id) async =>
      (await db.query('messages', where: 'id = ?', whereArgs: [id])).single;

  test('单任务单锚点：删除→撤销后任务行/锚点行/正文 marker/content_hash/edited_at 全部复原',
      () async {
    const origBody = '记得买菜 ⟦task:$anchorId1⟧';
    await insertMessage(db, 'm1', origBody);
    await db.update('messages', {'edited_at': 12345},
        where: 'id = ?', whereArgs: ['m1']);
    await insertTask(db, 't1', title: '买菜');
    await appDb.insertAnchor(anchor(anchorId1, 't1', 'm1', label: '买菜'));
    final task = (await appDb.getTaskById('t1'))!;
    final hashBefore =
        computeContentHash('com.test', '标题m1', origBody, 2000);

    final snap = await appDb.snapshotTaskDeletion(['t1']);
    expect(snap.anchors.single.id, anchorId1);
    expect(snap.bodies.single.targetId, 'm1');

    await appDb.deleteTasks(['t1']);
    // 删除后：任务行/锚点行删除，正文残迹化且留痕（edited_at 被刷新）
    expect(await appDb.getTaskById('t1'), isNull);
    expect(await appDb.anchorsForTask('t1'), isEmpty);
    final deleted = await messageRow('m1');
    expect(deleted['body'], '记得买菜 [任务:买菜]');
    expect(deleted['edited_at'], isNot(12345));

    // 撤销：任务行 + 快照整体复原
    await appDb.insertTask(task);
    await appDb.restoreTaskDeletionSnapshot(snap);

    expect((await appDb.getTaskById('t1'))?.title, '买菜');
    final anchors = await appDb.anchorsForTask('t1');
    expect(anchors.single.id, anchorId1);
    expect(anchors.single.label, '买菜');
    final restored = await messageRow('m1');
    expect(restored['body'], origBody, reason: 'marker 精确复原');
    expect(restored['content_hash'], hashBefore, reason: 'content_hash 一并复原');
    expect(restored['edited_at'], 12345, reason: 'edited_at 复原回删除前的值');
  });

  test('多任务多锚点交叉：同一正文含多个被删任务的锚点，整段原文回写天然正确', () async {
    const origMsg = '正文 ⟦task:$anchorId1⟧ 中段 ⟦task:$anchorId2⟧';
    const origNote = '笔记 ⟦task:$anchorId3⟧ 尾';
    await insertMessage(db, 'm1', origMsg); // edited_at 缺省为 null
    await db.insert('notes', {
      'id': 'n1',
      'chapter_id': 'c1',
      'title': '笔记',
      'content': origNote,
      'created_at': 1000,
      'updated_at': 777,
    });
    await insertTask(db, 't1', title: '买菜');
    await insertTask(db, 't2', title: '开会');
    await appDb.insertAnchor(anchor(anchorId1, 't1', 'm1', label: '买菜'));
    await appDb.insertAnchor(
        anchor(anchorId2, 't2', 'm1', label: '开会', createdAt: 1001));
    await appDb.insertAnchor(anchor(anchorId3, 't1', 'n1',
        targetType: AnchorTargetType.note, label: '买菜', createdAt: 1002));
    final t1 = (await appDb.getTaskById('t1'))!;
    final t2 = (await appDb.getTaskById('t2'))!;

    final snap = await appDb.snapshotTaskDeletion(['t1', 't2']);
    expect(snap.anchors, hasLength(3));
    expect(snap.bodies, hasLength(2), reason: '同一正文只记一份原文（按目标去重）');

    await appDb.deleteTasks(['t1', 't2']);
    expect((await messageRow('m1'))['body'], '正文 [任务:买菜] 中段 [任务:开会]');
    expect((await appDb.getNoteById('n1'))!.content, '笔记 [任务:买菜] 尾');
    expect(await appDb.allAnchors(), isEmpty);

    await appDb.insertTask(t1);
    await appDb.insertTask(t2);
    await appDb.restoreTaskDeletionSnapshot(snap);

    expect((await messageRow('m1'))['body'], origMsg);
    expect((await messageRow('m1'))['edited_at'], isNull,
        reason: '删除前 edited_at 为 null，复原后仍为 null');
    final note = (await appDb.getNoteById('n1'))!;
    expect(note.content, origNote);
    expect(note.updatedAt, 777, reason: 'updated_at 复原回删除前的值');
    expect(await appDb.allAnchors(), hasLength(3));
  });

  test('file 锚点：不入正文快照，撤销仅回插锚点行', () async {
    await insertTask(db, 't1', title: '看文件');
    await appDb.insertAnchor(anchor(anchorId1, 't1', 'f1',
        targetType: AnchorTargetType.file, label: '看文件'));
    final task = (await appDb.getTaskById('t1'))!;

    final snap = await appDb.snapshotTaskDeletion(['t1']);
    expect(snap.anchors.single.targetType, AnchorTargetType.file);
    expect(snap.bodies, isEmpty);

    await appDb.deleteTasks(['t1']);
    expect(await appDb.allAnchors(), isEmpty);

    await appDb.insertTask(task);
    await appDb.restoreTaskDeletionSnapshot(snap);
    expect((await appDb.anchorsForTask('t1')).single.id, anchorId1);
  });

  test('无锚点任务：快照为空，restore 为 no-op', () async {
    await insertTask(db, 't1', title: '孤立任务');
    final snap = await appDb.snapshotTaskDeletion(['t1']);
    expect(snap.anchors, isEmpty);
    expect(snap.bodies, isEmpty);
    await appDb.deleteTasks(['t1']);
    await appDb.restoreTaskDeletionSnapshot(snap); // 不抛异常即可
  });

  test('快照 JSON 序列化往返（提案 _undo payload 落库路径）', () async {
    await insertMessage(db, 'm1', '记得买菜 ⟦task:$anchorId1⟧');
    await insertTask(db, 't1', title: '买菜');
    await appDb.insertAnchor(anchor(anchorId1, 't1', 'm1', label: '买菜'));

    final snap = await appDb.snapshotTaskDeletion(['t1']);
    final roundTripped = TaskDeletionSnapshot.fromJson(
        (jsonDecode(jsonEncode(snap.toJson())) as Map).cast<String, dynamic>());

    expect(roundTripped.anchors.single.id, anchorId1);
    expect(roundTripped.anchors.single.taskId, 't1');
    expect(roundTripped.anchors.single.label, '买菜');
    expect(roundTripped.bodies.single.targetType, AnchorTargetType.message);
    expect(roundTripped.bodies.single.content, '记得买菜 ⟦task:$anchorId1⟧');

    // 用往返后的快照执行恢复，行为一致
    await appDb.deleteTasks(['t1']);
    await appDb.restoreTaskDeletionSnapshot(roundTripped);
    expect((await messageRow('m1'))['body'], '记得买菜 ⟦task:$anchorId1⟧');
    expect((await appDb.anchorsForTask('t1')).single.id, anchorId1);
  });
}
