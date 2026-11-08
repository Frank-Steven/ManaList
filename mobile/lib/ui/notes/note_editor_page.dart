import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../models/note.dart';
import '../../services/database.dart';
import '../../services/library_file_service.dart';
import '../../services/system_intent.dart';
import '../shared/anchored_markdown.dart';

/// 笔记编辑器（设计 §4）：标题 + 正文，退出自动保存，无保存按钮。
///
/// - 双模式：编辑态 = 纯文本 TextField；预览态 = [AnchoredMarkdownBody]
///   （markdown 笔记）。plain 笔记预览维持纯文本渲染。
/// - 附件：插入图片/文件 → 入 files 表 → 正文插入 `![name](file://id)`；
///   plain 笔记插图前弹一次性「转为 Markdown」确认（纯文本是 markdown
///   合法子集，无损）。
/// - v12（anchors-v2.md §3）：正文不再写入锚点 marker，编辑态高亮与
///   「添加任务锚点」入口废弃；任务关联改为章节级「关联任务」区
///   （NotesListPage），正文完全归作者。
///
/// - [existing] 非空 = 编辑已有笔记；否则按 [chapterId] 新建（content_format
///   默认 markdown）。
/// - 标题留空时取正文首个非空行的前 20 字作标题；标题、正文均为空则不保存。
/// - pop 返回值：新建且实际入库时为新建的 [Note]，其余情况为 null
///   （由调用方负责撤销注册）。
class NoteEditorPage extends StatefulWidget {
  final Note? existing;
  final String? chapterId;

  const NoteEditorPage({
    super.key,
    this.existing,
    this.chapterId,
  });

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  late final TextEditingController _titleController;
  late final TextEditingController _contentController;

  /// 笔记格式（'markdown' / 'plain'）；新建默认 markdown。
  late String _contentFormat =
      widget.existing?.contentFormat ?? 'markdown';

  /// 附件文件 id（引用 files.id），保存时随笔记落库。
  late List<String> _attachments =
      List<String>.of(widget.existing?.attachments ?? const []);

  /// false=编辑态 true=预览态。
  bool _preview = false;

  bool _allowPop = false;
  bool _exiting = false;
  Future<void>? _saveFuture;
  Note? _inserted;

  /// 库内当前状态快照（初始 = [NoteEditorPage.existing]，每次成功落库
  /// 后更新）——保存时与快照比较，避免冗余写库。
  late Note? _persistedNote = widget.existing;

  bool get _isMarkdown => _contentFormat == 'markdown';

  @override
  void initState() {
    super.initState();
    _titleController =
        TextEditingController(text: widget.existing?.title ?? '');
    _contentController =
        TextEditingController(text: widget.existing?.content ?? '');
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

  /// plain 笔记插图前的一次性「转为 Markdown」确认（details §1.3）。
  /// 已是 markdown 直接返回 true；用户取消返回 false。
  Future<bool> _ensureMarkdown() async {
    if (_isMarkdown) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('转为 Markdown'),
        content: const Text('图片需要 Markdown 渲染。纯文本是 Markdown 的合法子集，'
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
            if (!_preview)
              IconButton(
                tooltip: '插入图片/文件',
                onPressed: _insertAttachment,
                icon: const Icon(Icons.attach_file, size: 20),
              ),
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

  /// 预览态：markdown 笔记走统一渲染管线（SelectionArea 提供系统选择/复制）；
  /// plain 笔记维持纯文本渲染。
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
        child: AnchoredMarkdownBody(
          data: content.isEmpty ? '（无内容）' : content,
        ),
      ),
    );
  }
}
