import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/library_file.dart';
import 'package:msgrepo_mobile/services/attachment_store.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/services/library_file_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'dart:io';

/// DB v9 文件树形管理回归（虚拟文件夹，路径式 folder 字段）：
/// 路径工具函数、listFolder 一层视图（子文件夹派生 + extraFolders）、
/// moveToFolder、renameFolder 整棵子树换前缀、deleteFolder 文件上移一层。
/// 用 sqflite_common_ffi 内存库 + AttachmentStore.debugDirOverride，不依赖手机。
Future<void> createFilesTable(Database db) async {
  await db.execute('''
    CREATE TABLE files(
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      mime_type TEXT,
      size INTEGER,
      local_path TEXT NOT NULL,
      source TEXT NOT NULL,
      folder TEXT NOT NULL DEFAULT '',
      created_at INTEGER NOT NULL
    )
  ''');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  late Directory tmp;
  final appDb = AppDatabase.instance;
  final service = LibraryFileService.instance;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createFilesTable(db);
    // v10 起 listFolder/allFolders 与 library_folders 表取并集（空文件夹持久化）
    await migrateToV10(db);
    appDb.debugAttachDatabase(db);
    tmp = Directory.systemTemp.createTempSync('msgrepo-folder-');
    AttachmentStore.debugDirOverride = tmp;
  });

  tearDown(() async {
    appDb.debugDetachDatabase();
    await db.close();
    AttachmentStore.debugDirOverride = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<LibraryFile> importFile(String name, {String folder = ''}) =>
      service.importBytes(Uint8List.fromList([1]), name: name, folder: folder);

  group('路径工具函数', () {
    test('isValidFolderName：拒绝空、分隔符、. / ..', () {
      expect(isValidFolderName('工作'), isTrue);
      expect(isValidFolderName(''), isFalse);
      expect(isValidFolderName('a/b'), isFalse);
      expect(isValidFolderName('a\\b'), isFalse);
      expect(isValidFolderName('.'), isFalse);
      expect(isValidFolderName('..'), isFalse);
    });

    test('join / parent / name / isUnder', () {
      expect(joinFolderPath('', '工作'), '工作');
      expect(joinFolderPath('工作', '截图'), '工作/截图');
      expect(parentFolderPath('工作/截图'), '工作');
      expect(parentFolderPath('工作'), '');
      expect(parentFolderPath(''), '');
      expect(folderName('工作/截图'), '截图');
      expect(folderName('工作'), '工作');
      expect(folderIsUnder('工作/截图', '工作'), isTrue);
      expect(folderIsUnder('工作', '工作'), isTrue);
      expect(folderIsUnder('工作2', '工作'), isFalse, reason: '按段边界匹配');
      expect(folderIsUnder('任意', ''), isTrue, reason: '根目录是一切的祖先');
    });
  });

  group('listFolder 一层视图', () {
    test('子文件夹由文件 folder 字段派生（含多级路径的直接段）', () async {
      await importFile('root.txt');
      await importFile('a.txt', folder: '工作');
      await importFile('b.txt', folder: '工作/截图');
      await importFile('c.txt', folder: '个人');

      final root = await service.listFolder('');
      expect(root.folders, ['个人', '工作'], reason: '只列直接子文件夹');
      expect(root.files.map((f) => f.name), ['root.txt']);

      final work = await service.listFolder('工作');
      expect(work.folders, ['截图']);
      expect(work.files.map((f) => f.name), ['a.txt']);

      final shots = await service.listFolder('工作/截图');
      expect(shots.folders, isEmpty);
      expect(shots.files.map((f) => f.name), ['b.txt']);
    });

    test('extraFolders：会话内新建的空虚拟文件夹参与派生', () async {
      await importFile('a.txt', folder: '工作');
      final root = await service.listFolder('', extraFolders: {'新建文件夹'});
      expect(root.folders, containsAll(['工作', '新建文件夹']));
    });

    test('allFolders：全部去重路径升序', () async {
      await importFile('a.txt', folder: '工作/截图');
      await importFile('b.txt', folder: '工作');
      expect(await service.allFolders(), ['工作', '工作/截图']);
      // 排序按字符串字典序（Unicode 码位）：'临' U+4E34 < '工' U+5DE5
      expect(await service.allFolders(extraFolders: {'临时'}),
          ['临时', '工作', '工作/截图']);
    });
  });

  group('moveToFolder / renameFolder / deleteFolder', () {
    test('moveToFolder：批量移动，根目录为空串', () async {
      final a = await importFile('a.txt');
      final b = await importFile('b.txt');
      await service.moveToFolder([a.id, b.id], '工作');
      expect((await appDb.getFileById(a.id))?.folder, '工作');
      expect((await appDb.getFileById(b.id))?.folder, '工作');
      await service.moveToFolder([a.id], '');
      expect((await appDb.getFileById(a.id))?.folder, '');
    });

    test('renameFolder：整棵子树换前缀', () async {
      final a = await importFile('a.txt', folder: '工作');
      final b = await importFile('b.txt', folder: '工作/截图');
      final outside = await importFile('c.txt', folder: '工作2');

      final moved = await service.renameFolder('工作', '项目');
      expect(moved, 2);
      expect((await appDb.getFileById(a.id))?.folder, '项目');
      expect((await appDb.getFileById(b.id))?.folder, '项目/截图');
      expect((await appDb.getFileById(outside.id))?.folder, '工作2',
          reason: '段边界外的同名前缀不受影响');
    });

    test('renameFolder：非法名/重名/根目录拒绝', () async {
      await importFile('a.txt', folder: '工作');
      await importFile('b.txt', folder: '个人');
      expect(() => service.renameFolder('', 'x'), throwsArgumentError);
      expect(() => service.renameFolder('工作', 'a/b'), throwsArgumentError);
      expect(() => service.renameFolder('工作', '个人'), throwsArgumentError,
          reason: '目标已存在');
      expect((await appDb.getFiles()).map((f) => f.folder).toSet(),
          {'工作', '个人'});
    });

    test('deleteFolder：文件（含子文件夹）上移一层，文件不删', () async {
      final a = await importFile('a.txt', folder: '工作');
      final b = await importFile('b.txt', folder: '工作/截图');
      final keep = await importFile('c.txt', folder: '个人');

      final moved = await service.deleteFolder('工作');
      expect(moved, 2);
      expect((await appDb.getFileById(a.id))?.folder, '');
      expect((await appDb.getFileById(b.id))?.folder, '截图');
      expect((await appDb.getFileById(keep.id))?.folder, '个人');
      expect(await appDb.getFiles(), hasLength(3), reason: '只改 folder，不删文件');
      expect(await service.deleteFolder(''), 0, reason: '根目录不可删');
    });
  });

  test('导入落到指定文件夹，默认根目录', () async {
    final root = await importFile('r.txt');
    expect(root.folder, '');
    final nested = await importFile('n.txt', folder: '工作/截图');
    expect(nested.folder, '工作/截图');
    expect((await appDb.getFileById(nested.id))?.folder, '工作/截图');
  });

  group('getFilesUnderFolder（文件夹整选）', () {
    test('命中本层与全部后代，段边界外不受影响', () async {
      await importFile('a.txt', folder: '工作');
      await importFile('b.txt', folder: '工作/截图');
      await importFile('c.txt', folder: '工作/截图/原图');
      await importFile('d.txt', folder: '工作2');
      await importFile('e.txt');

      final under = await appDb.getFilesUnderFolder('工作');
      expect(under.map((f) => f.name).toSet(), {'a.txt', 'b.txt', 'c.txt'},
          reason: '含多级后代，不含 工作2 与根目录文件');

      final root = await appDb.getFilesUnderFolder('');
      expect(root, hasLength(5), reason: '空路径 = 全库');
    });
  });
}
