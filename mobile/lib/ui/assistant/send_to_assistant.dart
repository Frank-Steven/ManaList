import 'package:flutter/material.dart';

import '../../models/conversation.dart';
import '../../services/assistant/assistant_service.dart';
import '../../services/assistant/models.dart';
import '../../services/database.dart';
import 'chat_page.dart';

/// 库页各分区多选态「发送给助理」（ui-structure §2：单选即走 = 小型 sheet）：
/// 弹对话选择（现有对话 + 「新建对话」），所选条目追加为该对话的草稿附件
/// （conversations.draft_attachments，DB v9），SnackBar 提示并可跳转该对话。
Future<void> sendToAssistant(
    BuildContext context, List<ChatAttachment> items) async {
  if (items.isEmpty) return;
  final conversations = await AppDatabase.instance.getConversations();
  if (!context.mounted) return;
  // null = 用户取消；'__new__' = 新建对话；否则为对话 id
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(
            title: Text('发送给助理',
                style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('所选条目会加入对话的草稿附件'),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  leading: const Icon(Icons.add_comment_outlined),
                  title: const Text('新建对话'),
                  onTap: () => Navigator.of(sheetContext).pop('__new__'),
                ),
                for (final c in conversations)
                  ListTile(
                    leading: const Icon(Icons.chat_bubble_outline),
                    title:
                        Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: c.draftAttachments.isNotEmpty
                        ? Text('已有 ${c.draftAttachments.length} 个草稿附件',
                            style: const TextStyle(fontSize: 12))
                        : null,
                    onTap: () => Navigator.of(sheetContext).pop(c.id),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  Conversation conv;
  if (choice == '__new__') {
    conv = await AssistantService.instance.createConversation();
  } else {
    final found = await AppDatabase.instance.getConversationById(choice);
    if (found == null || !context.mounted) return;
    conv = found;
  }
  final drafts = await AppDatabase.instance
      .appendConversationDraftAttachments(conv.id, items);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text('已加入 ${items.length} 个附件到「${conv.title}」（共 ${drafts.length} 个草稿）'),
      action: SnackBarAction(
        label: '前往',
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(
              builder: (_) => ChatPage(
                  conversation:
                      conv.copyWith(draftAttachments: drafts))),
        ),
      ),
    ));
}
