import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../models/task.dart';
import '../../services/assistant/models.dart';
import '../../services/database.dart';
import '../../services/task_scale.dart';
import '../shared/priority_dot.dart';
import 'task_navigation.dart';
import 'task_tile.dart';

/// 来源锚点条目（v3 阶段 4）：锚点 + 解析后的目标标题。
class _AnchorSource {
  final TaskAnchor anchor;
  final String title;

  const _AnchorSource(this.anchor, this.title);
}

/// 任务详情面板（设计 §3/§7，v2.3；v2.5 内嵌统一）：待办列表与甘特视图底部
/// 面板共用同一组件（列表模式/详情模式互斥切换，不再是底部弹出抽屉）。
///
/// 内容：名称、尺度徽标、优先级色点、时间、描述；父任务条目、来源锚点
/// （v3 阶段 4：图标区分 message/note/file，点击反向跳转并高亮对应 chip，
/// 无锚点时回退历史只读的 source_message_id）、子任务列表（含完成进度）；
/// 右上角编辑图标进编辑器。
/// [onClose] 非空时左上角显示返回按钮（关闭详情回列表模式）。
/// 父/子任务条目点击经 [onOpenTask] 回调，由宿主决定跳转逻辑
/// （列表视图 = 切页签并高亮；甘特视图 = 跳到所在尺度视图并选中）。
class TaskDetailPanel extends StatefulWidget {
  final Task task;

  /// 右上角编辑图标。
  final VoidCallback onEdit;

  /// 点击父任务/子任务条目。
  final ValueChanged<Task>? onOpenTask;

  /// 左上角关闭（返回列表模式）；null 不显示。
  final VoidCallback? onClose;

  const TaskDetailPanel({
    super.key,
    required this.task,
    required this.onEdit,
    this.onOpenTask,
    this.onClose,
  });

  @override
  State<TaskDetailPanel> createState() => _TaskDetailPanelState();
}

class _TaskDetailPanelState extends State<TaskDetailPanel> {
  Task? _parent;
  List<Task> _children = [];
  List<_AnchorSource> _anchorSources = [];
  List<Message> _legacySources = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(TaskDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.id != widget.task.id ||
        oldWidget.task.updatedAt != widget.task.updatedAt) {
      _load();
    }
  }

  Future<void> _load() async {
    final db = AppDatabase.instance;
    final t = widget.task;
    final parent =
        t.parentId == null ? null : await db.getTaskById(t.parentId!);
    final children = await db.getChildTasks(t.id);
    // v3 阶段 4：来源锚点（message/note/file 统一列出，图标区分）。
    final anchors = await db.anchorsForTask(t.id);
    final sources = <_AnchorSource>[];
    for (final a in anchors) {
      switch (a.targetType) {
        case AnchorTargetType.message:
          final msg = await db.getMessageById(a.targetId);
          if (msg != null) sources.add(_AnchorSource(a, msg.title));
        case AnchorTargetType.note:
          final note = await db.getNoteById(a.targetId);
          if (note != null) sources.add(_AnchorSource(a, note.title));
        case AnchorTargetType.file:
          final file = await db.getFileById(a.targetId);
          if (file != null) sources.add(_AnchorSource(a, file.name));
      }
    }
    // 无锚点时回退历史只读的 source_message_id。
    var legacy = <Message>[];
    if (sources.isEmpty && t.sourceMessageId != null) {
      final msg = await db.getMessageById(t.sourceMessageId!);
      if (msg != null) legacy = [msg];
    }

    if (!mounted) return;
    setState(() {
      _parent = parent;
      _children = children;
      _anchorSources = sources;
      _legacySources = legacy;
      _loaded = true;
    });
  }

  IconData _anchorIcon(String targetType) => switch (targetType) {
        AnchorTargetType.note => Icons.edit_note,
        AnchorTargetType.file => Icons.insert_drive_file_outlined,
        _ => Icons.message_outlined,
      };

  void _showLegacySourceDialog(Message msg) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(msg.title),
        content: SingleChildScrollView(child: Text(msg.body)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  Widget _scaleChip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        timeScaleLabel(deriveTaskScale(
            widget.task.startAt, widget.task.endAt,
            kind: widget.task.kind)),
        style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
      ),
    );
  }

  Widget _taskLinkRow(BuildContext context, Task t) {
    final scheme = Theme.of(context).colorScheme;
    final done = t.status == TaskStatus.done;
    return InkWell(
      onTap: widget.onOpenTask == null ? null : () => widget.onOpenTask!(t),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: taskPriorityDotColor(t.priority),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                t.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  decoration: done ? TextDecoration.lineThrough : null,
                  color: done ? scheme.onSurfaceVariant : null,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              taskTimeSummary(t),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (widget.onOpenTask != null)
              Icon(Icons.chevron_right,
                  size: 16, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = widget.task;
    final done = t.status == TaskStatus.done;
    final doneCount =
        _children.where((c) => c.status == TaskStatus.done).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (widget.onClose != null)
                IconButton(
                  tooltip: '返回列表',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.arrow_back, size: 20),
                ),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: taskPriorityDotColor(t.priority),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        decoration:
                            done ? TextDecoration.lineThrough : null,
                      ),
                ),
              ),
              IconButton(
                tooltip: '编辑',
                visualDensity: VisualDensity.compact,
                onPressed: widget.onEdit,
                icon: const Icon(Icons.edit_outlined, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _scaleChip(context),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  taskTimeSummary(t),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          if (t.description != null && t.description!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(t.description!,
                style: Theme.of(context).textTheme.bodySmall),
          ],
          if (!_loaded)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Center(
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            ),
          if (_parent != null) ...[
            const SizedBox(height: 8),
            Text('父任务', style: Theme.of(context).textTheme.labelLarge),
            _taskLinkRow(context, _parent!),
          ],
          if (_anchorSources.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
                _anchorSources.length > 1
                    ? '来源锚点（${_anchorSources.length}）'
                    : '来源锚点',
                style: Theme.of(context).textTheme.labelLarge),
            for (final s in _anchorSources)
              InkWell(
                onTap: () => openAnchorTarget(context, s.anchor),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(_anchorIcon(s.anchor.targetType),
                          size: 16, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      Icon(Icons.chevron_right,
                          size: 16, color: scheme.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
          ],
          if (_legacySources.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('来源消息', style: Theme.of(context).textTheme.labelLarge),
            for (final msg in _legacySources)
              InkWell(
                onTap: () => _showLegacySourceDialog(msg),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(Icons.message_outlined,
                          size: 16, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          msg.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      Icon(Icons.chevron_right,
                          size: 16, color: scheme.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
          ],
          if (_children.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('子任务 $doneCount/${_children.length}',
                style: Theme.of(context).textTheme.labelLarge),
            for (final c in _children) _taskLinkRow(context, c),
          ],
        ],
      ),
    );
  }
}
