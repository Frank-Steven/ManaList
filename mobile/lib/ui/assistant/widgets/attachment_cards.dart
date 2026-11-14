import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../models/library_file.dart';
import '../../../services/assistant/models.dart';
import '../../../services/context_window.dart';
import '../../../services/notification_bridge.dart';
import '../../library/files_page.dart' show libraryFileIcon;

/// 附件的展示元数据（由 chat_page 按类型从库里解析）。
class AttachmentMeta {
  final String title;
  final IconData icon;

  /// file 类型附件的库实体（媒体预览/文件块用），其余类型为 null。
  final LibraryFile? file;

  /// 正文字符数估算（token 预算条用，assistant-v4-ui §3.6）：
  /// 消息 = body 长度，笔记 = content 长度，**文本文件** = 字节数（近似）；
  /// 对象已被删除/不可读时为 null（按 0 计）。
  ///
  /// ⚠️ 图片附件**不得**再用字节数（F22）：见 [imageTokens]。
  final int? chars;

  /// 图片附件的 token 估算（F22）：按**内联后的像素**算，不用文件字节。
  /// 非图片附件为 null。
  final int? imageTokens;

  const AttachmentMeta({
    required this.title,
    required this.icon,
    this.file,
    this.chars,
    this.imageTokens,
  });
}

/// token 估算（§3.6）：字符数 / 2（CJK 保守估计）。
int estimateTokensFromChars(int chars) => (chars / 2).ceil();

/// 图片内联口径：encodeInlineImage 默认把长边缩到 [kInlineImageMaxSide]
/// （services/assistant/image_encoder.dart:16）。视觉开销与**像素面积**相关、
/// 与文件字节数无关 —— 用字节数会把 50KB JPEG 算成 2.5 万 token（F22）。
const int kInlineImageMaxSide = 1024;

/// 视觉 token ≈ 缩放后像素面积 / 750（业界常用近似，仅用于预算提示）。
const int kImageTokenAreaDivisor = 750;

/// 宽高未知时的**保守上界**：1024×1024 / 750 ≈ 1398.1 → 取 1400。
const int kConservativeImageTokens = 1400;

/// 图片附件的 token 估算（F22 修复）：按长边 [maxSide] 等比缩放后的面积算，
/// 不用文件字节数。宽/高未知或非法 → 回退 [kConservativeImageTokens]。
int estimateImageTokens({
  int? width,
  int? height,
  int maxSide = kInlineImageMaxSide,
}) {
  if (width == null || height == null || width <= 0 || height <= 0) {
    return kConservativeImageTokens;
  }
  var w = width;
  var h = height;
  final longest = math.max(w, h);
  if (maxSide > 0 && longest > maxSide) {
    final scale = maxSide / longest;
    w = math.max(1, (w * scale).round());
    h = math.max(1, (h * scale).round());
  }
  return math.max(1, (w * h / kImageTokenAreaDivisor).ceil());
}

/// 草稿附件 token 估算合计（§3.6）：图片走 [AttachmentMeta.imageTokens]，
/// 其余类型沿用「字符/2」；元数据缺失按 0 计。
int sumAttachmentTokens(Iterable<AttachmentMeta?> metas) {
  var sum = 0;
  for (final meta in metas) {
    if (meta == null) continue;
    final imageTokens = meta.imageTokens;
    if (imageTokens != null) {
      sum += imageTokens;
      continue;
    }
    final chars = meta.chars;
    if (chars != null) sum += estimateTokensFromChars(chars);
  }
  return sum;
}

/// 附件预算档（§3.6）：≤80% 灰、>80% amber、>100% 红且禁用发送。
enum BudgetLevel { normal, warning, over }

/// 模型上下文上限缺省值：模型配置无数据时按 32k（§3.6）。
/// 别名（F44 去重）：唯一定义在 services/context_window.dart 的
/// kAssumedContextTokenLimit，**勿再写字面量**。
const int kDefaultContextTokenLimit = kAssumedContextTokenLimit;

BudgetLevel budgetLevel(int usedTokens, int limitTokens) {
  if (limitTokens <= 0 || usedTokens <= 0) return BudgetLevel.normal;
  final ratio = usedTokens / limitTokens;
  if (ratio > 1) return BudgetLevel.over;
  if (ratio > 0.8) return BudgetLevel.warning;
  return BudgetLevel.normal;
}

String formatAttachmentSize(int? bytes) {
  if (bytes == null) return '大小未知';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 是否图片附件（按 mime 前缀判定；chat_page 的预算分流也用它）。
bool isImageAttachment(LibraryFile f) =>
    (f.mimeType ?? '').startsWith('image/');

bool _isImage(LibraryFile f) => isImageAttachment(f);

/// 是否为可全屏预览的图片附件：附件卡片与草稿 chip（input_bar）共用同一判定，
/// 避免两处各写一份 mime 判断导致行为漂移（F03）。
bool isPreviewableImage(AttachmentMeta? meta) {
  final f = meta?.file;
  return f != null && _isImage(f);
}

/// 全屏图片查看器（可缩放）：附件卡片点按与草稿 chip 点按共用。
Future<void> showImagePreview(BuildContext context, LibraryFile file) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: InteractiveViewer(
        child: Image.file(File(file.localPath),
            errorBuilder: (_, __, ___) =>
                const Icon(Icons.broken_image_outlined, size: 64)),
      ),
    ),
  );
}

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
      onTap: () => showImagePreview(context, file),
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
