import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../models/message.dart';
import '../services/attachment_store.dart';
import '../services/database.dart';

/// 手动添加消息：附件只存访问方式（本地路径 / content URI / 链接 / 小程序路径），
/// 不复制文件内容。
class AddMessagePage extends StatefulWidget {
  const AddMessagePage({super.key});

  @override
  State<AddMessagePage> createState() => _AddMessagePageState();
}

class _AddMessagePageState extends State<AddMessagePage> {
  static const _uuid = Uuid();

  final _titleController = TextEditingController();
  final _bodyController = TextEditingController();
  final List<Attachment> _attachments = [];
  bool _saving = false;

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null) return;
    if (!mounted) return; // P3-5：await 之后页面可能已销毁
    // P3-2：image_picker 给的是缓存路径，必须复制进应用私有目录
    final stored = await AttachmentStore.instance.importPath(
      x.path,
      kind: Attachment.kindImage,
      label: x.name,
      mimeType: x.mimeType,
    );
    if (!mounted) return;
    if (stored == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('图片读取失败，未添加')));
      return;
    }
    setState(() => _attachments.add(stored));
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles();
    final f = result?.files.firstOrNull;
    if (f == null) return;
    if (!mounted) return; // P3-5：await 之后页面可能已销毁
    // P3-2：同样复制进仓库；没有本地路径（纯 content://）时退化为只记访问方式
    final stored = f.path == null
        ? null
        : await AttachmentStore.instance.importPath(f.path!,
            kind: Attachment.kindFile,
            label: f.name,
          );
    if (!mounted) return;
    setState(() {
      _attachments.add(stored ??
          Attachment(
            id: _uuid.v4(),
            kind: Attachment.kindFile,
            label: f.name,
            access: AttachmentAccess(
              type: AttachmentAccess.typeContentUri,
              value: f.path ?? '',
            ),
          ));
    });
  }

  Future<void> _addLink() async {
    final value = await _promptForText(
      title: '添加链接',
      label: 'https://…',
      hint: '粘贴网页链接',
    );
    if (value == null || value.isEmpty) return;
    if (!mounted) return; // P3-5：await 之后页面可能已销毁
    setState(() {
      _attachments.add(Attachment(
        id: _uuid.v4(),
        kind: Attachment.kindLink,
        access: AttachmentAccess(
            type: AttachmentAccess.typeUrl, value: value),
      ));
    });
  }

  Future<void> _addMiniprogram() async {
    final value = await _promptForText(
      title: '添加小程序路径',
      label: 'pages/detail?id=…',
      hint: '小程序页面路径',
    );
    if (value == null || value.isEmpty) return;
    if (!mounted) return; // P3-5：await 之后页面可能已销毁
    setState(() {
      _attachments.add(Attachment(
        id: _uuid.v4(),
        kind: Attachment.kindMiniprogram,
        access: AttachmentAccess(
            type: AttachmentAccess.typeMiniprogramPath, value: value),
      ));
    });
  }

  Future<String?> _promptForText(
      {required String title, required String label, String? hint}) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label, hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    final body = _bodyController.text.trim();
    if (title.isEmpty && body.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('请填写标题或内容'),
            duration: Duration(seconds: 2)));
      return;
    }
    setState(() => _saving = true);
    final postedAt = DateTime.now().millisecondsSinceEpoch;
    await AppDatabase.instance.insertMessageIfNew(Message(
      id: _uuid.v4(),
      packageName: 'manual',
      appName: '手动添加',
      title: title,
      body: body,
      postedAt: postedAt,
      captureType: 'manual',
      attachments: List.of(_attachments),
      contentHash: computeContentHash('manual', title, body, postedAt),
      status: MessageStatus.pending,
      priority: MessagePriority.none,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('手动添加'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: '标题',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _bodyController,
            minLines: 4,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: '内容',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Text('附件（只记录访问方式）',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.image_outlined, size: 18),
                label: const Text('图片'),
                onPressed: _pickImage,
              ),
              ActionChip(
                avatar: const Icon(Icons.insert_drive_file_outlined, size: 18),
                label: const Text('文件'),
                onPressed: _pickFile,
              ),
              ActionChip(
                avatar: const Icon(Icons.link, size: 18),
                label: const Text('链接'),
                onPressed: _addLink,
              ),
              ActionChip(
                avatar: const Icon(Icons.apps_outlined, size: 18),
                label: const Text('小程序'),
                onPressed: _addMiniprogram,
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < _attachments.length; i++)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.attachment),
              title: Text(_attachments[i].label ?? _attachments[i].kind),
              subtitle: Text(
                '${_attachments[i].access.type}: ${_attachments[i].access.value}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _attachments.removeAt(i)),
              ),
            ),
        ],
      ),
    );
  }
}
