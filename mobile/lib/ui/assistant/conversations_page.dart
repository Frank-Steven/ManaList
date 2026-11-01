import 'package:flutter/material.dart';

import '../../models/conversation.dart';
import '../../services/assistant/assistant_service.dart';
import '../../services/database.dart';
import 'approvals_page.dart';
import 'chat_page.dart';
import 'model_picker.dart';
import 'widgets/streaming_blocks.dart';

/// 助理主 Tab（design-v3 §5.1）：对话列表（新建/改名/删除），
/// AppBar 一级入口：待确认区、模型配置。设置已改回底部第 4 个 tab，
/// 本页不再持有设置入口。
/// 2026-11-01 多 Agent 并行：在途回合的对话在列表里指示工作状态
/// （思考中/回复中/工具执行中 + 呼吸圆点），回合由服务自持、跨页面存活。
class ConversationsPage extends StatefulWidget {
  const ConversationsPage({super.key});

  @override
  State<ConversationsPage> createState() => ConversationsPageState();
}

class ConversationsPageState extends State<ConversationsPage> {
  List<Conversation> _conversations = [];

  @override
  void initState() {
    super.initState();
    // 在途回合的开始/阶段变化/结束都会 bump turnsVersion
    AssistantService.instance.turnsVersion.addListener(_onTurnsChange);
    reload();
  }

  @override
  void dispose() {
    AssistantService.instance.turnsVersion.removeListener(_onTurnsChange);
    super.dispose();
  }

  void _onTurnsChange() {
    if (mounted) setState(() {});
  }

  Future<void> reload() async {
    final list = await AppDatabase.instance.getConversations();
    if (mounted) setState(() => _conversations = list);
  }

  Future<void> _newConversation() async {
    final conv = await AssistantService.instance.createConversation();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatPage(conversation: conv)),
    );
    await reload();
  }

  Future<void> _rename(Conversation conv) async {
    final controller = TextEditingController(text: conv.title);
    final saved = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名对话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '标题'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == null || saved.isEmpty) return;
    await AppDatabase.instance.renameConversation(conv.id, saved);
    await reload();
  }

  Future<void> _delete(Conversation conv) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除对话'),
        content: Text('删除「${conv.title}」？其待确认提案会保留在待确认区。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await AppDatabase.instance.deleteConversation(conv.id);
    await reload();
  }

  String _fmtTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}-${d.day} ${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('助理'),
        actions: [
          IconButton(
            tooltip: '待确认区',
            icon: const Icon(Icons.fact_check_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ApprovalsPage()),
            ),
          ),
          IconButton(
            tooltip: '模型配置',
            icon: const Icon(Icons.model_training),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ModelPickerPage()),
            ),
          ),
        ],
      ),
      body: _conversations.isEmpty
          ? Center(
              child: Text('还没有对话，点右下角新建',
                  style: TextStyle(color: cs.onSurfaceVariant)),
            )
          : ListView.builder(
              itemCount: _conversations.length,
              itemBuilder: (_, i) {
                final c = _conversations[i];
                final turn = AssistantService.instance.turnOf(c.id);
                return ListTile(
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: Text(c.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: turn != null
                      ? Row(
                          children: [
                            const BreathingDot(size: 6),
                            const SizedBox(width: 6),
                            Text('${turnPhaseLabel(turn.phase.value)}…',
                                style: TextStyle(
                                    fontSize: 12, color: cs.primary)),
                          ],
                        )
                      : Text(_fmtTime(c.updatedAt),
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant)),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'rename') _rename(c);
                      if (v == 'delete') _delete(c);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('重命名')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => ChatPage(conversation: c)),
                    );
                    await reload();
                  },
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        tooltip: '新建对话',
        onPressed: _newConversation,
        child: const Icon(Icons.add),
      ),
    );
  }
}
