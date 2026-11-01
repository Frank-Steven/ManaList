import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/message.dart';
import 'app_log.dart';

/// 附件仓库（P3-2）：把用户选中的文件**复制进应用私有目录**并去重。
///
/// 为什么必须复制：`image_picker` 返回的是**缓存路径**，系统清理缓存后原路径就失效；
/// `file_picker` 还可能只给 content:// URI。只存「访问方式」等于把附件做成死路径，
/// 所以这里落盘到 `<支持目录>/attachments/<sha256>.<ext>`，并把 sha256 作为文件名，
/// 同一份文件重复导入只占一份空间。
class AttachmentStore {
  AttachmentStore._();

  static final AttachmentStore instance = AttachmentStore._();

  static const _dirName = 'attachments';

  Directory? _dir;

  /// 单测用：覆盖附件根目录（避免依赖 path_provider 插件）。设置后不走缓存。
  static Directory? debugDirOverride;

  /// 附件根目录（不存在则创建）。
  Future<Directory> dir() async {
    final override = debugDirOverride;
    if (override != null) {
      if (!override.existsSync()) override.createSync(recursive: true);
      return override;
    }
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, _dirName));
    if (!d.existsSync()) d.createSync(recursive: true);
    _dir = d;
    return d;
  }

  /// 复制一份字节进仓库。sha256 相同则复用已有文件。
  Future<Attachment> importBytes(
    Uint8List bytes, {
    required String kind,
    String? label,
    String? mimeType,
    String? fileName,
  }) async {
    final digest = sha256.convert(bytes).toString();
    final ext = _extensionOf(fileName);
    final base = await dir();
    final file = File(p.join(base.path, '$digest$ext'));
    if (!file.existsSync()) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return Attachment(
      id: const Uuid().v4(),
      kind: kind,
      label: label ?? (fileName ?? digest),
      bytes: bytes.length,
      access: AttachmentAccess(
        type: AttachmentAccess.typeLocalPath,
        value: file.path,
        mimeType: mimeType,
      ),
    );
  }

  /// 从磁盘路径导入（图片选择器/文件选择器返回的路径）。
  Future<Attachment?> importPath(
    String path, {
    required String kind,
    String? label,
    String? mimeType,
  }) async {
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      final bytes = await f.readAsBytes();
      return await importBytes(bytes,
          kind: kind,
          label: label ?? p.basename(path),
          mimeType: mimeType,
          fileName: path);
    } catch (e, st) {
      AppLog.instance.warn('attachment.import', e, st);
      return null;
    }
  }

  /// 解析出可读的本地文件；旧数据（缓存路径 / content URI）也能尽力还原。
  File? resolve(Attachment a) {
    if (a.access.type != AttachmentAccess.typeLocalPath &&
        a.access.type != AttachmentAccess.typeContentUri) {
      return null;
    }
    final value = a.access.value;
    if (value.isEmpty) return null;
    final f = File(value);
    return f.existsSync() ? f : null;
  }

  /// 删除仓库里的文件（同一 sha256 被多条消息引用时不删，交给系统清理）。
  Future<void> deleteQuietly(Attachment a) async {
    final f = resolve(a);
    if (f == null) return;
    try {
      final base = await dir();
      if (!p.isWithin(base.path, f.path)) return; // 只删仓库内的文件
      await f.delete();
    } catch (e, st) {
      AppLog.instance.warn('attachment.delete', e, st);
    }
  }

  static String _extensionOf(String? name) {
    if (name == null) return '';
    final ext = p.extension(name);
    if (ext.isEmpty || ext.length > 12) return '';
    return ext.toLowerCase();
  }
}
