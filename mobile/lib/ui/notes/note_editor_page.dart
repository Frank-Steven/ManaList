import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../models/note.dart';
import '../../models/task.dart';
import '../../services/anchor_service.dart';
import '../../services/assistant/models.dart';
import '../../services/database.dart';
import '../../services/library_file_service.dart';
import '../../services/system_intent.dart';
import '../shared/anchor_highlight_controller.dart';
import '../shared/anchored_markdown.dart';
import '../tasks/task_navigation.dart';
import '../tasks/task_picker.dart';

/// 笔记编辑器（设计 §4；v3 阶段 4 markdown 化，design-v3 §3.3、details §1.3）：
/// 标题 + 正文，退出自动保存，无保存按钮。
///
/// v3 阶段 4 变更：
/// - 双模式：编辑态 = 纯文本 TextField + [AnchorHighlightController]
///   高亮 marker（不做 WYSIWYG）；预览态 = [AnchoredMarkdownBody]
///   （锚点 chip 可点击跳任务详情）。plain 笔记预览维持纯文本渲染。
/// - 手动锚点：编辑态工具栏「添加任务锚点」（取选中文本/光标处），预览态
///   长按选段的上下文菜单「添加任务锚点」；plain 笔记先弹「转为 Markdown」
///   一次性确认（纯文本是 markdown 合法子集，无损）。
/// - 附件：插入图片/文件 → 入 files 表 → 正文插入 `![name](file://id)`。
///
/// - [existing] 非空 = 编辑已有笔记；否则按 [chapterId] 新建（content_format
///   默认 markdown）。
/// - [highlightAnchorId] 非空 = 反向跳转进入：直接落到预览态并高亮/定位
///   该锚点 chip。
/// - 标题留空时取正文首个非空行的前 20 字作标题；标题、正文均为空则不保存。
/// - pop 返回值：新建且实际入库时为新建的 [Note]，其余情况为 null
///   （由调用方负责撤销注册）。
class NoteEditorPage extends StatefulWidget {
  final Note? existing;
  final String? chapterId;
  final String? highlightAnchorId;

  const NoteEditorPage({
    super.key,
    this.existing,
    this.chapterId,
    this.highlightAnchorId,
  });

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  late final TextEditingController _titleController;
  late final AnchorHighlightController _contentController;

  /// 笔记格式（'markdown' / 'plain'）；新建默认 markdown。
  late String _contentFormat =
      widget.existing?.contentFormat ?? 'markdown';

  /// 附件文件 id（引用 files.id），保存时随笔记落库。
  late List<String> _attachments =
      List<String>.of(widget.existing?.attachments ?? const []);

  /// false=编辑态 true=预览态；反向跳转（highlightAnchorId）直接落预览态。
  late bool _preview = widget.highlightAnchorId != null;

  bool _allowPop = false;
  bool _exiting = false;
  Future<void>? _saveFuture;
  Note? _inserted;

  /// 库内当前状态快照（初始 = [NoteEditorPage.existing]，每次成功落库/
  /// 锚点同步后更新）——保存时与快照比较，避免冗余写库。
  late Note? _persistedNote = widget.existing;

  /// 预览态 SelectionArea 当前选中的片段（「添加任务锚点」菜单用）。
  String? _selectedText;

  bool get _isMarkdown => _contentFormat == 'markdown';

  @override
  void initState() {
    super.initState();
    _titleController =
        TextEditingController(text: widget.existing?.title ?? '');
    _contentController =
        AnchorHighlightController(text: widget.existing?.content ?? '');
  }

  @override
  void dispose() {
    // 兜底：路由被外部移除时也保存（正常退出已在 PopScope 保存过，幂等）。
    // _doSave 在首个 await 前同步读完控制器，先于下面的 dispose。
    _save();
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  /// 保存一次，重复调用返回同一 Future。
  Future<void> _save() => _saveFuture ??= _doSave();

  Future<void> _doSave() async {
    final content = _contentController.text;
    var title = _titleController.text.trim();
    if (title.isEmpty) {
      for (final line in content.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) {
          title =
              trimmed.length <= 20 ? trimmed : trimmed.substring(0, 20);
          break;
        }
      }
    }
    if (title.isEmpty) return;

    final existing = _persistedNote;
    if (existing != null) {
      final unchanged = existing.title == title &&
          existing.content == content &&
          existing.contentFormat == _contentFormat &&
          _listEquals(existing.attachments, _attachments);
      if (unchanged) return;
      final updated = existing.copyWith(
        title: title,
        content: content,
        contentFormat: _contentFormat,
        attachments: _attachments,
      );
      await AppDatabase.instance.updateNote(updated);
      _persistedNote = updated;
      if (_inserted != null) _inserted = updated;
    } else {
      final now = DateTime.now().millisecondsSinceEpoch;
      final note = Note(
        id: const Uuid().v4(),
        chapterId: widget.chapterId!,
        title: title,
        content: content,
        contentFormat: _contentFormat,
        attachments: _attachments,
        createdAt: now,
        updatedAt: now,
      );
      await AppDatabase.instance.insertNote(note);
      _inserted = note;
      _persistedNote = note;
    }
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _onPopInvoked(bool didPop) async {
    if (didPop || _exiting) return;
    _exiting = true;
    await _save();
    if (!mounted) return;
    setState(() => _allowPop = true);
    // 等 PopScope 以 canPop=true 重建后再退出，否则这次 pop 仍会被拦截
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(_inserted);
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// plain 笔记加锚点/插图前的一次性「转为 Markdown」确认（details §1.3）。
  /// 已是 markdown 直接返回 true；用户取消返回 false。
  Future<bool> _ensureMarkdown() async {
    if (_isMarkdown) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('转为 Markdown'),
        content: const Text('锚点与图片需要 Markdown 渲染。纯文本是 Markdown 的合法子集，'
            '转换不改动正文内容；转换后预览将按 Markdown 渲染。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('转换')),
        ],
      ),
    );
    if (ok != true) return false;
    setState(() => _contentFormat = 'markdown');
    // 已入库的笔记立即持久化格式（新笔记随 _save 落库）。
    final existing = _persistedNote;
    if (existing != null) {
      final updated = existing.copyWith(contentFormat: _contentFormat);
      await AppDatabase.instance.updateNote(updated);
      _persistedNote = updated;
      if (_inserted != null) _inserted = updated;
    }
    return true;
  }

  /// 确保笔记已入库（锚点/附件要写 notes 行）；返回笔记 id，未入库且
  /// 内容为空（保存不了）时返回 null。
  /// 锚点写入以库内正文为准，先强制把最新编辑刷进库（_saveFuture 缓存的
  /// 可能是旧正文，否则 anchorText 定位会失败）。
  Future<String?> _ensurePersisted() async {
    _saveFuture = null;
    await _save();
    return _persistedNote?.id;
  }

  /// 手动锚点主流程（design-v3 §3.3）：选/建任务 → AnchorService 插
  /// marker + 写表 → 编辑器内容与库内正文同步。
  /// [anchorText] 为空时追加到正文末尾。
  Future<void> _addAnchor(String? anchorText) async {
    final text = anchorText?.trim();
    if (!await _ensureMarkdown()) return;
    if (!mounted) return;
    final task = await showTaskPicker(
        context, seedTitle: (text == null || text.isEmpty) ? null : text);
    if (task == null || !mounted) return;
    final noteId = await _ensurePersisted();
    if (noteId == null) {
      _toast('请先输入内容再添加锚点');
      return;
    }
    final result = await AnchorService.instance.insertAnchor(
      taskId: task.id,
      targetType: AnchorTargetType.note,
      targetId: noteId,
      anchorText: (text == null || text.isEmpty) ? null : text,
    );
    if (!mounted) return;
    if (!result.ok) {
      _toast(result.error ?? '添加锚点失败');
      return;
    }
    // 库内正文已被 AnchorService 改写（含 marker），回读同步编辑器。
    final note = await AppDatabase.instance.getNoteById(noteId);
    if (!mounted || note == null) return;
    _persistedNote = note;
    setState(() => _contentController.text = note.content);
    _saveFuture = null; // 内容变了，允许再次保存
    _toast(result.multipleMatches ? '已添加锚点（多处出现，定位在第一处）' : '已添加锚点');
  }

  /// 编辑态工具栏「添加任务锚点」：取当前选中文本，无选中则追加到末尾。
  Future<void> _addAnchorFromEditSelection() {
    final sel = _contentController.selection;
    final text = _contentController.text;
    String? selected;
    if (sel.isValid && !sel.isCollapsed &&
        sel.start >= 0 && sel.end <= text.length) {
      selected = text.substring(sel.start, sel.end);
    }
    return _addAnchor(selected);
  }

  /// 预览态长按选段「添加任务锚点」（SelectionArea 上下文菜单）。
  Future<void> _addAnchorFromPreviewSelection() async {
    final text = _selectedText?.trim();
    if (!mounted) return;
    if (text == null || text.isEmpty) return;
    await _addAnchor(text);
  }

  /// 插入附件（design-v3 §3.3）：图片/文件 → 入 files 表 → 光标处插入
  /// `![name](file://id)`。
  Future<void> _insertAttachment() async {
    final kind = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('图片'),
              onTap: () => Navigator.pop(ctx, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('文件'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
          ],
        ),
      ),
    );
    if (kind == null || !mounted) return;

    String? path;
    String? name;
    if (kind == 'image') {
      final picked =
          await ImagePicker().pickImage(source: ImageSource.gallery);
      path = picked?.path;
      name = picked?.name;
    } else {
      final picked = await FilePicker.platform.pickFiles(allowMultiple: false);
      path = picked?.files.single.path;
      name = picked?.files.single.name;
    }
    if (path == null || !mounted) return;
    if (!await _ensureMarkdown()) return;

    final file = await LibraryFileService.instance.importFromPath(
      path,
      name: name,
      mimeType: SystemIntent.mimeOf(path),
    );
    if (file == null) {
      _toast('附件导入失败');
      return;
    }
    setState(() => _attachments = [..._attachments, file.id]);
    _insertAtCursor('![${file.name}](file://${file.id})');
    _toast('已插入附件「${file.name}」');
  }

  /// 在光标处插入片段（前面不是换行则先补一个换行，保证图片语法独占行）。
  void _insertAtCursor(String snippet) {
    final text = _contentController.text;
    final sel = _contentController.selection;
    final at = (sel.isValid && sel.start >= 0) ? sel.start : text.length;
    final needNl = at > 0 && text[at - 1] != '\n';
    final insert = needNl ? '\n$snippet' : snippet;
    _contentController.text =
        text.substring(0, at) + insert + text.substring(at);
    _contentController.selection =
        TextSelection.collapsed(offset: at + insert.length);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) => _onPopInvoked(didPop),
      child: Scaffold(
        appBar: AppBar(
          title: TextField(
            controller: _titleController,
            style: Theme.of(context).textTheme.titleLarge,
            decoration: const InputDecoration(
              hintText: '标题',
              border: InputBorder.none,
            ),
            textInputAction: TextInputAction.next,
          ),
          actions: [
            if (!_preview) ...[
              IconButton(
                tooltip: '添加任务锚点',
                onPressed: _addAnchorFromEditSelection,
                icon: const Icon(Icons.add_link, size: 20),
              ),
              IconButton(
                tooltip: '插入图片/文件',
                onPressed: _insertAttachment,
                icon: const Icon(Icons.attach_file, size: 20),
              ),
            ],
            IconButton(
              tooltip: _preview ? '编辑' : '预览',
              onPressed: () => setState(() => _preview = !_preview),
              icon: Icon(
                  _preview ? Icons.edit_outlined : Icons.visibility_outlined,
                  size: 20),
            ),
          ],
        ),
        body: _preview ? _buildPreview() : _buildEditor(),
      ),
    );
  }

  Widget _buildEditor() {
    return TextField(
      controller: _contentController,
      expands: true,
      maxLines: null,
      minLines: null,
      keyboardType: TextInputType.multiline,
      textAlignVertical: TextAlignVertical.top,
      decoration: const InputDecoration(
        hintText: '正文（支持 Markdown）',
        border: InputBorder.none,
        contentPadding: EdgeInsets.all(16),
      ),
    );
  }

  /// 预览态（details §1.3）：markdown 笔记走锚点渲染管线（SelectionArea
  /// 提供长按选段 + 「添加任务锚点」菜单）；plain 笔记维持纯文本渲染。
  Widget _buildPreview() {
    final content = _contentController.text;
    if (!_isMarkdown) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          content.isEmpty ? '（无内容）' : content,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectionArea(
        onSelectionChanged: (content) =>
            _selectedText = content?.plainText,
        contextMenuBuilder: (context, selectableRegionState) {
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: selectableRegionState.contextMenuAnchors,
            buttonItems: [
              ...selectableRegionState.contextMenuButtonItems,
              ContextMenuButtonItem(
                label: '添加任务锚点',
                onPressed: () {
                  ContextMenuController.removeAny();
                  _addAnchorFromPreviewSelection();
                },
              ),
            ],
          );
        },
        child: AnchoredMarkdownBody(
          data: content.isEmpty ? '（无内容）' : content,
          highlightAnchorId: widget.highlightAnchorId,
          onOpenTask: (Task t) => showTaskDetailSheet(context, t),
        ),
      ),
    );
  }
}
