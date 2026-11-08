import 'dart:convert';

import '../../models/conversation.dart';
import '../../models/library_file.dart';
import '../../services/assistant/models.dart';
import '../../services/database.dart';
import '../../services/library_file_service.dart';

/// 导出对话为 markdown 文件，落文件区（source: noteExport）。
/// 对话页 ⋮ 菜单与对话列表长按菜单共用（assistant-v4-ui §2.2）。
/// 返回落盘的文件名。
Future<String> exportConversationToMarkdown(Conversation conversation,
    {String modelLabel = ''}) async {
  final messages =
      await AppDatabase.instance.getChatMessages(conversation.id);
  String two(int v) => v.toString().padLeft(2, '0');
  String fmtFullTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  final buf = StringBuffer()
    ..writeln('# ${conversation.title}')
    ..writeln()
    ..writeln(
        '> 导出自 ManaList 助理对话${modelLabel.isEmpty ? '' : ' · 模型：$modelLabel'}')
    ..writeln();
  for (final m in messages) {
    final who = m.role == ChatRole.user
        ? '我'
        : m.role == ChatRole.assistant
            ? '助理'
            : '工具';
    buf
      ..writeln('## $who（${fmtFullTime(m.createdAt)}）')
      ..writeln()
      ..writeln(m.content)
      ..writeln();
  }
  final safeTitle =
      conversation.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  final name = '对话-${safeTitle.isEmpty ? '未命名' : safeTitle}.md';
  await LibraryFileService.instance.importBytes(
    utf8.encode(buf.toString()),
    name: name,
    mimeType: 'text/markdown',
    source: FileSource.noteExport,
  );
  return name;
}
