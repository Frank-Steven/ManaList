import 'dart:convert';
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
  // R03-A4：路径/ID 级引用检查涉及的三张表（只建被查询的列）
  await db.execute('''
    CREATE TABLE messages(
      id TEXT PRIMARY KEY,
      attachments TEXT NOT NULL DEFAULT '[]'
    )
  ''');
  await db.execute('''
    CREATE TABLE conversations(
      id TEXT PRIMARY KEY,
      draft_attachments TEXT NOT NULL DEFAULT '[]'
    )
  ''');
  await db.execute('''
    CREATE TABLE chat_messages(
      id TEXT PRIMARY KEY,
      conversation_id TEXT NOT NULL,
      attachments TEXT NOT NULL DEFAULT '[]'
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
        'attachments': '[${attachments.map((a) => '"$a"').join(',')}]',
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
    final file =
        await service.importFromPath(src.path, mimeType: 'application/pdf');
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
    final file =
        await service.importBytes(Uint8List.fromList([1]), name: 'old.txt');
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

  test('delete：有引用未 force → 拒绝；force → 行+锚点清，但引用仍在故**本体保留**', () async {
    final file =
        await service.importBytes(Uint8List.fromList([5]), name: 'ref.bin');
    await insertNote(db, 'n1', [file.id]);
    await insertAnchor(db, 'anchor-1', file.id);

    expect(await service.delete(file.id), isFalse, reason: '有引用未 force 时应拒绝');
    expect(await appDb.getFileById(file.id), isNotNull);
    expect(File(file.localPath).existsSync(), isTrue);

    // R03-A4 新语义：force 只绕过「拒绝删行」，仍被笔记附件引用的物理文件必须保留
    expect(await service.delete(file.id, force: true), isTrue);
    expect(await appDb.getFileById(file.id), isNull, reason: 'files 行已删');
    final anchors = await db
        .query('task_anchors', where: 'target_id = ?', whereArgs: [file.id]);
    expect(anchors, isEmpty, reason: '文件锚点行应用层级联删除');
    expect(File(file.localPath).existsSync(), isTrue,
        reason: '笔记附件仍引用该路径 → 本体保留，避免死链（行为变更）');

    // 清掉最后一处引用后，再删另一条同路径行 → 本体才消失
    await db.delete('notes');
    final samePath = await service.importBytes(Uint8List.fromList([5]),
        name: 'ref-again.bin');
    expect(samePath.localPath, file.localPath, reason: '同字节 import 命中同一物理路径');
    expect(await service.delete(samePath.id), isTrue);
    expect(File(file.localPath).existsSync(), isFalse,
        reason: '所有来源都不再引用后才删本体');
  });

  test('delete：无引用直接删；不存在的 id 视为成功', () async {
    final file =
        await service.importBytes(Uint8List.fromList([6]), name: 'free.bin');
    expect(await service.delete(file.id), isTrue);
    expect(await appDb.getFileById(file.id), isNull);
    expect(await service.delete('no-such-id'), isTrue);
  });

  // ---------- R03-A4：路径级引用安全（7 类来源） ----------
  group('R03-A4 路径级引用安全', () {
    Future<void> insertMessage(String id, String attachmentsJson) =>
        db.insert('messages', {'id': id, 'attachments': attachmentsJson});

    Future<void> insertDraft(String id, String json) =>
        db.insert('conversations', {'id': id, 'draft_attachments': json});

    Future<void> insertChatMessage(String id, String json) => db.insert(
        'chat_messages',
        {'id': id, 'conversation_id': 'c1', 'attachments': json});

    Future<void> insertNoteContent(String id, String content) =>
        db.insert('notes', {
          'id': id,
          'chapter_id': 'ch1',
          'title': '笔记$id',
          'content': content,
          'attachments': '[]',
          'created_at': 1000,
          'updated_at': 1000,
        });

    test('同路径两行：删第一条本体保留，删第二条才消失', () async {
      final a = await service.importBytes(Uint8List.fromList([7, 7]),
          name: 'dup-1.bin');
      final b = await service.importBytes(Uint8List.fromList([7, 7]),
          name: 'dup-2.bin');
      expect(b.localPath, a.localPath, reason: 'sha256 去重 → 同一物理路径');

      final refsA = await service.countReferences(a.id);
      expect(refsA.fileRowCount, 1, reason: '另一条同路径 files 行');
      expect(refsA.hasAny, isFalse, reason: '同路径行不是「删了会失效」的引用');
      expect(refsA.hasPathHolders, isTrue, reason: '但它仍占用物理文件');

      expect(await service.delete(a.id), isTrue);
      expect(File(a.localPath).existsSync(), isTrue,
          reason: '仍有一条 files 行引用该路径');

      final refsB = await service.countPathReferences(b.localPath,
          fileId: b.id, excludeFileId: b.id);
      expect(refsB.fileRowCount, 0, reason: '删掉后没有其它同路径行');

      expect(await service.delete(b.id), isTrue);
      expect(File(a.localPath).existsSync(), isFalse, reason: '无人引用 → 本体删除');
    });

    test('messages.attachments 路径引用：删行后本体保留，清引用后才删', () async {
      final f = await service.importBytes(Uint8List.fromList([1, 2, 3]),
          name: 'msg-ref.bin');
      // 用 jsonEncode 造合法 JSON（Windows 路径含反斜杠，手写会成非法转义）
      await insertMessage(
          'm1',
          jsonEncode([
            {
              'access': {'type': 'local_path', 'value': f.localPath},
            }
          ]));

      final refs = await service.countReferences(f.id);
      expect(refs.messageCount, 1);

      expect(await service.delete(f.id), isFalse, reason: '有引用，未 force 拒绝');
      expect(await service.delete(f.id, force: true), isTrue);
      expect(await appDb.getFileById(f.id), isNull);
      expect(File(f.localPath).existsSync(), isTrue, reason: '消息仍引用该路径');

      await db.delete('messages');
      final again = await service.importBytes(Uint8List.fromList([1, 2, 3]),
          name: 'msg-ref2.bin');
      expect(again.localPath, f.localPath);
      expect(await service.delete(again.id), isTrue);
      expect(File(f.localPath).existsSync(), isFalse);
    });

    test('笔记 attachments 与正文 file:// 分别计数（正文不写 attachments 也算）', () async {
      final f = await service.importBytes(Uint8List.fromList([4, 4]),
          name: 'note-ref.bin');
      await insertNote(db, 'n-attach', [f.id]);
      await insertNoteContent('n-content', '看这张 ![图](file://${f.id})');

      final refs = await service.countReferences(f.id);
      expect(refs.noteCount, 1, reason: 'attachments 引用');
      expect(refs.noteContentCount, 1, reason: '仅正文 file:// 引用');
      expect(refs.hasAny, isTrue);
    });

    test('草稿/聊天附件只认 type==file', () async {
      final f = await service.importBytes(Uint8List.fromList([5, 5]),
          name: 'draft-ref.bin');
      await insertDraft('c1', '[{"type":"file","id":"${f.id}"}]');
      await insertChatMessage('cm1', '[{"type":"file","id":"${f.id}"}]');
      await insertChatMessage('cm2', '[{"type":"message","id":"${f.id}"}]');
      await insertDraft('c2', '[{"type":"note","id":"${f.id}"}]');

      final refs = await service.countReferences(f.id);
      expect(refs.draftCount, 1);
      expect(refs.chatCount, 1, reason: 'type=message 不应算');
    });

    test('task_anchors 仍计数', () async {
      final f = await service.importBytes(Uint8List.fromList([6, 6]),
          name: 'anchor-ref.bin');
      await insertAnchor(db, 'anchor-a4', f.id);
      expect((await service.countReferences(f.id)).anchorCount, 1);
    });

    test('损坏 JSON（含 id 子串但解析失败）→ 保守计 1 条引用', () async {
      final f = await service.importBytes(Uint8List.fromList([8, 8]),
          name: 'broken.bin');
      // 含「JSON 转义后的路径」子串、但不是合法 JSON（真实损坏行就是这样被截断的）
      await insertMessage(
          'm-broken', 'not-json-but-has-${jsonEncode(f.localPath)}"');

      final refs = await service.countReferences(f.id);
      expect(refs.messageCount, 1, reason: '解析失败按「有引用」处理（保守）');
      expect(refs.hasAny, isTrue);
    });

    test('完全无引用 → 物理文件被删除', () async {
      final f = await service.importBytes(Uint8List.fromList([9, 9]),
          name: 'clean.bin');
      expect((await service.countReferences(f.id)).hasAny, isFalse);
      expect(await service.delete(f.id), isTrue);
      expect(File(f.localPath).existsSync(), isFalse);
    });
  });
}
