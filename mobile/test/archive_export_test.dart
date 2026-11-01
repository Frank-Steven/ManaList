import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/archive_export_service.dart';
import 'package:msgrepo_mobile/services/attachment_store.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// v3 存档导出（基于 DB v8）：zip 结构、manifest、anchors.json 直读
/// task_anchors（marker 已在消息正文里，原样随正文导出）、front matter
/// （attachments 从 notes 列读取）、附件打包。用 sqflite_common_ffi 内存库
/// 跑真 SQLite（与 task_anchors_test 同款基建），zip 用 archive 包解开校验。
const anchorId1 = '11111111-1111-4111-8111-111111111111';
const anchorId2 = '22222222-2222-4222-8222-222222222222';
const anchorId3 = '33333333-3333-4333-8333-333333333333';

void main() {
  sqfliteFfiInit();

  late Database db;
  late Directory tmp;
  late Directory attachDir;
  late Directory outDir;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    // 与 database.dart 的 v8 形态一致的最小建表
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
    await createV8Tables(db);
    await db.execute(
        'CREATE TABLE notebooks(id TEXT PRIMARY KEY, name TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)');
    await db.execute(
        'CREATE TABLE chapters(id TEXT PRIMARY KEY, notebook_id TEXT NOT NULL, name TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)');
    await db.execute(
        "CREATE TABLE notes(id TEXT PRIMARY KEY, chapter_id TEXT NOT NULL, title TEXT NOT NULL, content TEXT NOT NULL DEFAULT '', content_format TEXT NOT NULL DEFAULT 'plain', attachments TEXT NOT NULL DEFAULT '[]', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)");

    tmp = Directory.systemTemp.createTempSync('archive_export_test');
    attachDir = Directory(p.join(tmp.path, 'attachments'))..createSync();
    outDir = Directory(p.join(tmp.path, 'out'))..createSync();
    AttachmentStore.debugDirOverride = attachDir;
  });

  tearDown(() async {
    AttachmentStore.debugDirOverride = null;
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<void> insertTask(String id,
      {String? title,
      String status = 'active',
      String? parentId}) async {
    await db.insert('tasks', {
      'id': id,
      'title': title ?? '任务$id',
      'description': null,
      'kind': 'point',
      'start_at': null,
      'end_at': null,
      'priority': 'normal',
      'is_annual': 0,
      'source_message_id': null,
      'status': status,
      'created_at': 1000,
      'updated_at': 1000,
      'parent_id': parentId,
    });
  }

  Future<void> insertMessage(String id, String body,
      {List<Attachment> attachments = const [],
      int createdAt = 2000}) async {
    await db.insert('messages', {
      'id': id,
      'package_name': 'com.test',
      'app_name': 'Test',
      'channel_id': null,
      'conversation_title': null,
      'sender': null,
      'title': '标题$id',
      'body': body,
      'posted_at': createdAt,
      'capture_type': 'notification',
      'import_source': null,
      'attachments':
          jsonEncode(attachments.map((e) => e.toJson()).toList()),
      'content_hash': 'hash-$id',
      'status': 'pending',
      'priority': 'none',
      'linked_task_id': null,
      'edited_at': null,
      'created_at': createdAt,
    });
  }

  Future<void> insertAnchor(String id, String taskId, String targetId,
          {String targetType = 'message',
          String? label,
          int createdAt = 3000}) =>
      db.insert('task_anchors', {
        'id': id,
        'task_id': taskId,
        'target_type': targetType,
        'target_id': targetId,
        'label': label,
        'created_by': 'user',
        'created_at': createdAt,
      });

  Future<Map<String, ArchiveFile>> exportAndUnzip() async {
    final result = await ArchiveExportService.instance
        .exportArchive(database: db, outputDir: outDir);
    final bytes = await File(result.path).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    return {for (final f in archive.files) f.name: f};
  }

  Map<String, dynamic> jsonOf(Map<String, ArchiveFile> files, String name) =>
      jsonDecode(utf8.decode(files[name]!.content as List<int>))
          as Map<String, dynamic>;

  List<dynamic> jsonListOf(Map<String, ArchiveFile> files, String name) =>
      jsonDecode(utf8.decode(files[name]!.content as List<int>))
          as List<dynamic>;

  String textOf(Map<String, ArchiveFile> files, String name) =>
      utf8.decode(files[name]!.content as List<int>);

  test('空库也能导出：zip 结构完整，counts 全 0', () async {
    final files = await exportAndUnzip();
    for (final name in [
      'manifest.json',
      'tasks.json',
      'messages.json',
      'anchors.json',
      'library/notebooks.json',
      'library/files.json',
    ]) {
      expect(files.containsKey(name), isTrue, reason: '缺少 $name');
    }
    final manifest = jsonOf(files, 'manifest.json');
    expect(manifest['format'], 'msgrepo-archive');
    expect(manifest['version'], 1);
    expect(manifest['appVersion'], isA<String>());
    expect(manifest['exportedAt'], isA<int>());
    expect(manifest['counts'],
        {'tasks': 0, 'messages': 0, 'notes': 0, 'files': 0, 'anchors': 0});
  });

  test('锚点行直读导出：marker 已在正文里，原样随 messages.json 导出', () async {
    await insertTask('t1', title: '买菜');
    await insertTask('t2', title: '取快递', status: 'archived');
    await insertTask('t3', title: '无关任务');
    // m1 有两个锚点（同一消息多任务），m2 一个；marker 已在正文末尾
    await insertMessage('m1', '记得买菜 ⟦task:$anchorId1⟧ ⟦task:$anchorId2⟧',
        createdAt: 2001);
    await insertMessage('m2', '也别忘了 ⟦task:$anchorId3⟧', createdAt: 2002);
    await insertMessage('m3', '无关联', createdAt: 2003);
    await insertAnchor(anchorId1, 't1', 'm1', label: '买菜', createdAt: 3001);
    await insertAnchor(anchorId2, 't2', 'm1', label: '取快递', createdAt: 3002);
    await insertAnchor(anchorId3, 't1', 'm2', label: '买菜', createdAt: 3003);

    final files = await exportAndUnzip();

    // anchors.json = task_anchors 全量原样（含 archived 任务的锚点）
    final anchors = jsonListOf(files, 'anchors.json');
    expect(anchors.length, 3);
    expect(
        anchors.map((a) => a['id']),
        containsAll([anchorId1, anchorId2, anchorId3]));
    final a1 = anchors.singleWhere((a) => a['id'] == anchorId1);
    expect(a1['task_id'], 't1');
    expect(a1['target_type'], 'message');
    expect(a1['target_id'], 'm1');
    expect(a1['label'], '买菜');
    expect(a1['created_by'], 'user');
    expect(a1['created_at'], 3001);

    // 正文原样导出（marker 不再追加，已在正文里）
    final messages = jsonListOf(files, 'messages.json');
    final m1 = messages.singleWhere((m) => m['id'] == 'm1');
    final m2 = messages.singleWhere((m) => m['id'] == 'm2');
    final m3 = messages.singleWhere((m) => m['id'] == 'm3');
    expect(m1['body'], '记得买菜 ⟦task:$anchorId1⟧ ⟦task:$anchorId2⟧');
    expect(m2['body'], '也别忘了 ⟦task:$anchorId3⟧');
    expect(m3['body'], '无关联');
    // content_hash 原样导出（导入侧按 §1.4 重算，不信任导出值）
    expect(m1['content_hash'], 'hash-m1');
    // attachments 解码为 JSON 数组
    expect(m1['attachments'], isA<List<dynamic>>());

    // tasks 全量导出（含 archived 与 parent_id 字段）
    final tasks = jsonListOf(files, 'tasks.json');
    expect(tasks.length, 3);
    expect(tasks.map((t) => t['id']), containsAll(['t1', 't2', 't3']));
    expect(tasks.singleWhere((t) => t['id'] == 't2')['status'], 'archived');
    expect(tasks.first.containsKey('parent_id'), isTrue);

    final manifest = jsonOf(files, 'manifest.json');
    expect(manifest['counts'],
        {'tasks': 3, 'messages': 3, 'notes': 0, 'files': 0, 'anchors': 3});
  });

  test('文件锚点（target_type=file）同样原样导出', () async {
    await insertTask('t1', title: '报销');
    await insertAnchor(anchorId1, 't1', 'file-9',
        targetType: 'file', label: '报销');

    final files = await exportAndUnzip();
    final anchors = jsonListOf(files, 'anchors.json');
    expect(anchors.single['target_type'], 'file');
    expect(anchors.single['target_id'], 'file-9');
  });

  test('笔记三级：notebooks.json + front matter 字段正确（attachments 从列读取）',
      () async {
    await db.insert('notebooks',
        {'id': 'nb1', 'name': '学习', 'sort': 0, 'created_at': 4000});
    await db.insert('chapters', {
      'id': 'ch1',
      'notebook_id': 'nb1',
      'name': '数学',
      'sort': 0,
      'created_at': 4001,
    });
    await db.insert('notes', {
      'id': 'n1',
      'chapter_id': 'ch1',
      'title': '公式: 速查 #1',
      'content': 'E = mc^2\n第二行',
      'content_format': 'plain',
      'attachments': jsonEncode(['f1', 'f2']),
      'created_at': 4002,
      'updated_at': 4003,
    });
    await db.insert('notes', {
      'id': 'n2',
      'chapter_id': 'ch1',
      'title': 'markdown 笔记',
      'content': '# 标题',
      'content_format': 'markdown',
      'created_at': 4004,
      'updated_at': 4005,
    });

    final files = await exportAndUnzip();

    final nb = jsonOf(files, 'library/notebooks.json');
    expect((nb['notebooks'] as List).single['id'], 'nb1');
    expect((nb['chapters'] as List).single['id'], 'ch1');

    expect(files.containsKey('library/notes/n1.md'), isTrue);
    expect(files.containsKey('library/notes/n2.md'), isTrue);

    final md = textOf(files, 'library/notes/n1.md');
    expect(md, startsWith('---\n'));
    expect(md, contains('\nid: n1\n'));
    // 标题含 : 与 #，必须用引号（JSON 双引号是合法 YAML）
    expect(md, contains('\ntitle: "公式: 速查 #1"\n'));
    expect(md, contains('\nchapter_id: ch1\n'));
    expect(md, contains('\ncontent_format: plain\n'));
    expect(md, contains('\ncreated_at: 4002\n'));
    expect(md, contains('\nupdated_at: 4003\n'));
    expect(md, contains('\nattachments: [f1, f2]\n'), reason: '从 notes 列读取');
    expect(md, endsWith('---\nE = mc^2\n第二行'));

    final md2 = textOf(files, 'library/notes/n2.md');
    expect(md2, contains('\ncontent_format: markdown\n'));
    // 安全标题原样输出不加引号（贴近规格示例）
    expect(md2, contains('\ntitle: markdown 笔记\n'));
    expect(md2, contains('\nattachments: []\n'), reason: '缺省空数组');

    final manifest = jsonOf(files, 'manifest.json');
    expect(manifest['counts']['notes'], 2);
  });

  test('附件打进 library/files/<fileId>__<safeName>，丢失的文件跳过并计数',
      () async {
    final payload = utf8.encode('fake image bytes');
    final f = File(p.join(attachDir.path, 'abc123.png'))
      ..writeAsBytesSync(payload);
    final ok = Attachment(
      id: 'file-1',
      kind: Attachment.kindImage,
      label: '照片 1.png',
      bytes: payload.length,
      access: AttachmentAccess(
        type: AttachmentAccess.typeLocalPath,
        value: f.path,
        mimeType: 'image/png',
      ),
    );
    const missing = Attachment(
      id: 'file-2',
      kind: Attachment.kindFile,
      label: 'gone.pdf',
      bytes: 10,
      access: AttachmentAccess(
        type: AttachmentAccess.typeLocalPath,
        value: '/nonexistent/gone.pdf',
      ),
    );
    await insertMessage('m1', '带附件', attachments: [ok, missing]);
    await insertMessage('m2', '同一附件再引用', attachments: [ok]);

    final result = await ArchiveExportService.instance
        .exportArchive(database: db, outputDir: outDir);
    expect(result.skippedFiles, 1);
    expect(result.files, 1);
    expect(
        p.basename(result.path),
        matches(RegExp(r'^msgrepo-archive-\d{8}-\d{6}\.zip$')));

    final bytes = await File(result.path).readAsBytes();
    final files = {
      for (final e in ZipDecoder().decodeBytes(bytes).files) e.name: e
    };

    final filesJson = jsonListOf(files, 'library/files.json');
    expect(filesJson.length, 1, reason: '同一附件被多条消息引用只打包一次');
    final entry = filesJson.single;
    expect(entry['id'], 'file-1');
    expect(entry['name'], '照片 1.png');
    expect(entry['mime_type'], 'image/png');
    expect(entry['size'], payload.length);
    expect(entry['path'], 'library/files/file-1__照片_1.png');
    expect(entry['created_at'], 2000);

    final zipped = files['library/files/file-1__照片_1.png']!;
    expect(zipped.content as List<int>, payload);

    final manifest = jsonOf(files, 'manifest.json');
    expect(manifest['counts']['files'], 1);
  });
}
