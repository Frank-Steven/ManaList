import 'package:flutter/material.dart';

/// 文件夹树（2026-11-01，库·文件区树形总览 / 树形移动选择器共用）：
/// 由排序后的完整路径列表（'a/b/c' 形式）构建嵌套节点。
class FolderTreeNode {
  final String name;

  /// 完整路径（'' 只用于伪根，不作为可选节点出现）。
  final String path;
  final List<FolderTreeNode> children;

  FolderTreeNode({required this.name, required this.path})
      : children = [];
}

/// 路径列表 → 根节点的子树（根目录本身不在返回值里，由调用方单独加）。
List<FolderTreeNode> buildFolderTree(List<String> paths) {
  final roots = <FolderTreeNode>[];
  final byPath = <String, FolderTreeNode>{};
  for (final p in paths) {
    if (p.isEmpty) continue;
    final segments = p.split('/');
    var prefix = '';
    List<FolderTreeNode> level = roots;
    for (final seg in segments) {
      prefix = prefix.isEmpty ? seg : '$prefix/$seg';
      var node = byPath[prefix];
      if (node == null) {
        node = FolderTreeNode(name: seg, path: prefix);
        byPath[prefix] = node;
        level.add(node);
      }
      level = node.children;
    }
  }
  return roots;
}

/// 树形文件夹选择 sheet：返回选中的文件夹路径（'' = 根目录），
/// 取消返回 null。[allowCreate] 为 true 时末尾带「新建文件夹…」，
/// 选中它返回 [createSentinel]（调用方弹命名框后再处理）。
Future<String?> showFolderTreePicker(
  BuildContext context, {
  required String title,
  required List<String> folders,
  bool allowCreate = false,
  String createSentinel = '__new__',
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: _FolderTreeSheet(
        title: title,
        folders: folders,
        allowCreate: allowCreate,
        createSentinel: createSentinel,
        onSelect: (path) => Navigator.of(sheetContext).pop(path),
      ),
    ),
  );
}

/// 树形总览 sheet：整棵树可展开/收起，点击跳转到目标文件夹。
Future<void> showFolderTreeOverview(
  BuildContext context, {
  required List<String> folders,
  required String currentFolder,
  required ValueChanged<String> onJump,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: _FolderTreeSheet(
        title: '文件夹总览',
        folders: folders,
        currentFolder: currentFolder,
        allowCreate: false,
        onSelect: (path) {
          Navigator.of(sheetContext).pop();
          onJump(path);
        },
      ),
    ),
  );
}

class _FolderTreeSheet extends StatefulWidget {
  final String title;
  final List<String> folders;
  final String? currentFolder;
  final bool allowCreate;
  final String createSentinel;
  final ValueChanged<String> onSelect;

  const _FolderTreeSheet({
    required this.title,
    required this.folders,
    this.currentFolder,
    required this.allowCreate,
    this.createSentinel = '__new__',
    required this.onSelect,
  });

  @override
  State<_FolderTreeSheet> createState() => _FolderTreeSheetState();
}

class _FolderTreeSheetState extends State<_FolderTreeSheet> {
  late final List<FolderTreeNode> _roots = buildFolderTree(widget.folders);

  /// 展开的节点路径（缺省展开第一层）。
  late final Set<String> _expanded = {for (final r in _roots) r.path};

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rows = <Widget>[
      _row(
        depth: 0,
        icon: Icons.home_outlined,
        label: '根目录',
        current: widget.currentFolder == '',
        onTap: () => widget.onSelect(''),
      ),
      for (final n in _roots) ..._nodeRows(n, 0, cs),
    ];
    return ConstrainedBox(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(widget.title,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                ...rows,
                if (widget.allowCreate)
                  _row(
                    depth: 0,
                    icon: Icons.create_new_folder_outlined,
                    label: '新建文件夹…',
                    onTap: () => widget.onSelect(widget.createSentinel),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 节点自身一行 + 展开时递归子节点行。
  List<Widget> _nodeRows(FolderTreeNode node, int depth, ColorScheme cs) {
    final hasChildren = node.children.isNotEmpty;
    final expanded = _expanded.contains(node.path);
    return [
      _row(
        depth: depth + 1,
        icon: Icons.folder_outlined,
        label: node.name,
        current: widget.currentFolder == node.path,
        expandable: hasChildren,
        expanded: expanded,
        onExpand: () => setState(() {
          if (!_expanded.remove(node.path)) _expanded.add(node.path);
        }),
        onTap: () => widget.onSelect(node.path),
      ),
      if (expanded)
        for (final c in node.children) ..._nodeRows(c, depth + 1, cs),
    ];
  }

  Widget _row({
    required int depth,
    required IconData icon,
    required String label,
    bool current = false,
    bool expandable = false,
    bool expanded = false,
    VoidCallback? onExpand,
    VoidCallback? onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.only(left: 12.0 + depth * 18, right: 4),
        child: Row(
          children: [
            Icon(icon,
                size: 20,
                color: current ? cs.primary : cs.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: current ? cs.primary : null,
                    fontWeight: current ? FontWeight.w600 : null,
                  ),
                ),
              ),
            ),
            if (expandable)
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: cs.onSurfaceVariant),
                onPressed: onExpand,
              ),
          ],
        ),
      ),
    );
  }
}
