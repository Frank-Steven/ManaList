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
    // B46：选择集是「ID 快照」，这里只剔除已不存在的 ID；
    // 期间新归档的消息**不会**自动并入旧快照（避免全选集合被悄悄扩大）。
    final allIds = (await _db.getArchivedMessageIds()).toSet();
    if (!mounted) return;
    setState(() {
      _messages = messages;
      _loading = false;
      _selected.removeWhere((id) => !allIds.contains(id));
      if (_selected.isEmpty) _selecting = false;
    });
  }

  /// B46：全选 = **全部已归档**。首屏仍只查 defaultMessageLimit(500) 条，
  /// 但选择范围来自 ID 快照（getArchivedMessageIds），不再是首屏列表。
  Future<void> _selectAll() async {
    final ids = await _db.getArchivedMessageIds();
    if (!mounted) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(ids);
      _selecting = _selected.isNotEmpty;
    });
  }

  /// B46：按 ID 取出（500 分块更新 processed，然后一次 reload）。
  Future<void> _unarchiveIds(List<String> ids) async {
    if (ids.isEmpty) return;
    await _db.updateMessageStatusChunked(ids, MessageStatus.processed);
    UndoService.instance.register(
      label: '已取出',
      undo: () => _db.updateMessageStatusChunked(ids, MessageStatus.archived),
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已取出', onUndone: reload);
    await reload();
  }

  /// B46：按 ID 删除 —— 单事务写入 DB 撤销备份再删；撤销闭包只持批次 id。
  Future<void> _deleteIds(List<String> ids) async {
    if (ids.isEmpty) return;
    final batchId = await _db.deleteArchivedWithBackup(ids);
    if (batchId == null) return;
    UndoService.instance.register(
      label: '已删除',
      undo: () => _db.restoreDeletedMessageBatch(batchId),
      // 到期 / clear / undo 失败时丢弃这批备份（成功 undo 已由恢复函数清掉）。
      onExpire: () => _db.deleteUndoBackupBatch(batchId),
    );
    // B46（task-76/77）：先把列表 reload 完，再弹 SnackBar。
    // 原来的「先 show 再 reload」会让 reload 触发的重建与 SnackBar 展示同一帧竞争：
    // 真机上表现为删除后 0.3–4.2s 连拍都看不到「已删除 + 撤销」（4s 窗口被吃光）。
    // 这里只调整顺序，备份/UndoService 注册/闭包/4s 时长一律不动。
    await reload();
    if (!mounted) return;
    showUndoSnackBar(context, '已删除', onUndone: reload);
  }

  /// 右滑（积极）：取出归档。
  List<SwipeAction> _startActionsFor(Message m) {
    final cs = Theme.of(context).colorScheme;
    return [
      SwipeAction(
        icon: Icons.unarchive_outlined,
        label: '取出',
        color: cs.primary,
        onTap: () => _unarchiveIds([m.id]),
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
        onTap: () => _deleteIds([m.id]),
      ),
    ];
  }

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

  /// B46：批量入口只传**选择的 ID**（快照可能包含首屏之外的 ID）。
  Future<void> _runBatch(Future<void> Function(List<String> ids) op) async {
    final ids = _selected.toList();
    _exitSelection();
    if (ids.isNotEmpty) await op(ids);
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
            // B46：全选 = 全部已归档（ID 快照），不再只选首屏这 500 条。
            onPressed: () => _selectAll(),
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
                  onTap: () => _runBatch(_unarchiveIds),
                ),
                SelectionAction(
                  icon: Icons.delete_outline,
                  tooltip: '删除',
                  enabled: hasSelection,
                  onTap: () => _runBatch(_deleteIds),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
