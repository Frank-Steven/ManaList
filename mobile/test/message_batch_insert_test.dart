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
  String? body,
  String? sender,
  // D01：默认仍是最常见的聊天来源（微信）——既有用例语义不变；
  // 非聊天来源的用例显式传 pkg/app 覆盖。
  String pkg = 'com.tencent.mm',
  String app = '微信',
  int postedAt = 1700000000000,
}) =>
    Message(
      id: id,
      packageName: pkg,
      appName: app,
      sender: sender,
      title: title ?? id,
      body: body ?? 'body-$id',
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
    final inserted =
        await db.transaction((txn) => insertMessagesIfNewInto(txn, [
              msg(id: 'a', hash: 'h1'),
              msg(id: 'b', hash: 'h2'),
              msg(id: 'c', hash: 'h3'),
            ]));
    expect(inserted, 3);
    expect(await idsInInsertOrder(db), ['a', 'b', 'c']);
  });

  test('批内同 hash 只留第一条（与逐条 check-then-insert 等价）', () async {
    final inserted =
        await db.transaction((txn) => insertMessagesIfNewInto(txn, [
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
    await db.insert(
        'messages', msg(id: 'old', hash: 'h1', title: '旧内容').toRow());
    final inserted =
        await db.transaction((txn) => insertMessagesIfNewInto(txn, [
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
    expect(await db.query('messages'), isEmpty, reason: '若函数自己提交过，这里会看到 2 行');
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

  // ---------- D01：非聊天来源 2 秒近重复拦截（2026-11-27，用户选定） ----------
  group('D01 非聊天 2 秒近重复', () {
    /// 天气类来源：每次推送 contentHash 不同（时间戳/计数变化），但内容一致。
    Message weather(String id, int postedAt, {String? body, String? title}) =>
        msg(
          id: id,
          hash: 'w-$id',
          pkg: 'com.huawei.weather',
          app: '天气',
          title: title ?? '深圳',
          body: body ?? '多云 24°C 湿度 60%',
          postedAt: postedAt,
        );

    const base = 1700000000000;

    Future<int> insertAll(List<Message> ms) =>
        db.transaction((txn) => insertMessagesIfNewInto(txn, ms));

    test('天气同 body Δ22ms：只入库 1 行', () async {
      final n = await insertAll([
        weather('w1', base),
        weather('w2', base + 22),
      ]);
      expect(n, 1);
      expect(await idsInInsertOrder(db), ['w1'], reason: '先到先得');
    });

    test('天气同 body Δ23ms：只入库 1 行（同一窗口内）', () async {
      final n = await insertAll([
        weather('w1', base),
        weather('w2', base + 23),
      ]);
      expect(n, 1);
    });

    test('USB 插入/移除同 key Δ1007ms：只入库 1 行', () async {
      Message usb(String id, int at) => msg(
            id: id,
            hash: 'usb-$id',
            pkg: 'android.systemui',
            app: '系统界面',
            title: 'USB',
            body: '已连接 USB 设备',
            postedAt: at,
          );
      final n = await insertAll([usb('u1', base), usb('u2', base + 1007)]);
      expect(n, 1);
    });

    test('音乐同 key Δ1344ms：只入库 1 行', () async {
      Message music(String id, int at) => msg(
            id: id,
            hash: 'm-$id',
            pkg: 'com.netease.cloudmusic',
            app: '网易云音乐',
            title: '晴天',
            body: '正在播放：晴天 - 周杰伦',
            postedAt: at,
          );
      final n =
          await insertAll([music('mu1', base), music('mu2', base + 1344)]);
      expect(n, 1);
    });

    test('边界：Δ2000ms 拦截；Δ2001ms 放行', () async {
      expect(
        await insertAll([
          weather('b1', base),
          weather('b2', base + 2000),
        ]),
        1,
        reason: '窗口含边界（|Δ| <= 2000 拦截）',
      );
      await db.delete('messages');
      expect(
        await insertAll([
          weather('c1', base),
          weather('c2', base + 2001),
        ]),
        2,
        reason: '超出窗口后允许入库',
      );
    });

    test('跨批：上一批已入库，下一批同 key Δ22ms 被拦', () async {
      expect(await insertAll([weather('k1', base)]), 1);
      expect(await insertAll([weather('k2', base + 22)]), 0,
          reason: '库内已存在同 key 近重复 → 跨批也要拦');
      expect(await idsInInsertOrder(db), ['k1']);
    });

    test('同一批内同 key 相差 5s：两条都必须入库（批内不能按 key 一锅端）', () async {
      final n = await insertAll([
        weather('p1', base),
        weather('p2', base + 22), // 窗口内 → 拦
        weather('p3', base + 5022), // 距 p1 5022ms、距 p2 5000ms → 都超窗 → 放行
      ]);
      expect(n, 2, reason: '同批内只拦窗口内的那一条，超出 2s 必须保留');
      expect(await idsInInsertOrder(db), ['p1', 'p3']);
    });

    test('同一批内同 key 相差 3s（>2s）：两条都入库', () async {
      final n = await insertAll([
        weather('q1', base),
        weather('q2', base + 3000),
      ]);
      expect(n, 2, reason: '批内比较同样按 ±2000ms 窗口，不是按 key 去重');
    });

    test('同 key 但相差 > 2s：两批都放行', () async {
      expect(await insertAll([weather('t1', base)]), 1);
      expect(await insertAll([weather('t2', base + 5000)]), 1,
          reason: '超过窗口的再次推送是新的有效信息');
      expect((await idsInInsertOrder(db)).length, 2);
    });

    test('title / body / sender 任一不同都视为不同消息', () async {
      final n = await insertAll([
        weather('d1', base),
        weather('d2', base + 22, title: '广州'),
        weather('d3', base + 23, body: '晴 30°C'),
        msg(
          id: 'd4',
          hash: 'd4',
          pkg: 'com.huawei.weather',
          app: '天气',
          title: '深圳',
          body: '多云 24°C 湿度 60%',
          sender: '小明',
          postedAt: base + 24,
        ),
      ]);
      expect(n, 4, reason: '内容 key 不同 → 都不是近重复');
    });

    test('聊天来源不受影响：微信同 key Δ22ms 仍然两条都入库', () async {
      Message chat(String id, int at) => msg(
            id: id,
            hash: 'chat-$id',
            pkg: 'com.tencent.mm',
            app: '微信',
            title: '张三',
            body: '在吗',
            postedAt: at,
          );
      final n = await insertAll([chat('x1', base), chat('x2', base + 22)]);
      expect(n, 2, reason: '聊天里同一句话连发两次是正常行为，不能拦');
    });

    test('单条 insertMessageIfNew 走同一规则（非聊天 22ms 拦第二条第）', () async {
      final appDb = AppDatabase.instance;
      appDb.debugAttachDatabase(db);
      try {
        expect(await appDb.insertMessageIfNew(weather('s1', base)), isTrue);
        expect(
            await appDb.insertMessageIfNew(weather('s2', base + 22)), isFalse,
            reason: '单条入口必须与批量同一判定');
        expect(
            await appDb.insertMessageIfNew(weather('s3', base + 5000)), isTrue,
            reason: '超出窗口仍然入库');
        expect((await idsInInsertOrder(db)).length, 2);
      } finally {
        appDb.debugDetachDatabase();
      }
    });
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
