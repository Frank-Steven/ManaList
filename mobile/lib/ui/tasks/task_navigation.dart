import 'package:flutter/material.dart';

import '../../models/task.dart';
import '../../services/app_ui_state.dart';
import '../../services/assistant/models.dart';
import '../../services/database.dart';
import '../messages/message_detail_sheet.dart';
import '../notes/chapters_page.dart';
import 'task_detail_panel.dart';
import 'task_editor.dart';

/// 锚点双向跳转中枢（anchors-v2.md §3）：
/// - 正向：对象详情「关联任务」区 chip 点击 → [showTaskDetailSheet] 弹任务详情；
/// - 反向：任务详情「来源锚点」列表点击 → [openAnchorTarget] 按目标类型
///   跳消息详情 / 章节笔记列表 / 库·文件区。

/// 任务详情底部弹出（锚点 chip 点击的落点）。编辑走任务编辑器；
/// 父/子任务点击再叠一层详情。
Future<void> showTaskDetailSheet(BuildContext context, Task task) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (ctx, scroll) => SingleChildScrollView(
        controller: scroll,
        child: TaskDetailPanel(
          task: task,
          onClose: () => Navigator.of(ctx).pop(),
          onEdit: () async {
            final result = await showTaskEditor(ctx, existing: task);
            final saved = result?.task;
            if (result == null || result.deleted || saved == null) return;
            await AppDatabase.instance.updateTask(saved);
            // 内容变化体现在宿主下次 reload；面板本身随任务 id 不变，
            // 这里直接重建一层详情展示新数据。
            if (ctx.mounted) {
              Navigator.of(ctx).pop();
              // ignore: use_build_context_synchronously
              await showTaskDetailSheet(context, saved);
            }
          },
          onOpenTask: (t) => showTaskDetailSheet(ctx, t),
        ),
      ),
    ),
  );
}

/// 反向跳转（任务详情「来源锚点」点击）：
/// - message → 消息详情面板（「关联任务」区）；
/// - chapter → 章节笔记列表页；
/// - file → 收到库页文件区（弹层先收起）。
Future<void> openAnchorTarget(BuildContext context, TaskAnchor anchor) async {
  final db = AppDatabase.instance;
  switch (anchor.targetType) {
    case AnchorTargetType.message:
      final msg = await db.getMessageById(anchor.targetId);
      if (!context.mounted) return;
      if (msg == null) {
        _toastGone(context, '消息');
        return;
      }
      await showMessageDetail(context, msg);
    case AnchorTargetType.chapter:
      final chapter = await db.getChapterById(anchor.targetId);
      if (!context.mounted) return;
      if (chapter == null) {
        _toastGone(context, '章节');
        return;
      }
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => NotesListPage(chapter: chapter),
      ));
    case AnchorTargetType.file:
      final file = await db.getFileById(anchor.targetId);
      if (!context.mounted) return;
      if (file == null) {
        _toastGone(context, '文件');
        return;
      }
      // 先收起弹层再切 tab，否则文件区被详情面板盖住
      Navigator.of(context, rootNavigator: true)
          .popUntil((route) => route.isFirst);
      AppUiState.instance.openLibrary(AppUiState.librarySectionFiles);
  }
}

void _toastGone(BuildContext context, String what) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('$what已不存在')));
}
