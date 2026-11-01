import 'package:flutter/material.dart';

import '../../models/task.dart';
import '../../services/database.dart';
import 'task_editor.dart';

/// 手动锚点流程的任务选择器（design-v3 §3.3）：底部弹出，选已有任务
/// （活动任务，标题过滤）或「新建任务」（复用任务编辑器）。
/// 返回选中的任务；取消返回 null。
Future<Task?> showTaskPicker(BuildContext context, {String? seedTitle}) {
  return showModalBottomSheet<Task>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _TaskPickerSheet(seedTitle: seedTitle),
  );
}

class _TaskPickerSheet extends StatefulWidget {
  final String? seedTitle;

  const _TaskPickerSheet({this.seedTitle});

  @override
  State<_TaskPickerSheet> createState() => _TaskPickerSheetState();
}

class _TaskPickerSheetState extends State<_TaskPickerSheet> {
  final _filterController = TextEditingController();
  List<Task>? _tasks;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final tasks = await AppDatabase.instance.getTasks(status: TaskStatus.active);
    if (!mounted) return;
    setState(() => _tasks = tasks);
  }

  Future<void> _createTask() async {
    final result = await showTaskEditor(context, seedTitle: widget.seedTitle);
    final task = result?.task;
    if (result == null || result.deleted || task == null || !mounted) return;
    await AppDatabase.instance.insertTask(task);
    if (mounted) Navigator.of(context).pop(task);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final query = _filterController.text.trim();
    final tasks = _tasks;
    final shown = tasks == null
        ? const <Task>[]
        : (query.isEmpty
            ? tasks
            : tasks.where((t) => t.title.contains(query)).toList());
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _filterController,
                      autofocus: false,
                      decoration: const InputDecoration(
                        hintText: '搜索任务标题',
                        prefixIcon: Icon(Icons.search, size: 20),
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _createTask,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('新建'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: tasks == null
                  ? const Center(child: CircularProgressIndicator())
                  : shown.isEmpty
                      ? Center(
                          child: Text(query.isEmpty ? '没有活动任务' : '没有匹配「$query」的任务',
                              style: TextStyle(color: cs.onSurfaceVariant)))
                      : ListView.builder(
                          itemCount: shown.length,
                          itemBuilder: (context, i) {
                            final t = shown[i];
                            return ListTile(
                              dense: true,
                              leading: Icon(Icons.radio_button_unchecked,
                                  size: 18, color: cs.onSurfaceVariant),
                              title: Text(t.title,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              onTap: () => Navigator.of(context).pop(t),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
