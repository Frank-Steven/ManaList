import 'dart:io';

import 'package:flutter/material.dart';

import '../../../models/library_file.dart';
import '../../../services/assistant/models.dart';
import '../../../services/notification_bridge.dart';
import '../../library/files_page.dart' show libraryFileIcon;

/// 附件的展示元数据（由 chat_page 按类型从库里解析）。
class AttachmentMeta {
  final String title;
  final IconData icon;

  /// file 类型附件的库实体（媒体预览/文件块用），其余类型为 null。
  final LibraryFile? file;

  const AttachmentMeta({
    required this.title,
    required this.icon,
    this.file,
  });
}

String formatAttachmentSize(int? bytes) {
  if (bytes == null) return '大小未知';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

bool _isImage(LibraryFile f) => (f.mimeType ?? '').startsWith('image/');
bool _isVideo(LibraryFile f) => (f.mimeType ?? '').startsWith('video/');
bool _isAudio(LibraryFile f) => (f.mimeType ?? '').startsWith('audio/');

/// 消息附件的堆叠卡片（2026-11-01）：
/// 多个附件横向堆叠（纸牌感），左右滑动切换；按类型渲染——
/// 媒体（图片可直接预览/视频/音频）显示预览，文档显示文件块
/// （类型图标 + 文件名 + 大小）。
class AttachmentCardStack extends StatefulWidget {
  final List<ChatAttachment> attachments;
  final AttachmentMeta? Function(ChatAttachment) metaOf;

  const AttachmentCardStack({
    super.key,
    required this.attachments,
    required this.metaOf,
  });

  @override
  State<AttachmentCardStack> createState() => _AttachmentCardStackState();
}

class _AttachmentCardStackState extends State<AttachmentCardStack> {
  late final PageController _ctrl =
      PageController(viewportFraction: 0.62);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.attachments;
    if (items.length == 1) {
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 210,
          height: 132,
          child: AttachmentCard(
              attachment: items.first, meta: widget.metaOf(items.first)),
        ),
      );
    }
    // 多附件：PageView 视口比例 < 1，两侧卡片露出边缘（纸牌堆叠感），
    // 非当前页缩小 + 微旋，左右滑动切换预览/文件信息
    return SizedBox(
      height: 132,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return PageView.builder(
            controller: _ctrl,
            padEnds: false,
            itemCount: items.length,
            itemBuilder: (context, i) {
              var delta = 0.0;
              if (_ctrl.hasClients && _ctrl.position.haveDimensions) {
                delta = (_ctrl.page ?? _ctrl.initialPage.toDouble()) - i;
              }
              final scale = 1 - 0.08 * delta.abs().clamp(0.0, 1.0);
              final angle = 0.035 * delta.clamp(-1.0, 1.0);
              return Transform.rotate(
                angle: angle,
                child: Transform.scale(
                  scale: scale,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: AttachmentCard(
                        attachment: items[i],
                        meta: widget.metaOf(items[i])),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// 单个附件卡片：按类型渲染媒体预览或文件块。
class AttachmentCard extends StatelessWidget {
  final ChatAttachment attachment;
  final AttachmentMeta? meta;

  const AttachmentCard({
    super.key,
    required this.attachment,
    required this.meta,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final file = meta?.file;
    final body = file != null && _isImage(file)
        ? _ImagePreview(file: file)
        : _FileBlock(attachment: attachment, meta: meta);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant, width: 0.5),
      ),
      child: body,
    );
  }
}

/// 图片附件：直接预览，点按全屏（可缩放）。
class _ImagePreview extends StatelessWidget {
  final LibraryFile file;

  const _ImagePreview({required this.file});

  @override
  Widget build(BuildContext context) {
    final image = Image.file(
      File(file.localPath),
      fit: BoxFit.cover,
      // 卡片预览不需要原图全分辨率，限制解码尺寸省内存
      cacheWidth: 420,
      cacheHeight: 420,
      errorBuilder: (_, __, ___) => _IconFallback(
          icon: Icons.broken_image_outlined, label: file.name),
    );
    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          insetPadding: const EdgeInsets.all(12),
          child: InteractiveViewer(
            child: Image.file(File(file.localPath),
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.broken_image_outlined, size: 64)),
          ),
        ),
      ),
      child: SizedBox.expand(child: image),
    );
  }
}

/// 非图片附件：文件块（类型图标 + 文件名 + 大小）；
/// 视频/音频带播放 affordance，点按交给系统应用打开。
class _FileBlock extends StatelessWidget {
  final ChatAttachment attachment;
  final AttachmentMeta? meta;

  const _FileBlock({required this.attachment, required this.meta});

  Future<void> _open(BuildContext context) async {
    final file = meta?.file;
    if (file == null) return;
    final ok = await NotificationBridge.instance
        .openDeeplink('file://${file.localPath}');
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('系统没有可打开该文件的应用')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final file = meta?.file;
    final playable = file != null && (_isVideo(file) || _isAudio(file));
    final icon = file != null
        ? (_isVideo(file)
            ? Icons.play_circle_outline
            : _isAudio(file)
                ? Icons.audiotrack_outlined
                : libraryFileIcon(file))
        : (meta?.icon ?? Icons.attach_file);
    final sizeText = file == null
        ? switch (attachment.type) {
            ChatAttachmentType.note => '笔记',
            ChatAttachmentType.message => '消息',
            _ => '文件',
          }
        : formatAttachmentSize(file.size);
    return InkWell(
      onTap: playable ? () => _open(context) : null,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 30, color: cs.primary),
            const Spacer(),
            Text(
              meta?.title ?? attachment.id,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              sizeText,
              style: TextStyle(
                  fontSize: 10,
                  color: cs.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconFallback extends StatelessWidget {
  final IconData icon;
  final String label;

  const _IconFallback({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 28, color: cs.onSurfaceVariant),
          const SizedBox(height: 4),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}
