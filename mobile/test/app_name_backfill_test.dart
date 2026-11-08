import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables, insertMessage;

/// F2（ux-fixes-2026-11 §2.1）：应用名回填 DAO——只覆盖「未解析」行
/// （null / 空串 / 固化成包名），正常名称与其它包名不受影响。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  final appDb = AppDatabase.instance;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createBaseTables(db);
    // 生产库从 v1 起保留 raw_messages；测试 schema 补一张最小同名列的表
    await db.execute(
        'CREATE TABLE raw_messages(id TEXT PRIMARY KEY, package_name TEXT NOT NULL, app_name TEXT)');
    appDb.debugAttachDatabase(db);
  });

  tearDown(() async {
    appDb.debugDetachDatabase();
    await db.close();
  });

  Future<void> insertWithName(String id, String pkg, String? appName) =>
      db.insert('messages', {
        'id': id,
        'package_name': pkg,
        'app_name': appName,
        'title': '标题$id',
        'body': '正文$id',
        'posted_at': 2000,
        'capture_type': 'notification',
        'content_hash': 'hash-$id',
        'created_at': 2000,
      });

  Future<String?> nameOf(String id) async => (await db
      .query('messages', columns: ['app_name'], where: 'id = ?', whereArgs: [id]))
      .single['app_name'] as String?;

  test('回填只覆盖未解析行，正常名称与其它包名不动', () async {
    await insertWithName('m1', 'com.x', null); // 未设置
    await insertWithName('m2', 'com.x', ''); // 空串
    await insertWithName('m3', 'com.x', 'com.x'); // 固化成包名
    await insertWithName('m4', 'com.x', '已有名称'); // 正常
    await insertWithName('m5', 'com.y', null); // 别的包

    final updated = await appDb.backfillMessageAppName('com.x', '某应用');
    expect(updated, 3);

    expect(await nameOf('m1'), '某应用');
    expect(await nameOf('m2'), '某应用');
    expect(await nameOf('m3'), '某应用');
    expect(await nameOf('m4'), '已有名称');
    expect(await nameOf('m5'), isNull);
  });

  test('raw_messages 同步回填', () async {
    await db.insert('raw_messages',
        {'id': 'r1', 'package_name': 'com.x', 'app_name': 'com.x'});
    await insertMessage(db, 'm9', '正文');

    await appDb.backfillMessageAppName('com.x', '某应用');

    final raw = await db
        .query('raw_messages', where: 'id = ?', whereArgs: ['r1']);
    expect(raw.single['app_name'], '某应用');
  });
}
