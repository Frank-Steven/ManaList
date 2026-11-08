import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/anchor_service.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/crdt.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 锚点服务回归（anchors-v2.md §2，v12 重写）：
/// 对象级锚点只落 task_anchors 表——插入（存在性校验 / 同三元组幂等去重 /
/// label 缺省取任务标题）、移除（只删行，正文不动）、op_log 双写
/// （or_add / or_remove，crdt.md §4.3）。
/// 用 sqflite_common_ffi 内存库注入 AppDatabase 单例。
Future<void> createSchema(Database db) async {
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
      "CREATE TABLE chapters(id TEXT PRIMARY KEY, notebook_id TEXT NOT NULL, name TEXT NOT NULL, sort INTEGER NOT NULL, created_at INTEGER NOT NULL)");
  await db.execute(
      "CREATE TABLE notes(id TEXT PRIMARY KEY, chapter_id TEXT NOT NULL, title TEXT NOT NULL, content TEXT NOT NULL DEFAULT '', content_format TEXT NOT NULL DEFAULT 'plain', attachments TEXT NOT NULL DEFAULT '[]', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)");
  await createV8Tables(db);
  await createOpLogTable(db);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  final appDb = AppDatabase.instance;
  final svc = AnchorService.instance;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createSchema(db);
    appDb.debugAttachDatabase(db);
    await db.insert('tasks', {
      'id': 't1',
      'title': '买菜',
      'kind': 'point',
      'priority': 'normal',
      'status': 'active',
      'created_at': 1000,
      'updated_at': 1000,
    });
  });

  tearDown(() async {
    appDb.debugDetachDatabase();
    await db.close();
  });

  Future<void> insertMessage(String id, String body) => db.insert('messages', {
        'id': id,
        'package_name': 'com.test',
        'title': '标题$id',
        'body': body,
        'posted_at': 2000,
        'capture_type': 'notification',
        'content_hash': computeContentHash('com.test', '标题$id', body, 2000),
        'created_at': 2000,
      });

  Future<String> bodyOf(String id) async =>
      (await db.query('messages', columns: ['body'], where: 'id = ?', whereArgs: [id]))
          .single['body'] as String;

  test('插入：只落表行，正文不动、edited_at 不留痕', () async {
    await insertMessage('m1', '记得买菜，顺路取快递');
    final r = await svc.insertAnchor(
        taskId: 't1',
        targetType: AnchorTargetType.message,
        targetId: 'm1');
    expect(r.ok, isTrue);
    expect(await bodyOf('m1'), '记得买菜，顺路取快递', reason: '正文完全只读');

    final row = await appDb.getAnchorById(r.anchor!.id);
    expect(row?.taskId, 't1');
    expect(row?.label, '买菜', reason: 'label 缺省取任务标题快照');
    expect(row?.createdBy, AnchorCreatedBy.user);
    expect(
        (await db.query('messages', where: "id = 'm1'")).single['edited_at'],
        isNull,
        reason: '受限写入通道已取消');
  });

  test('插入：同三元组幂等去重，返回既有行', () async {
    await insertMessage('m1', '正文');
    final r1 = await svc.insertAnchor(
        taskId: 't1',
        targetType: AnchorTargetType.message,
        targetId: 'm1');
    final r2 = await svc.insertAnchor(
        taskId: 't1',
        targetType: AnchorTargetType.message,
        targetId: 'm1');
    expect(r2.ok, isTrue);
    expect(r2.alreadyExists, isTrue);
    expect(r2.anchor!.id, r1.anchor!.id);
    expect((await appDb.anchorsForTask('t1')).length, 1);
  });

  test('插入：目标/任务不存在返回错误，不落任何写入', () async {
    final r = await svc.insertAnchor(
        taskId: 't1',
        targetType: AnchorTargetType.message,
        targetId: 'ghost');
    expect(r.ok, isFalse);
    expect(r.error, contains('不存在'));

    await insertMessage('m1', '正文');
    final r2 = await svc.insertAnchor(
        taskId: 'ghost-task',
        targetType: AnchorTargetType.message,
        targetId: 'm1');
    expect(r2.ok, isFalse);
    expect(await appDb.anchorsForTask('t1'), isEmpty);
  });

  test('章节锚点：锚到 chapters.id，不写 notes.content', () async {
    await db.insert('chapters', {
      'id': 'c1',
      'notebook_id': 'nb1',
      'name': '章节',
      'sort': 0,
      'created_at': 1000,
    });
    final r = await svc.insertAnchor(
        taskId: 't1',
        targetType: AnchorTargetType.chapter,
        targetId: 'c1');
    expect(r.ok, isTrue);
    expect(r.anchor!.targetType, AnchorTargetType.chapter);
  });

  test('文件锚点：只落表行', () async {
    await db.insert('files', {
      'id': 'f1',
      'name': '报销单.pdf',
      'local_path': '/tmp/f1',
      'source': 'import',
      'created_at': 1000,
    });
    final r = await svc.insertAnchor(
        taskId: 't1', targetType: AnchorTargetType.file, targetId: 'f1');
    expect(r.ok, isTrue);
    expect((await appDb.getAnchorById(r.anchor!.id))?.targetType,
        AnchorTargetType.file);
  });

  test('移除：只删锚点行，正文与 content_hash 不变', () async {
    const original = '记得买菜';
    await insertMessage('m1', original);
    final hashBefore = (await db.query('messages', where: "id = 'm1'"))
        .single['content_hash'];

    final r = await svc.insertAnchor(
        taskId: 't1',
        targetType: AnchorTargetType.message,
        targetId: 'm1');
    final removed = await svc.removeAnchor(r.anchor!.id);
    expect(removed, isTrue);
    expect(await appDb.getAnchorById(r.anchor!.id), isNull);
    final row = (await db.query('messages', where: "id = 'm1'")).single;
    expect(row['body'], original);
    expect(row['content_hash'], hashBefore);
  });

  test('移除不存在的锚点返回 false', () async {
    expect(await svc.removeAnchor('00000000-0000-4000-8000-000000000000'),
        isFalse);
  });

  test('op_log 双写：or_add / or_remove 落账（crdt.md §4.3）', () async {
    await insertMessage('m1', '正文');
    final r = await svc.insertAnchor(
        taskId: 't1',
        targetType: AnchorTargetType.message,
        targetId: 'm1');
    await svc.removeAnchor(r.anchor!.id);

    final ops = await appDb.recentOps();
    expect(ops.length, 2);
    expect(ops[1]['kind'], OpKind.orAdd, reason: '新的在前，旧的是 or_add');
    expect(ops[1]['target'], 'anchors:t1');
    expect(ops[0]['kind'], OpKind.orRemove);
    // lamport 单调递增
    expect((ops[0]['lamport'] as int) > (ops[1]['lamport'] as int), isTrue);
  });
}
