import 'package:flutter/material.dart';

import '../../../services/assistant/models.dart';
import 'attachment_cards.dart';

/// `/` 快捷指令集（assistant-v4-ui §3.6）：指令名 → 提示词模板。
/// 固定集，不做自定义命令编辑器；模板插入输入框后可继续编辑。
const kSlashCommands = <String, String>{
  '整理收件箱': '帮我整理收件箱：评估未处理消息，垃圾标记优先级，重要的草拟任务。',
  '总结': '总结我附上的内容，给出要点列表。',
  '建任务': '根据以下内容建任务（一个意图拆成多个原子任务）：',
  '翻译': '把以下内容翻译成中文：',
};

/// 输入以 `/` 开头时返回匹配的指令名列表（纯函数，便于单测）；
/// 非 `/` 开头或无匹配返回空表（面板隐藏）。
List<String> matchingSlashCommands(String input) {
  if (!input.startsWith('/')) return const [];
  final prefix = input.substring(1);
  return kSlashCommands.keys
      .where((name) => name.startsWith(prefix))
      .toList(growable: false);
}

/// 对话页输入区（assistant-v4-ui §3.6 组件拆分决策）：
/// 附件条（含草稿 chip 移除）+ `/` 指令面板 + 输入胶囊 + 发送/停止键。
///
/// 令牌：胶囊圆角 22 / surfaceContainerHigh 底 + outlineVariant 描边；
/// 发送键回合中同位置变红色停止键（避免布局跳动）。
class ChatInputBar extends StatefulWidget {
  final TextEditingController controller;
  final bool busy;

  /// 草稿附件（附件条）；空表不渲染附件条。
  final List<ChatAttachment> attachments;
  final AttachmentMeta? Function(ChatAttachment attachment) metaOf;
  final ValueChanged<ChatAttachment> onRemoveAttachment;

  final VoidCallback onAddAttachments;
  final VoidCallback onPickScreenshots;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  /// 草稿附件的 token 估算合计（预算条，§3.6）；null 不渲染预算条。
  final int? attachmentTokens;

  /// 模型上下文上限（token）；无数据时按 32k。
  final int tokenLimit;

  const ChatInputBar({
    super.key,
    required this.controller,
    required this.busy,
    required this.attachments,
    required this.metaOf,
    required this.onRemoveAttachment,
    required this.onAddAttachments,
    required this.onPickScreenshots,
    required this.onSend,
    required this.onCancel,
    this.attachmentTokens,
    this.tokenLimit = kDefaultContextTokenLimit,
  });

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(ChatInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  void _applySlashCommand(String name) {
    widget.controller.text = kSlashCommands[name]!;
    widget.controller.selection = TextSelection.collapsed(
        offset: widget.controller.text.length);
  }

  Widget _buildSlashPanel(ColorScheme cs) {
    final matches = matchingSlashCommands(widget.controller.text);
    if (matches.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final name in matches)
            ListTile(
              dense: true,
              leading: Icon(Icons.bolt, size: 16, color: cs.primary),
              title: Text('/$name', style: const TextStyle(fontSize: 13)),
              subtitle: Text(kSlashCommands[name]!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              onTap: () => _applySlashCommand(name),
            ),
        ],
      ),
    );
  }

  Widget _buildAttachmentBar(ColorScheme cs) {
    return Container(
      height: 44,
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final a in widget.attachments)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: InputChip(
                      avatar: Icon(
                          widget.metaOf(a)?.icon ?? Icons.attach_file,
                          size: 16),
                      label: Text(
                          widget.metaOf(a)?.title ?? a.id,
                          style: const TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(color: cs.outlineVariant),
                      onDeleted: () => widget.onRemoveAttachment(a),
                    ),
                  ),
              ],
            ),
          ),
          if (widget.attachmentTokens != null) _buildBudgetBar(cs),
        ],
      ),
    );
  }

  /// 预算条（§3.6）：48 宽细条 + 百分比；≤80% 灰、>80% amber、
  /// >100% 红且发送键禁用。
  Widget _buildBudgetBar(ColorScheme cs) {
    final used = widget.attachmentTokens!;
    final level = budgetLevel(used, widget.tokenLimit);
    final pct = widget.tokenLimit > 0
        ? (used / widget.tokenLimit * 100).clamp(0, 999).round()
        : 0;
    final color = switch (level) {
      BudgetLevel.normal => cs.onSurfaceVariant,
      BudgetLevel.warning => Colors.amber.shade800,
      BudgetLevel.over => cs.error,
    };
    return Tooltip(
      message: level == BudgetLevel.over
          ? '附件超出模型上下文，请移除部分附件'
          : '附件约占上下文 $pct%（≈$used / ${widget.tokenLimit} tokens）',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 48,
              child: LinearProgressIndicator(
                value: widget.tokenLimit > 0
                    ? (used / widget.tokenLimit).clamp(0.0, 1.0)
                    : 0,
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
                color: color,
                backgroundColor: cs.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 2),
            Text('$pct%',
                style: TextStyle(
                    fontSize: 10, color: color, fontFeatures: const [])),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildSlashPanel(cs),
            if (widget.attachments.isNotEmpty) _buildAttachmentBar(cs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: cs.outlineVariant),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        IconButton(
                          tooltip: '添加附件（笔记/消息/文件）',
                          visualDensity: VisualDensity.compact,
                          icon: Icon(Icons.attach_file,
                              size: 20, color: cs.onSurfaceVariant),
                          onPressed:
                              widget.busy ? null : widget.onAddAttachments,
                        ),
                        IconButton(
                          tooltip: '从相册选截图',
                          visualDensity: VisualDensity.compact,
                          icon: Icon(Icons.photo_library_outlined,
                              size: 20, color: cs.onSurfaceVariant),
                          onPressed:
                              widget.busy ? null : widget.onPickScreenshots,
                        ),
                        Expanded(
                          child: TextField(
                            controller: widget.controller,
                            minLines: 1,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              hintText: '和助理说点什么，或输入 / 快捷指令…',
                              isDense: true,
                              border: InputBorder.none,
                              contentPadding:
                                  EdgeInsets.symmetric(vertical: 10),
                            ),
                            onSubmitted: (_) => widget.onSend(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 回合中发送键变停止键（同一位置，避免布局跳动）；
                // 附件超预算时发送禁用并提示（§3.6 预算规则拦截）
                _buildSendButton(cs),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSendButton(ColorScheme cs) {
    final overBudget = !widget.busy &&
        budgetLevel(widget.attachmentTokens ?? 0, widget.tokenLimit) ==
            BudgetLevel.over;
    return IconButton.filled(
      tooltip: widget.busy
          ? '取消'
          : overBudget
              ? '附件超出模型上下文，请移除部分附件'
              : '发送',
      style: IconButton.styleFrom(
        backgroundColor: widget.busy ? cs.error : cs.primary,
        foregroundColor: widget.busy ? cs.onError : cs.onPrimary,
      ),
      icon: Icon(widget.busy ? Icons.stop : Icons.send, size: 20),
      onPressed:
          widget.busy ? widget.onCancel : (overBudget ? null : widget.onSend),
    );
  }
}
