import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:sqflite/sqflite.dart';

import '../models/message.dart';
import 'archive_export_service.dart';
import 'assistant/models.dart';
import 'attachment_store.dart';
import 'database.dart';

/// 导入被拒绝（格式不支持 / 库非空）——用户可读的拒绝原因。
class ArchiveImportException implements Exception {
  final String message;
  ArchiveImportException(this.message);
  @override
  String toString() => message;
}

/// 导入结果：各类条数 + 一致性警告列表（警告不阻断导入，§5.3-4）。
class ArchiveImportResult {
  final int tasks;
  final int messages;
  final int notes;
  final int files;
  final int anchors;
  final List<String> warnings;

  const ArchiveImportResult({
    required this.tasks,
    required this.messages,
    required this.notes,
    required this.files,
    required this.anchors,
    required this.warnings,
  });
}

/// v3 存档导入（格式与流程定稿见 design-v3-details §5.3）：
/// 解压 → 校验 manifest.format/version → 空库守卫（非空拒绝，不做合并）→
/// 单事务入库（全量保留原 id）→ marker 一致性校验（缺失记入警告列表）。
///
/// content_hash 不信任导出值，导入时按 §1.4 规则重算
/// （computeContentHash 内建 strip marker）。
class ArchiveImportService {
  ArchiveImportService._();

  static final ArchiveImportService instance = ArchiveImportService._();

  /// 从 [zipPath] 导入。空库守卫失败或格式不支持时抛 [ArchiveImportException]。
  ///
  /// [database] 供测试注入（内存库）；默认走 [AppDatabase] 单例。
  Future<ArchiveImportResult> importArchive(
    String zipPath, {
    Database? database,
  }) async {
    final bytes = await File(zipPath).readAsBytes();
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw ArchiveImportException('不是有效的 zip 文件');
    }
    final entries = {for (final f in archive.files) f.name: f};

    String textOf(String name) =>
        utf8.decode(entries[name]!.content as List<int>);

    // 1. manifest 校验（§5.3-1）：格式/版本不支持即拒绝并明示。
    final manifestEntry = entries['manifest.json'];
    if (manifestEntry == null) {
      throw ArchiveImportException('不是 ManaList 存档：缺少 manifest.json');
    }
    final Map<String, dynamic> manifest;
    try {
      manifest =
          (jsonDecode(textOf('manifest.json')) as Map).cast<String, dynamic>();
    } catch (_) {
      throw ArchiveImportException('manifest.json 损坏，无法解析');
    }
    if (manifest['format'] != ArchiveExportService.archiveFormat) {
      throw ArchiveImportException(
          '不是 ManaList 存档（format=${manifest['format']}）');
    }
    if (manifest['version'] != ArchiveExportService.archiveVersion) {
      throw ArchiveImportException(
          '存档版本不支持（version=${manifest['version']}，'
          '本应用支持 v${ArchiveExportService.archiveVersion}）');
    }

    List<Map<String, Object?>> rowsOf(String name) {
      final entry = entries[name];
      if (entry == null) return const [];
      return [
        for (final e in (jsonDecode(textOf(name)) as List))
          (e as Map).cast<String, Object?>(),
      ];
    }

    final tasks = rowsOf('tasks.json');
    final messages = rowsOf('messages.json');
    final anchors = rowsOf('anchors.json');
    final filesIndex = rowsOf('library/files.json');
    final notebooksJson = entries['library/notebooks.json'] != null
        ? (jsonDecode(textOf('library/notebooks.json')) as Map)
            .cast<String, dynamic>()
        : const <String, dynamic>{};
    final notebooks = [
      for (final e in (notebooksJson['notebooks'] as List? ?? const []))
        (e as Map).cast<String, Object?>(),
    ];
    final chapters = [
      for (final e in (notebooksJson['chapters'] as List? ?? const []))
        (e as Map).cast<String, Object?>(),
    ];

    // 笔记：library/notes/<noteId>.md（front matter + 正文）。
    final warnings = <String>[];
    final notes = <Map<String, Object?>>[];
    for (final f in archive.files) {
      if (!f.isFile ||
          !f.name.startsWith('library/notes/') ||
          !f.name.endsWith('.md')) {
        continue;
      }
      final parsed = _parseNoteMarkdown(textOf(f.name));
      if (parsed == null) {
        warnings.add('笔记 ${f.name} 缺少 front matter，已跳过');
        continue;
      }
      notes.add(parsed);
    }

    final db = database ?? await AppDatabase.instance.database;

    // 2. 空库守卫（§5.3-2）：首版不做合并。
    final existing = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM tasks'))! +
        Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM messages'))! +
        Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM notes'))! +
        Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM files'))! +
        Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM task_anchors'))!;
    if (existing > 0) {
      throw ArchiveImportException('当前库已有数据，首版不支持合并导入；请在全新安装上使用');
    }

    // 3. 文件本体复制进 attachment_store（事务外 IO）：
    //    files 表条目重写 local_path 为新位置、保留原 id（file://id 引用保持有效）；
    //    message_attachment 条目只落盘不回填 files 表——attachment_store 按
    //    sha256 命名，同一字节序列重建同一路径，messages.json 里的引用自然复活。
    final fileRows = <Map<String, Object?>>[];
    for (final f in filesIndex) {
      final id = f['id'];
      final zipPath = f['path'];
      if (id is! String || zipPath is! String) {
        warnings.add('files.json 条目缺 id/path，已跳过');
        continue;
      }
      final entry = entries[zipPath];
      if (entry == null) {
        warnings.add('文件 ${f['name'] ?? id} 在存档中缺失（$zipPath），已跳过');
        continue;
      }
      final content = entry.content as List<int>;
      final att = await AttachmentStore.instance.importBytes(
        content is Uint8List ? content : Uint8List.fromList(content),
        kind: Attachment.kindFile,
        label: f['name'] as String?,
        mimeType: f['mime_type'] as String?,
        fileName: f['name'] as String?,
      );
      if (f['source'] == 'message_attachment') continue;
      fileRows.add({
        'id': id,
        'name': f['name'] as String? ?? id,
        'mime_type': f['mime_type'],
        'size': f['size'],
        'local_path': att.access.value,
        'source': f['source'] as String? ?? 'user_upload',
        'created_at': (f['created_at'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      });
    }

    // 4. 单事务入库（§5.3-3）：notebooks/chapters → notes → files →
    //    tasks → messages（content_hash 按 §1.4 重算）→ anchors。全量保留原 id。
    await db.transaction((txn) async {
      for (final r in notebooks) {
        await txn.insert('notebooks', r);
      }
      for (final r in chapters) {
        await txn.insert('chapters', r);
      }
      for (final r in notes) {
        await txn.insert('notes', r);
      }
      for (final r in fileRows) {
        await txn.insert('files', r);
      }
      for (final r in tasks) {
        await txn.insert('tasks', r);
      }
      for (final r in messages) {
        await txn.insert('messages', {
          ...r,
          'attachments': jsonEncode(r['attachments'] ?? const []),
          'content_hash': computeContentHash(
            r['package_name'] as String? ?? '',
            r['title'] as String? ?? '',
            r['body'] as String? ?? '',
            (r['posted_at'] as num?)?.toInt() ?? 0,
          ),
        });
      }
      for (final r in anchors) {
        await txn.insert('task_anchors', r);
      }
    });

    // 5. marker 一致性校验（§5.3-4）：锚点 marker 必须在对应正文中存在；
    //    缺失记入警告列表（不阻断）。file 锚点无 marker，跳过。
    final bodiesById = {
      for (final r in messages) r['id'] as String: r['body'] as String? ?? '',
    };
    final notesById = {
      for (final r in notes) r['id'] as String: r['content'] as String? ?? '',
    };
    for (final a in anchors) {
      final anchorId = a['id'] as String;
      final targetType = a['target_type'] as String;
      final targetId = a['target_id'] as String;
      final body = switch (targetType) {
        'message' => bodiesById[targetId],
        'note' => notesById[targetId],
        _ => null,
      };
      if (targetType == 'file') continue;
      if (body == null) {
        warnings.add('锚点 $anchorId 的目标 $targetType/$targetId 不存在');
      } else if (!body.contains(anchorMarker(anchorId))) {
        warnings.add('锚点 $anchorId 的 marker 在 $targetType/$targetId 正文中缺失');
      }
    }

    return ArchiveImportResult(
      tasks: tasks.length,
      messages: messages.length,
      notes: notes.length,
      files: fileRows.length,
      anchors: anchors.length,
      warnings: warnings,
    );
  }

  /// 解析笔记 .md 的 front matter（导出侧 _noteMarkdown 的逆操作）：
  /// 标量只支持两种形态——裸字符串 / JSON 双引号串（合法 YAML flow scalar），
  /// attachments 为 flow 列表。缺 front matter 或缺 id/chapter_id 返回 null。
  static Map<String, Object?>? _parseNoteMarkdown(String text) {
    if (!text.startsWith('---\n')) return null;
    final end = text.indexOf('\n---\n', 4);
    if (end < 0) return null;
    final fields = <String, String>{};
    for (final line in text.substring(4, end).split('\n')) {
      final sep = line.indexOf(': ');
      if (sep <= 0) continue;
      fields[line.substring(0, sep)] = line.substring(sep + 2);
    }
    final id = _scalar(fields['id']);
    final chapterId = _scalar(fields['chapter_id']);
    if (id == null || chapterId == null) return null;
    return {
      'id': id,
      'chapter_id': chapterId,
      'title': _scalar(fields['title']) ?? '',
      'content': text.substring(end + 5),
      'content_format': _scalar(fields['content_format']) ?? 'markdown',
      'attachments': jsonEncode(_flowList(fields['attachments'])),
      'created_at': int.tryParse(fields['created_at'] ?? '') ?? 0,
      'updated_at': int.tryParse(fields['updated_at'] ?? '') ?? 0,
    };
  }

  /// YAML 标量：JSON 双引号串解码，其余原样（导出侧 _yamlScalar 的逆）。
  static String? _scalar(String? raw) {
    if (raw == null) return null;
    if (raw.startsWith('"')) {
      try {
        return jsonDecode(raw) as String;
      } catch (_) {
        return raw;
      }
    }
    return raw;
  }

  /// flow 列表 `[a, "b, c"]`：逗号在引号外才分隔，元素按标量规则解码。
  static List<String> _flowList(String? raw) {
    if (raw == null) return const [];
    final t = raw.trim();
    if (!t.startsWith('[') || !t.endsWith(']')) return const [];
    final inner = t.substring(1, t.length - 1).trim();
    if (inner.isEmpty) return const [];
    final items = <String>[];
    final buf = StringBuffer();
    var inQuote = false;
    var escaped = false;
    for (final ch in inner.split('')) {
      if (escaped) {
        buf.write(ch);
        escaped = false;
        continue;
      }
      if (ch == r'\' && inQuote) {
        buf.write(ch);
        escaped = true;
        continue;
      }
      if (ch == '"') {
        inQuote = !inQuote;
        buf.write(ch);
        continue;
      }
      if (ch == ',' && !inQuote) {
        items.add(buf.toString().trim());
        buf.clear();
        continue;
      }
      buf.write(ch);
    }
    items.add(buf.toString().trim());
    return [for (final i in items) _scalar(i) ?? i];
  }
}
