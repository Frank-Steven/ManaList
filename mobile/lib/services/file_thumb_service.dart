import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'app_log.dart';

/// 文件缩略图加载（2026-11-01）：视频首帧 / PDF 首页经平台通道（Android
/// 框架 API，无需第三方依赖）取回位图字节；文本类文件直接读开头片段。
/// 全部走内存缓存 + 并发合并（滚动列表反复触发同一路径时只算一次）。
/// 失败返回 null，调用方回退到类型图标。
class FileThumbService {
  FileThumbService._();

  static final FileThumbService instance = FileThumbService._();

  static const _channel = MethodChannel('dev.msgrepo.mobile/bridge');

  final Map<String, Uint8List?> _mem = {};
  final Map<String, Future<Uint8List?>> _inflight = {};

  final Map<String, String?> _textMem = {};
  final Map<String, Future<String?>> _textInflight = {};

  /// 视频首帧 JPEG 字节。
  Future<Uint8List?> videoThumb(String path) =>
      _cachedBitmap('video:$path', 'getVideoThumbnail', path);

  /// PDF 首页 PNG 字节。
  Future<Uint8List?> pdfThumb(String path) =>
      _cachedBitmap('pdf:$path', 'getPdfThumbnail', path);

  Future<Uint8List?> _cachedBitmap(
      String key, String method, String path) {
    if (_mem.containsKey(key)) return Future.value(_mem[key]);
    return _inflight.putIfAbsent(
      key,
      () => _invoke(method, path)
          .then((bytes) => _mem[key] = bytes)
          .whenComplete(() => _inflight.remove(key)),
    );
  }

  Future<Uint8List?> _invoke(String method, String path) async {
    try {
      final bytes =
          await _channel.invokeMethod<Uint8List>(method, {'path': path});
      if (bytes != null && bytes.isNotEmpty) return bytes;
    } catch (e, st) {
      // 缩略图是锦上添花：解码失败/通道缺失都静默回退图标
      AppLog.instance.warn('file-thumb.$method', e, st);
    }
    return null;
  }

  /// 文本类文件的开头片段（用于内容预览缩略图），最多 [maxChars] 字符。
  Future<String?> textSnippet(String path, {int maxChars = 600}) {
    if (_textMem.containsKey(path)) return Future.value(_textMem[path]);
    return _textInflight.putIfAbsent(
      path,
      () => _readSnippet(path, maxChars)
          .then((s) => _textMem[path] = s)
          .whenComplete(() => _textInflight.remove(path)),
    );
  }

  Future<String?> _readSnippet(String path, int maxChars) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final raf = await file.open();
      try {
        // 按字节截断避免一次读入整个大文件；尾部可能是半个 UTF-8 字符，
        // 交给解码器容错替换即可（预览用途）
        final bytes = await raf.read(maxChars * 2);
        final text = utf8.decode(bytes, allowMalformed: true);
        return text.length > maxChars ? text.substring(0, maxChars) : text;
      } finally {
        await raf.close();
      }
    } catch (e, st) {
      AppLog.instance.warn('file-thumb.text', e, st);
      return null;
    }
  }
}
