import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// v11 → v12 迁移回归（crdt.md §7 + anchors-v2.md §6）：
/// op_log 建表；行内 marker 剥离 + content_hash 重算；note 锚点转章节级
///（悬挂删除）；同三元组锚点去重留最早；无 marker 数据原样通过。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const a1 = '11111111-1111-4111-8111-111111111111';
  const a2 = '22222222-2222-4222-8222-222222222222';
  const a3 = '33333333-3333-4333-8333-333333333333';
  const a4 = '44444444-4444-4444-8444-444444444444';

  /// 造 v11 形态的库（无 op_log，正文可含行内 marker，锚点可指向 note）。
  Future<Database> v11Db() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE messages(
        id TEXT PRIMARY KEY, package_name TEXT NOT NULL, app_name TEXT,
        channel_id TEXT, conversation_title TEXT, sender TEXT,
        title TEXT NOT NULL, body TEXT NOT NULL, posted_at INTEGER NOT NULL,
        capture_type TEXT NOT NULL, import_source TEXT,
        attachments TEXT NOT NULL DEFAULT '[]',
        content_hash TEXT NOT NULL UNIQUE,
        status TEXT NOT NULL DEFAULT 'pending',
        priority TEXT NOT NULL DEFAULT 'none',
        linked_task_id TEXT, edited_at INTEGER, created_at INTEGER NOT NULL)
    ''');
    await db.execute(
        "CREATE TABLE notes(id TEXT PRIMARY KEY, chapter_id TEXT NOT NULL, title TEXT NOT NULL, content TEXT NOT NULL DEFAULT '', content_format TEXT NOT NULL DEFAULT 'plain', attachments TEXT NOT NULL DEFAULT '[]', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)");
    await db.execute(
        'CREATE TABLE chapters(id TEXT PRIMARY KEY, notebook_id TEXT NOT NULL, name TEXT NOT NULL, sort INTEGER NOT NULL, created_at INTEGER NOT NULL)');
    await createV8Tables(db);
    return db;
  }

  Future<void> insertMsg(Database db, String id, String body) =>
      db.insert('messages', {
        'id': id,
        'package_name': 'com.test',
        'title': '标题$id',
        'body': body,
        'posted_at': 2000,
        'capture_type': 'notification',
        'content_hash': 'stale-$id',
        'created_at': 2000,
      });

  Future<void> insertAnchorRow(Database db, String id, String targetType,
          String targetId, int createdAt) =>
      db.insert('task_anchors', {
        'id': id,
        'task_id': 't1',
        'target_type': targetType,
        'target_id': targetId,
        'label': '标签$id',
        'created_by': 'user',
        'created_at': createdAt,
      });

  Future<Map<String, Object?>> row(
          Database db, String table, String id) async =>
      (await db.query(table, where: 'id = ?', whereArgs: [id])).single;

  test('marker 剥离 + content_hash 重算；无 marker 正文原样通过', () async {
    final db = await v11Db();
    await insertMsg(db, 'm1', '记得买菜 ⟦task:$a1⟧');
    await insertMsg(db, 'm2', '纯文本');

    await migrateToV12(db);

    final m1 = await row(db, 'messages', 'm1');
    expect(m1['body'], '记得买菜', reason: 'marker 连同前导空格剥离');
    expect(
        m1['content_hash'],
        computeContentHash('com.test', '标题m1', '记得买菜', 2000),
        reason: '哈希按剥离后明文重算');
    expect((await row(db, 'messages', 'm2'))['body'], '纯文本');
    // op_log 表已建
    await db.query('op_log');
    await db.close();
  });

  test('note 锚点转章节级；悬挂 note 锚点删除；notes 正文 marker 剥离', () async {
    final db = await v11Db();
    await db.insert('chapters', {
      'id': 'c1', 'notebook_id': 'nb1', 'name': '章', 'sort': 0,
      'created_at': 1000,
    });
    await db.insert('notes', {
      'id': 'n1', 'chapter_id': 'c1', 'title': '笔记',
      'content': '正文 ⟦task:$a3⟧', 'created_at': 1000, 'updated_at': 1000,
    });
    await insertAnchorRow(db, a3, 'note', 'n1', 1000);
    await insertAnchorRow(db, a4, 'note', 'ghost-note', 1001);

    await migrateToV12(db);

    final a = await row(db, 'task_anchors', a3);
    expect(a['target_type'], 'chapter');
    expect(a['target_id'], 'c1', reason: '改挂到笔记所属章节');
    expect(await db.query('task_anchors', where: 'id = ?', whereArgs: [a4]),
        isEmpty,
        reason: '目标笔记不存在 → 悬挂锚点删除');
    expect((await row(db, 'notes', 'n1'))['content'], '正文');
    await db.close();
  });

  test('同三元组锚点去重，保留最早 created_at', () async {
    final db = await v11Db();
    await insertMsg(db, 'm1', '正文');
    await insertAnchorRow(db, a1, 'message', 'm1', 1002); // 晚
    await insertAnchorRow(db, a2, 'message', 'm1', 1000); // 早，保留
    await insertAnchorRow(db, a3, 'message', 'm1', 1001);

    await migrateToV12(db);

    final anchors = await db.query('task_anchors');
    expect(anchors, hasLength(1));
    expect(anchors.single['id'], a2);
    await db.close();
  });

  test('迁移幂等：再跑一遍不炸、结果不变', () async {
    final db = await v11Db();
    await insertMsg(db, 'm1', '记得买菜 ⟦task:$a1⟧');
    await insertAnchorRow(db, a1, 'message', 'm1', 1000);

    await migrateToV12(db);
    await migrateToV12(db);

    expect((await row(db, 'messages', 'm1'))['body'], '记得买菜');
    expect(await db.query('task_anchors'), hasLength(1));
    await db.close();
  });
}
