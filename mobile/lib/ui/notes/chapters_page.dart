import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../models/note.dart';
import '../../services/assistant/models.dart';
import '../../services/database.dart';
import '../assistant/attachment_pick_controller.dart';
import '../assistant/send_to_assistant.dart';
import '../messages/message_widgets.dart'
    show SelectionAction, SelectionActionBar;
import '../shared/linked_tasks_section.dart';
import 'note_editor_page.dart';
import 'notes_page.dart';

/// 笔记模块第二层：章节列表。长按拖动排序；行尾菜单重命名/删除（级联 + 复合撤销）。
/// pick 模式（2026-11-01，附件选择）：仅下钻传参，本层无可选条目。
class ChaptersPage extends StatefulWidget {
  final Notebook notebook;

  /// 附件选择模式：下钻笔记列表复用多选，选择状态写入 [pickController]。
  final bool pickMode;
  final AttachmentPickController? pickController;

  const ChaptersPage({
    super.key,
    required this.notebook,
    this.pickMode = false,
    this.pickController,
  });

  @override
  State<ChaptersPage> createState() => _ChaptersPageState();
}

class _ChaptersPageState extends State<ChaptersPage> {
  List<Chapter> _chapters = [];
  Map<String, int> _noteCounts = {};

  /// 章节级锚点计数（anchors-v2 §3 列表行轻标记）。
  Map<String, int> _anchorCounts = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final db = AppDatabase.instance;
    final chapters = await db.getChapters(widget.notebook.id);
    final rawDb = await db.database;
    final countRows = await rawDb.rawQuery(
        'SELECT chapter_id, COUNT(*) AS c FROM notes GROUP BY chapter_id');
    final anchorRows = await rawDb.rawQuery(
        "SELECT target_id, COUNT(*) AS c FROM task_anchors "
        "WHERE target_type = 'chapter' GROUP BY target_id");
    if (mounted) {
      setState(() {
        _chapters = chapters;
        _noteCounts = {
          for (final r in countRows)
            r['chapter_id'] as String: (r['c'] as num).toInt(),
        };
        _anchorCounts = {
          for (final r in anchorRows)
            r['target_id'] as String: (r['c'] as num).toInt(),
        };
      });
    }
  }

  Future<void> _openNotes(Chapter chapter) async {
    final pickConfirmed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          builder: (_) => NotesListPage(
                chapter: chapter,
                pickMode: widget.pickMode,
                pickController: widget.pickController,
              )),
    );
    // B13：pick 模式下深层页的「确认」= 带着选择回到附件选择页。
    // 本层只是中间路由（NotesPage 不是路由，它在选择页的 TabBarView 里），
    // 所以原样上抛，让选择页的底部「已选 + 确认」栏重新可见。
    if (pickConfirmed == true && mounted) {
      Navigator.of(context).pop(true);
      return;
    }
    await _reload();
  }

  Future<void> _addChapter() async {
    final name = await promptNameDialog(context, title: '新建章节');
    if (name == null) return;
    final chapter = Chapter(
      id: const Uuid().v4(),
      notebookId: widget.notebook.id,
      name: name,
      sort: _chapters.isEmpty ? 0 : _chapters.last.sort + 1,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await AppDatabase.instance.insertChapter(chapter);
    await _reload();
    if (!mounted) return;
    showUndoSnackBar(context, '已新建章节「$name」', () async {
      await AppDatabase.instance.deleteChapter(chapter.id);
      if (mounted) await _reload();
    });
  }

  Future<void> _renameChapter(Chapter chapter) async {
    final name = await promptNameDialog(context,
        title: '重命名章节', initialValue: chapter.name);
    if (name == null || name == chapter.name) return;
    await AppDatabase.instance.renameChapter(chapter.id, name);
    await _reload();
  }

  Future<void> _deleteChapter(Chapter chapter) async {
    final notes = await AppDatabase.instance.getNotes(chapter.id);
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除章节'),
        content:
            Text('删除「${chapter.name}」将同时删除其中 ${notes.length} 条笔记。'),
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

    await AppDatabase.instance.deleteChapter(chapter.id);
    await _reload();
    if (!mounted) return;
    showUndoSnackBar(context, '已删除章节「${chapter.name}」', () async {
      final db = AppDatabase.instance;
      await db.insertChapter(chapter);
      for (final note in notes) {
        await db.insertNote(note);
      }
      if (mounted) await _reload();
    });
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    setState(() {
      final moved = _chapters.removeAt(oldIndex);
      _chapters.insert(newIndex, moved);
    });
    final rawDb = await AppDatabase.instance.database;
    final batch = rawDb.batch();
    for (var i = 0; i < _chapters.length; i++) {
      batch.update('chapters', {'sort': i},
          where: 'id = ?', whereArgs: [_chapters[i].id]);
    }
    await batch.commit(noResult: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.notebook.name),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: _addChapter),
        ],
      ),
      body: _chapters.isEmpty
          ? const Center(child: Text('暂无章节，点右上角 + 新建'))
          : ReorderableListView.builder(
              itemCount: _chapters.length,
              onReorderItem: _onReorder,
              itemBuilder: (context, index) {
                final chapter = _chapters[index];
                return ListTile(
                  key: ValueKey(chapter.id),
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(chapter.name),
                  subtitle: Row(
                    children: [
                      Text('${_noteCounts[chapter.id] ?? 0} 条笔记'),
                      if ((_anchorCounts[chapter.id] ?? 0) > 0) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.link,
                            size: 13,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                        Text(' ${_anchorCounts[chapter.id]}',
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ],
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) => switch (action) {
                      'rename' => _renameChapter(chapter),
                      _ => _deleteChapter(chapter),
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('重命名')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                  onTap: () => _openNotes(chapter),
                );
              },
            ),
    );
  }
}

/// 笔记模块第三层：章节内笔记列表（updated_at 倒序）。
/// 多选态（长按进入）底部操作条带「发送给助理」（草稿附件，DB v9）。
/// pick 模式（2026-11-01，附件选择）：选择状态写入 [pickController]
/// （退出本页后选择仍保留在控制器里），底部操作条由附件选择页统一提供。
class NotesListPage extends StatefulWidget {
  final Chapter chapter;

  /// 附件选择模式。
  final bool pickMode;
  final AttachmentPickController? pickController;

  const NotesListPage({
    super.key,
    required this.chapter,
    this.pickMode = false,
    this.pickController,
  });

  @override
  State<NotesListPage> createState() => _NotesListPageState();
}

class _NotesListPageState extends State<NotesListPage> {
  List<Note> _notes = [];

  bool _selecting = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    // pick 模式：本地 _selected 是控制器（唯一事实源）的镜像
    if (widget.pickMode) {
      widget.pickController?.addListener(_syncFromPick);
      _syncFromPick();
    }
    _reload();
  }

  @override
  void dispose() {
    if (widget.pickMode) {
      widget.pickController?.removeListener(_syncFromPick);
    }
    super.dispose();
  }

  AttachmentPickController? get _pick =>
      widget.pickMode ? widget.pickController : null;

  /// pick 模式：控制器 → 本地多选态回同步。
  void _syncFromPick() {
    final pick = _pick;
    if (pick == null || !mounted) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(pick.idsOfType(ChatAttachmentType.note));
      if (_selected.isEmpty) _selecting = false;
    });
  }

  Future<void> _reload() async {
    final notes = await AppDatabase.instance.getNotes(widget.chapter.id);
    if (mounted) {
      setState(() {
        _notes = notes;
        if (!widget.pickMode) {
          _selected.removeWhere((id) => !notes.any((n) => n.id == id));
          if (_selected.isEmpty) _selecting = false;
        }
      });
      // pick 模式：为已选条目补充显示名（底栏 chip 用）
      final pick = _pick;
      if (pick != null) {
        for (final n in notes) {
          if (pick.isSelected(ChatAttachmentType.note, n.id)) {
            pick.registerMeta(
                ChatAttachmentType.note, n.id, n.title, Icons.note_outlined);
          }
        }
      }
    }
  }

  void _toggleSelect(Note n) {
    final pick = _pick;
    if (pick != null) {
      // pick 模式：写控制器，本地状态由 _syncFromPick 回同步
      pick.toggle(ChatAttachmentType.note, n.id,
          title: n.title, icon: Icons.note_outlined);
      setState(() => _selecting = true);
      return;
    }
    setState(() {
      if (!_selected.remove(n.id)) _selected.add(n.id);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  Future<void> _sendSelectedToAssistant() async {
    final targets = _notes.where((n) => _selected.contains(n.id)).toList();
    if (targets.isEmpty) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    await sendToAssistant(context, [
      for (final n in targets)
        ChatAttachment(type: ChatAttachmentType.note, id: n.id),
    ]);
  }

  Future<void> _addNote() async {
    // 编辑器退出自动保存；返回非空 Note 表示新建入库
    final created = await Navigator.of(context).push<Note>(
      MaterialPageRoute(
          builder: (_) => NoteEditorPage(chapterId: widget.chapter.id)),
    );
    await _reload();
    if (created == null || !mounted) return;
    showUndoSnackBar(context, '已新建笔记「${created.title}」', () async {
      await AppDatabase.instance.deleteNote(created.id);
      if (mounted) await _reload();
    });
  }

  Future<void> _openNote(Note note) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteEditorPage(existing: note)),
    );
    await _reload();
  }

  Future<void> _deleteNote(Note note) async {
    await AppDatabase.instance.deleteNote(note.id);
    await _reload();
    if (!mounted) return;
    showUndoSnackBar(context, '已删除笔记「${note.title}」', () async {
      await AppDatabase.instance.insertNote(note);
      if (mounted) await _reload();
    });
  }

  /// B13：pick 模式的本地确认栏（已选笔记数 + 确认）。
  ///
  /// 只负责**带着选择回到附件选择页**（选择存在 [AttachmentPickController] 里，
  /// 跨路由不丢），真正把附件交回对话的确认仍由附件选择页统一执行——
  /// 与消息/文件分区「底部条由选择页统一提供」的约定一致，不在深层复制一套提交逻辑。
  Widget _buildPickConfirmBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          border: Border(
              top: BorderSide(color: cs.outlineVariant, width: 0.5)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _selected.isEmpty
                    ? '未选择笔记'
                    : '已选 ${_selected.length} 项笔记',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('确认（${_selected.length}）'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // B13：pick 模式下选择存在控制器里，返回不应清空——给明确的返回箭头
        // （原来这里被「×（退出多选）」占据，按它等于丢选择，系统返回又没有箭头）。
        leading: widget.pickMode
            ? IconButton(
                tooltip: '返回（已选保留）',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              )
            : _selecting
                ? IconButton(
                    tooltip: '退出',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      final pick = _pick;
                      if (pick != null) {
                        pick.clearType(ChatAttachmentType.note);
                        setState(() => _selecting = false);
                        return;
                      }
                      setState(() {
                        _selecting = false;
                        _selected.clear();
                      });
                    },
                  )
                : null,
        title: Text(_selecting ? '已选 ${_selected.length} 项' : widget.chapter.name),
        actions: [
          if (!_selecting)
            IconButton(icon: const Icon(Icons.add), onPressed: _addNote),
        ],
      ),
      body: Column(
        children: [
          // 章节级「关联任务」区（anchors-v2 §3：章节是笔记集合的锚点粒度）
          if (!widget.pickMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: LinkedTasksSection(
                targetType: AnchorTargetType.chapter,
                targetId: widget.chapter.id,
                seedTitle: widget.chapter.name,
              ),
            ),
          Expanded(
            child: _notes.isEmpty
                ? const Center(child: Text('暂无笔记，点右上角 + 新建'))
                : ListView.builder(
              itemCount: _notes.length,
              itemBuilder: (context, index) {
                final note = _notes[index];
                final selected = _selected.contains(note.id);
                final firstLine = note.content
                    .split('\n')
                    .map((l) => l.trim())
                    .firstWhere((l) => l.isNotEmpty, orElse: () => '');
                return ListTile(
                  // pick 模式（附件选择）：点击即选中/取消，无删除菜单、
                  // 无需先长按进多选
                  leading: _selecting || widget.pickMode
                      ? Icon(selected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked)
                      : null,
                  title: Text(note.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (firstLine.isNotEmpty)
                        Text(firstLine,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(_formatMillis(note.updatedAt),
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                  trailing: _selecting || widget.pickMode
                      ? null
                      : PopupMenuButton<String>(
                          onSelected: (_) => _deleteNote(note),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'delete', child: Text('删除')),
                          ],
                        ),
                  onTap: () {
                    if (widget.pickMode || _selecting) {
                      _toggleSelect(note);
                    } else {
                      _openNote(note);
                    }
                  },
                  onLongPress: widget.pickMode
                      ? null
                      : () {
                          if (!_selecting) {
                            setState(() {
                              _selecting = true;
                              _selected.add(note.id);
                            });
                          }
                        },
                );
              },
            ),
          ),
        ],
      ),
      // B13：pick 模式下本页是独立路由，附件选择页的「已选 + 确认」栏在上一层
      // 看不到，所以这里补一个确认入口（把选择带回选择页，由它统一确认并返回结果）；
      // 普通模式仍只有多选态的「发送给助理」，行为不变。
      bottomNavigationBar: widget.pickMode
          ? _buildPickConfirmBar(context)
          : _selecting
              ? SelectionActionBar(
                  actions: [
                    SelectionAction(
                      icon: Icons.send_outlined,
                      tooltip: '发送给助理',
                      enabled: _selected.isNotEmpty,
                      onTap: _sendSelectedToAssistant,
                    ),
                  ],
                )
              : null,
    );
  }
}

String _formatMillis(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}
