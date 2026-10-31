import 'package:flutter/material.dart';

import '../../models/library_file.dart';
import '../../services/assistant/models.dart';
import '../../services/database.dart';
import '../library/files_page.dart' show libraryFileIcon;

/// 附件选择器（design-v3 §5.1）：从库中多选消息/笔记/文件，
/// 返回附件引用列表（正文在请求时由 assistant_service 展开）。
///
/// 与库页同构：TabBar 三分区「消息 / 笔记 / 文件」（顺序与库页一致），
/// 行样式对齐各分区（消息=标题+来源应用、笔记=标题+笔记本/章节、
/// 文件=mime 图标+大小/时间/所在文件夹），点行切换勾选（同分区多选态）。
/// 不直接复用分区页组件：分区页自持数据加载与导航状态，选择语义（引用而非
/// 打开详情）也不同；此处只复用视觉与交互约定。
class AttachmentPickerPage extends StatefulWidget {
  final List<ChatAttachment> selected;

  const AttachmentPickerPage({super.key, this.selected = const []});

  @override
  State<AttachmentPickerPage> createState() => _AttachmentPickerPageState();
}

class _PickerItem {
  final ChatAttachment ref;
  final String title;
  final String subtitle;
  final IconData icon;
  const _PickerItem(this.ref, this.title, this.subtitle, this.icon);
}

class _AttachmentPickerPageState extends State<AttachmentPickerPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  late final Map<String, ChatAttachment> _selected = {
    for (final a in widget.selected) '${a.type}:${a.id}': a,
  };

  List<_PickerItem> _messages = [];
  List<_PickerItem> _notes = [];
  List<_PickerItem> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  static String _formatTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  static String _formatSize(int? bytes) {
    if (bytes == null) return '大小未知';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Future<void> _load() async {
    final db = AppDatabase.instance;
    final messages = [
      for (final m in await db.getMessages(limit: 200))
        _PickerItem(
          ChatAttachment(type: ChatAttachmentType.message, id: m.id),
          m.title,
          '${m.appName ?? m.packageName} · ${_formatTime(m.postedAt)}',
          Icons.mail_outline,
        ),
    ];
    final notes = <_PickerItem>[];
    for (final nb in await db.getNotebooks()) {
      for (final ch in await db.getChapters(nb.id)) {
        for (final n in await db.getNotes(ch.id)) {
          notes.add(_PickerItem(
            ChatAttachment(type: ChatAttachmentType.note, id: n.id),
            n.title,
            '${nb.name} / ${ch.name}',
            Icons.note_outlined,
          ));
        }
      }
    }
    String fileSubtitle(LibraryFile f) => [
          _formatSize(f.size),
          _formatTime(f.createdAt),
          if (f.folder.isNotEmpty) f.folder,
        ].join(' · ');
    final files = [
      for (final f in await db.getFiles())
        _PickerItem(
          ChatAttachment(type: ChatAttachmentType.file, id: f.id),
          f.name,
          fileSubtitle(f),
          libraryFileIcon(f),
        ),
    ];
    if (mounted) {
      setState(() {
        _messages = messages;
        _notes = notes;
        _files = files;
        _loading = false;
      });
    }
  }

  Widget _buildList(List<_PickerItem> items, String emptyHint) {
    final cs = Theme.of(context).colorScheme;
    if (items.isEmpty) {
      return Center(
          child: Text(emptyHint, style: TextStyle(color: cs.onSurfaceVariant)));
    }
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (_, i) {
        final item = items[i];
        final key = '${item.ref.type}:${item.ref.id}';
        final selected = _selected.containsKey(key);
        return ListTile(
          leading: Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked),
          title:
              Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(item.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
          trailing: Icon(item.icon, size: 18, color: cs.onSurfaceVariant),
          onTap: () => setState(() =>
              selected ? _selected.remove(key) : _selected[key] = item.ref),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('选择附件（已选 ${_selected.length}）'),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_selected.values.toList()),
            child: const Text('完成'),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: const [Tab(text: '消息'), Tab(text: '笔记'), Tab(text: '文件')],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tab,
              children: [
                _buildList(_messages, '库里还没有消息'),
                _buildList(_notes, '库里还没有笔记'),
                _buildList(_files, '库里还没有文件'),
              ],
            ),
    );
  }
}
