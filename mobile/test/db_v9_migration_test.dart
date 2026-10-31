import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// DB v8 → v9 迁移回归：files 加 folder 列（虚拟文件夹，'' = 根目录）、
/// conversations 加 draft_attachments 列（草稿附件 JSON，默认 '[]'）；
/// 迁移幂等（PRAGMA 先查再加）；初始建表（createV8Tables）已带新列，两条路径收敛。
/// 用 sqflite_common_ffi 跑真 SQLite，不依赖手机。

/// v8 形态的 files / conversations（无 v9 新列）。
Future<void> createV8ShapeTables(Database db) async {
  await db.execute('''
    CREATE TABLE files(
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      mime_type TEXT,
      size INTEGER,
      local_path TEXT NOT NULL,
      source TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE conversations(
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      model_config_id TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''');
}

Future<List<String>> columnNames(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return [for (final r in rows) r['name'] as String];
}

void main() {
  sqfliteFfiInit();

  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  });

  tearDown(() async {
    await db.close();
  });

  test('v8 老表迁移后加列，存量行取默认值', () async {
    await createV8ShapeTables(db);
    await db.insert('files', {
      'id': 'f1',
      'name': '报告.pdf',
      'local_path': '/x/f1',
      'source': 'user_upload',
      'created_at': 1000,
    });
    await db.insert('conversations',
        {'id': 'c1', 'title': '对话', 'created_at': 1000, 'updated_at': 1000});

    await migrateToV9(db);

    expect(await columnNames(db, 'files'), contains('folder'));
    expect(await columnNames(db, 'conversations'),
        contains('draft_attachments'));

    final file = (await db.query('files')).single;
    expect(file['folder'], '', reason: '存量文件落根目录');
    final conv = (await db.query('conversations')).single;
    expect(conv['draft_attachments'], '[]', reason: '存量对话无草稿附件');
  });

  test('迁移幂等：重复执行不报错、列不重复', () async {
    await createV8ShapeTables(db);
    await migrateToV9(db);
    await migrateToV9(db);
    expect(
        (await columnNames(db, 'files')).where((c) => c == 'folder').length, 1);
    expect(
        (await columnNames(db, 'conversations'))
            .where((c) => c == 'draft_attachments')
            .length,
        1);
  });

  test('初始建表（createV8Tables）已带 v9 新列，migrateToV9 安全空转', () async {
    await createV8Tables(db);
    expect(await columnNames(db, 'files'), contains('folder'));
    expect(await columnNames(db, 'conversations'),
        contains('draft_attachments'));
    // 新列已存在时迁移是 no-op（与 _onCreate 路径收敛）
    await migrateToV9(db);
    await db.insert('files', {
      'id': 'f1',
      'name': 'a.bin',
      'local_path': '/x/a',
      'source': 'user_upload',
      'created_at': 1000,
    });
    expect((await db.query('files')).single['folder'], '');
  });
}
