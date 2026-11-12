import 'package:flutter/material.dart';

import '../../../services/assistant/models.dart';
import 'attachment_cards.dart';
import 'context_meter.dart';

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

  /// 回合中是否显示「停止」键。
  /// F21 第②阶段起主进行态条上有唯一停止键，输入栏 busy 时只留占位
  /// （不显示第二个停止键、也不让布局跳动）。
  final bool showStopButton;

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
    this.showStopButton = true,
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

  /// F03：草稿附件 chip。图片 chip 点按 → 全屏预览（与附件卡片共用
  /// [showImagePreview]）；非图片 chip 保持原样（不可点）。
  /// 删除按钮与批量上限语义完全不变。
  Widget _buildDraftChip(ChatAttachment a, ColorScheme cs) {
    final meta = widget.metaOf(a);
    final file = meta?.file;
    return InputChip(
      avatar: Icon(meta?.icon ?? Icons.attach_file, size: 16),
      label: Text(meta?.title ?? a.id, style: const TextStyle(fontSize: 11)),
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: cs.outlineVariant),
      onPressed: isPreviewableImage(meta)
          ? () => showImagePreview(context, file!)
          : null,
      onDeleted: () => widget.onRemoveAttachment(a),
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
                    child: _buildDraftChip(a, cs),
                  ),
              ],
            ),
          ),
          if (widget.attachmentTokens != null) _buildContextIndicator(),
        ],
      ),
    );
  }

  /// 上下文指示器（F21 审批稿 / DSH ContextMeter 实证最小版）：
  /// 折叠态 = 14px 圆环 + NN%；点击 → 底部 sheet（只有「附件（估算）」一行）。
  ///
  /// 数据口径见 context_meter.dart：上限是 App 现值 32768（模型未声明窗口），
  /// 面板明确写「按 32k 估算」，不伪造系统提示词/工具定义/对话三类。
  /// 超预算时发送键仍由 budgetLevel 拦截（见 _buildSendButton），行为不变。
  Widget _buildContextIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: ContextMeter(
        usedTokens: widget.attachmentTokens!,
        limitTokens: widget.tokenLimit,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasImageDraft =
        widget.attachments.any((a) => isPreviewableImage(widget.metaOf(a)));
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 6), // F29：减少垂直留白
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
                      borderRadius: BorderRadius.circular(12), // F29：更紧凑的圆角
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
                            decoration: InputDecoration(
                              // F03：有截图草稿时可留空直接发（默认指令见
                              // chat_page.outgoingTextFor），否则维持原文案。
                              hintText: hasImageDraft
                                  ? '可留空：直接发送这些截图'
                                  : '和助理说点什么…', // F30：缩短hint避免折行
                              isDense: true,
                              border: InputBorder.none,
                              contentPadding:
                                  const EdgeInsets.symmetric(vertical: 10),
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
    if (widget.busy && !widget.showStopButton) {
      // 主进行态条已提供唯一停止键：这里只保留等宽占位，防止布局跳动。
      return const SizedBox(
        key: ValueKey("input-stop-placeholder"),
        width: 48,
        height: 48,
      );
    }
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
