import 'package:flutter/material.dart';

import '../../services/assistant/models.dart';
import '../library/files_page.dart';
import '../messages/messages_page.dart';
import '../notes/notes_page.dart';
import 'attachment_pick_controller.dart';

/// 附件选择器（design-v3 §5.1；2026-11-01 与库页同构改版）：
/// **直接复用**库页三分区（消息/笔记/文件）的多选、筛选器、分类展开——
/// 差异只在多选后的去处：库页底部是多种操作的并集（按选中项状态取可用交集），
/// 本页底部是「已选附件列表 + 确认按钮」。
///
/// 选择状态由 [AttachmentPickController] 持有（跨分区累积、跨笔记下钻不丢），
/// 各分区页（pick 模式）把它当唯一事实源。确认时返回附件引用列表
/// （正文在请求时由 assistant_service 展开）。
class AttachmentPickerPage extends StatefulWidget {
  final List<ChatAttachment> selected;

  const AttachmentPickerPage({super.key, this.selected = const []});

  @override
  State<AttachmentPickerPage> createState() => _AttachmentPickerPageState();
}

class _AttachmentPickerPageState extends State<AttachmentPickerPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  late final AttachmentPickController _pick;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _pick = AttachmentPickController(widget.selected);
  }

  @override
  void dispose() {
    _tab.dispose();
    _pick.dispose();
    super.dispose();
  }

  void _confirm() =>
      Navigator.of(context).pop(_pick.attachments);

  /// 底栏：已选附件列表（chip 可移除）+ 确认按钮。
  Widget _buildSelectionBar(ColorScheme cs) {
    return AnimatedBuilder(
      animation: _pick,
      builder: (context, _) {
        final items = _pick.attachments;
        return SafeArea(
          top: false,
          child: Container(
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              border: Border(
                  top: BorderSide(color: cs.outlineVariant, width: 0.5)),
            ),
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: items.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text('未选择附件',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: cs.onSurfaceVariant)),
                        )
                      : SizedBox(
                          height: 40,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final a in items)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: InputChip(
                                    avatar: Icon(
                                        _pick.iconOf(a.type, a.id),
                                        size: 16),
                                    label: Text(
                                      _pick.titleOf(a.type, a.id),
                                      style: const TextStyle(fontSize: 12),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    visualDensity: VisualDensity.compact,
                                    onDeleted: () =>
                                        _pick.deselect(a.type, a.id),
                                  ),
                                ),
                            ],
                          ),
                        ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _confirm,
                  // F4 §3.3-13：计数变化位次滚动而非硬跳
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: Text('确认（${_pick.length}）',
                        key: ValueKey(_pick.length)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // F4 §3.5-19：返回 = 确认所选（与「确认」按钮同效），消除
    // 「选了半天下滑返回全丢」
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _confirm();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('选择附件'),
          bottom: TabBar(
            controller: _tab,
            tabs: const [Tab(text: '消息'), Tab(text: '笔记'), Tab(text: '文件')],
          ),
        ),
        body: TabBarView(
          controller: _tab,
          children: [
            MessagesPage(pickMode: true, pickController: _pick),
            NotesPage(pickMode: true, pickController: _pick),
            FilesPage(pickMode: true, pickController: _pick),
          ],
        ),
        bottomNavigationBar: _buildSelectionBar(cs),
      ),
    );
  }
}
