import 'package:flutter/material.dart';

import '../../models/task.dart';
import '../../services/anchor_service.dart';
import '../../services/assistant/models.dart';
import '../../services/database.dart';
import '../../services/undo_service.dart';
import '../messages/message_widgets.dart' show showUndoSnackBar;
import '../tasks/task_navigation.dart';
import '../tasks/task_picker.dart';

/// 对象详情的「关联任务」区（anchors-v2.md §3）：对象级锚点的唯一人工入口。
///
/// chip 列表（任务标题 + 状态色，点击跳任务详情，长按移除并给撤销），
/// 行尾「+ 关联任务」选已有任务或新建。锚点只落 task_anchors 表，
/// 不触碰任何正文。
class LinkedTasksSection extends StatefulWidget {
  /// AnchorTargetType.message / chapter / file。
  final String targetType;
  final String targetId;

  /// 新建任务时的标题种子（消息标题/章节名/文件名）。
  final String? seedTitle;

  const LinkedTasksSection({
    super.key,
    required this.targetType,
    required this.targetId,
    this.seedTitle,
  });

  @override
  State<LinkedTasksSection> createState() => _LinkedTasksSectionState();
}

class _LinkedTasksSectionState extends State<LinkedTasksSection> {
  List<TaskAnchor> _anchors = const [];
  Map<String, Task> _tasks = const {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final db = AppDatabase.instance;
    final anchors =
        await db.anchorsForTarget(widget.targetType, widget.targetId);
    final tasks =
        await db.tasksByIds(anchors.map((a) => a.taskId).toSet().toList());
    if (!mounted) return;
    setState(() {
      _anchors = anchors;
      _tasks = {for (final t in tasks) t.id: t};
    });
  }

  Future<void> _add() async {
    final task = await showTaskPicker(context, seedTitle: widget.seedTitle);
    if (task == null || !mounted) return;
    final result = await AnchorService.instance.insertAnchor(
      taskId: task.id,
      targetType: widget.targetType,
      targetId: widget.targetId,
    );
    if (!mounted) return;
    if (!result.ok) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            SnackBar(content: Text(result.error ?? '关联失败')));
      return;
    }
    await _reload();
    if (!mounted || result.alreadyExists) return;
    final anchorId = result.anchor!.id;
    UndoService.instance.register(
      label: '撤销：关联任务',
      undo: () async {
        await AnchorService.instance.removeAnchor(anchorId);
        if (mounted) await _reload();
      },
    );
    showUndoSnackBar(context, '已关联任务「${task.title}」',
        onUndone: _reload);
  }

  Future<void> _remove(TaskAnchor anchor, Task? task) async {
    await AnchorService.instance.removeAnchor(anchor.id);
    await _reload();
    if (!mounted) return;
    UndoService.instance.register(
      label: '撤销：移除关联',
      undo: () async {
        await AnchorService.instance.insertAnchor(
          taskId: anchor.taskId,
          targetType: anchor.targetType,
          targetId: anchor.targetId,
          label: anchor.label,
        );
        if (mounted) await _reload();
      },
    );
    showUndoSnackBar(
        context, '已移除与「${task?.title ?? anchor.label ?? '任务'}」的关联',
        onUndone: _reload);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('关联任务',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: cs.onSurfaceVariant)),
            const Spacer(),
            IconButton(
              tooltip: '关联任务',
              icon: const Icon(Icons.add_link, size: 20),
              onPressed: _add,
            ),
          ],
        ),
        if (_anchors.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('暂无关联任务',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in _anchors)
                _TaskChip(
                  anchor: a,
                  task: _tasks[a.taskId],
                  onOpen: (t) => showTaskDetailSheet(context, t),
                  onRemove: () => _remove(a, _tasks[a.taskId]),
                ),
            ],
          ),
      ],
    );
  }
}

class _TaskChip extends StatelessWidget {
  final TaskAnchor anchor;
  final Task? task;
  final ValueChanged<Task> onOpen;
  final VoidCallback onRemove;

  const _TaskChip({
    required this.anchor,
    required this.task,
    required this.onOpen,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = task?.title ?? anchor.label ?? '任务';
    final done = task?.status == TaskStatus.done;
    final archived = task?.status == TaskStatus.archived;
    final color = archived ? cs.outline : (done ? Colors.green : cs.primary);
    return GestureDetector(
      onTap: task == null ? null : () => onOpen(task!),
      onLongPress: onRemove,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.task_alt, size: 14, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: color,
                  decoration: done ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
