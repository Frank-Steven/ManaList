import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// O03 数据层回归（2026-10-21）：通知队列的「批量去重插入」。
///
/// 覆盖：条数、插入顺序（rowid = 入参顺序）、批内同 hash 只留第一条、
/// 库里已有 hash 跳过且不覆盖、分块查重（>400）、以及「确实跑在调用方事务里」
/// 的整体回滚。用 sqflite_common_ffi 跑真 SQLite，不依赖手机。
Message msg({
  required String id,
  required String hash,
  String? title,
  int postedAt = 1700000000000,
}) =>
    Message(
      id: id,
      packageName: 'com.tencent.mm',
      appName: '微信',
      title: title ?? id,
      body: 'body-$id',
      postedAt: postedAt,
      captureType: 'notification',
      contentHash: hash,
      createdAt: postedAt,
    );

/// 与 database.dart _createV4Tables 里的 messages 表保持一致（只留本测试要用的列，
/// content_hash 的 UNIQUE 必须保留，它参与去重语义）。
Future<void> createMessagesTable(Database db) async {
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
}

Future<List<String>> idsInInsertOrder(Database db, {int? limit}) async {
  final rows = await db.query('messages',
      columns: ['id'], orderBy: 'rowid', limit: limit);
  return [for (final r in rows) r['id'] as String];
}

void main() {
  sqfliteFfiInit();

  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createMessagesTable(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('全是新消息：返回条数正确，插入顺序 = 入参顺序', () async {
    final inserted = await db.transaction((txn) => insertMessagesIfNewInto(txn, [
          msg(id: 'a', hash: 'h1'),
          msg(id: 'b', hash: 'h2'),
          msg(id: 'c', hash: 'h3'),
        ]));
    expect(inserted, 3);
    expect(await idsInInsertOrder(db), ['a', 'b', 'c']);
  });

  test('批内同 hash 只留第一条（与逐条 check-then-insert 等价）', () async {
    final inserted = await db.transaction((txn) => insertMessagesIfNewInto(txn, [
          msg(id: 'first', hash: 'dup', title: '第一次'),
          msg(id: 'second', hash: 'dup', title: '第二次'),
          msg(id: 'other', hash: 'h9'),
        ]));
    expect(inserted, 2, reason: 'dup 只算一条，other 一条');
    expect(await idsInInsertOrder(db), ['first', 'other']);
    final rows = await db.query('messages',
        columns: ['title'], where: 'id = ?', whereArgs: ['first']);
    expect(rows.first['title'], '第一次', reason: '先到先得，后到的同内容不应覆盖');
  });

  test('库里已有的 hash 被跳过，且不覆盖原行', () async {
    await db.insert('messages', msg(id: 'old', hash: 'h1', title: '旧内容').toRow());
    final inserted = await db.transaction((txn) => insertMessagesIfNewInto(txn, [
          msg(id: 'dup', hash: 'h1', title: '新内容'),
          msg(id: 'new', hash: 'h2', title: '新条目'),
        ]));
    expect(inserted, 1);
    expect(await idsInInsertOrder(db), ['old', 'new']);
    final rows = await db.query('messages',
        columns: ['title'], where: 'id = ?', whereArgs: ['old']);
    expect(rows.first['title'], '旧内容');
  });

  test('空列表：返回 0 且不写库', () async {
    expect(await insertMessagesIfNewInto(db, const <Message>[]), 0);
    expect(await db.query('messages'), isEmpty);
  });

  test('确实跑在调用方事务里：中途抛错整批回滚', () async {
    await expectLater(
      db.transaction((txn) async {
        await insertMessagesIfNewInto(
            txn, [msg(id: 'a', hash: 'h1'), msg(id: 'b', hash: 'h2')]);
        throw StateError('boom');
      }),
      throwsA(isA<StateError>()),
    );
    expect(await db.query('messages'), isEmpty,
        reason: '若函数自己提交过，这里会看到 2 行');
  });

  test('超过分块阈值（900 条 / 每块 400）不丢不重，顺序保持', () async {
    final many = [
      for (var i = 0; i < 900; i++) msg(id: 'm$i', hash: 'hash$i'),
    ];
    final inserted =
        await db.transaction((txn) => insertMessagesIfNewInto(txn, many));
    expect(inserted, 900);
    expect((await idsInInsertOrder(db)).length, 900);
    expect(await idsInInsertOrder(db, limit: 3), ['m0', 'm1', 'm2']);
  });

  test('分块查重命中：库里已有 500 条时只插剩下的 400 条', () async {
    final many = [
      for (var i = 0; i < 900; i++) msg(id: 'm$i', hash: 'hash$i'),
    ];
    // 先把前 500 条落库（模拟上一轮已入库）
    await db.transaction(
        (txn) => insertMessagesIfNewInto(txn, many.sublist(0, 500)));
    final inserted =
        await db.transaction((txn) => insertMessagesIfNewInto(txn, many));
    expect(inserted, 400);
    expect((await idsInInsertOrder(db)).length, 900);
    expect(await idsInInsertOrder(db, limit: 1), ['m0'],
        reason: '已存在的行不被重排/覆盖');
  });
}
