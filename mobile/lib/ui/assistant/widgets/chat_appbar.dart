import 'package:flutter/material.dart';

import 'auto_scroll_title.dart';

/// 对话页顶栏（assistant-v4-ui §3.2 组件拆分决策）：
/// 标题（1 行省略）+ ⋮ 溢出菜单。
///
/// F36 方案A：模型入口已下移到输入区上方的胶囊行，顶栏只留标题，
/// 标题字号放大并与返回箭头同基线对齐（不再有第二行把标题顶高）。
class ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final VoidCallback onRename;
  final VoidCallback onExport;
  final VoidCallback onClearAndRestart;
  final VoidCallback onDelete;

  const ChatAppBar({
    super.key,
    required this.title,
    required this.onRename,
    required this.onExport,
    required this.onClearAndRestart,
    required this.onDelete,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      // F21 审批稿「标题方案③」：溢出才自动滚动，可手动拖、hover/触摸/
      // 聚焦即停；非溢出静止、系统「减少动态效果」时也不自动滚。
      title: AutoScrollTitle(
        text: title,
        style: const TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
      actions: [
        PopupMenuButton<String>(
          onSelected: (v) {
            switch (v) {
              case 'rename':
                onRename();
              case 'export':
                onExport();
              case 'clear':
                onClearAndRestart();
              case 'delete':
                onDelete();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('重命名')),
            PopupMenuItem(value: 'export', child: Text('导出对话')),
            PopupMenuItem(value: 'clear', child: Text('清空重开')),
            PopupMenuItem(value: 'delete', child: Text('删除对话')),
          ],
        ),
      ],
    );
  }
}

/// 回合进行中切换模型的后果说明（assistant-v4-ui §3.2 决策）。
/// 返回 true = 用户确认「仍然切换」。无在途回合时调用方应跳过本 sheet。
Future<bool> showModelSwitchConsequences(BuildContext context) async {
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('切换模型',
                  style: Theme.of(sheetContext).textTheme.titleMedium),
              const SizedBox(height: 12),
              const _Consequence(text: '当前正在进行的回合不受影响——它的上下文已按旧模型组装，会用旧模型跑完'),
              const _Consequence(text: '切换从下一条消息（下一回合）起生效'),
              const _Consequence(text: '若新模型不支持图像理解（vision），已挂的图片附件将只以文字声明发送'),
              const _Consequence(text: '上下文上限可能变化，附件预算按新模型重新计算'),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(sheetContext).pop(true),
                    child: const Text('仍然切换'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  return confirmed ?? false;
}

class _Consequence extends StatelessWidget {
  final String text;
  const _Consequence({required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                  color: cs.onSurfaceVariant, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 13, height: 1.5, color: cs.onSurface)),
          ),
        ],
      ),
    );
  }
}
