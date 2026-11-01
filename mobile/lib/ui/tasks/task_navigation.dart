import 'package:flutter/material.dart';

import '../../models/task.dart';
import '../../services/app_ui_state.dart';
import '../../services/assistant/models.dart';
import '../../services/database.dart';
import '../messages/message_detail_sheet.dart';
import '../notes/note_editor_page.dart';
import 'task_detail_panel.dart';
import 'task_editor.dart';

/// 锚点双向跳转中枢（design-v3 §3.4，v3 阶段 4）：
/// - 正向：锚点 chip 点击 → [showTaskDetailSheet] 弹任务详情；
/// - 反向：任务详情「来源锚点」列表点击 → [openAnchorTarget] 按目标类型
///   跳消息详情 / 笔记编辑器（定位高亮该 chip）/ 库·文件区。

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
/// - message → 消息详情面板；
/// - note → 笔记编辑器，预览态并高亮/定位该锚点 chip；
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
    case AnchorTargetType.note:
      final note = await db.getNoteById(anchor.targetId);
      if (!context.mounted) return;
      if (note == null) {
        _toastGone(context, '笔记');
        return;
      }
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => NoteEditorPage(
          existing: note,
          highlightAnchorId: anchor.id,
        ),
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
