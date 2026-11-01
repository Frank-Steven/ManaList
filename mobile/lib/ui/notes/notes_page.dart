import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../models/note.dart';
import '../../services/database.dart';
import '../../services/undo_service.dart';
import '../assistant/attachment_pick_controller.dart';
import 'chapters_page.dart';

/// 撤销统一入口（设计 §6，v2.1）：逆操作入队 + SnackBar 提示（「{label}」+ 撤销按钮，
/// 4 秒、不排队），「撤销」按钮弹栈执行。
void showUndoSnackBar(
    BuildContext context, String label, Future<void> Function() undo) {
  UndoService.instance.register(label: label, undo: undo);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(label),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () => UndoService.instance.undoLatest(),
        ),
      ),
    );
}

/// 名称输入对话框：返回 trim 后的非空名称，取消或空输入返回 null。
Future<String?> promptNameDialog(BuildContext context,
    {required String title, String? initialValue}) async {
  final controller = TextEditingController(text: initialValue);
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '名称'),
        onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  final name = result?.trim();
  return (name == null || name.isEmpty) ? null : name;
}

/// 笔记模块第一层：笔记本列表（设计 §4）。
/// 长按拖动排序；行尾菜单重命名/删除（删除为级联 + 复合撤销）。
/// pick 模式（2026-11-01，附件选择）：下钻章节/笔记列表复用多选，
/// 选择状态写入 [pickController]（跨页面导航不丢）。
class NotesPage extends StatefulWidget {
  const NotesPage({
    super.key,
    this.pickMode = false,
    this.pickController,
  });

  /// 附件选择模式：仅下钻传参，本层（笔记本列表）无可选条目。
  final bool pickMode;
  final AttachmentPickController? pickController;

  @override
  State<NotesPage> createState() => NotesPageState();
}

class NotesPageState extends State<NotesPage> {
  List<Notebook> _notebooks = [];
  Map<String, int> _chapterCounts = {};
  bool _defaultChecked = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 供外部（如底部导航切页）触发的公开刷新入口。
  Future<void> reload() => _reload();

  /// 库页 FAB「新建笔记本」入口（ui-structure §4：领域主创建统一 FAB）。
  Future<void> createNotebook() => _addNotebook();

  Future<void> _reload() async {
    final db = AppDatabase.instance;
    var notebooks = await db.getNotebooks();
    // 首次打开没有任何笔记本时自动建一个「默认笔记本」
    if (notebooks.isEmpty && !_defaultChecked) {
      _defaultChecked = true;
      await db.insertNotebook(Notebook(
        id: const Uuid().v4(),
        name: '默认笔记本',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      notebooks = await db.getNotebooks();
    }
    final rawDb = await db.database;
    final countRows = await rawDb.rawQuery(
        'SELECT notebook_id, COUNT(*) AS c FROM chapters GROUP BY notebook_id');
    if (mounted) {
      setState(() {
        _notebooks = notebooks;
        _chapterCounts = {
          for (final r in countRows)
            r['notebook_id'] as String: (r['c'] as num).toInt(),
        };
      });
    }
  }

  Future<void> _openChapters(Notebook notebook) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => ChaptersPage(
                notebook: notebook,
                pickMode: widget.pickMode,
                pickController: widget.pickController,
              )),
    );
    await _reload();
  }

  Future<void> _addNotebook() async {
    final name = await promptNameDialog(context, title: '新建笔记本');
    if (name == null) return;
    final notebook = Notebook(
      id: const Uuid().v4(),
      name: name,
      sort: _notebooks.isEmpty ? 0 : _notebooks.last.sort + 1,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await AppDatabase.instance.insertNotebook(notebook);
    await _reload();
    if (!mounted) return;
    showUndoSnackBar(context, '已新建笔记本「$name」', () async {
      await AppDatabase.instance.deleteNotebook(notebook.id);
      if (mounted) await _reload();
    });
  }

  Future<void> _renameNotebook(Notebook notebook) async {
    final name = await promptNameDialog(context,
        title: '重命名笔记本', initialValue: notebook.name);
    if (name == null || name == notebook.name) return;
    await AppDatabase.instance.renameNotebook(notebook.id, name);
    await _reload();
  }

  /// 级联删除的复合撤销（设计 §4/§6）：删除前读出整棵子树，撤销时原样插回。
  Future<void> _deleteNotebook(Notebook notebook) async {
    final chapters = await AppDatabase.instance.getChapters(notebook.id);
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除笔记本'),
        content: Text(
            '删除「${notebook.name}」将同时删除其下 ${chapters.length} 个章节及全部笔记。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final notesByChapter = <String, List<Note>>{};
    for (final chapter in chapters) {
      notesByChapter[chapter.id] =
          await AppDatabase.instance.getNotes(chapter.id);
    }
    await AppDatabase.instance.deleteNotebook(notebook.id);
    await _reload();
    if (!mounted) return;
    showUndoSnackBar(context, '已删除笔记本「${notebook.name}」', () async {
      final db = AppDatabase.instance;
      await db.insertNotebook(notebook);
      for (final chapter in chapters) {
        await db.insertChapter(chapter);
        for (final note in notesByChapter[chapter.id] ?? const <Note>[]) {
          await db.insertNote(note);
        }
      }
      if (mounted) await _reload();
    });
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    setState(() {
      final moved = _notebooks.removeAt(oldIndex);
      _notebooks.insert(newIndex, moved);
    });
    final rawDb = await AppDatabase.instance.database;
    final batch = rawDb.batch();
    for (var i = 0; i < _notebooks.length; i++) {
      batch.update('notebooks', {'sort': i},
          where: 'id = ?', whereArgs: [_notebooks[i].id]);
    }
    await batch.commit(noResult: true);
  }

  @override
  Widget build(BuildContext context) {
    // ui-structure §3：分区页不持有 AppBar（由库页容器统一持有）。
    return Scaffold(
      body: _notebooks.isEmpty
          ? const Center(child: Text('暂无笔记本，点右下角 + 新建'))
          : ReorderableListView.builder(
              itemCount: _notebooks.length,
              onReorderItem: _onReorder,
              itemBuilder: (context, index) {
                final notebook = _notebooks[index];
                return ListTile(
                  key: ValueKey(notebook.id),
                  leading: const Icon(Icons.book_outlined),
                  title: Text(notebook.name),
                  subtitle:
                      Text('${_chapterCounts[notebook.id] ?? 0} 个章节'),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) => switch (action) {
                      'rename' => _renameNotebook(notebook),
                      _ => _deleteNotebook(notebook),
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('重命名')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                  onTap: () => _openChapters(notebook),
                );
              },
            ),
    );
  }
}
