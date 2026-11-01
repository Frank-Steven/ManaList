import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'db_v9_migration_test.dart' show createV8ShapeTables;

/// DB v10 回归：library_folders 表（空文件夹持久化）。
/// 迁移建表幂等；文件夹 DAO：插入含祖先补齐、整树删除、整树换前缀。
/// 用 sqflite_common_ffi 内存库 + debugAttachDatabase，不依赖手机。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  final appDb = AppDatabase.instance;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createV8ShapeTables(db);
    await migrateToV10(db);
    appDb.debugAttachDatabase(db);
  });

  tearDown(() async {
    appDb.debugDetachDatabase();
    await db.close();
  });

  test('v9 老库迁移后建表，幂等', () async {
    final tables = await db
        .rawQuery("SELECT name FROM sqlite_master WHERE type='table'");
    expect(tables.map((t) => t['name']), contains('library_folders'));
    // 再跑一遍不报错（CREATE TABLE IF NOT EXISTS）
    await migrateToV10(db);
    expect(await appDb.getLibraryFolders(), isEmpty);
  });

  test('insertLibraryFolder 含祖先路径补齐，读回升序', () async {
    await appDb.insertLibraryFolder('工作/截图/2026');
    expect(await appDb.getLibraryFolders(), ['工作', '工作/截图', '工作/截图/2026']);
    // 幂等：重复插入不重复
    await appDb.insertLibraryFolder('工作/截图');
    expect(await appDb.getLibraryFolders(), ['工作', '工作/截图', '工作/截图/2026']);
    // 空路径是 no-op
    await appDb.insertLibraryFolder('');
    expect(await appDb.getLibraryFolders(), hasLength(3));
  });

  test('deleteLibraryFolderTree 删除自身与后代，兄弟不受影响', () async {
    await appDb.insertLibraryFolder('工作/截图');
    await appDb.insertLibraryFolder('工作/文档');
    await appDb.insertLibraryFolder('生活');
    await appDb.deleteLibraryFolderTree('工作/截图');
    expect(await appDb.getLibraryFolders(), ['工作', '工作/文档', '生活']);
  });

  test('renameLibraryFolderTree 整棵子树换前缀', () async {
    await appDb.insertLibraryFolder('工作/截图/2026');
    await appDb.insertLibraryFolder('工作临时');
    await appDb.renameLibraryFolderTree('工作', '职场');
    expect(await appDb.getLibraryFolders(),
        ['工作临时', '职场', '职场/截图', '职场/截图/2026'],
        reason: '只匹配路径前缀段，不误伤「工作临时」');
  });
}
