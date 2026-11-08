import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart'
    show anchor, anchorId1, anchorId2, anchorId3, createBaseTables, insertMessage, insertTask;

/// 删除任务的撤销快照（v12 对象级锚点，anchors-v2.md §2）：
/// 锚点不入正文，deleteTasks 只删任务行 + 锚点行（正文不动），
/// 快照只记锚点行（bodies 恒空）；撤销 = 回插任务行 + 锚点行。
/// 旧版快照 payload（bodies 含行内 marker 正文）仍兼容：回写前剥离 marker。
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

  test('单任务单锚点：删除→撤销后任务行/锚点行复原，正文全程不动', () async {
    const body = '记得买菜';
    await insertMessage(db, 'm1', body);
    await insertTask(db, 't1', title: '买菜');
    await appDb.insertAnchor(anchor(anchorId1, 't1', 'm1', label: '买菜'));
    final task = (await appDb.getTaskById('t1'))!;

    final snap = await appDb.snapshotTaskDeletion(['t1']);
    expect(snap.anchors.single.id, anchorId1);
    expect(snap.bodies, isEmpty, reason: '对象级锚点不入正文，正文无快照');

    await appDb.deleteTasks(['t1']);
    expect(await appDb.getTaskById('t1'), isNull);
    expect(await appDb.anchorsForTask('t1'), isEmpty);
    expect((await messageRow('m1'))['body'], body, reason: '正文不受影响');
    expect((await messageRow('m1'))['edited_at'], isNull);

    // 撤销：任务行 + 锚点行复原
    await appDb.insertTask(task);
    await appDb.restoreTaskDeletionSnapshot(snap);

    expect((await appDb.getTaskById('t1'))?.title, '买菜');
    final anchors = await appDb.anchorsForTask('t1');
    expect(anchors.single.id, anchorId1);
    expect(anchors.single.label, '买菜');
    expect((await messageRow('m1'))['body'], body, reason: '正文始终未被改写');
  });

  test('多任务多锚点：message/chapter 锚点全部级联删除并复原', () async {
    await insertMessage(db, 'm1', '正文');
    await db.insert('chapters',
        {'id': 'c1', 'notebook_id': 'nb1', 'name': '章节', 'sort': 0, 'created_at': 1000});
    await insertTask(db, 't1', title: '买菜');
    await insertTask(db, 't2', title: '开会');
    await appDb.insertAnchor(anchor(anchorId1, 't1', 'm1', label: '买菜'));
    await appDb.insertAnchor(
        anchor(anchorId2, 't2', 'm1', label: '开会', createdAt: 1001));
    await appDb.insertAnchor(anchor(anchorId3, 't1', 'c1',
        targetType: AnchorTargetType.chapter, label: '买菜', createdAt: 1002));
    final t1 = (await appDb.getTaskById('t1'))!;
    final t2 = (await appDb.getTaskById('t2'))!;

    final snap = await appDb.snapshotTaskDeletion(['t1', 't2']);
    expect(snap.anchors, hasLength(3));
    expect(snap.bodies, isEmpty);

    await appDb.deleteTasks(['t1', 't2']);
    expect(await appDb.allAnchors(), isEmpty);
    expect((await messageRow('m1'))['body'], '正文');

    await appDb.insertTask(t1);
    await appDb.insertTask(t2);
    await appDb.restoreTaskDeletionSnapshot(snap);

    expect(await appDb.allAnchors(), hasLength(3));
    expect((await messageRow('m1'))['body'], '正文');
  });

  test('file 锚点：删除后撤销回插锚点行', () async {
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

  test('旧版快照兼容：bodies 含行内 marker 的正文，回写前剥离 marker', () async {
    // 模拟 v11 及之前落库的撤销 payload（正文带 ⟦task:id⟧ marker）
    await insertMessage(db, 'm1', '当前正文');
    const legacy = TaskDeletionSnapshot(
      anchors: [],
      bodies: [
        TaskDeletionBodySnapshot(
          targetType: AnchorTargetType.message,
          targetId: 'm1',
          content: '记得买菜 ⟦task:$anchorId1⟧',
          editedAt: 12345,
        ),
      ],
    );

    await appDb.restoreTaskDeletionSnapshot(legacy);
    final row = await messageRow('m1');
    expect(row['body'], '记得买菜', reason: '回写前剥离 marker');
    expect(row['edited_at'], 12345);
  });

  test('快照 JSON 序列化往返（提案 _undo payload 落库路径）', () async {
    await insertMessage(db, 'm1', '记得买菜');
    await insertTask(db, 't1', title: '买菜');
    await appDb.insertAnchor(anchor(anchorId1, 't1', 'm1', label: '买菜'));

    final snap = await appDb.snapshotTaskDeletion(['t1']);
    final roundTripped = TaskDeletionSnapshot.fromJson(
        (jsonDecode(jsonEncode(snap.toJson())) as Map).cast<String, dynamic>());

    expect(roundTripped.anchors.single.id, anchorId1);
    expect(roundTripped.anchors.single.taskId, 't1');
    expect(roundTripped.anchors.single.label, '买菜');
    expect(roundTripped.bodies, isEmpty);

    // 用往返后的快照执行恢复，行为一致
    await appDb.deleteTasks(['t1']);
    await appDb.restoreTaskDeletionSnapshot(roundTripped);
    expect((await appDb.anchorsForTask('t1')).single.id, anchorId1);
    expect((await messageRow('m1'))['body'], '记得买菜');
  });
}
