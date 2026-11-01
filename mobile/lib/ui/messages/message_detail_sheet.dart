import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/message.dart';
import '../../models/task.dart';
import '../../services/anchor_service.dart';
import '../../services/app_ui_state.dart';
import '../../services/assistant/models.dart';
import '../../services/attachment_store.dart';
import '../../services/database.dart';
import '../../services/fold_markers.dart';
import '../../services/system_intent.dart';
import '../shared/anchored_markdown.dart';
import '../tasks/task_navigation.dart';
import '../tasks/task_picker.dart';

/// 消息详情面板（P3-2 → F07/F08/F09/F10/F11；v3 阶段 4 锚点化）。
///
/// - 看图（缩略图点击放大）；
/// - F07 编辑正文 / 增删附件（写 messages.body / attachments，并打 edited_at）；
/// - F08 展示关联待办（v8 起走 task_anchors），点击跳到任务页；
/// - F09 附件里的链接可「打开」「复制」；
/// - F10 附件里的文件可「导出到下载」（MediaStore，不需要存储权限）；
/// - F11 小程序附件如实说明暂不支持打开，并允许复制路径。
///
/// v3 阶段 4（design-v3 §3.4）：
/// - 正文改用统一 markdown 渲染管线（[AnchoredMarkdownBody]，只读）：
///   锚点 marker 显示为可点击 chip（跳任务详情）；
/// - 长按选段上下文菜单「添加任务锚点」（受限写入，走 edited_at）。
Future<void> showMessageDetail(BuildContext context, Message m) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      expand: false,
      // F07 修复（2026-10-21 验收）：SnackBar 原先发出后被子面板挡住看不见，
      // 给面板自己套一层 ScaffoldMessenger + 透明 Scaffold，提示就浮在面板上方。
      builder: (ctx, scroll) => ScaffoldMessenger(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: _MessageDetail(message: m, scroll: scroll),
        ),
      ),
    ),
  );
}

class _MessageDetail extends StatefulWidget {
  const _MessageDetail({required this.message, required this.scroll});

  final Message message;
  final ScrollController scroll;

  @override
  State<_MessageDetail> createState() => _MessageDetailState();
}

class _MessageDetailState extends State<_MessageDetail> {
  late String _body = widget.message.body;
  late List<Attachment> _attachments =
      List<Attachment>.of(widget.message.attachments);
  List<Task>? _linkedTasks;
  bool _loadingTasks = true;

  /// SelectionArea 当前选中的正文片段（「添加任务锚点」菜单用）。
  String? _selectedText;

  Message get message => widget.message;

  @override
  void initState() {
    super.initState();
    _loadLinkedTasks();
  }

  Future<void> _loadLinkedTasks() async {
    try {
      final tasks = await AppDatabase.instance.tasksForMessage(message.id);
      if (mounted) {
        setState(() {
          _linkedTasks = tasks;
          _loadingTasks = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingTasks = false);
    }
  }

  Future<void> _editBody() async {
    final controller = TextEditingController(text: _body);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑正文'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: TextField(
            controller: controller,
            maxLines: null,
            minLines: 6,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '消息正文（保存后标记为用户编辑）',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == null) return;
    await AppDatabase.instance.updateMessageBody(message.id, saved);
    if (!mounted) return;
    setState(() => _body = saved);
    _toast('正文已保存');
  }

  Future<void> _addAttachment() async {
    final picked = await FilePicker.platform.pickFiles(allowMultiple: false);
    final path = picked?.files.single.path;
    if (path == null) return;
    final name = picked!.files.single.name;
    final att = await AttachmentStore.instance
        .importPath(path, kind: Attachment.kindFile);
    if (att == null) {
      _toast('附件导入失败');
      return;
    }
    final next = [..._attachments, att];
    await _persistAttachments(next);
    if (!mounted) return;
    setState(() => _attachments = next);
    _toast('已添加附件「${att.label ?? name}」');
  }

  Future<void> _removeAttachment(Attachment a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除附件'),
        content: Text('确认移除「${a.label ?? a.kind}」？（只从这条消息解绑，不删文件）'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('移除')),
        ],
      ),
    );
    if (ok != true) return;
    final next = _attachments.where((x) => x.id != a.id).toList();
    await _persistAttachments(next);
    if (!mounted) return;
    setState(() => _attachments = next);
    _toast('已移除附件');
  }

  Future<void> _persistAttachments(List<Attachment> list) {
    return AppDatabase.instance.updateMessageAttachments(
        message.id, [for (final a in list) a.toJson()]);
  }

  Future<void> _openLink(String url) async {
    final ok = await SystemIntent.openUrl(url);
    if (!ok) _toast('没有可以打开该链接的应用');
  }

  Future<void> _copy(String text, [String what = '内容']) async {
    await Clipboard.setData(ClipboardData(text: text));
    _toast('$what 已复制');
  }

  Future<void> _exportToDownloads(Attachment a) async {
    final file = AttachmentStore.instance.resolve(a);
    if (file == null) {
      _toast('文件已不可用（可能被清理）');
      return;
    }
    try {
      final where = await SystemIntent.exportToDownloads(
        file.path,
        name: _fileNameOf(a, file),
        mime: a.access.mimeType ?? SystemIntent.mimeOf(file.path),
      );
      _toast('已导出到 $where');
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  String _fileNameOf(Attachment a, File file) {
    final label = a.label;
    if (label != null && label.contains('.')) return label;
    return file.uri.pathSegments.last;
  }

  void _jumpToTasks() {
    Navigator.of(context).pop();
    AppUiState.instance.setTab(AppUiState.tasksTabIndex);
  }

  /// 长按选段「添加任务锚点」（design-v3 §3.4）：选/建任务 →
  /// AnchorService 受限写入消息正文（marker + edited_at 留痕）。
  /// 选中文本经 SelectionArea.onSelectionChanged 捕获在 [_selectedText]。
  Future<void> _addAnchorFromSelection() async {
    final text = _selectedText?.trim();
    if (!mounted || text == null || text.isEmpty) return;
    final task = await showTaskPicker(context, seedTitle: text);
    if (task == null || !mounted) return;
    final result = await AnchorService.instance.insertAnchor(
      taskId: task.id,
      targetType: AnchorTargetType.message,
      targetId: message.id,
      anchorText: text,
    );
    if (!mounted) return;
    if (!result.ok) {
      _toast(result.error ?? '添加锚点失败');
      return;
    }
    // 正文已被受限写入（含 marker），回读同步展示与关联列表。
    final fresh = await AppDatabase.instance.getMessageById(message.id);
    if (!mounted) return;
    setState(() {
      if (fresh != null) _body = fresh.body;
      _loadingTasks = true;
    });
    _loadLinkedTasks();
    _toast(result.multipleMatches ? '已添加锚点（多处出现，定位在第一处）' : '已添加锚点');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final time = DateTime.fromMillisecondsSinceEpoch(message.postedAt);
    final meta = [
      message.appName ?? message.packageName,
      if (message.conversationTitle?.isNotEmpty == true)
        message.conversationTitle!,
      if (message.sender?.isNotEmpty == true) message.sender!,
      '${time.month}-${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
    ].join(' · ');

    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Text(
          message.title.isEmpty ? '(无标题)' : stripFoldMarkers(message.title),
          style: tt.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(meta, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text('正文',
                  style: tt.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
            ),
            TextButton.icon(
              onPressed: _editBody,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('编辑'),
            ),
          ],
        ),
        SelectionArea(
          onSelectionChanged: (content) =>
              _selectedText = content?.plainText,
          contextMenuBuilder: (context, selectableRegionState) {
            return AdaptiveTextSelectionToolbar.buttonItems(
              anchors: selectableRegionState.contextMenuAnchors,
              buttonItems: [
                ...selectableRegionState.contextMenuButtonItems,
                ContextMenuButtonItem(
                  label: '添加任务锚点',
                  onPressed: () {
                    ContextMenuController.removeAny();
                    _addAnchorFromSelection();
                  },
                ),
              ],
            );
          },
          child: AnchoredMarkdownBody(
            data: _body.isEmpty ? '（无正文）' : _body,
            onOpenTask: (t) => showTaskDetailSheet(context, t),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Icon(Icons.checklist_rtl, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 6),
            Text('关联待办',
                style: tt.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 6),
        if (_loadingTasks)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: SizedBox(
                height: 16,
                width: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if ((_linkedTasks ?? const <Task>[]).isEmpty)
          Text('这条消息没有关联待办',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant))
        else
          for (final t in _linkedTasks!) _taskRow(t, cs, tt),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Text('附件 ${_attachments.length}',
                  style: tt.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
            ),
            TextButton.icon(
              onPressed: _addAttachment,
              icon: const Icon(Icons.attach_file, size: 18),
              label: const Text('添加'),
            ),
          ],
        ),
        if (_attachments.isEmpty)
          Text('没有附件',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant))
        else
          for (final a in _attachments) _attachment(a),
      ],
    );
  }

  Widget _taskRow(Task t, ColorScheme cs, TextTheme tt) {
    final done = t.status == TaskStatus.done;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: _jumpToTasks,
        child: Row(
          children: [
            Icon(
              done ? Icons.check_circle_outline : Icons.radio_button_unchecked,
              size: 16,
              color: done ? cs.primary : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tt.bodyMedium),
            ),
            if (t.startAt != null)
              Text(_shortTime(t.startAt!),
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  String _shortTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}-${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Widget _attachment(Attachment a) {
    final store = AttachmentStore.instance;
    final file = store.resolve(a);
    final isImage = a.kind == Attachment.kindImage;

    if (isImage && file != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => _previewImage(context, file),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  file,
                  height: 180,
                  cacheHeight:
                      (180 * MediaQuery.devicePixelRatioOf(context)).round(),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _attachmentRow(a, '图片无法解码'),
                ),
              ),
            ),
            _attachmentActions(a, file),
          ],
        ),
      );
    }
    return _attachmentRow(a, isImage ? '图片文件已不可用' : _describe(a), file: file);
  }

  Widget _attachmentRow(Attachment a, String detail, {File? file}) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_iconFor(a), size: 20, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.label ?? a.kind,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    SelectableText(detail,
                        style:
                            tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
              IconButton(
                tooltip: '移除附件',
                onPressed: () => _removeAttachment(a),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
          _attachmentActions(a, file),
        ],
      ),
    );
  }

  Widget _attachmentActions(Attachment a, File? file) {
    final cs = Theme.of(context).colorScheme;
    final actions = <Widget>[];

    if (a.access.type == AttachmentAccess.typeUrl) {
      final url = a.access.value;
      actions.add(TextButton.icon(
        onPressed: () => _openLink(url),
        icon: const Icon(Icons.open_in_new, size: 16),
        label: const Text('打开'),
      ));
      actions.add(TextButton.icon(
        onPressed: () => _copy(url, '链接'),
        icon: const Icon(Icons.copy, size: 16),
        label: const Text('复制链接'),
      ));
    } else if (a.kind == Attachment.kindMiniprogram ||
        a.access.type == AttachmentAccess.typeMiniprogramPath) {
      actions.add(TextButton.icon(
        onPressed: () => _copy(a.access.value, '小程序路径'),
        icon: const Icon(Icons.copy, size: 16),
        label: const Text('复制路径'),
      ));
    } else if (file != null) {
      actions.add(TextButton.icon(
        onPressed: () => _exportToDownloads(a),
        icon: const Icon(Icons.download_outlined, size: 16),
        label: const Text('导出到下载'),
      ));
    }
    if (actions.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 4, children: actions),
          if (a.kind == Attachment.kindMiniprogram ||
              a.access.type == AttachmentAccess.typeMiniprogramPath)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Text(
                '小程序附件暂不支持直接打开（采集端只记录到路径，没有可启动的 appId）',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  String _describe(Attachment a) {
    final size = a.bytes;
    final sizeText = size == null ? '' : ' · ${_formatBytes(size)}';
    switch (a.access.type) {
      case AttachmentAccess.typeUrl:
        return '链接：${a.access.value}';
      case AttachmentAccess.typeMiniprogramPath:
        return '小程序：${a.access.value}';
      case AttachmentAccess.typeAppDeeplink:
        return '应用内跳转：${a.access.value}';
      default:
        return '本地文件$sizeText';
    }
  }

  IconData _iconFor(Attachment a) {
    switch (a.kind) {
      case Attachment.kindImage:
        return Icons.image_outlined;
      case Attachment.kindLink:
        return Icons.link;
      case Attachment.kindMiniprogram:
        return Icons.widgets_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  void _previewImage(BuildContext context, File file) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: InteractiveViewer(
          minScale: 0.8,
          maxScale: 4,
          child: Image.file(file, fit: BoxFit.contain),
        ),
      ),
    );
  }

  static String _formatBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
