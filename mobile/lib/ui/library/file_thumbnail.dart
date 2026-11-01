import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/library_file.dart';
import '../../services/file_thumb_service.dart';
import '../../services/library_file_service.dart' show guessMimeFromName;
import 'files_page.dart' show libraryFileIcon;

/// 文件缩略图（2026-11-01）：图片直接解码（cacheWidth 限制解码尺寸，
/// 列表/卡片滚动不爆内存）；视频经平台通道取首帧、PDF 取首页渲染；
/// 文本类文件（txt/md/log/json/csv 等）显示内容开头片段；其余回退类型
/// 图标。文件区列表/卡片模式与 Agent 附件卡片共用。
class FileThumbnail extends StatelessWidget {
  final LibraryFile file;

  /// 显示边长（逻辑像素）。
  final double size;

  /// 回退图标大小（缺省随 size 缩放）。
  final double? iconSize;

  /// true 时忽略 size、充满父约束（网格卡的封面区）。
  final bool fill;

  const FileThumbnail({
    super.key,
    required this.file,
    this.size = 40,
    this.iconSize,
    this.fill = false,
  });

  /// 判断口径统一：mime 优先，mime 缺失（旧数据未回填）按扩展名兜底。
  static String _mime(LibraryFile f) =>
      (f.mimeType ?? guessMimeFromName(f.name) ?? '').toLowerCase();

  static bool isImage(LibraryFile f) => _mime(f).startsWith('image/');

  static bool isVideo(LibraryFile f) => _mime(f).startsWith('video/');

  static bool isPdf(LibraryFile f) => _mime(f) == 'application/pdf';

  /// 可做内容片段预览的文本类文件。
  static bool isTextLike(LibraryFile f) {
    if (_mime(f).startsWith('text/')) return true;
    const exts = [
      '.txt', '.md', '.markdown', '.log', '.json', '.csv',
      '.yaml', '.yml', '.xml', '.html', '.htm',
    ];
    final name = f.name.toLowerCase();
    return exts.any(name.endsWith);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fallback = Icon(libraryFileIcon(file),
        size: iconSize ?? size * 0.55, color: cs.primary);

    final Widget content;
    if (isImage(file)) {
      // fill 模式缓存尺寸按网格卡实际大小估（2x 足够清晰）
      final cache = ((fill ? 160 : size) * 2).round();
      content = Image.file(
        File(file.localPath),
        fit: BoxFit.cover,
        // 2x 物理像素足够：原图可能是几千万像素的照片
        cacheWidth: cache,
        cacheHeight: cache,
        errorBuilder: (_, __, ___) => Center(child: fallback),
      );
    } else if (isVideo(file)) {
      content = _AsyncThumb(
        future: FileThumbService.instance.videoThumb(file.localPath),
        fallback: fallback,
        // 播放角标提示这是视频
        overlay: Icon(Icons.play_circle_outline,
            size: (iconSize ?? size * 0.55) * 0.8,
            color: Colors.white.withValues(alpha: 0.9)),
      );
    } else if (isPdf(file)) {
      content = _AsyncThumb(
        future: FileThumbService.instance.pdfThumb(file.localPath),
        fallback: fallback,
      );
    } else if (isTextLike(file)) {
      content = _TextPreview(path: file.localPath, fallback: fallback);
    } else {
      content = Center(child: fallback);
    }

    if (fill) return SizedBox.expand(child: content);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: size,
        height: size,
        child: content,
      ),
    );
  }
}

/// 异步位图缩略图（视频首帧 / PDF 首页共用）：加载完成淡入，失败回退图标。
class _AsyncThumb extends StatelessWidget {
  final Future<Object?> future;
  final Widget fallback;
  final Widget? overlay;

  const _AsyncThumb({
    required this.future,
    required this.fallback,
    this.overlay,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Object?>(
      future: future,
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes is! Uint8List) return Center(child: fallback);
        final image = Image.memory(
          bytes,
          fit: BoxFit.cover,
          // 滚动 rebuild 不闪动
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => Center(child: fallback),
        );
        if (overlay == null) return image;
        return Stack(
          fit: StackFit.expand,
          children: [image, Center(child: overlay)],
        );
      },
    );
  }
}

/// 文本类文件的内容片段预览：极小字号平铺开头内容，远看是「文档」质感。
class _TextPreview extends StatelessWidget {
  final String path;
  final Widget fallback;

  const _TextPreview({required this.path, required this.fallback});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<String?>(
      future: FileThumbService.instance.textSnippet(path),
      builder: (context, snap) {
        final text = snap.data;
        if (text == null || text.trim().isEmpty) {
          return Center(child: fallback);
        }
        return Container(
          color: cs.surfaceContainerHighest,
          padding: const EdgeInsets.all(3),
          alignment: Alignment.topLeft,
          child: Text(
            text,
            maxLines: 12,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontSize: 5,
              height: 1.15,
              color: cs.onSurfaceVariant,
              fontFamily: 'monospace',
            ),
          ),
        );
      },
    );
  }
}
