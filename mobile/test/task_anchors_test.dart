import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// v8 任务锚点 DAO 回归（取代 v6 的 message_task_links_test）：
/// task_anchors CRUD、双向查询（按 taskId / 按 target）、列表映射、
/// tasksForMessage/messagesForTask，以及删除消息/笔记/任务时的锚点清理。
/// 用 sqflite_common_ffi 跑真 SQLite，不依赖手机。
const anchorId1 = '11111111-1111-4111-8111-111111111111';
const anchorId2 = '22222222-2222-4222-8222-222222222222';
const anchorId3 = '33333333-3333-4333-8333-333333333333';

TaskAnchor anchor(String id, String taskId, String targetId,
        {String targetType = AnchorTargetType.message,
        String? label,
        int createdAt = 1000}) =>
    TaskAnchor(
      id: id,
      taskId: taskId,
      targetType: targetType,
      targetId: targetId,
      label: label,
      createdBy: AnchorCreatedBy.user,
      createdAt: createdAt,
    );

Future<void> createBaseTables(Database db) async {
  await db.execute('''
    CREATE TABLE messages(
      id TEXT PRIMARY KEY,
      package_name TEXT NOT NULL,
      app_name TEXT,
      channel_id TEXT,
      conversation_title TEXT,
      sender TEXT,
      title TEXT NOT NULL,
      body TEXT NOT NULL,
      posted_at INTEGER NOT NULL,
      capture_type TEXT NOT NULL,
      import_source TEXT,
      attachments TEXT NOT NULL DEFAULT '[]',
      content_hash TEXT NOT NULL UNIQUE,
      status TEXT NOT NULL DEFAULT 'pending',
      priority TEXT NOT NULL DEFAULT 'none',
      linked_task_id TEXT,
      edited_at INTEGER,
      created_at INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE tasks(
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      description TEXT,
      kind TEXT NOT NULL,
      start_at INTEGER,
      end_at INTEGER,
      priority TEXT NOT NULL DEFAULT 'normal',
      is_annual INTEGER NOT NULL DEFAULT 0,
      source_message_id TEXT,
      status TEXT NOT NULL DEFAULT 'active',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      parent_id TEXT
    )
  ''');
  await db.execute(
      "CREATE TABLE notes(id TEXT PRIMARY KEY, chapter_id TEXT NOT NULL, title TEXT NOT NULL, content TEXT NOT NULL DEFAULT '', content_format TEXT NOT NULL DEFAULT 'plain', attachments TEXT NOT NULL DEFAULT '[]', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)");
  await createV8Tables(db);
}

Future<void> insertMessage(Database db, String id, String body) =>
    db.insert('messages', {
      'id': id,
      'package_name': 'com.test',
      'title': '标题$id',
      'body': body,
      'posted_at': 2000,
      'capture_type': 'notification',
      'content_hash': 'hash-$id',
      'created_at': 2000,
    });

Future<void> insertTask(Database db, String id,
        {String? title, int? startAt}) =>
    db.insert('tasks', {
      'id': id,
      'title': title ?? '任务$id',
      'kind': 'point',
      'start_at': startAt,
      'priority': 'normal',
      'status': 'active',
      'created_at': 1000,
      'updated_at': 1000,
    });

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
    // deleteTasks 会起 400ms 的重排 timer；等它跑完再关内存库
    await Future<void>.delayed(const Duration(milliseconds: 450));
    appDb.debugDetachDatabase();
    await db.close();
  });

  test('CRUD：插入/按 id 查/按任务查/按目标查/删除', () async {
    await appDb.insertAnchor(anchor(anchorId1, 't1', 'm1', label: '买菜'));
    await appDb.insertAnchor(anchor(anchorId2, 't1', 'n1',
        targetType: AnchorTargetType.note, createdAt: 1001));
    await appDb.insertAnchor(anchor(anchorId3, 't2', 'm1', createdAt: 1002));

    final byId = await appDb.getAnchorById(anchorId1);
    expect(byId?.taskId, 't1');
    expect(byId?.label, '买菜');

    final forT1 = await appDb.anchorsForTask('t1');
    expect(forT1.map((a) => a.id), [anchorId1, anchorId2]);

    final forM1 =
        await appDb.anchorsForTarget(AnchorTargetType.message, 'm1');
    expect(forM1.map((a) => a.id), [anchorId1, anchorId3]);
    // targetType 隔离：笔记 n1 不混进消息查询
    final forN1 = await appDb.anchorsForTarget(AnchorTargetType.note, 'n1');
    expect(forN1.single.id, anchorId2);

    final batch = await appDb.anchorsByIds([anchorId1, anchorId3, 'missing']);
    expect(batch.map((a) => a.id), containsAll([anchorId1, anchorId3]));

    await appDb.deleteAnchor(anchorId1);
    expect(await appDb.getAnchorById(anchorId1), isNull);
    expect((await appDb.anchorsForTask('t1')).map((a) => a.id), [anchorId2]);
  });

  test('列表映射：messageAnchorTaskIds / taskAnchorMessageIds', () async {
    await appDb.insertAnchor(anchor(anchorId1, 't1', 'm1'));
    await appDb.insertAnchor(anchor(anchorId2, 't2', 'm1', createdAt: 1001));
    await appDb.insertAnchor(anchor(anchorId3, 't1', 'm2', createdAt: 1002));

    final byMessage = await appDb.messageAnchorTaskIds();
    expect(byMessage['m1'], ['t1', 't2']);
    expect(byMessage['m2'], ['t1']);

    final byTask = await appDb.taskAnchorMessageIds();
    expect(byTask['t1'], ['m1', 'm2']);
    expect(byTask['t2'], ['m1']);
  });

  test('tasksForMessage / messagesForTask 双向联查', () async {
    await insertMessage(db, 'm1', '正文一');
    await insertMessage(db, 'm2', '正文二');
    await insertTask(db, 't1', title: '买菜', startAt: 5000);
    await insertTask(db, 't2', title: '未定时的');
    await appDb.insertAnchor(anchor(anchorId1, 't1', 'm1'));
    await appDb.insertAnchor(anchor(anchorId2, 't2', 'm1', createdAt: 1001));
    await appDb.insertAnchor(anchor(anchorId3, 't1', 'm2', createdAt: 1002));

    final tasks = await appDb.tasksForMessage('m1');
    expect(tasks.map((t) => t.id), ['t1', 't2'], reason: '未定时的排在后面');

    final sources = await appDb.messagesForTask('t1');
    expect(sources.map((m) => m.id), containsAll(['m1', 'm2']));
  });

  test('删除消息级联删锚点行', () async {
    await insertMessage(db, 'm1', '正文');
    await insertTask(db, 't1');
    await appDb.insertAnchor(anchor(anchorId1, 't1', 'm1'));

    await appDb.deleteMessages(['m1']);
    expect(await appDb.anchorsForTask('t1'), isEmpty);
  });

  test('删除笔记级联删锚点行', () async {
    await db.insert('notes', {
      'id': 'n1',
      'chapter_id': 'c1',
      'title': '笔记',
      'created_at': 1000,
      'updated_at': 1000,
    });
    await insertTask(db, 't1');
    await appDb.insertAnchor(anchor(anchorId1, 't1', 'n1',
        targetType: AnchorTargetType.note));

    await appDb.deleteNote('n1');
    expect(await appDb.anchorsForTask('t1'), isEmpty);
  });

  test('删除任务：锚点残迹化（marker → [任务:label] 纯文本）并删锚点行', () async {
    await insertMessage(db, 'm1', '记得买菜 ⟦task:$anchorId1⟧');
    await insertTask(db, 't1', title: '买菜');
    await appDb.insertAnchor(anchor(anchorId1, 't1', 'm1', label: '买菜'));

    await appDb.deleteTasks(['t1']);

    final body = (await db.query('messages', where: "id = 'm1'"))
        .single['body'] as String;
    expect(body, '记得买菜 [任务:买菜]', reason: '内容不留空洞、不留死 id');
    expect(await appDb.anchorsForTask('t1'), isEmpty);
    // 残迹化走受限写入：edited_at 留痕
    expect(
        (await db.query('messages', where: "id = 'm1'"))
            .single['edited_at'],
        isNotNull);
  });

  test('allAnchors 按创建时间全量返回（存档导出用）', () async {
    await appDb.insertAnchor(anchor(anchorId2, 't1', 'm1', createdAt: 1001));
    await appDb.insertAnchor(anchor(anchorId1, 't2', 'm2'));
    final all = await appDb.allAnchors();
    expect(all.map((a) => a.id), [anchorId1, anchorId2]);
  });
}
