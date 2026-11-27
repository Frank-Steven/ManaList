import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/library_file.dart';
import '../models/message.dart';
import 'assistant/models.dart';
import 'attachment_store.dart';
import 'database.dart';

/// JSON 文本内的子串判据：把 `value` 编成 JSON 字面量（含引号）后交给 `instr()`。
///
/// 为什么不拼 LIKE：JSON 会把 Windows 路径的 `\` 转义成 `\\`，而 LIKE 的
/// `ESCAPE` 又要把 `\\` 折回单个 `\` —— 两层转义叠在一起必然匹配不到
/// （R03-A4 实测：消息附件引用被漏算）。`instr()` 是**字面子串**匹配，
/// 拿 jsonEncode 的结果直接比，不经过任何转义规则。
String jsonNeedle(Object value) => jsonEncode(value);

/// 笔记正文里的文件引用：`![name](file://<fileId>)`。
///
/// 与 ui/messages/anchored_markdown.dart、note_editor_page.dart 的写法同语义；
/// 刻意在 services 内自带一份正则（不反向 import ui/，保持依赖方向）。
final RegExp noteFileLinkPattern =
    RegExp(r'!\[[^\]]*\]\(file://([0-9a-fA-F-]+)\)');

/// 文件被引用的统计（删除前检查，design-v3 §1.3；R03-A4 扩到 7 类来源）。
class LibraryFileReferences {
  /// 同 local_path 的**其它** files 行数（物理文件按 sha256 去重，可能多行共享）。
  final int fileRowCount;

  /// messages.attachments 里 access.value == 路径的消息数。
  final int messageCount;

  /// notes.attachments 引用该文件 id 的笔记数。
  final int noteCount;

  /// 笔记**正文** `![name](file://<id>)` 引用该文件的笔记数。
  final int noteContentCount;

  /// conversations.draft_attachments 里 type=='file' 且 id 命中的会话数。
  final int draftCount;

  /// chat_messages.attachments 里 type=='file' 且 id 命中的消息数。
  final int chatCount;

  /// target_type='file' 指向该文件的任务锚点数。
  final int anchorCount;

  const LibraryFileReferences({
    this.fileRowCount = 0,
    this.messageCount = 0,
    this.noteCount = 0,
    this.noteContentCount = 0,
    this.draftCount = 0,
    this.chatCount = 0,
    this.anchorCount = 0,
  });

  /// 是否被「删掉就会失效」的引用持有（笔记/正文/消息/草稿/聊天/锚点）。
  ///
  /// **不含** [fileRowCount]：同路径的其它 files 行是另一条**活着的**库记录，
  /// 删掉本条不会让它失效，所以不该拦住「删这一行」。
  bool get hasAny =>
      messageCount > 0 ||
      noteCount > 0 ||
      noteContentCount > 0 ||
      draftCount > 0 ||
      chatCount > 0 ||
      anchorCount > 0;

  /// 物理文件是否仍被任何来源占用（= [hasAny] 或还有同路径 files 行）。
  ///
  /// 这是**删除文件本体**的唯一判据：只要还有一条同路径记录或任何引用，
  /// 本体就必须保留，否则会给对方留下死路径。
  bool get hasPathHolders => hasAny || fileRowCount > 0;
}

// ---- 文件夹路径（DB v9，虚拟文件夹：'' = 根目录，'/' 分隔段） ----

/// 单段文件夹名是否合法（非空、不含路径分隔符、不是 . / ..）。
bool isValidFolderName(String name) =>
    name.isNotEmpty &&
    !name.contains('/') &&
    !name.contains('\\') &&
    name != '.' &&
    name != '..';

/// 拼接子文件夹路径（[parent] 为 '' 时结果就是 [name]）。
String joinFolderPath(String parent, String name) =>
    parent.isEmpty ? name : '$parent/$name';

/// 父文件夹路径；根目录（''）的父仍是 ''。
String parentFolderPath(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

/// 路径最后一段（显示名）；根目录返回 ''。
String folderName(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

/// [path] 是否为 [ancestor] 的自身或后代（前缀匹配按段边界）。
bool folderIsUnder(String path, String ancestor) =>
    ancestor.isEmpty || path == ancestor || path.startsWith('$ancestor/');

/// 从文件名扩展名推断 MIME（2026-11-01）：导入时调用方常给不出 mime，
/// 不补的话 files 表 mime_type 为 NULL，缩略图/图标判断全部失效。
/// 覆盖常见媒体/文档类型；未知返回 null（保留「未知」语义，不硬猜）。
String? guessMimeFromName(String name) {
  final ext = p.extension(name).toLowerCase();
  if (ext.length < 2) return null;
  return switch (ext.substring(1)) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    'heic' || 'heif' => 'image/heic',
    'svg' => 'image/svg+xml',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    'mkv' => 'video/x-matroska',
    'webm' => 'video/webm',
    '3gp' => 'video/3gpp',
    'avi' => 'video/x-msvideo',
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'm4a' => 'audio/mp4',
    'aac' => 'audio/aac',
    'flac' => 'audio/flac',
    'ogg' => 'audio/ogg',
    'txt' || 'log' || 'md' || 'markdown' => 'text/plain',
    'csv' => 'text/csv',
    'json' => 'application/json',
    'xml' || 'yaml' || 'yml' || 'html' || 'htm' => 'text/plain',
    'pdf' => 'application/pdf',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt' => 'application/vnd.ms-powerpoint',
    'pptx' =>
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'zip' => 'application/zip',
    'apk' => 'application/vnd.android.package-archive',
    _ => null,
  };
}

/// 归一后的 MIME（B29）：库里有值就用，为 NULL（旧数据/归档导入）按扩展名兜底。
/// 这是「类型判断」的唯一入口，UI 层不要再各自 `mimeType ?? guessMimeFromName(...)`。
String effectiveMimeOf(LibraryFile f) =>
    f.mimeType ?? guessMimeFromName(f.name) ?? '';

/// 是否图片附件（B29 唯一判定）：MIME 前缀命中，或 MIME 缺失时扩展名兜底命中。
///
/// 背景：存量行可能 `mime_type` + `size` 双 NULL，只认 mime 前缀会把真图片判成
/// 「非图片」，附件预算于是静默算 0。
bool isImageFile(LibraryFile f) => effectiveMimeOf(f).startsWith('image/');

/// 重命名锁定后缀（2026-11-01）：文件不允许改后缀名（类型语义会乱），
/// 用户输入的不同后缀（或重复的原后缀）一律剥掉，再拼回 [original] 的
/// 原后缀；原文件无后缀则按输入原样返回。
String lockedRename(String original, String input) {
  final ext = p.extension(original);
  var base = input.trim();
  if (ext.isEmpty) return base;
  final lower = base.toLowerCase();
  if (lower.endsWith(ext.toLowerCase())) {
    base = base.substring(0, base.length - ext.length);
  } else {
    final typedExt = p.extension(base);
    if (typedExt.isNotEmpty) {
      base = base.substring(0, base.length - typedExt.length);
    }
  }
  return '$base$ext';
}

/// 某文件夹的一层视图：直接子文件夹名 + 直接文件。
class LibraryFolderView {
  /// 直接子文件夹名（不含路径前缀），按字典序。
  final List<String> folders;
  final List<LibraryFile> files;

  const LibraryFolderView({required this.folders, required this.files});

  bool get isEmpty => folders.isEmpty && files.isEmpty;
}

/// 库·文件区的写操作服务（design-v3 §1.3/§3.1）：
/// 导入（落 attachment_store + 写 files 表）、重命名、删除（引用检查）。
class LibraryFileService {
  LibraryFileService._();

  static final LibraryFileService instance = LibraryFileService._();

  static const _uuid = Uuid();

  /// 从磁盘路径导入（file_picker / image_picker 返回的路径）。
  /// 文件本体复制进附件仓库（sha256 去重），元数据入 files 表。
  /// 源文件不可读时返回 null（与 AttachmentStore.importPath 一致）。
  /// [folder]：导入落到的文件夹（v9，'' = 根目录）。
  Future<LibraryFile?> importFromPath(
    String path, {
    String? name,
    String? mimeType,
    String source = FileSource.userUpload,
    String folder = '',
  }) async {
    final att = await AttachmentStore.instance.importPath(
      path,
      kind: Attachment.kindFile,
      label: name,
      mimeType: mimeType,
    );
    if (att == null) return null;
    final fileName = name ?? att.label ?? p.basename(path);
    final file = LibraryFile(
      id: _uuid.v4(),
      name: fileName,
      // 调用方没给 mime 时从扩展名推断：否则缩略图/图标判断失效
      mimeType: mimeType ?? att.access.mimeType ?? guessMimeFromName(fileName),
      size: att.bytes,
      localPath: att.access.value,
      source: source,
      folder: folder,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await AppDatabase.instance.insertFile(file);
    return file;
  }

  /// 从内存字节导入（截图等没有落盘路径的场景）。
  Future<LibraryFile> importBytes(
    Uint8List bytes, {
    required String name,
    String? mimeType,
    String source = FileSource.userUpload,
    String folder = '',
  }) async {
    final att = await AttachmentStore.instance.importBytes(
      bytes,
      kind: Attachment.kindFile,
      label: name,
      mimeType: mimeType,
      fileName: name,
    );
    final file = LibraryFile(
      id: _uuid.v4(),
      name: name,
      mimeType:
          mimeType ?? att.access.mimeType ?? guessMimeFromName(name),
      size: att.bytes,
      localPath: att.access.value,
      source: source,
      folder: folder,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await AppDatabase.instance.insertFile(file);
    return file;
  }

  /// 重命名（2026-11-01 起锁定后缀名，见 [lockedRename]）。
  Future<void> rename(String id, String name) async {
    final file = await AppDatabase.instance.getFileById(id);
    if (file == null) return;
    final newName = lockedRename(file.name, name);
    if (newName.isEmpty || newName == file.name) return;
    await AppDatabase.instance.renameFile(id, newName);
  }

  // ---- 文件夹（v9 虚拟派生 + v10 空文件夹持久化） ----

  /// 新建空文件夹落库（v10；含祖先路径补齐，幂等）。
  Future<void> createFolder(String path) =>
      AppDatabase.instance.insertLibraryFolder(path);

  /// 某文件夹及其全部后代文件夹下的文件（2026-11-01 文件夹整选用）。
  Future<List<LibraryFile>> filesUnderFolder(String path) =>
      AppDatabase.instance.getFilesUnderFolder(path);

  /// 一层视图：[path] 下的直接子文件夹名 + 直接文件。
  /// [extraFolders]：UI 层会话内补充的文件夹路径，参与子文件夹派生。
  Future<LibraryFolderView> listFolder(String path,
      {Set<String> extraFolders = const {}}) async {
    final files = await AppDatabase.instance.getFilesInFolder(path);
    final allPaths = {
      ...await AppDatabase.instance.getFileFolders(),
      ...await AppDatabase.instance.getLibraryFolders(),
      ...extraFolders,
    };
    final children = <String>{};
    final prefix = path.isEmpty ? '' : '$path/';
    for (final f in allPaths) {
      if (!f.startsWith(prefix)) continue;
      final rest = f.substring(prefix.length);
      if (rest.isEmpty) continue;
      children.add(rest.contains('/')
          ? rest.substring(0, rest.indexOf('/'))
          : rest);
    }
    final folders = children.toList()..sort();
    return LibraryFolderView(folders: folders, files: files);
  }

  /// 全部文件夹路径（含 [extraFolders]；移动目标选择器用）。
  Future<List<String>> allFolders({Set<String> extraFolders = const {}}) async {
    final all = {
      ...await AppDatabase.instance.getFileFolders(),
      ...await AppDatabase.instance.getLibraryFolders(),
      ...extraFolders,
    }.toList()
      ..sort();
    return all;
  }

  /// 批量移动文件到 [path]（'' = 根目录）。
  Future<void> moveToFolder(List<String> ids, String path) =>
      AppDatabase.instance.moveFilesToFolder(ids, path);

  /// 重命名文件夹：[path] 整棵子树换前缀（虚拟文件夹 = 批量改 folder 字段；
  /// v10 持久化文件夹行同步换前缀）。
  /// 返回受影响文件数；[newName] 不合法或目标已存在时抛 [ArgumentError]。
  Future<int> renameFolder(String path, String newName) async {
    if (path.isEmpty) throw ArgumentError('根目录不能重命名');
    if (!isValidFolderName(newName)) throw ArgumentError('非法文件夹名：$newName');
    final newPath = joinFolderPath(parentFolderPath(path), newName);
    if (newPath == path) return 0;
    final existing = {
      ...await AppDatabase.instance.getFileFolders(),
      ...await AppDatabase.instance.getLibraryFolders(),
    };
    if (existing.any((f) => folderIsUnder(f, newPath))) {
      throw ArgumentError('已存在同名文件夹：$newName');
    }
    final moved = <String, List<String>>{}; // newFolder -> fileIds
    final files = await AppDatabase.instance.getFiles();
    for (final f in files) {
      if (!folderIsUnder(f.folder, path)) continue;
      final suffix = f.folder.substring(path.length); // '' 或 '/...'
      moved.putIfAbsent('$newPath$suffix', () => []).add(f.id);
    }
    for (final entry in moved.entries) {
      await AppDatabase.instance.moveFilesToFolder(entry.value, entry.key);
    }
    await AppDatabase.instance.renameLibraryFolderTree(path, newPath);
    return moved.values.fold<int>(0, (s, l) => s + l.length);
  }

  /// 删除文件夹：其中（含子文件夹）的文件上移一层到父文件夹，文件本身不删；
  /// 持久化的文件夹行（含子树）一并删除。返回上移的文件数。
  Future<int> deleteFolder(String path) async {
    if (path.isEmpty) return 0;
    final parent = parentFolderPath(path);
    final files = await AppDatabase.instance.getFiles();
    final moved = <String, List<String>>{};
    for (final f in files) {
      if (!folderIsUnder(f.folder, path)) continue;
      final suffix = f.folder.substring(path.length); // '' 或 '/...'
      final target = suffix.isEmpty
          ? parent
          : parent.isEmpty
              ? suffix.substring(1) // 上移到根目录，去掉前导 '/'
              : '$parent$suffix';
      moved.putIfAbsent(target, () => []).add(f.id);
    }
    for (final entry in moved.entries) {
      await AppDatabase.instance.moveFilesToFolder(entry.value, entry.key);
    }
    await AppDatabase.instance.deleteLibraryFolderTree(path);
    return moved.values.fold<int>(0, (s, l) => s + l.length);
  }

  /// 删除前引用检查（唯一实现）：委托 [countPathReferences]，
  /// 用该文件的 local_path（路径键）+ fileId（ID 键）统计 7 类来源。
  Future<LibraryFileReferences> countReferences(String fileId) async {
    final file = await AppDatabase.instance.getFileById(fileId);
    if (file == null) {
      // 行已不存在：只能按 ID 键统计（路径未知）
      return countPathReferences('', fileId: fileId);
    }
    return countPathReferences(file.localPath,
        fileId: fileId, excludeFileId: fileId);
  }

  /// 按 **路径 + ID** 统计引用（R03-A4 的 7 类来源，全部走前缀过滤以避免全表解码）。
  ///
  /// - [localPath] 为空 → 只算 ID 键来源；
  /// - [excludeFileId] 非空 → files 计数排除该行（删除自己时用）；
  /// - **命中 LIKE 但解析失败 → 计 1 条引用**（保守：宁可少删，不留死链）。
  Future<LibraryFileReferences> countPathReferences(
    String localPath, {
    String? fileId,
    String? excludeFileId,
  }) async {
    final hasPath = localPath.isNotEmpty;
    final hasId = fileId != null && fileId.isNotEmpty;
    if (!hasPath && !hasId) return const LibraryFileReferences();
    final db = await AppDatabase.instance.database;

    // 1) 同路径的其它 files 行
    var fileRowCount = 0;
    if (hasPath) {
      final rows = excludeFileId == null
          ? await db.rawQuery(
              'SELECT COUNT(*) AS n FROM files WHERE local_path = ?',
              [localPath])
          : await db.rawQuery(
              'SELECT COUNT(*) AS n FROM files WHERE local_path = ? AND id != ?',
              [localPath, excludeFileId]);
      fileRowCount = (rows.first['n'] as num?)?.toInt() ?? 0;
    }

    /// 逐行解码的通用计数：先用 `instr` 字面量过滤（大表不全解），再按 [matches] 判定。
    Future<int> countJsonRows(String table, String column, String needle,
        bool Function(List<dynamic> list) matches) async {
      final rows = await db.query(table, columns: [column],
          where: 'instr($column, ?) > 0', whereArgs: [needle]);
      var n = 0;
      for (final row in rows) {
        final raw = row[column] as String?;
        if (raw == null || raw.isEmpty) continue;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List && matches(decoded)) n++;
        } catch (_) {
          n++; // 保守：命中 LIKE 却解不出 → 当作有引用
        }
      }
      return n;
    }

    // 2) messages.attachments：access.value == 路径（不看 access.type，保守）
    var messageCount = 0;
    if (hasPath) {
      // 库里存的是 JSON 文本（路径里的 \ 已转义成 \\），必须拿 jsonNeedle 比字面量
      final rows = await db.query('messages', columns: ['attachments'],
          where: 'instr(attachments, ?) > 0',
          whereArgs: [jsonNeedle(localPath)]);
      for (final row in rows) {
        final raw = row['attachments'] as String?;
        if (raw == null || raw.isEmpty) continue;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! List) {
            messageCount++;
            continue;
          }
          final hit = decoded.any((e) =>
              e is Map &&
              e['access'] is Map &&
              (e['access'] as Map)['value'] == localPath);
          if (hit) messageCount++;
        } catch (_) {
          messageCount++; // 保守
        }
      }
    }

    // 3) notes.attachments：元素是 string id
    var noteCount = 0;
    // 4) notes.content：`![name](file://<id>)`
    var noteContentCount = 0;
    // 5) conversations.draft_attachments：type=='file'
    var draftCount = 0;
    // 6) chat_messages.attachments：type=='file'
    var chatCount = 0;
    if (hasId) {
      final idNeedle = jsonNeedle(fileId);
      noteCount = await countJsonRows(
          'notes', 'attachments', idNeedle,
          (list) => list.any((e) => e.toString() == fileId));
      draftCount = await countJsonRows(
          'conversations', 'draft_attachments', idNeedle,
          (list) => list.any((e) =>
              e is Map && e['type'] == 'file' && e['id'] == fileId));
      chatCount = await countJsonRows(
          'chat_messages', 'attachments', idNeedle,
          (list) => list.any((e) =>
              e is Map && e['type'] == 'file' && e['id'] == fileId));

      final contentRows = await db.query('notes', columns: ['content'],
          where: 'instr(content, ?) > 0',
          whereArgs: ['file://$fileId']);
      for (final row in contentRows) {
        final raw = row['content'] as String? ?? '';
        try {
          if (noteFileLinkPattern
              .allMatches(raw)
              .any((m) => m.group(1) == fileId)) {
            noteContentCount++;
          }
        } catch (_) {
          noteContentCount++; // 保守
        }
      }
    }

    // 7) task_anchors（沿用既有查询）
    final anchorRows = await db.rawQuery(
      "SELECT COUNT(*) AS n FROM task_anchors WHERE target_type = ? AND target_id = ?",
      [AnchorTargetType.file, hasId ? fileId : ''],
    );
    final anchorCount = (anchorRows.first['n'] as num?)?.toInt() ?? 0;

    return LibraryFileReferences(
      fileRowCount: fileRowCount,
      messageCount: messageCount,
      noteCount: noteCount,
      noteContentCount: noteContentCount,
      draftCount: draftCount,
      chatCount: chatCount,
      anchorCount: anchorCount,
    );
  }

  /// 删除文件。
  ///
  /// R03-A4（路径级引用安全）：
  /// - 有引用且未 [force] → 返回 false 且不动数据；
  /// - [force] **只**绕过「有引用就拒绝删行」这一步，**不再绕过路径检查**；
  /// - 删完 files 行（锚点应用层级联，见 AppDatabase.deleteFile）后重新统计
  ///   「路径 + ID」引用：**仍有任何来源引用该路径 → 保留物理文件本体**，
  ///   避免同一 sha256 路径被其它 files 行 / 消息附件 / 笔记引用时产生死链。
  Future<bool> delete(String id, {bool force = false}) async {
    final refs = await countReferences(id);
    if (refs.hasAny && !force) return false;
    final file = await AppDatabase.instance.getFileById(id);
    if (file == null) return true;
    await AppDatabase.instance.deleteFile(id);
    // 行已删，无需 excludeFileId；只关心「是否还有人引用这个物理路径」
    final remaining =
        await countPathReferences(file.localPath, fileId: file.id);
    if (remaining.hasPathHolders) return true; // 仍被引用/同路径行 → 保留本体
    await AttachmentStore.instance.deleteQuietly(Attachment(
      id: file.id,
      kind: Attachment.kindFile,
      access: AttachmentAccess(
        type: AttachmentAccess.typeLocalPath,
        value: file.localPath,
        mimeType: file.mimeType,
      ),
    ));
    return true;
  }
}
