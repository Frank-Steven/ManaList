import "package:flutter/material.dart";

import "context_meter.dart";

/// F36 方案A（2026-11-13）：输入区上方的「模型胶囊 + 思考强度胶囊 + 上下文圆环」行，
/// 以及点开思考强度后的**整宽档位面板**。
///
/// 口径（与设计稿一致）：
/// - null = 自动（不发参数，等价旧行为）；off = 显式关闭（不发）；low/medium/high = 发。
/// - 胶囊默认显示「思考」；非默认档才显示档位名（「思考 · 高」）。
/// - 能力不支持时**隐藏思考强度胶囊**（模型胶囊与圆环照常）。
/// - 上下文圆环用**字符估算**，必须标注「约」，不伪装成模型真实 usage。
const String kAiContentDisclaimer = "内容由 AI 生成";

/// 面板里的档位顺序（设计稿：高 → 中 → 低 → 关闭 → 自动）。
const List<String?> kReasoningOptions = <String?>[
  "high",
  "medium",
  "low",
  "off",
  null,
];

/// 档位名称（面板与胶囊共用）。
String reasoningOptionLabel(String? level) => switch (level) {
      "high" => "高",
      "medium" => "中",
      "low" => "低",
      "off" => "关闭",
      _ => "自动",
    };

/// 档位一句话描述（面板每项第二行）。
String reasoningOptionDescription(String? level) => switch (level) {
      "high" => "思考更久，适合复杂推理与长链路分析",
      "medium" => "平衡速度与推理深度，多数任务的稳妥选择",
      "low" => "略作思考，响应更快",
      "off" => "显式关闭推理，最快回复",
      _ => "由模型自身默认行为决定（不发送参数）",
    };

/// 是否默认档（自动）——面板里给它挂「推荐」徽标。
bool isDefaultReasoningLevel(String? level) => level == null;

/// 胶囊文案：默认「思考」，非默认「思考 · 高/中/低/关闭」。
String reasoningPillText(String? effective) =>
      effective == null ? "思考" : "思考 · ${reasoningOptionLabel(effective)}";

/// 对话上下文 token 的**近似**估算：历史消息字符数 / 4 + 草稿附件估算。
int estimateContextTokens({
  required int historyChars,
  required int attachmentTokens,
}) {
  if (historyChars <= 0) return attachmentTokens < 0 ? 0 : attachmentTokens;
  final fromHistory = (historyChars / 4).round();
  return fromHistory + (attachmentTokens < 0 ? 0 : attachmentTokens);
}

/// 圆环的「约 N%（字符估算）」文案。
String contextEstimateText(int usedTokens, int limitTokens) =>
    "约 ${contextPercent(usedTokens, limitTokens)}%（字符估算）";

/// 上下文用量说明（底部 sheet）：明确这是估算口径。
Future<void> showContextEstimateSheet(
  BuildContext context, {
  required int usedTokens,
  required int limitTokens,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final cs = Theme.of(sheetContext).colorScheme;
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("上下文已用 ${contextEstimateText(usedTokens, limitTokens)}",
                  style: Theme.of(sheetContext).textTheme.titleMedium),
              const SizedBox(height: 10),
              Text(
                "口径：历史消息字数 ÷ 4 + 草稿附件估算（按 32k 上下文计）。"
                "这是**近似值**，不是模型侧的真实 token 用量。",
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 输入区上方的一行：模型胶囊（最左）+ 思考强度胶囊 + 右侧上下文圆环。
class ReasoningPillRow extends StatelessWidget {
  const ReasoningPillRow({
    super.key,
    required this.modelLabel,
    required this.onModelTap,
    required this.reasoningText,
    required this.reasoningActive,
    required this.showReasoning,
    required this.onReasoningTap,
    required this.usedTokens,
    required this.limitTokens,
  });

  final String modelLabel;
  final VoidCallback onModelTap;
  final String reasoningText;

  /// 是否非默认档（用于小圆点高亮）。
  final bool reasoningActive;

  /// 能力不支持时隐藏思考强度胶囊。
  final bool showReasoning;
  final VoidCallback onReasoningTap;

  final int usedTokens;
  final int limitTokens;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      // F38：右侧内边距 4 → 12（与左侧对称，胶囊整体左移，不再贴行右边缘）。
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: Row(
        children: [
          // F39：点击是「跳转模型配置页」而不是下拉，所以不再画 ▾ 小三角
          // （同时把它的横向占位一起去掉，胶囊宽度只由模型名决定）。
          _pill(
            key: const ValueKey('reasoning-model-pill'),
            context: context,
            onTap: onModelTap,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    modelLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: cs.onSurface),
                  ),
                ),
              ],
            ),
          ),
          if (showReasoning) ...[
            const SizedBox(width: 6),
            _pill(
              key: const ValueKey('reasoning-strength-pill'),
              context: context,
              onTap: onReasoningTap,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color:
                          reasoningActive ? cs.primary : cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    reasoningText,
                    style: TextStyle(fontSize: 12, color: cs.onSurface),
                  ),
                ],
              ),
            ),
          ],
          const Spacer(),
          ContextMeter(
            usedTokens: usedTokens,
            limitTokens: limitTokens,
            onTap: () => showContextEstimateSheet(
              context,
              usedTokens: usedTokens,
              limitTokens: limitTokens,
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill({
    Key? key,
    required BuildContext context,
    required VoidCallback onTap,
    required Widget child,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          key: key,
          constraints: const BoxConstraints(minHeight: 32, maxWidth: 168),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 整宽档位面板（贴在输入区上方，不是跟随胶囊的浮层）。
class ReasoningPanel extends StatelessWidget {
  const ReasoningPanel({
    super.key,
    required this.selected,
    required this.onSelect,
    this.onClose,
  });

  final String? selected;
  final ValueChanged<String?> onSelect;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxHeight = MediaQuery.of(context).size.height * 0.46;
    return Container(
      key: const ValueKey("reasoning-panel"),
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    "推理强度（仅对支持的模型生效）",
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                if (onClose != null)
                  IconButton(
                    key: const ValueKey("reasoning-panel-close"),
                    tooltip: "收起",
                    constraints:
                        const BoxConstraints(minWidth: 44, minHeight: 44),
                    iconSize: 18,
                    onPressed: onClose,
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            for (final level in kReasoningOptions)
              _option(context, level),
          ],
        ),
      ),
    );
  }

  Widget _option(BuildContext context, String? level) {
    final cs = Theme.of(context).colorScheme;
    final isSelected = level == selected;
    return InkWell(
      key: ValueKey("reasoning-option-${level ?? "auto"}"),
      borderRadius: BorderRadius.circular(8),
      onTap: () => onSelect(level),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? cs.primaryContainer.withValues(alpha: 0.5) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        reasoningOptionLabel(level),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                      if (isDefaultReasoningLevel(level)) ...[
                        const SizedBox(width: 6),
                        Container(
                          key: const ValueKey("reasoning-recommended"),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: cs.primary.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            "推荐",
                            style: TextStyle(fontSize: 10, color: cs.primary),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    reasoningOptionDescription(level),
                    style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check, size: 16, color: cs.primary),
          ],
        ),
      ),
    );
  }
}