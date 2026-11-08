import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../services/database.dart';
import '../../services/undo_service.dart';
import 'message_widgets.dart';
import '../shared/skeleton_list.dart';

/// 已归档消息页（设计 §5.1；F3 手势统一：右滑 = 取出，左滑 = 删除），多选批量同上。
class ArchivedMessagesPage extends StatefulWidget {
  const ArchivedMessagesPage({super.key});

  @override
  State<ArchivedMessagesPage> createState() => _ArchivedMessagesPageState();
}

class _ArchivedMessagesPageState extends State<ArchivedMessagesPage> {
  final AppDatabase _db = AppDatabase.instance;

  List<Message> _messages = [];
  bool _loading = true;
  bool _selecting = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final messages = await _db.getMessages(status: MessageStatus.archived);
    if (!mounted) return;
    setState(() {
      _messages = messages;
      _loading = false;
      _selected.removeWhere((id) => !_messages.any((m) => m.id == id));
      if (_selected.isEmpty) _selecting = false;
    });
  }

  Future<void> _unarchive(List<Message> targets) async {
    await _db.updateMessageStatus(
        [for (final m in targets) m.id], MessageStatus.processed);
    UndoService.instance.register(
      label: '已取出',
      undo: () async {
        await _db.updateMessageStatus(
            [for (final m in targets) m.id], MessageStatus.archived);
      },
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已取出', onUndone: reload);
    await reload();
  }

  Future<void> _delete(List<Message> targets) async {
    await _db.deleteMessages([for (final m in targets) m.id]);
    UndoService.instance.register(
      label: '已删除',
      undo: () => _db.restoreMessages(targets),
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已删除', onUndone: reload);
    await reload();
  }

  /// 右滑（积极）：取出归档。
  List<SwipeAction> _startActionsFor(Message m) {
    final cs = Theme.of(context).colorScheme;
    return [
      SwipeAction(
        icon: Icons.unarchive_outlined,
        label: '取出',
        color: cs.primary,
        onTap: () => _unarchive([m]),
      ),
    ];
  }

  /// 左滑（消极）：删除。
  List<SwipeAction> _actionsFor(Message m) {
    final cs = Theme.of(context).colorScheme;
    return [
      SwipeAction(
        icon: Icons.delete_outline,
        label: '删除',
        color: cs.error,
        onTap: () => _delete([m]),
      ),
    ];
  }

  List<Message> get _selectedMessages =>
      _messages.where((m) => _selected.contains(m.id)).toList();

  void _toggleSelect(Message m) {
    setState(() {
      if (!_selected.remove(m.id)) _selected.add(m.id);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  Future<void> _runBatch(Future<void> Function(List<Message>) op) async {
    final targets = _selectedMessages;
    _exitSelection();
    if (targets.isNotEmpty) await op(targets);
  }

  AppBar _buildAppBar() {
    if (_selecting) {
      return AppBar(
        leading: IconButton(
          tooltip: '退出',
          icon: const Icon(Icons.close),
          onPressed: _exitSelection,
        ),
        title: Text('已选 ${_selected.length} 项'),
        actions: [
          TextButton(
            onPressed: () => setState(
                () => _selected.addAll(_messages.map((m) => m.id))),
            child: const Text('全选'),
          ),
          TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () => setState(() => _selected.clear()),
            child: const Text('取消'),
          ),
        ],
      );
    }
    return AppBar(title: const Text('已归档'));
  }

  @override
  Widget build(BuildContext context) {
    final hasSelection = _selected.isNotEmpty;
    return Scaffold(
      appBar: _buildAppBar(),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: reload,
              child: _loading && _messages.isEmpty
                  ? const DeferredSkeletonList(
                      loading: true, child: SizedBox.shrink())
                  : _messages.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            const SizedBox(height: 120),
                            Center(
                              child: Column(
                                children: [
                                  Icon(Icons.archive_outlined,
                                      size: 48, color: Theme.of(context)
                                          .colorScheme.onSurfaceVariant),
                                  const SizedBox(height: 12),
                                  const Text('暂无归档消息'),
                                  const SizedBox(height: 4),
                                  Text('右滑消息归档后，会出现在这里',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(context)
                                              .colorScheme.onSurfaceVariant)),
                                ],
                              ),
                            ),
                          ],
                        )
                      : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: _messages.length,
                      itemBuilder: (context, i) {
                        final m = _messages[i];
                        return MessageTile(
                          key: ValueKey(m.id),
                          message: m,
                          selecting: _selecting,
                          selected: _selected.contains(m.id),
                          startActions: _startActionsFor(m),
                          actions: _actionsFor(m),
                          onTap: () {
                            if (_selecting) _toggleSelect(m);
                          },
                          onLongPress: () {
                            if (!_selecting) {
                              setState(() {
                                _selecting = true;
                                _selected.add(m.id);
                              });
                            }
                          },
                        );
                      },
                    ),
            ),
          ),
          if (_selecting)
            SelectionActionBar(
              actions: [
                SelectionAction(
                  icon: Icons.unarchive_outlined,
                  tooltip: '取出',
                  enabled: hasSelection,
                  onTap: () => _runBatch(_unarchive),
                ),
                SelectionAction(
                  icon: Icons.delete_outline,
                  tooltip: '删除',
                  enabled: hasSelection,
                  onTap: () => _runBatch(_delete),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
