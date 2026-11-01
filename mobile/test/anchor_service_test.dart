import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/anchor_service.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 锚点服务回归（design-v3-details §1.5）：
/// 插入（anchorText 首次出现处之后 / 多处取第一处并注明 / 定位失败报错 /
/// 缺省追加到末尾）、移除（marker 清除 + edited_at 留痕 + content_hash 重算）、
/// 文件锚点只落表、残迹化、渲染预取缓存。
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
      "CREATE TABLE notes(id TEXT PRIMARY KEY, chapter_id TEXT NOT NULL, title TEXT NOT NULL, content TEXT NOT NULL DEFAULT '', content_format TEXT NOT NULL DEFAULT 'plain', attachments TEXT NOT NULL DEFAULT '[]', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)");
  await createV8Tables(db);
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
    svc.clearCache();
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

  test('插入：anchorText 首次出现处之后插入 marker', () async {
    await insertMessage('m1', '记得买菜，顺路取快递');
    final r = await svc.insertAnchor(
        taskId: 't1',
        targetType: AnchorTargetType.message,
        targetId: 'm1',
        anchorText: '买菜');
    expect(r.ok, isTrue);
    expect(r.multipleMatches, isFalse);
    expect(await bodyOf('m1'), '记得买菜⟦task:${r.anchor!.id}⟧，顺路取快递');

    final row = await appDb.getAnchorById(r.anchor!.id);
    expect(row?.taskId, 't1');
    expect(row?.label, '买菜', reason: 'label 缺省取任务标题快照');
    expect(row?.createdBy, AnchorCreatedBy.user);
    // 受限写入留痕
    final msg = await appDb.getMessageById('m1');
    expect(msg, isNotNull);
    final edited = (await db.query('messages', where: "id = 'm1'"))
        .single['edited_at'];
    expect(edited, isNotNull);
  });

  test('插入：多处出现取第一处并注明', () async {
    await insertMessage('m1', '买牛奶和买面包都要买');
    final r = await svc.insertAnchor(
        taskId: 't1',
        targetType: AnchorTargetType.message,
        targetId: 'm1',
        anchorText: '买');
    expect(r.ok, isTrue);
    expect(r.multipleMatches, isTrue, reason: '多处出现要在结果里注明');
    expect(await bodyOf('m1'), '买⟦task:${r.anchor!.id}⟧牛奶和买面包都要买');
  });

  test('插入：定位失败返回错误，不落任何写入', () async {
    await insertMessage('m1', '正文里没有那个词');
    final r = await svc.insertAnchor(
        taskId: 't1',
        targetType: AnchorTargetType.message,
        targetId: 'm1',
        anchorText: '不存在');
    expect(r.ok, isFalse);
    expect(r.error, contains('定位失败'));
    expect(await bodyOf('m1'), '正文里没有那个词');
    expect(await appDb.anchorsForTask('t1'), isEmpty);
  });

  test('插入：anchorText 缺省时追加到正文末尾（空格分隔）', () async {
    await insertMessage('m1', '记得买菜');
    final r = await svc.insertAnchor(
        taskId: 't1',
        targetType: AnchorTargetType.message,
        targetId: 'm1');
    expect(await bodyOf('m1'), '记得买菜 ⟦task:${r.anchor!.id}⟧');

    await insertMessage('m2', '');
    final r2 = await svc.insertAnchor(
        taskId: 't1',
        targetType: AnchorTargetType.message,
        targetId: 'm2');
    expect(await bodyOf('m2'), '⟦task:${r2.anchor!.id}⟧',
        reason: '空正文直接放 marker，不留前导空格');
  });

  test('笔记锚点：写入 notes.content 并刷新 updated_at', () async {
    await db.insert('notes', {
      'id': 'n1',
      'chapter_id': 'c1',
      'title': '笔记',
      'content': '周三之前交初稿',
      'created_at': 1000,
      'updated_at': 1000,
    });
    final r = await svc.insertAnchor(
        taskId: 't1',
        targetType: AnchorTargetType.note,
        targetId: 'n1',
        anchorText: '初稿');
    expect(r.ok, isTrue);
    final note = (await db.query('notes')).single;
    expect(note['content'], '周三之前交初稿⟦task:${r.anchor!.id}⟧');
    expect((note['updated_at'] as int) > 1000, isTrue);
  });

  test('文件锚点：只落表行，不动内容', () async {
    final r = await svc.insertAnchor(
        taskId: 't1', targetType: AnchorTargetType.file, targetId: 'f1');
    expect(r.ok, isTrue);
    final row = await appDb.getAnchorById(r.anchor!.id);
    expect(row?.targetType, AnchorTargetType.file);
  });

  test('移除：marker 清除、锚点行删除，正文与 content_hash 复原', () async {
    const original = '记得买菜';
    await insertMessage('m1', original);
    final hashBefore = (await db.query('messages', where: "id = 'm1'"))
        .single['content_hash'];

    final r = await svc.insertAnchor(
        taskId: 't1',
        targetType: AnchorTargetType.message,
        targetId: 'm1');
    expect(await bodyOf('m1'), isNot(original));

    final removed = await svc.removeAnchor(r.anchor!.id);
    expect(removed, isTrue);
    expect(await bodyOf('m1'), original);
    expect(await appDb.getAnchorById(r.anchor!.id), isNull);
    final row = (await db.query('messages', where: "id = 'm1'")).single;
    expect(row['content_hash'], hashBefore,
        reason: '插入→移除往返后 content_hash 不变（§1.4 测试点）');
  });

  test('移除不存在的锚点返回 false', () async {
    expect(await svc.removeAnchor('00000000-0000-4000-8000-000000000000'),
        isFalse);
  });

  test('残迹化：该任务所有 marker 替换为 [任务:label] 纯文本', () async {
    await insertMessage('m1', '记得买菜');
    await insertMessage('m2', '别忘了买菜');
    final r1 = await svc.insertAnchor(
        taskId: 't1',
        targetType: AnchorTargetType.message,
        targetId: 'm1');
    final r2 = await svc.insertAnchor(
        taskId: 't1',
        targetType: AnchorTargetType.message,
        targetId: 'm2',
        anchorText: '买菜');

    await svc.residualizeForTask('t1');

    expect(await bodyOf('m1'), '记得买菜 [任务:买菜]');
    expect(await bodyOf('m2'), '别忘了买菜[任务:买菜]');
    expect(anchorMarkerPattern.hasMatch(await bodyOf('m1')), isFalse,
        reason: '不留死 id');
    expect(await appDb.anchorsForTask('t1'), isEmpty);
    expect(r1.anchor, isNotNull);
    expect(r2.anchor, isNotNull);
  });

  test('渲染预取：按正文批量提取 marker id → 批量联查入缓存', () async {
    await insertMessage('m1', '记得买菜');
    final r = await svc.insertAnchor(
        taskId: 't1',
        targetType: AnchorTargetType.message,
        targetId: 'm1');
    svc.clearCache();

    final map = await svc.prefetchForBodies(
        [await bodyOf('m1'), '没有 marker 的正文']);
    expect(map.keys, [r.anchor!.id]);
    expect(map[r.anchor!.id]?.taskId, 't1');
    // 二次预取命中缓存（id 仍返回）
    final again = await svc.prefetchForBodies([await bodyOf('m1')]);
    expect(again.keys, [r.anchor!.id]);
  });
}
