import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../models/library_file.dart';
import '../../services/database.dart';

/// `![name](file://id)` 中的文件 id。
final RegExp fileImagePattern =
    RegExp(r'!\[[^\]]*\]\(file://([0-9a-fA-F-]+)\)');

/// 统一的 markdown 渲染管线：笔记预览、消息详情共用。
/// `file://` 图片解析到 attachment_store 本地文件。
///
/// v12（anchors-v2.md §5）：锚点职责已移除——锚点不再写入正文，
/// 本组件只负责 markdown 正文渲染；任务关联见对象详情的「关联任务」区。
class AnchoredMarkdownBody extends StatefulWidget {
  final String data;
  final void Function(String text, String? href, String? title)? onTapLink;

  const AnchoredMarkdownBody({
    super.key,
    required this.data,
    this.onTapLink,
  });

  @override
  State<AnchoredMarkdownBody> createState() => AnchoredMarkdownBodyState();

  /// 测试注入：非空时 [_load] 跳过 DB 预取，直接使用注入的文件联查数据。
  @visibleForTesting
  static Map<String, LibraryFile>? debugFiles;
}

class AnchoredMarkdownBodyState extends State<AnchoredMarkdownBody> {
  Map<String, LibraryFile> _files = const {};

  /// 联查数据版本：每次 _load 完成递增（驱动 MarkdownBody key 重建）。
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AnchoredMarkdownBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) _load();
  }

  Future<void> _load() async {
    // widget 测试注入（sqflite_ffi 与 FakeAsync 不兼容，测试绕过 DB 直给联查数据）
    final debug = AnchoredMarkdownBody.debugFiles;
    if (debug != null) {
      _files = debug;
      if (mounted) setState(() => _revision++);
      return;
    }
    final fileIds = fileImagePattern
        .allMatches(widget.data)
        .map((m) => m.group(1)!)
        .toSet()
        .toList();
    final files = await AppDatabase.instance.filesByIds(fileIds);
    if (!mounted) return;
    setState(() {
      _files = {for (final f in files) f.id: f};
      // flutter_markdown 的 MarkdownBuilder 只在 data 变化时重建内部解析树，
      // 联查数据异步到达不会触发重建——用 key 版本号强制重建。
      _revision++;
    });
  }

  /// `file://` 图片 → attachment_store 本地文件；查不到/非图片降级为文件名占位。
  /// 其他 scheme 不联网加载（隐私与离线优先），显示占位文本。
  Widget _buildImage(MarkdownImageConfig config) {
    final cs = Theme.of(context).colorScheme;
    final uri = config.uri;
    if (uri.scheme == 'file') {
      final id = uri.host.isNotEmpty
          ? uri.host
          : uri.path.replaceAll('/', '');
      final f = _files[id];
      final isImage = f?.mimeType?.startsWith('image/') ?? false;
      if (f != null && isImage) {
        final file = File(f.localPath);
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            file,
            // F4 §3.3-12：内联预览图限制解码尺寸（消息流宽 ~360dp × 3x）
            cacheWidth: 1080,
            errorBuilder: (_, __, ___) =>
                Text('[图片已不可用: ${f.name}]',
                    style: TextStyle(color: cs.onSurfaceVariant)),
          ),
        );
      }
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file_outlined,
              size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(f?.name ?? config.alt ?? '附件',
              style: TextStyle(color: cs.onSurfaceVariant)),
        ],
      );
    }
    return Text('[图片: ${config.alt ?? uri.toString()}]',
        style: TextStyle(color: cs.onSurfaceVariant));
  }

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      // flutter_markdown 内部按 data 缓存解析树；联查数据到达后 _revision
      // 变化，强制重建让图片解析用上文件数据。
      key: ValueKey(_revision),
      data: widget.data,
      // 通知正文/笔记的单换行都按换行渲染（markdown 默认把单 \n 当空格，
      // 会糊掉采集原文的换行结构）
      softLineBreak: true,
      sizedImageBuilder: _buildImage,
      onTapLink: widget.onTapLink == null
          ? null
          : (text, href, title) => widget.onTapLink!(text, href, title),
    );
  }
}
