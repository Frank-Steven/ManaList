import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/library_file.dart';
import '../../services/assistant/models.dart';
import '../../services/library_file_service.dart';
import '../../services/notification_bridge.dart';
import '../../services/system_intent.dart';
import '../assistant/send_to_assistant.dart';
import '../messages/message_widgets.dart' show SelectionAction, SelectionActionBar;
import '../notes/notes_page.dart' show promptNameDialog;

/// 按 mime 给文件分区/附件选择器共用的行首图标（唯一事实源）。
IconData libraryFileIcon(LibraryFile file) {
  final mime = file.mimeType ?? '';
  if (mime.startsWith('image/')) return Icons.image_outlined;
  if (mime.startsWith('video/')) return Icons.videocam_outlined;
  if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
  if (mime.startsWith('text/') || mime == 'application/json') {
    return Icons.article_outlined;
  }
  if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
  return Icons.insert_drive_file_outlined;
}

/// v3 阶段 3 库·文件区（design-v3 §1.3/§3.1）+ DB v9 树形管理：
/// 当前文件夹面包屑 + 子文件夹列表 + 文件列表；文件夹是虚拟的（落在文件
/// folder 字段上），支持新建/重命名/删除（删除 = 文件上移一层，不删文件）、
/// 多选移动到文件夹、多选「发送给助理」（草稿附件）；导入落到当前文件夹。
/// 重命名/删除文件沿用原有入口（删除保留引用检查）。
class FilesPage extends StatefulWidget {
  const FilesPage({super.key, this.onSelectionChanged});

  /// 多选态变化回调：库页容器用来在多选时隐藏 FAB（与消息分区一致）。
  final ValueChanged<bool>? onSelectionChanged;

  @override
  State<FilesPage> createState() => FilesPageState();
}

class FilesPageState extends State<FilesPage> {
  /// 当前文件夹路径（'' = 根目录）。
  String _folder = '';

  LibraryFolderView _view = const LibraryFolderView(folders: [], files: []);

  /// 会话内新建但还没有文件的虚拟文件夹（有文件落入后即由 DB 派生，可移除）。
  final Set<String> _virtualFolders = {};

  bool _loading = true;
  bool _importing = false;

  bool _selecting = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final view = await LibraryFileService.instance
        .listFolder(_folder, extraFolders: _virtualFolders);
    if (mounted) {
      setState(() {
        _view = view;
        _loading = false;
        _selected.removeWhere((id) => !view.files.any((f) => f.id == id));
        if (_selected.isEmpty) _selecting = false;
      });
      widget.onSelectionChanged?.call(_selecting);
    }
  }

  void _enterFolder(String name) {
    setState(() {
      _folder = joinFolderPath(_folder, name);
      _exitSelection(notify: false);
    });
    widget.onSelectionChanged?.call(false);
  }

  void _jumpTo(String path) {
    setState(() {
      _folder = path;
      _exitSelection(notify: false);
    });
    widget.onSelectionChanged?.call(false);
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
    setState(() => _virtualFolders.add(path));
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
    // 会话内虚拟文件夹跟随换前缀
    final newPath = joinFolderPath(_folder, newName);
    final remapped = <String>{};
    for (final v in _virtualFolders) {
      remapped.add(folderIsUnder(v, path) ? '$newPath${v.substring(path.length)}' : v);
    }
    _virtualFolders
      ..clear()
      ..addAll(remapped);
    await reload();
  }

  Future<void> _deleteFolder(String name) async {
    final path = joinFolderPath(_folder, name);
    final moved = await LibraryFileService.instance.deleteFolder(path);
    _virtualFolders.removeWhere((v) => folderIsUnder(v, path));
    await reload();
    _toast(moved > 0 ? '文件夹已删除，$moved 个文件已移到上级' : '文件夹已删除');
  }

  // ---- 多选 ----

  void _toggleSelect(LibraryFile f) {
    setState(() {
      if (!_selected.remove(f.id)) _selected.add(f.id);
      if (_selected.isEmpty) _selecting = false;
    });
    widget.onSelectionChanged?.call(_selecting);
  }

  void _exitSelection({bool notify = true}) {
    _selecting = false;
    _selected.clear();
    if (notify) widget.onSelectionChanged?.call(false);
  }

  List<LibraryFile> get _selectedFiles =>
      _view.files.where((f) => _selected.contains(f.id)).toList();

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

  /// 移动目标选择（L5 小型 sheet）：根目录 + 全部文件夹 + 新建文件夹。
  Future<String?> _pickMoveTarget() async {
    final folders = await LibraryFileService.instance
        .allFolders(extraFolders: _virtualFolders);
    if (!mounted) return null;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('移动到',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    leading: const Icon(Icons.home_outlined),
                    title: const Text('根目录'),
                    onTap: () => Navigator.of(sheetContext).pop(''),
                  ),
                  for (final f in folders)
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title:
                          Text(f, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.of(sheetContext).pop(f),
                    ),
                  ListTile(
                    leading: const Icon(Icons.create_new_folder_outlined),
                    title: const Text('新建文件夹…'),
                    onTap: () => Navigator.of(sheetContext).pop('__new__'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (choice == null || choice != '__new__') return choice;
    // 新建文件夹作为移动目标：建在根目录下，立即成为移动落点（不算空虚拟文件夹）
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
    final name = await promptNameDialog(context,
        title: '重命名文件', initialValue: file.name);
    if (name == null || name == file.name) return;
    await LibraryFileService.instance.rename(file.id, name);
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

  IconData _iconFor(LibraryFile file) => libraryFileIcon(file);

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
            tooltip: '新建文件夹',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: _createFolder,
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
          Text('已选 ${_selected.length} 项'),
          const Spacer(),
          TextButton(
            onPressed: () =>
                setState(() => _selected.addAll(_view.files.map((f) => f.id))),
            child: const Text('全选'),
          ),
          TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () => setState(() => _selected.clear()),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionBar() {
    final hasSelection = _selected.isNotEmpty;
    return SelectionActionBar(
      actions: [
        SelectionAction(
          icon: Icons.drive_file_move_outlined,
          tooltip: '移动到文件夹',
          enabled: hasSelection,
          onTap: _moveSelected,
        ),
        SelectionAction(
          icon: Icons.send_outlined,
          tooltip: '发送给助理',
          enabled: hasSelection,
          onTap: _sendSelectedToAssistant,
        ),
      ],
    );
  }

  Widget _buildFolderTile(String name) {
    return ListTile(
      leading: const Icon(Icons.folder_outlined),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.more_vert),
      onTap: () => _enterFolder(name),
      onLongPress: () => _showFolderActions(name),
    );
  }

  Widget _buildFileTile(LibraryFile file) {
    final selected = _selected.contains(file.id);
    return ListTile(
      leading: _selecting
          ? Icon(selected
              ? Icons.check_circle
              : Icons.radio_button_unchecked)
          : Icon(_iconFor(file)),
      title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
          '${_formatSize(file.size)} · ${_formatTime(file.createdAt)}'),
      trailing: _selecting ? null : const Icon(Icons.more_vert),
      onTap: () {
        if (_selecting) {
          _toggleSelect(file);
        } else {
          _showActions(file);
        }
      },
      onLongPress: () {
        if (!_selecting) {
          setState(() {
            _selecting = true;
            _selected.add(file.id);
          });
          widget.onSelectionChanged?.call(true);
        }
      },
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
          if (_selecting) _buildSelectionHeader() else _buildBreadcrumb(context),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : itemCount == 0
                    ? Center(
                        child: Text(
                            _folder.isEmpty ? '暂无文件，点右下角 + 导入' : '空文件夹',
                            style: TextStyle(color: cs.onSurfaceVariant)),
                      )
                    : RefreshIndicator(
                        onRefresh: reload,
                        child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: itemCount,
                          itemBuilder: (context, index) {
                            if (index < _view.folders.length) {
                              return _buildFolderTile(_view.folders[index]);
                            }
                            return _buildFileTile(
                                _view.files[index - _view.folders.length]);
                          },
                        ),
                      ),
          ),
          if (_selecting) _buildSelectionBar(),
        ],
      ),
    );
  }
}
