import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import '../../models/library_file.dart';
import '../../services/assistant/models.dart';
import '../../services/library_file_service.dart';
import '../../services/notification_bridge.dart';
import '../../services/system_intent.dart';
import '../assistant/attachment_pick_controller.dart';
import '../assistant/send_to_assistant.dart';
import '../messages/message_widgets.dart' show SelectionAction, SelectionActionBar;
import '../notes/notes_page.dart' show promptNameDialog;
import '../shared/back_to_top.dart';
import 'file_thumbnail.dart';
import 'folder_tree.dart';
import '../shared/skeleton_list.dart';

/// 按 mime 给文件分区/附件选择器共用的行首图标（唯一事实源）。
/// mime 缺失（旧数据）时按扩展名兜底推断。
IconData libraryFileIcon(LibraryFile file) {
  final mime = file.mimeType ?? guessMimeFromName(file.name) ?? '';
  if (mime.startsWith('image/')) return Icons.image_outlined;
  if (mime.startsWith('video/')) return Icons.videocam_outlined;
  if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
  if (mime.startsWith('text/') || mime == 'application/json') {
    return Icons.article_outlined;
  }
  if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
  return Icons.insert_drive_file_outlined;
}

/// 文件类型显示名（2026-11-01：类型随列表/卡片副标题展示）：
/// 「PNG 图片」「MP4 视频」「PDF 文档」；无扩展名回退「文件」。
String libraryFileTypeLabel(LibraryFile file) {
  final mime = file.mimeType ?? guessMimeFromName(file.name) ?? '';
  final ext = p.extension(file.name);
  final extLabel =
      ext.length > 1 ? ext.substring(1).toUpperCase() : '';
  final kind = switch (mime) {
    _ when mime.startsWith('image/') => '图片',
    _ when mime.startsWith('video/') => '视频',
    _ when mime.startsWith('audio/') => '音频',
    _ when mime.startsWith('text/') || mime == 'application/json' => '文本',
    'application/pdf' => '文档',
    'application/msword' ||
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document' =>
      '文档',
    'application/vnd.ms-excel' ||
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' =>
      '表格',
    'application/vnd.ms-powerpoint' ||
    'application/vnd.openxmlformats-officedocument.presentationml.presentation' =>
      '演示',
    'application/zip' => '压缩包',
    _ => '',
  };
  if (extLabel.isEmpty) return kind.isEmpty ? '文件' : kind;
  return kind.isEmpty ? extLabel : '$extLabel $kind';
}

/// v3 阶段 3 库·文件区（design-v3 §1.3/§3.1）+ DB v9/v10 树形管理：
/// 当前文件夹面包屑 + 子文件夹列表 + 文件列表；文件夹落在文件的 folder 字段上，
/// 空文件夹由 library_folders 表持久化（v10）。支持新建/重命名/删除
/// （删除 = 文件上移一层，不删文件）、多选移动到文件夹（树形选择器）、
/// 树形总览跳转、列表/卡片两种展示、多选「发送给助理」（草稿附件）；
/// 导入落到当前文件夹。重命名/删除文件沿用原有入口（删除保留引用检查）。
class FilesPage extends StatefulWidget {
  const FilesPage({
    super.key,
    this.onSelectionChanged,
    this.pickMode = false,
    this.pickController,
  });

  /// 多选态变化回调：库页容器用来在多选时隐藏 FAB（与消息分区一致）。
  final ValueChanged<bool>? onSelectionChanged;

  /// 附件选择模式（2026-11-01）：复用本页的多选/文件夹导航，
  /// 选择状态写入 [pickController]（跨分区累积、跨文件夹不丢），
  /// 底部操作条由附件选择页统一提供。
  final bool pickMode;
  final AttachmentPickController? pickController;

  @override
  State<FilesPage> createState() => FilesPageState();
}

class FilesPageState extends State<FilesPage> {
  /// 当前文件夹路径（'' = 根目录）。
  String _folder = '';

  LibraryFolderView _view = const LibraryFolderView(folders: [], files: []);

  bool _loading = true;
  bool _importing = false;

  /// 会话级展示模式（'list' | 'grid'）。
  String _viewMode = 'list';

  bool _selecting = false;
  final Set<String> _selected = {};

  /// 被选中的文件夹本体（当前层直接子文件夹名，2026-11-01）：
  /// 空文件夹没有文件可挂在 [_selected] 里，但「选中空文件夹」本身是
  /// 合法操作（至少可以批量删除它）；非空文件夹被选中时也会登记在这里，
  /// 批量删除时连同文件夹一起删（其文件已随文件删除走）。
  final Set<String> _selectedFolders = {};

  /// 当前层各直接子文件夹（含后代）的文件列表（文件夹整选用，
  /// reload 时一并加载；文件夹数量少，代价可忽略）。
  Map<String, List<LibraryFile>> _subfolderFiles = {};

  @override
  void initState() {
    super.initState();
    // pick 模式：本地 _selected 是控制器（唯一事实源）的镜像
    if (widget.pickMode) {
      widget.pickController?.addListener(_syncFromPick);
      _syncFromPick();
    }
    reload();
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

  /// pick 模式：控制器 → 本地多选态回同步（跨文件夹选择也保留在控制器里）。
  void _syncFromPick() {
    final pick = _pick;
    if (pick == null || !mounted) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(pick.idsOfType(ChatAttachmentType.file));
      if (_selected.isEmpty) _selecting = false;
    });
  }

  Future<void> reload() async {
    final view = await LibraryFileService.instance.listFolder(_folder);
    // 直接子文件夹（含后代）的文件，供文件夹整选/勾选态显示
    final subFiles = <String, List<LibraryFile>>{};
    for (final name in view.folders) {
      subFiles[name] = await LibraryFileService.instance
          .filesUnderFolder(joinFolderPath(_folder, name));
    }
    if (mounted) {
      setState(() {
        _view = view;
        _subfolderFiles = subFiles;
        _loading = false;
        if (!widget.pickMode) {
          // 保留子文件夹整选带入的选择（它们的文件不在本层视图里）
          final keep = <String>{
            ...view.files.map((f) => f.id),
            for (final files in subFiles.values) ...files.map((f) => f.id),
          };
          _selected.removeWhere((id) => !keep.contains(id));
          // 文件夹本体的选择也要随视图对账（改名/删除后可能已不存在）
          _selectedFolders.removeWhere((n) => !view.folders.contains(n));
          if (_selected.isEmpty && _selectedFolders.isEmpty) {
            _selecting = false;
          }
        }
      });
      // pick 模式：为已选条目补充显示名（底栏 chip 用）
      final pick = _pick;
      if (pick != null) {
        final all = [...view.files, for (final fs in subFiles.values) ...fs];
        for (final f in all) {
          if (pick.isSelected(ChatAttachmentType.file, f.id)) {
            pick.registerMeta(
                ChatAttachmentType.file, f.id, f.name, libraryFileIcon(f));
          }
        }
      }
      widget.onSelectionChanged?.call(_selecting);
    }
  }

  Future<void> _enterFolder(String name) async {
    setState(() {
      _folder = joinFolderPath(_folder, name);
      // pick 模式：选择跨文件夹保留（存在控制器里）
      if (!widget.pickMode) _exitSelection(notify: false);
    });
    if (!widget.pickMode) widget.onSelectionChanged?.call(false);
    // 必须重新拉取：否则 _view 仍是上一层数据，空文件夹可无限「进入」
    await reload();
  }

  Future<void> _jumpTo(String path) async {
    setState(() {
      _folder = path;
      if (!widget.pickMode) _exitSelection(notify: false);
    });
    if (!widget.pickMode) widget.onSelectionChanged?.call(false);
    await reload();
  }

  // ---- 文件夹 ----

  Future<void> _createFolder() async {
    final name = await promptNameDialog(context, title: '新建文件夹');
    if (name == null) return;
    if (!isValidFolderName(name)) {
      _toast('文件夹名不能包含 / 或 \\');
      return;
    }
    final path = joinFolderPath(_folder, name);
    if (_view.folders.contains(name)) {
      _toast('已存在同名文件夹');
      return;
    }
    // 空文件夹落库（library_folders 表），离开页面后仍可见
    await LibraryFileService.instance.createFolder(path);
    await reload();
  }

  Future<void> _renameFolder(String name) async {
    final path = joinFolderPath(_folder, name);
    final newName = await promptNameDialog(context,
        title: '重命名文件夹', initialValue: name);
    if (newName == null || newName == name) return;
    try {
      await LibraryFileService.instance.renameFolder(path, newName);
    } on ArgumentError catch (e) {
      _toast('${e.message}');
      return;
    }
    await reload();
  }

  Future<void> _deleteFolder(String name) async {
    final path = joinFolderPath(_folder, name);
    final moved = await LibraryFileService.instance.deleteFolder(path);
    await reload();
    _toast(moved > 0 ? '文件夹已删除，$moved 个文件已移到上级' : '文件夹已删除');
  }

  // ---- 多选 ----

  void _toggleSelect(LibraryFile f) {
    final pick = _pick;
    if (pick != null) {
      // pick 模式：写控制器，本地状态由 _syncFromPick 回同步
      pick.toggle(ChatAttachmentType.file, f.id,
          title: f.name, icon: libraryFileIcon(f));
      setState(() => _selecting = true);
      return;
    }
    setState(() {
      if (!_selected.remove(f.id)) _selected.add(f.id);
      if (_selected.isEmpty && _selectedFolders.isEmpty) _selecting = false;
    });
    widget.onSelectionChanged?.call(_selecting);
  }

  /// 文件长按 / 菜单「选择」：进入多选并选中该文件（2026-11-01）。
  void _startFileSelection(LibraryFile f) {
    if (widget.pickMode) return;
    setState(() {
      _selecting = true;
      _selected.add(f.id);
    });
    widget.onSelectionChanged?.call(true);
  }

  /// 文件夹勾选态（0 无 / 1 部分 / 2 全部）：空文件夹看本体选择
  /// （[_selectedFolders]），非空看其（含后代）文件的选中比例。
  int _folderSelectState(String name) {
    final files = _subfolderFiles[name] ?? const [];
    if (files.isEmpty) return _selectedFolders.contains(name) ? 2 : 0;
    final n = files.where((f) => _selected.contains(f.id)).length;
    if (n == 0) return 0;
    return n == files.length ? 2 : 1;
  }

  /// 文件夹长按 / 菜单「选择」：进入多选并选中该文件夹——
  /// 非空 = 整选其（含后代）全部文件；空 = 选中文件夹本体
  /// （2026-11-01：空文件夹也可选中，至少可随批量删除一起删）。
  void _startFolderSelection(String name) {
    if (widget.pickMode) return;
    final files = _subfolderFiles[name] ?? const [];
    setState(() {
      _selecting = true;
      if (files.isEmpty) {
        _selectedFolders.add(name);
      } else {
        _selected.addAll(files.map((f) => f.id));
      }
    });
    widget.onSelectionChanged?.call(true);
  }

  void _toggleSelectFolder(String name) {
    final files = _subfolderFiles[name] ?? const [];
    // 空文件夹：切换本体选择（pick 模式附件只能是文件，空文件夹不可选）
    if (files.isEmpty) {
      if (_pick != null) return;
      setState(() {
        if (!_selectedFolders.remove(name)) _selectedFolders.add(name);
        if (_selected.isEmpty && _selectedFolders.isEmpty) {
          _selecting = false;
        }
      });
      widget.onSelectionChanged?.call(_selecting);
      return;
    }
    final allSelected = files.every((f) => _selected.contains(f.id));
    final pick = _pick;
    if (pick != null) {
      for (final f in files) {
        final sel = pick.isSelected(ChatAttachmentType.file, f.id);
        if (allSelected ? sel : !sel) {
          pick.toggle(ChatAttachmentType.file, f.id,
              title: f.name, icon: libraryFileIcon(f));
        }
      }
      setState(() {});
      return;
    }
    setState(() {
      if (allSelected) {
        _selected.removeAll(files.map((f) => f.id));
        if (_selected.isEmpty && _selectedFolders.isEmpty) {
          _selecting = false;
        }
      } else {
        _selected.addAll(files.map((f) => f.id));
      }
    });
    widget.onSelectionChanged?.call(_selecting);
  }

  void _exitSelection({bool notify = true}) {
    final pick = _pick;
    if (pick != null) {
      pick.clearType(ChatAttachmentType.file);
      setState(() => _selecting = false);
      return;
    }
    _selecting = false;
    _selected.clear();
    _selectedFolders.clear();
    if (notify) widget.onSelectionChanged?.call(false);
  }

  /// 当前选中的文件实体（本层视图 + 子文件夹整选带入，去重）。
  List<LibraryFile> get _selectedFiles {
    final out = <String, LibraryFile>{
      for (final f in _view.files)
        if (_selected.contains(f.id)) f.id: f,
    };
    for (final files in _subfolderFiles.values) {
      for (final f in files) {
        if (_selected.contains(f.id)) out[f.id] = f;
      }
    }
    return out.values.toList();
  }

  Future<void> _moveSelected() async {
    final targets = _selectedFiles;
    if (targets.isEmpty) return;
    final dest = await _pickMoveTarget();
    if (dest == null || !mounted) return;
    await LibraryFileService.instance
        .moveToFolder([for (final f in targets) f.id], dest);
    setState(() => _exitSelection());
    await reload();
    _toast('已移动 ${targets.length} 个文件到${dest.isEmpty ? '根目录' : '「$dest」'}');
  }

  /// 移动目标选择：树形文件夹选择器（可展开层级），含新建文件夹。
  Future<String?> _pickMoveTarget() async {
    final folders = await LibraryFileService.instance.allFolders();
    if (!mounted) return null;
    final choice = await showFolderTreePicker(
      context,
      title: '移动到',
      folders: folders,
      allowCreate: true,
    );
    if (choice == null || choice != '__new__') return choice;
    // 新建文件夹作为移动目标：建在根目录下，立即成为移动落点
    if (!mounted) return null;
    final name = await promptNameDialog(context, title: '新建文件夹');
    if (name == null) return null;
    if (!isValidFolderName(name)) {
      _toast('文件夹名不能包含 / 或 \\');
      return null;
    }
    return name;
  }

  Future<void> _sendSelectedToAssistant() async {
    final targets = _selectedFiles;
    if (targets.isEmpty) return;
    setState(() => _exitSelection());
    await sendToAssistant(context, [
      for (final f in targets)
        ChatAttachment(type: ChatAttachmentType.file, id: f.id),
    ]);
  }

  /// 批量导出到下载目录（多选菜单，2026-11-01）。
  Future<void> _exportSelected() async {
    final targets = _selectedFiles;
    if (targets.isEmpty) return;
    var ok = 0;
    for (final f in targets) {
      try {
        await SystemIntent.exportToDownloads(f.localPath,
            name: f.name, mime: SystemIntent.mimeOf(f.name));
        ok++;
      } catch (_) {
        // 单个失败不中断批量，最后统一汇报
      }
    }
    if (!mounted) return;
    setState(() => _exitSelection());
    _toast(ok == targets.length
        ? '已导出 $ok 个文件到下载目录'
        : '导出 $ok/${targets.length} 个文件，其余失败');
  }

  /// 批量删除（多选菜单，2026-11-01）：引用检查合并提示，确认后强删。
  /// 选中的文件夹一并删除（空文件夹直接删，非空文件夹解散、文件上移一层）。
  Future<void> _deleteSelected() async {
    final targets = _selectedFiles;
    final folderCount = _selectedFolders.length;
    if (targets.isEmpty && folderCount == 0) return;
    var noteRefs = 0;
    var anchorRefs = 0;
    for (final f in targets) {
      final refs = await LibraryFileService.instance.countReferences(f.id);
      noteRefs += refs.noteCount;
      anchorRefs += refs.anchorCount;
    }
    if (!mounted) return;
    if (noteRefs > 0 || anchorRefs > 0) {
      final parts = <String>[
        if (noteRefs > 0) '$noteRefs 处笔记附件',
        if (anchorRefs > 0) '$anchorRefs 个任务锚点',
      ];
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('文件仍被引用'),
          content: Text('所选 ${targets.length} 个文件中，有被 ${parts.join('、')} '
              '引用的。\n删除后这些引用会失效。仍要删除吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('仍要删除'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    for (final f in targets) {
      await LibraryFileService.instance.delete(f.id, force: true);
    }
    var folderNote = '';
    if (folderCount > 0) {
      var movedUp = 0;
      for (final name in _selectedFolders) {
        movedUp += await LibraryFileService.instance
            .deleteFolder(joinFolderPath(_folder, name));
      }
      folderNote = movedUp > 0
          ? '$folderCount 个文件夹（其中 $movedUp 个文件已上移）'
          : '$folderCount 个文件夹';
    }
    if (!mounted) return;
    setState(() => _exitSelection());
    await reload();
    _toast([
      if (targets.isNotEmpty) '已删除 ${targets.length} 个文件',
      if (folderNote.isNotEmpty) '已删除 $folderNote',
    ].join('；'));
  }

  // ---- 导入（落到当前文件夹） ----

  Future<void> _importFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return; // 用户取消
    final paths = [for (final f in result.files) f.path].nonNulls.toList();
    if (paths.isEmpty) {
      _toast('所选文件没有可读路径，无法导入');
      return;
    }
    await _runImport(paths.length, () async {
      var ok = 0;
      for (final path in paths) {
        final imported = await LibraryFileService.instance
            .importFromPath(path, folder: _folder);
        if (imported != null) ok++;
      }
      return ok;
    });
  }

  Future<void> _importImage() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null) return; // 用户取消
    await _runImport(1, () async {
      final imported = await LibraryFileService.instance.importFromPath(x.path,
          name: x.name, mimeType: x.mimeType, folder: _folder);
      return imported == null ? 0 : 1;
    });
  }

  Future<void> _runImport(int total, Future<int> Function() run) async {
    setState(() => _importing = true);
    try {
      final ok = await run();
      await reload();
      _toast(ok == total ? '已导入 $ok 个文件' : '导入 $ok/$total 个文件，其余读取失败');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// 库页 FAB「导入」入口（ui-structure §4：领域主创建统一 FAB）：
  /// 原 AppBar 溢出菜单的两项导入降为小 sheet（L5）。
  Future<void> importEntry() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('导入文件'),
              onTap: () => Navigator.of(sheetContext).pop('files'),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('导入图片/截图'),
              onTap: () => Navigator.of(sheetContext).pop('image'),
            ),
          ],
        ),
      ),
    );
    if (action == 'files') await _importFiles();
    if (action == 'image') await _importImage();
  }

  // ---- 重命名 / 删除 ----

  Future<void> _rename(LibraryFile file) async {
    final ext = p.extension(file.name);
    final base = ext.isEmpty
        ? file.name
        : file.name.substring(0, file.name.length - ext.length);
    final controller = TextEditingController(text: base);
    final newBase = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名文件'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 1,
          decoration: InputDecoration(
            // 后缀名锁定不可改（类型语义），只做展示
            suffixText: ext.isEmpty ? null : ext,
            helperText: ext.isEmpty ? null : '文件后缀名不可修改',
          ),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (newBase == null || newBase.isEmpty || newBase == base) return;
    await LibraryFileService.instance.rename(file.id, newBase + ext);
    await reload();
  }

  Future<void> _delete(LibraryFile file) async {
    final refs = await LibraryFileService.instance.countReferences(file.id);
    if (!mounted) return;
    if (refs.hasAny) {
      final parts = <String>[
        if (refs.noteCount > 0) '${refs.noteCount} 篇笔记的附件',
        if (refs.anchorCount > 0) '${refs.anchorCount} 个任务锚点',
      ];
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('文件仍被引用'),
          content: Text('「${file.name}」正被 ${parts.join('、')} 引用。\n'
              '删除后这些引用会失效（笔记附件丢失、锚点移除）。仍要删除吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('仍要删除'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await LibraryFileService.instance.delete(file.id, force: true);
    await reload();
  }

  // ---- 打开 / 导出 ----

  Future<void> _open(LibraryFile file) async {
    final ok = await NotificationBridge.instance
        .openDeeplink('file://${file.localPath}');
    if (!ok && mounted) {
      // file:// 在 Android 7+ 基本被系统拒（无 FileProvider），退化为展示路径，
      // 引导用户用「导出到下载目录」后经系统文件管理器打开/分享。
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('无法直接打开'),
          content: Text('系统没有可处理该文件的应用。\n\n'
              '可改用「导出到下载目录」后在文件管理器中打开或分享。\n\n'
              '存储位置：\n${file.localPath}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _export(LibraryFile file) async {
    try {
      final where = await SystemIntent.exportToDownloads(file.localPath,
          name: file.name, mime: SystemIntent.mimeOf(file.name));
      if (mounted) _toast('已导出到 $where');
    } catch (e) {
      if (mounted) _toast('导出失败：$e');
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _showActions(LibraryFile file) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.pickMode)
              ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: const Text('选择'),
                subtitle: const Text('进入多选并选中该文件'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _startFileSelection(file);
                },
              ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('打开'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _open(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('导出到下载目录'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _export(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outlined),
              title: const Text('移动到文件夹'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                final dest = await _pickMoveTarget();
                if (dest == null) return;
                await LibraryFileService.instance.moveToFolder([file.id], dest);
                await reload();
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _rename(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _delete(file);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showFolderActions(String name) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('选择'),
              subtitle: const Text('进入多选并选中其中全部文件'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _startFolderSelection(name);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名文件夹'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _renameFolder(name);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除文件夹'),
              subtitle: const Text('其中的文件会移到上一级，不会被删除'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _deleteFolder(name);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---- UI ----

  static String _formatSize(int? bytes) {
    if (bytes == null) return '大小未知';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  static String _formatTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  /// 面包屑行（分区级首行工具条，ui-structure §4）：
  /// 「文件 / seg / seg」逐级可点跳转，尾端新建文件夹入口。
  Widget _buildBreadcrumb(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final segments = _folder.isEmpty ? const <String>[] : _folder.split('/');
    final style = TextStyle(fontSize: 13, color: cs.onSurfaceVariant);
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _crumb('文件', '', style, cs, isLast: segments.isEmpty),
                for (var i = 0; i < segments.length; i++)
                  _crumb(segments[i], segments.sublist(0, i + 1).join('/'),
                      style, cs,
                      isLast: i == segments.length - 1),
              ],
            ),
          ),
          IconButton(
            tooltip: '文件夹总览',
            icon: const Icon(Icons.account_tree_outlined),
            onPressed: () async {
              final folders =
                  await LibraryFileService.instance.allFolders();
              if (!context.mounted) return;
              showFolderTreeOverview(
                context,
                folders: folders,
                currentFolder: _folder,
                onJump: _jumpTo,
              );
            },
          ),
          IconButton(
            tooltip: _viewMode == 'list' ? '卡片模式' : '列表模式',
            icon: Icon(_viewMode == 'list'
                ? Icons.view_module_outlined
                : Icons.view_list_outlined),
            onPressed: () => setState(
                () => _viewMode = _viewMode == 'list' ? 'grid' : 'list'),
          ),
          IconButton(
            tooltip: '新建文件夹',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: _createFolder,
          ),
          IconButton(
            tooltip: '导入文件',
            icon: const Icon(Icons.upload_file_outlined),
            onPressed: importEntry,
          ),
        ],
      ),
    );
  }

  Widget _crumb(String label, String path, TextStyle style, ColorScheme cs,
      {required bool isLast}) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (path.isNotEmpty || label != '文件')
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Icon(Icons.chevron_right,
                  size: 16, color: cs.onSurfaceVariant),
            ),
          InkWell(
            onTap: isLast ? null : () => _jumpTo(path),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text(label,
                  style: isLast
                      ? style.copyWith(
                          color: cs.onSurface, fontWeight: FontWeight.w600)
                      : style),
            ),
          ),
        ],
      ),
    );
  }

  /// 多选态首行工具条（与消息分区同构）。
  Widget _buildSelectionHeader() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 48,
      color: cs.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: '退出',
            icon: const Icon(Icons.close),
            onPressed: () => setState(_exitSelection),
          ),
          Text('已选 ${_selected.length + _selectedFolders.length} 项'),
          const Spacer(),
          TextButton(
            onPressed: () {
              final pick = _pick;
              if (pick != null) {
                for (final f in _view.files) {
                  pick.select(ChatAttachmentType.file, f.id,
                      title: f.name, icon: libraryFileIcon(f));
                }
                return;
              }
              setState(
                  () => _selected.addAll(_view.files.map((f) => f.id)));
            },
            child: const Text('全选'),
          ),
          TextButton(
            onPressed: _selected.isEmpty && _selectedFolders.isEmpty
                ? null
                : () {
                      final pick = _pick;
                      if (pick != null) {
                        pick.clearType(ChatAttachmentType.file);
                        return;
                      }
                      setState(() {
                        _selected.clear();
                        _selectedFolders.clear();
                      });
                    },
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionBar() {
    final hasFiles = _selected.isNotEmpty;
    final hasSelection = hasFiles || _selectedFolders.isNotEmpty;
    return SelectionActionBar(
      actions: [
        SelectionAction(
          icon: Icons.drive_file_move_outlined,
          tooltip: '移动到文件夹',
          enabled: hasFiles,
          onTap: _moveSelected,
        ),
        SelectionAction(
          icon: Icons.download_outlined,
          tooltip: '导出到下载目录',
          enabled: hasFiles,
          onTap: _exportSelected,
        ),
        SelectionAction(
          icon: Icons.send_outlined,
          tooltip: '发送给助理',
          enabled: hasFiles,
          onTap: _sendSelectedToAssistant,
        ),
        SelectionAction(
          icon: Icons.delete_outline,
          tooltip: '删除',
          enabled: hasSelection,
          onTap: _deleteSelected,
        ),
      ],
    );
  }

  /// 文件夹条目与文件条目同一套版式（2026-11-01）：40px 缩略图位
  /// （文件夹图标代替文件缩略图）+ 名称 + 副标题（文件数）。
  /// 多选/附件选择态：行首变三态勾选（整选含后代全部文件），
  /// 「进入」移到尾端箭头。
  Widget _buildFolderTile(String name) {
    final cs = Theme.of(context).colorScheme;
    final selectable = _selecting || widget.pickMode;
    final state = _folderSelectState(name);
    final count = (_subfolderFiles[name] ?? const []).length;
    return ListTile(
      leading: selectable
          ? Icon(
              switch (state) {
                2 => Icons.check_circle,
                1 => Icons.indeterminate_check_box,
                _ => Icons.radio_button_unchecked,
              },
              color: state == 0 ? cs.outline : cs.primary,
            )
          : const _FolderThumbnail(size: 40),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('$count 个文件'),
      trailing: selectable
          // 多选态：点击行 = 整选，进入文件夹保留为尾端按钮
          ? IconButton(
              tooltip: '进入',
              icon: const Icon(Icons.chevron_right),
              onPressed: () => _enterFolder(name),
            )
          : IconButton(
              tooltip: '更多',
              icon: const Icon(Icons.more_vert),
              onPressed: () => _showFolderActions(name),
            ),
      onTap: () =>
          selectable ? _toggleSelectFolder(name) : _enterFolder(name),
      onLongPress:
          selectable ? null : () => _startFolderSelection(name),
    );
  }

  Widget _buildFileTile(LibraryFile file) {
    final selected = _selected.contains(file.id);
    // pick 模式（附件选择）：点击即选中/取消，无操作菜单、无需先长按进多选
    final pickUI = widget.pickMode;
    return ListTile(
      leading: _selecting || pickUI
          ? Icon(selected
              ? Icons.check_circle
              : Icons.radio_button_unchecked)
          : FileThumbnail(file: file, size: 40),
      title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
          '${libraryFileTypeLabel(file)} · ${_formatSize(file.size)} · ${_formatTime(file.createdAt)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      trailing: _selecting || pickUI
          ? null
          : IconButton(
              tooltip: '更多',
              icon: const Icon(Icons.more_vert),
              onPressed: () => _showActions(file),
            ),
      onTap: () {
        if (_selecting || pickUI) {
          _toggleSelect(file);
        } else {
          _showActions(file);
        }
      },
      onLongPress:
          pickUI ? null : () => _startFileSelection(file),
    );
  }

  /// 卡片模式（grid）：文件夹大卡 + 文件缩略图卡，点击行为与列表一致。
  Widget _buildGrid({ScrollController? scrollController}) {
    final itemCount = _view.folders.length + _view.files.length;
    return GridView.builder(
      controller: scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.82,
      ),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index < _view.folders.length) {
          return _buildFolderCard(_view.folders[index]);
        }
        return _buildFileCard(_view.files[index - _view.folders.length]);
      },
    );
  }

  /// 文件夹卡与文件卡同一套版式：缩略图区（文件夹图标）+ 名称 + 元信息；
  /// 多选态右上角三态勾选，名称旁的箭头进入文件夹。
  Widget _buildFolderCard(String name) {
    final cs = Theme.of(context).colorScheme;
    final selectable = _selecting || widget.pickMode;
    final state = _folderSelectState(name);
    final count = (_subfolderFiles[name] ?? const []).length;
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: cs.surfaceContainerLow,
      shape: state != 0
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: cs.primary, width: 2),
            )
          : null,
      child: InkWell(
        onTap: () =>
            selectable ? _toggleSelectFolder(name) : _enterFolder(name),
        onLongPress:
            selectable ? null : () => _startFolderSelection(name),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const _FolderThumbnail(size: 96, fill: true),
                  if (selectable)
                    Positioned(
                      top: 4,
                      left: 4,
                      child: Icon(
                        switch (state) {
                          2 => Icons.check_circle,
                          1 => Icons.indeterminate_check_box,
                          _ => Icons.radio_button_unchecked,
                        },
                        size: 22,
                        color: state == 0 ? cs.onSurfaceVariant : cs.primary,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5)),
                  ),
                  if (selectable)
                    // 多选态保留进入入口（点击卡片 = 整选）
                    GestureDetector(
                      onTap: () => _enterFolder(name),
                      child: Icon(Icons.chevron_right,
                          size: 16, color: cs.onSurfaceVariant),
                    )
                  else
                    // 非多选态：长按已用于进入多选，菜单入口放名称行尾
                    GestureDetector(
                      onTap: () => _showFolderActions(name),
                      child: Icon(Icons.more_vert,
                          size: 16, color: cs.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: Text('$count 个文件',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileCard(LibraryFile file) {
    final cs = Theme.of(context).colorScheme;
    final selected = _selected.contains(file.id);
    final pickUI = widget.pickMode;
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: cs.surfaceContainerLow,
      shape: selected
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: cs.primary, width: 2),
            )
          : null,
      child: InkWell(
        onTap: () {
          if (_selecting || pickUI) {
            _toggleSelect(file);
          } else {
            _showActions(file);
          }
        },
        onLongPress:
            pickUI ? null : () => _startFileSelection(file),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FileThumbnail(file: file, size: 96, fill: true),
                  if (_selecting || pickUI)
                    Positioned(
                      top: 4,
                      left: 4,
                      child: Icon(
                        selected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        size: 22,
                        color: selected ? cs.primary : cs.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
              child: Text(file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: Text(
                  '${libraryFileTypeLabel(file)} · ${_formatSize(file.size)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // ui-structure §3：分区页不持有 AppBar（由库页容器统一持有）；
    // 原 AppBar 里的导入进度指示降级为内容顶部进度条。
    final itemCount = _view.folders.length + _view.files.length;
    return Scaffold(
      body: Column(
        children: [
          if (_importing) const LinearProgressIndicator(minHeight: 2),
          // 面包屑始终显示；多选工具条独立占一行（2026-11-01：原先多选
          // 会顶掉面包屑，多选期间无法导航/切换视图/导入）
          _buildBreadcrumb(context),
          if (_selecting) ...[
            const Divider(height: 1),
            _buildSelectionHeader(),
          ],
          const Divider(height: 1),
          Expanded(
            child: _loading
                // F4 §3.3-10：骨架屏替代转圈（延迟出现，防闪）
                ? const DeferredSkeletonList(
                    loading: true, child: SizedBox.shrink())
                : itemCount == 0
                    ? Center(
                        child: Text(
                            _folder.isEmpty ? '暂无文件，点右下角 + 导入' : '空文件夹',
                            style: TextStyle(color: cs.onSurfaceVariant)),
                      )
                    : RefreshIndicator(
                        onRefresh: reload,
                        // F3 §3.2-7：滚动 >3 屏后右下角出「回顶」小 FAB
                        child: ScrollableWithBackToTop(
                          scrollableBuilder: (controller) => _viewMode ==
                                  'grid'
                              ? _buildGrid(scrollController: controller)
                              : ListView.builder(
                                  controller: controller,
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  itemCount: itemCount,
                                  itemBuilder: (context, index) {
                                    if (index < _view.folders.length) {
                                      return _buildFolderTile(
                                          _view.folders[index]);
                                    }
                                    return _buildFileTile(_view.files[
                                        index - _view.folders.length]);
                                  },
                                ),
                        ),
                      ),
          ),
          // pick 模式：底部操作条由附件选择页统一提供（已选附件 + 确认）
          if (_selecting && !widget.pickMode) _buildSelectionBar(),
        ],
      ),
    );
  }
}

/// 文件夹「缩略图」（2026-11-01 与文件条目统一版式）：与 [FileThumbnail]
/// 相同的容器尺寸与圆角，内容固定为文件夹图标。
class _FolderThumbnail extends StatelessWidget {
  final double size;
  final bool fill;

  const _FolderThumbnail({this.size = 40, this.fill = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final icon = Icon(Icons.folder_outlined,
        size: fill ? 44 : size * 0.55, color: cs.primary);
    if (fill) {
      return SizedBox.expand(
        child: Container(color: cs.surfaceContainerHigh, child: Center(child: icon)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: size,
        height: size,
        child: Container(
            color: cs.surfaceContainerHigh, child: Center(child: icon)),
      ),
    );
  }
}
