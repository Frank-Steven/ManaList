import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/archive_export_service.dart';
import 'package:msgrepo_mobile/services/archive_import_service.dart';
import 'package:msgrepo_mobile/services/attachment_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables;

/// 存档导出→导入往返（design-v3-details §5.3）：
/// 全量保留原 id 一致还原、content_hash 按 §1.4 重算、marker 一致性警告、
/// 非空库拒绝、manifest 格式/版本拒绝。用 sqflite_common_ffi 内存库跑真 SQLite。
const anchorId1 = '11111111-1111-4111-8111-111111111111';
const anchorIdBad = '99999999-9999-4999-8999-999999999999';

void main() {
  sqfliteFfiInit();

  late Directory tmp;
  late Directory attachDirA; // 导出侧 attachment_store
  late Directory attachDirB; // 导入侧 attachment_store（全新安装）
  late Directory outDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('archive_roundtrip_test');
    attachDirA = Directory(p.join(tmp.path, 'attA'))..createSync();
    attachDirB = Directory(p.join(tmp.path, 'attB'))..createSync();
    outDir = Directory(p.join(tmp.path, 'out'))..createSync();
  });

  tearDown(() {
    AttachmentStore.debugDirOverride = null;
    tmp.deleteSync(recursive: true);
  });

  Future<Database> newDb() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createBaseTables(db);
    await db.execute(
        'CREATE TABLE notebooks(id TEXT PRIMARY KEY, name TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)');
    await db.execute(
        'CREATE TABLE chapters(id TEXT PRIMARY KEY, notebook_id TEXT NOT NULL, name TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)');
    return db;
  }

  Future<List<Map<String, Object?>>> rows(Database db, String table) =>
      db.query(table);

  test('导出 → 导入往返一致（全量保留原 id，content_hash 重算）', () async {
    final db1 = await newDb();
    // 任务：含父子关系与归档任务
    await db1.insert('tasks', {
      'id': 't-parent', 'title': '周报', 'description': null, 'kind': 'point',
      'start_at': null, 'end_at': null, 'priority': 'important', 'is_annual': 0,
      'source_message_id': null, 'status': 'active', 'created_at': 1000,
      'updated_at': 1001, 'parent_id': null,
    });
    await db1.insert('tasks', {
      'id': 't-child', 'title': '写初稿', 'description': '周五前', 'kind': 'range',
      'start_at': 1761900000000, 'end_at': 1761984000000, 'priority': 'normal',
      'is_annual': 0, 'source_message_id': null, 'status': 'archived',
      'created_at': 1002, 'updated_at': 1003, 'parent_id': 't-parent',
    });
    // 消息：m1 正文带 marker（与锚点一致），m2 带「坏」锚点（正文无 marker）
    await db1.insert('messages', {
      'id': 'm1', 'package_name': 'com.test', 'app_name': 'Test',
      'channel_id': null, 'conversation_title': '群聊', 'sender': '张三',
      'title': '记得写周报', 'body': '周五前交 ⟦task:$anchorId1⟧',
      'posted_at': 1700000000000, 'capture_type': 'notification',
      'import_source': null, 'attachments': '[]',
      'content_hash': 'stale-hash-m1', // 导入侧应重算，不信任导出值
      'status': 'processed', 'priority': 'red', 'linked_task_id': null,
      'edited_at': null, 'created_at': 2000,
    });
    await db1.insert('messages', {
      'id': 'm2', 'package_name': 'com.test', 'app_name': null,
      'channel_id': null, 'conversation_title': null, 'sender': null,
      'title': '无 marker 的正文', 'body': '纯文本',
      'posted_at': 1700000001000, 'capture_type': 'manual',
      'import_source': null, 'attachments': '[]', 'content_hash': 'hash-m2',
      'status': 'pending', 'priority': 'none', 'linked_task_id': null,
      'edited_at': 1700000002000, 'created_at': 2001,
    });
    // 笔记三级 + 附件列
    await db1.insert('notebooks',
        {'id': 'nb1', 'name': '工作', 'sort': 0, 'created_at': 4000});
    await db1.insert('chapters', {
      'id': 'ch1', 'notebook_id': 'nb1', 'name': '项目', 'sort': 0,
      'created_at': 4001,
    });
    await db1.insert('notes', {
      'id': 'n1', 'chapter_id': 'ch1', 'title': '设计稿: 注意 #事项',
      'content': '# 正文\n引用 ![f](file://f1)', 'content_format': 'markdown',
      'attachments': jsonEncode(['f1']), 'created_at': 4002,
      'updated_at': 4003,
    });
    // 文件区：真实字节进 attachment_store
    AttachmentStore.debugDirOverride = attachDirA;
    final payload = utf8.encode('hello archive');
    final att = await AttachmentStore.instance
        .importBytes(payload, kind: 'file', label: '说明.txt');
    await db1.insert('files', {
      'id': 'f1', 'name': '说明.txt', 'mime_type': 'text/plain',
      'size': payload.length, 'local_path': att.access.value,
      'source': 'user_upload', 'created_at': 5000,
    });
    // 锚点：a1 一致（marker 在 m1 正文里），a-bad 不一致（m2 正文无 marker）
    await db1.insert('task_anchors', {
      'id': anchorId1, 'task_id': 't-parent', 'target_type': 'message',
      'target_id': 'm1', 'label': '周报', 'created_by': 'user',
      'created_at': 3000,
    });
    await db1.insert('task_anchors', {
      'id': anchorIdBad, 'task_id': 't-parent', 'target_type': 'message',
      'target_id': 'm2', 'label': '坏锚点', 'created_by': 'user',
      'created_at': 3001,
    });

    // ---- 导出 ----
    final export = await ArchiveExportService.instance
        .exportArchive(database: db1, outputDir: outDir);
    await db1.close();

    // ---- 导入到全新库 ----
    AttachmentStore.debugDirOverride = attachDirB;
    final db2 = await newDb();
    final result = await ArchiveImportService.instance
        .importArchive(export.path, database: db2);

    expect(result.tasks, 2);
    expect(result.messages, 2);
    expect(result.notes, 1);
    expect(result.files, 1);
    expect(result.anchors, 2);
    // marker 一致性警告：a-bad 的正文缺 marker
    expect(result.warnings, hasLength(1));
    expect(result.warnings.single, contains(anchorIdBad));

    // 任务逐字段一致（原 id、parent_id、archived 全保留）
    final tasks = await rows(db2, 'tasks');
    expect(tasks.map((t) => t['id']), containsAll(['t-parent', 't-child']));
    final child = tasks.singleWhere((t) => t['id'] == 't-child');
    expect(child['parent_id'], 't-parent');
    expect(child['status'], 'archived');
    expect(child['start_at'], 1761900000000);

    // 消息逐字段一致，唯 content_hash 按 §1.4 重算
    final messages = await rows(db2, 'messages');
    final m1 = messages.singleWhere((m) => m['id'] == 'm1');
    expect(m1['body'], '周五前交 ⟦task:$anchorId1⟧');
    expect(m1['priority'], 'red');
    expect(m1['status'], 'processed');
    expect(m1['content_hash'], isNot('stale-hash-m1'));
    expect(
        m1['content_hash'],
        computeContentHash(
            'com.test', '记得写周报', '周五前交 ⟦task:$anchorId1⟧', 1700000000000));
    final m2 = messages.singleWhere((m) => m['id'] == 'm2');
    expect(m2['edited_at'], 1700000002000);

    // 笔记：front matter 往返逐字段一致
    final notes = await rows(db2, 'notes');
    expect(notes.single['id'], 'n1');
    expect(notes.single['title'], '设计稿: 注意 #事项');
    expect(notes.single['content'], '# 正文\n引用 ![f](file://f1)');
    expect(notes.single['content_format'], 'markdown');
    expect(notes.single['attachments'], jsonEncode(['f1']));
    expect(notes.single['created_at'], 4002);
    expect(notes.single['updated_at'], 4003);
    expect((await rows(db2, 'notebooks')).single['name'], '工作');
    expect((await rows(db2, 'chapters')).single['notebook_id'], 'nb1');

    // 文件：原 id 保留，local_path 重写为新仓库位置，字节一致
    final files = await rows(db2, 'files');
    expect(files.single['id'], 'f1');
    expect(files.single['name'], '说明.txt');
    expect(files.single['source'], 'user_upload');
    expect(files.single['created_at'], 5000);
    final newPath = files.single['local_path'] as String;
    expect(p.isWithin(attachDirB.path, newPath), isTrue,
        reason: '文件本体复制进新安装的 attachment_store');
    expect(await File(newPath).readAsBytes(), payload);

    // 锚点原样还原
    final anchors = await rows(db2, 'task_anchors');
    expect(anchors.map((a) => a['id']),
        containsAll([anchorId1, anchorIdBad]));

    // ---- 非空库守卫：再导一次必须拒绝 ----
    await expectLater(
      ArchiveImportService.instance
          .importArchive(export.path, database: db2),
      throwsA(isA<ArchiveImportException>()
          .having((e) => e.message, 'message', contains('合并'))),
    );
    await db2.close();
  });

  group('manifest 校验（§5.3-1）', () {
    Future<String> zipWith(Map<String, String> files) async {
      final archive = Archive();
      for (final e in files.entries) {
        final bytes = utf8.encode(e.value);
        archive.addFile(ArchiveFile(e.key, bytes.length, bytes));
      }
      final f = File(p.join(outDir.path, 'bad.zip'));
      await f.writeAsBytes(ZipEncoder().encode(archive));
      return f.path;
    }

    test('缺 manifest 拒绝', () async {
      final db = await newDb();
      final path = await zipWith({'tasks.json': '[]'});
      await expectLater(
        ArchiveImportService.instance.importArchive(path, database: db),
        throwsA(isA<ArchiveImportException>()
            .having((e) => e.message, 'message', contains('manifest'))),
      );
      await db.close();
    });

    test('format 不符拒绝', () async {
      final db = await newDb();
      final path = await zipWith({
        'manifest.json': jsonEncode({'format': 'other', 'version': 1}),
      });
      await expectLater(
        ArchiveImportService.instance.importArchive(path, database: db),
        throwsA(isA<ArchiveImportException>()),
      );
      await db.close();
    });

    test('version 不支持拒绝并明示', () async {
      final db = await newDb();
      final path = await zipWith({
        'manifest.json':
            jsonEncode({'format': 'msgrepo-archive', 'version': 99}),
      });
      await expectLater(
        ArchiveImportService.instance.importArchive(path, database: db),
        throwsA(isA<ArchiveImportException>()
            .having((e) => e.message, 'message', contains('99'))),
      );
      await db.close();
    });

    test('非 zip 文件拒绝', () async {
      final db = await newDb();
      final f = File(p.join(outDir.path, 'notazip.zip'));
      await f.writeAsBytes(utf8.encode('definitely not a zip'));
      await expectLater(
        ArchiveImportService.instance.importArchive(f.path, database: db),
        throwsA(isA<ArchiveImportException>()),
      );
      await db.close();
    });
  });
}
