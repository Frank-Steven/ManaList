import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../../models/library_file.dart';
import '../../models/task.dart';
import '../../services/anchor_service.dart';
import '../../services/assistant/models.dart';
import '../../services/database.dart';

/// 锚点渲染联查数据（[AnchoredMarkdownBody] 渲染一份正文所需的全部联查结果）。
typedef AnchorRenderData = ({
  Map<String, TaskAnchor> anchors,
  Map<String, Task> tasks,
  Map<String, LibraryFile> files,
});

/// 锚点 marker 的行内语法（design-v3-details §1.2）：匹配 `⟦task:<uuid>⟧`，
/// 产出 tag 为 `taskanchor`、attribute `id` = anchorId 的 Element。
/// 代码区保护由 markdown 包天然提供：fenced code block / inline code span
/// 不跑 inline syntax 解析，其中的 marker 样文本保持原文（有测试固化）。
class TaskAnchorInlineSyntax extends md.InlineSyntax {
  TaskAnchorInlineSyntax() : super(anchorMarkerPattern.pattern);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final el = md.Element.text('taskanchor', '');
    el.attributes['id'] = match.group(1)!.toLowerCase();
    parser.addNode(el);
    return true;
  }
}

/// `![name](file://id)` 中的文件 id。
final RegExp fileImagePattern =
    RegExp(r'!\[[^\]]*\]\(file://([0-9a-fA-F-]+)\)');

/// 统一的锚点感知 markdown 渲染管线（design-v3 §3.3、details §1.2）：
/// 笔记预览、消息详情共用。渲染前按正文批量预取锚点/任务/文件（避免逐
/// marker 查库），marker 渲染为可点击的任务 chip（标题 + 状态色），
/// `file://` 图片解析到 attachment_store 本地文件。
///
/// - [onOpenTask]：点击锚点 chip；null 时 chip 不可点。
/// - [highlightAnchorId]：反向跳转定位用——该锚点 chip 加描边并滚动到可见。
class AnchoredMarkdownBody extends StatefulWidget {
  final String data;
  final ValueChanged<Task>? onOpenTask;
  final String? highlightAnchorId;
  final void Function(String text, String? href, String? title)? onTapLink;

  const AnchoredMarkdownBody({
    super.key,
    required this.data,
    this.onOpenTask,
    this.highlightAnchorId,
    this.onTapLink,
  });

  @override
  State<AnchoredMarkdownBody> createState() => AnchoredMarkdownBodyState();

  /// 测试注入：非空时 [_load] 跳过 DB 预取，直接使用注入的联查数据。
  /// （widget 测试跑在 FakeAsync 区，sqflite_ffi 的 DB 调用会挂死，
  /// 见 test/anchor_markdown_test.dart。）
  @visibleForTesting
  static AnchorRenderData? debugData;
}

class AnchoredMarkdownBodyState extends State<AnchoredMarkdownBody> {
  Map<String, TaskAnchor> _anchors = const {};
  Map<String, Task> _tasks = const {};
  Map<String, LibraryFile> _files = const {};
  final _highlightKey = GlobalKey();

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
    final debug = AnchoredMarkdownBody.debugData;
    if (debug != null) {
      _anchors = debug.anchors;
      _tasks = debug.tasks;
      _files = debug.files;
      if (mounted) setState(() => _revision++);
      return;
    }
    final anchors =
        await AnchorService.instance.prefetchForBodies([widget.data]);
    final db = AppDatabase.instance;
    final taskIds = anchors.values.map((a) => a.taskId).toSet().toList();
    final tasks = await db.tasksByIds(taskIds);
    final fileIds = fileImagePattern
        .allMatches(widget.data)
        .map((m) => m.group(1)!)
        .toSet()
        .toList();
    final files = await db.filesByIds(fileIds);
    if (!mounted) return;
    setState(() {
      _anchors = {for (final a in anchors.values) a.id: a};
      _tasks = {for (final t in tasks) t.id: t};
      _files = {for (final f in files) f.id: f};
      // flutter_markdown 的 MarkdownBuilder 只在 data 变化时重建内部解析树，
      // 联查数据异步到达不会触发 chip 重建——用 key 版本号强制重建。
      _revision++;
    });
    if (widget.highlightAnchorId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _highlightKey.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            alignment: 0.3,
          );
        }
      });
    }
  }

  /// 锚点 chip：图标 + 任务标题 + 状态色（active=主色、done=绿+删除线、
  /// archived=灰）。锚点行缺失（异常残迹）时降级为弱化的 marker 原文。
  Widget _anchorChip(BuildContext context, md.Element element,
      TextStyle? preferredStyle) {
    final cs = Theme.of(context).colorScheme;
    final anchorId = element.attributes['id'] ?? '';
    final anchor = _anchors[anchorId];
    if (anchor == null) {
      return Text(anchorMarker(anchorId),
          style: preferredStyle?.copyWith(color: cs.onSurfaceVariant) ??
              TextStyle(color: cs.onSurfaceVariant));
    }
    final task = _tasks[anchor.taskId];
    final title = task?.title ?? anchor.label ?? '任务';
    final done = task?.status == TaskStatus.done;
    final archived = task?.status == TaskStatus.archived;
    final color =
        archived ? cs.outline : (done ? Colors.green : cs.primary);
    final highlighted = anchorId == widget.highlightAnchorId;
    final chip = Container(
      key: highlighted ? _highlightKey : null,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: color.withValues(alpha: highlighted ? 0.9 : 0.45),
            width: highlighted ? 1.6 : 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.task_alt, size: 13, color: color),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: (preferredStyle ?? const TextStyle()).copyWith(
                fontSize: (preferredStyle?.fontSize ?? 14) - 1,
                color: color,
                decoration: done ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ],
      ),
    );
    final onOpenTask = widget.onOpenTask;
    if (task == null || onOpenTask == null) return chip;
    return GestureDetector(onTap: () => onOpenTask(task), child: chip);
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
      // 变化，强制重建让 chip 用上任务标题/状态。
      key: ValueKey(_revision),
      data: widget.data,
      // 通知正文/笔记的单换行都按换行渲染（markdown 默认把单 \n 当空格，
      // 会糊掉采集原文的换行结构）
      softLineBreak: true,
      inlineSyntaxes: [TaskAnchorInlineSyntax()],
      builders: {
        'taskanchor': _TaskAnchorChipBuilder(
          chipBuilder: _anchorChip,
        ),
      },
      sizedImageBuilder: _buildImage,
      onTapLink: widget.onTapLink == null
          ? null
          : (text, href, title) => widget.onTapLink!(text, href, title),
    );
  }
}

/// flutter_markdown 的 builder 适配层：把 `taskanchor` Element 交给
/// [AnchoredMarkdownBody] 的 chip 构造（需要 BuildContext 取主题）。
class _TaskAnchorChipBuilder extends MarkdownElementBuilder {
  _TaskAnchorChipBuilder({required this.chipBuilder});

  final Widget Function(
          BuildContext context, md.Element element, TextStyle? preferredStyle)
      chipBuilder;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) =>
      chipBuilder(context, element, preferredStyle);
}
