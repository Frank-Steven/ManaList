import 'package:flutter/material.dart';

import '../../services/assistant/models.dart';

/// 附件选择态共享控制器（2026-11-01）：附件选择页与库页三分区
/// （消息/笔记/文件）复用同一套多选交互，选择状态上收到本控制器——
/// 跨分区累积、跨页面导航（笔记：笔记本 → 章节 → 笔记列表）不丢。
///
/// 各分区页在 pick 模式下把本控制器当作唯一事实源：
/// 用户行操作只写控制器，页面本地 _selected 由监听控制器回同步。
class AttachmentPickController extends ChangeNotifier {
  final Map<String, ChatAttachment> _refs = {};
  final Map<String, String> _titles = {};
  final Map<String, IconData> _icons = {};

  AttachmentPickController([List<ChatAttachment> initial = const []]) {
    for (final a in initial) {
      _refs[keyOf(a.type, a.id)] = a;
    }
  }

  static String keyOf(String type, String id) => '$type:$id';

  int get length => _refs.length;

  List<ChatAttachment> get attachments => List.unmodifiable(_refs.values);

  bool isSelected(String type, String id) =>
      _refs.containsKey(keyOf(type, id));

  /// 某类型的全部已选 id（分区页同步本地多选态用）。
  Set<String> idsOfType(String type) => {
        for (final a in _refs.values)
          if (a.type == type) a.id,
      };

  /// 已选条目的显示名（分区页选中时登记；未登记时给类型兜底名）。
  String titleOf(String type, String id) =>
      _titles[keyOf(type, id)] ??
      switch (type) {
        ChatAttachmentType.message => '消息',
        ChatAttachmentType.note => '笔记',
        _ => '文件',
      };

  IconData iconOf(String type, String id) =>
      _icons[keyOf(type, id)] ??
      switch (type) {
        ChatAttachmentType.message => Icons.mail_outline,
        ChatAttachmentType.note => Icons.note_outlined,
        _ => Icons.insert_drive_file_outlined,
      };

  /// 登记显示元数据（页面加载到已选条目时调用，不触发通知）。
  void registerMeta(String type, String id, String title, IconData icon) {
    final key = keyOf(type, id);
    if (!_refs.containsKey(key)) return;
    _titles[key] = title;
    _icons[key] = icon;
  }

  void select(String type, String id, {String? title, IconData? icon}) {
    final key = keyOf(type, id);
    final isNew = !_refs.containsKey(key);
    _refs[key] = ChatAttachment(type: type, id: id);
    if (title != null) _titles[key] = title;
    if (icon != null) _icons[key] = icon;
    if (isNew) notifyListeners();
  }

  void deselect(String type, String id) {
    if (_refs.remove(keyOf(type, id)) != null) notifyListeners();
  }

  void toggle(String type, String id, {String? title, IconData? icon}) {
    if (isSelected(type, id)) {
      deselect(type, id);
    } else {
      select(type, id, title: title, icon: icon);
    }
  }

  /// 清空某类型的全部选择（分区页「取消/退出多选」）。
  void clearType(String type) {
    final keys = [
      for (final a in _refs.values)
        if (a.type == type) keyOf(a.type, a.id),
    ];
    if (keys.isEmpty) return;
    for (final k in keys) {
      _refs.remove(k);
    }
    notifyListeners();
  }
}
