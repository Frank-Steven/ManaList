import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/library_file.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/attachment_store.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/services/library_file_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// v3 阶段 3 库·文件区服务回归（design-v3 §1.3/§3.1）：
/// 导入（落附件仓库 + 写 files 表）、重命名、删除前引用检查
/// （笔记 attachments + target_type='file' 的任务锚点）、force 删除与本体清理。
/// 用 sqflite_common_ffi 内存库 + AttachmentStore.debugDirOverride，不依赖手机。
Future<void> createTables(Database db) async {
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
  await db.execute('''
    CREATE TABLE notes(
      id TEXT PRIMARY KEY,
      chapter_id TEXT NOT NULL,
      title TEXT NOT NULL,
      content TEXT NOT NULL DEFAULT '',
      content_format TEXT NOT NULL DEFAULT 'plain',
      attachments TEXT NOT NULL DEFAULT '[]',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE task_anchors(
      id TEXT PRIMARY KEY,
      task_id TEXT NOT NULL,
      target_type TEXT NOT NULL,
      target_id TEXT NOT NULL,
      label TEXT,
      created_by TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''');
}

Future<void> insertNote(Database db, String id, List<String> attachments) =>
    db.insert(
      'notes',
      {
        'id': id,
        'chapter_id': 'ch1',
        'title': '笔记$id',
        'attachments':
            '[${attachments.map((a) => '"$a"').join(',')}]',
        'created_at': 1000,
        'updated_at': 1000,
      },
    );

Future<void> insertAnchor(Database db, String id, String fileId) =>
    db.insert('task_anchors', {
      'id': id,
      'task_id': 't1',
      'target_type': AnchorTargetType.file,
      'target_id': fileId,
      'created_by': AnchorCreatedBy.user,
      'created_at': 1000,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  late Directory tmp;
  final appDb = AppDatabase.instance;
  final service = LibraryFileService.instance;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createTables(db);
    appDb.debugAttachDatabase(db);
    tmp = Directory.systemTemp.createTempSync('msgrepo-libfile-');
    AttachmentStore.debugDirOverride = tmp;
  });

  tearDown(() async {
    appDb.debugDetachDatabase();
    await db.close();
    AttachmentStore.debugDirOverride = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('importFromPath：复制进仓库 + 元数据入库；源不存在返回 null', () async {
    final src = File('${tmp.path}/report.pdf')..writeAsBytesSync([1, 2, 3]);
    final file = await service.importFromPath(src.path,
        mimeType: 'application/pdf');
    expect(file, isNotNull);
    expect(file!.name, 'report.pdf');
    expect(file.size, 3);
    expect(file.mimeType, 'application/pdf');
    expect(file.source, FileSource.userUpload);
    expect(file.localPath, isNot(src.path), reason: '必须是仓库内的复制品');
    expect(File(file.localPath).existsSync(), isTrue);

    final row = await appDb.getFileById(file.id);
    expect(row?.name, 'report.pdf');

    expect(await service.importFromPath('${tmp.path}/nope.bin'), isNull);
  });

  test('importBytes：按给定名称入库', () async {
    final file = await service.importBytes(
      Uint8List.fromList([9, 8, 7, 6]),
      name: '截图.png',
      mimeType: 'image/png',
    );
    expect(file.size, 4);
    expect((await appDb.getFileById(file.id))?.mimeType, 'image/png');
    expect(File(file.localPath).readAsBytesSync(), [9, 8, 7, 6]);
  });

  test('rename：只改显示名，路径不动', () async {
    final file = await service.importBytes(Uint8List.fromList([1]),
        name: 'old.txt');
    await service.rename(file.id, 'new.txt');
    final row = await appDb.getFileById(file.id);
    expect(row?.name, 'new.txt');
    expect(row?.localPath, file.localPath);
  });

  test('countReferences：笔记 attachments 与文件锚点分别计数', () async {
    final a = await service.importBytes(Uint8List.fromList([1]), name: 'a.bin');
    final b = await service.importBytes(Uint8List.fromList([2]), name: 'b.bin');

    await insertNote(db, 'n1', [a.id, b.id]);
    await insertNote(db, 'n2', [a.id]);
    await insertNote(db, 'n3', []); // 无引用
    await insertAnchor(db, 'anchor-1', a.id);
    await insertAnchor(db, 'anchor-2', a.id);

    final refsA = await service.countReferences(a.id);
    expect(refsA.noteCount, 2);
    expect(refsA.anchorCount, 2);
    expect(refsA.hasAny, isTrue);

    final refsB = await service.countReferences(b.id);
    expect(refsB.noteCount, 1);
    expect(refsB.anchorCount, 0);

    final c = await service.importBytes(Uint8List.fromList([3]), name: 'c.bin');
    expect((await service.countReferences(c.id)).hasAny, isFalse);
  });

  test('delete：有引用且未 force → 拒绝且数据不动；force → 行、锚点、本体全清',
      () async {
    final file =
        await service.importBytes(Uint8List.fromList([5]), name: 'ref.bin');
    await insertNote(db, 'n1', [file.id]);
    await insertAnchor(db, 'anchor-1', file.id);

    expect(await service.delete(file.id), isFalse,
        reason: '有引用未 force 时应拒绝');
    expect(await appDb.getFileById(file.id), isNotNull);
    expect(File(file.localPath).existsSync(), isTrue);

    expect(await service.delete(file.id, force: true), isTrue);
    expect(await appDb.getFileById(file.id), isNull);
    expect(File(file.localPath).existsSync(), isFalse, reason: '仓库本体一并删除');
    final anchors = await db.query('task_anchors',
        where: 'target_id = ?', whereArgs: [file.id]);
    expect(anchors, isEmpty, reason: '文件锚点行应用层级联删除');
  });

  test('delete：无引用直接删；不存在的 id 视为成功', () async {
    final file =
        await service.importBytes(Uint8List.fromList([6]), name: 'free.bin');
    expect(await service.delete(file.id), isTrue);
    expect(await appDb.getFileById(file.id), isNull);
    expect(await service.delete('no-such-id'), isTrue);
  });
}
