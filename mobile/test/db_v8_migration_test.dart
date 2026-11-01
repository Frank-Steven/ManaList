import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// DB v7 → v8 迁移回归（design-v3 §1.5）：
/// message_task_links 全量行 + messages.linked_task_id 非空行 → task_anchors
/// （(message_id, task_id) 去重、悬挂引用跳过、created_by='user'、label=任务标题
/// 快照），marker 以空格分隔追加到消息正文末尾，随后 DROP links 表；
/// notes 加 attachments 列；五张新表建立。
/// 用 sqflite_common_ffi 跑真 SQLite，不依赖手机。
Future<void> createV7Schema(Database db) async {
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
  await createMessageTaskLinksTable(db);
  // v7 的 notes 没有 attachments 列
  await db.execute(
      "CREATE TABLE notes(id TEXT PRIMARY KEY, chapter_id TEXT NOT NULL, title TEXT NOT NULL, content TEXT NOT NULL DEFAULT '', content_format TEXT NOT NULL DEFAULT 'plain', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)");
}

Future<void> insertMessage(Database db, String id, String body,
        {String? linkedTaskId, int createdAt = 2000}) =>
    db.insert('messages', {
      'id': id,
      'package_name': 'com.test',
      'title': '标题$id',
      'body': body,
      'posted_at': createdAt,
      'capture_type': 'notification',
      'content_hash': 'hash-$id',
      'linked_task_id': linkedTaskId,
      'created_at': createdAt,
    });

Future<void> insertTask(Database db, String id, String title) =>
    db.insert('tasks', {
      'id': id,
      'title': title,
      'kind': 'point',
      'priority': 'normal',
      'status': 'active',
      'created_at': 1000,
      'updated_at': 1000,
    });

Future<bool> tableExists(Database db, String name) async {
  final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [name]);
  return rows.isNotEmpty;
}

void main() {
  sqfliteFfiInit();

  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createV7Schema(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('links 与 linked_task_id 都转锚点，按 (message, task) 去重', () async {
    await insertTask(db, 't1', '买菜');
    await insertTask(db, 't2', '取快递');
    await insertMessage(db, 'm1', '记得买菜', createdAt: 2001);
    await insertMessage(db, 'm2', '也别忘了', linkedTaskId: 't1', createdAt: 2002);
    await insertMessage(db, 'm3', '无关联', createdAt: 2003);
    await db.insert('message_task_links',
        {'message_id': 'm1', 'task_id': 't1', 'created_at': 3001});
    await db.insert('message_task_links',
        {'message_id': 'm1', 'task_id': 't2', 'created_at': 3002});
    // 双写残留：m1.linked_task_id = t1 与 links 行重复，应去重
    await db.update('messages', {'linked_task_id': 't1'},
        where: 'id = ?', whereArgs: ['m1']);

    await migrateToV8(db);

    final anchors = await db.query('task_anchors', orderBy: 'created_at ASC');
    expect(anchors.length, 3, reason: 'm1→t1、m1→t2、m2→t1 各一个锚点');
    for (final a in anchors) {
      expect(a['created_by'], 'user');
      expect(a['target_type'], 'message');
      expect(
          a['id'] as String,
          matches(RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')),
          reason: '锚点 id 为小写 uuid');
    }
    final m1t1 = anchors.singleWhere(
        (a) => a['task_id'] == 't1' && a['target_id'] == 'm1');
    expect(m1t1['label'], '买菜', reason: 'label 取任务标题快照');
    expect(m1t1['created_at'], 3001, reason: '沿用关联创建时间');
  });

  test('marker 以空格分隔追加到正文末尾，顺序按关联创建时间', () async {
    await insertTask(db, 't1', '买菜');
    await insertTask(db, 't2', '取快递');
    await insertMessage(db, 'm1', '记得买菜');
    await insertMessage(db, 'm2', '也别忘了', linkedTaskId: 't1');
    await insertMessage(db, 'm3', '无关联');
    await db.insert('message_task_links',
        {'message_id': 'm1', 'task_id': 't1', 'created_at': 3001});
    await db.insert('message_task_links',
        {'message_id': 'm1', 'task_id': 't2', 'created_at': 3002});

    await migrateToV8(db);

    final anchors = await db.query('task_anchors', orderBy: 'created_at ASC');
    final a1 = anchors.singleWhere(
        (a) => a['task_id'] == 't1' && a['target_id'] == 'm1');
    final a2 = anchors.singleWhere((a) => a['task_id'] == 't2');
    final a3 = anchors.singleWhere((a) => a['target_id'] == 'm2');

    final bodies = {
      for (final r in await db.query('messages', columns: ['id', 'body']))
        r['id'] as String: r['body'] as String,
    };
    expect(bodies['m1'],
        '记得买菜 ⟦task:${a1['id']}⟧ ⟦task:${a2['id']}⟧');
    expect(bodies['m2'], '也别忘了 ⟦task:${a3['id']}⟧');
    expect(bodies['m3'], '无关联', reason: '无关联消息正文不动');

    // marker 能被全项目统一正则提取，id 与锚点行一致
    final m1Markers = anchorMarkerPattern
        .allMatches(bodies['m1']!)
        .map((m) => m.group(1)!)
        .toList();
    expect(m1Markers, [a1['id'], a2['id']]);
  });

  test('悬挂引用跳过：任务或消息已删的关联不产生锚点', () async {
    await insertTask(db, 't1', '买菜');
    await insertMessage(db, 'm1', '还在');
    await db.insert('message_task_links',
        {'message_id': 'm1', 'task_id': 't1', 'created_at': 3001});
    await db.insert('message_task_links',
        {'message_id': 'm1', 'task_id': 'ghost-task', 'created_at': 3002});
    await db.insert('message_task_links',
        {'message_id': 'ghost-message', 'task_id': 't1', 'created_at': 3003});
    await insertMessage(db, 'm2', '指向已删任务', linkedTaskId: 'ghost-task');

    await migrateToV8(db);

    final anchors = await db.query('task_anchors');
    expect(anchors.length, 1);
    expect(anchors.single['task_id'], 't1');
    expect(anchors.single['target_id'], 'm1');
    final m2 = (await db.query('messages', where: "id = 'm2'")).single;
    expect(m2['body'], '指向已删任务', reason: '悬挂 linked_task_id 不追加 marker');
  });

  test('完成后 links 表已删，新表全部建立，notes 加 attachments 列', () async {
    await migrateToV8(db);

    expect(await tableExists(db, 'message_task_links'), isFalse);
    for (final t in [
      'task_anchors',
      'files',
      'conversations',
      'chat_messages',
      'change_proposals',
    ]) {
      expect(await tableExists(db, t), isTrue, reason: '缺少新表 $t');
    }

    final noteCols = await db.rawQuery('PRAGMA table_info(notes)');
    expect(noteCols.map((c) => c['name']), contains('attachments'));
    // attachments 缺省空数组
    await db.insert('notes', {
      'id': 'n1',
      'chapter_id': 'c1',
      'title': '笔记',
      'created_at': 1,
      'updated_at': 1,
    });
    final note = (await db.query('notes')).single;
    expect(note['attachments'], '[]');
  });

  test('change_proposals 含 batch_id 列（details §3.1 回写）', () async {
    await migrateToV8(db);
    final cols = await db.rawQuery('PRAGMA table_info(change_proposals)');
    expect(cols.map((c) => c['name']),
        containsAll(['id', 'conversation_id', 'batch_id', 'tool', 'summary', 'payload', 'status', 'created_at', 'resolved_at']));
  });

  test('content_hash 不因迁移改变（marker 尾部空格不参与重算）', () async {
    await insertTask(db, 't1', '买菜');
    await insertMessage(db, 'm1', '记得买菜', linkedTaskId: 't1');

    await migrateToV8(db);

    final row = (await db.query('messages')).single;
    expect(row['content_hash'], 'hash-m1', reason: '迁移不重算 content_hash');
  });
}
