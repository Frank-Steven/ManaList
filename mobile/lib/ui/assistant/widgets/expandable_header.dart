import "package:flutter/material.dart";

/// 统一的「可展开标题行」（task-91）。
///
/// 起因：过程块外层用 `chevron_right`（三角在左），内层思考/工具块用
/// `expand_more`/`expand_less`（三角在右）——四处各写各的 Row 导致视觉不一致。
/// 现在四个调用点统一走本组件：
/// - **三角固定在右**，只用 `Icons.expand_more` + `AnimatedRotation(turns: 0.5)`；
/// - 不再混用 `chevron_right` / `expand_less`；
/// - 左侧可选 leading 图标，标题与状态文案之间固定 6dp。
class ExpandableHeader extends StatelessWidget {
  const ExpandableHeader({
    super.key,
    this.leading,
    required this.title,
    this.status,
    this.statusColor,
    this.statusFontFeatures,
    required this.expanded,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    this.titleSize = 12.5,
    this.statusSize = 12,
  });

  /// 标题左侧的图标（如思考块的大脑、工具块的工具图标）。
  final Widget? leading;

  final String title;

  /// 标题右侧的状态文案（如「已思考 12s」「已回注」）；null 不显示。
  final String? status;
  final Color? statusColor;

  /// 状态里的数字用等宽字形，避免秒数跳动导致横向抖动。
  final List<FontFeature>? statusFontFeatures;

  final bool expanded;

  /// 为 null 表示该行不可展开（此时不显示三角，也不响应点击）。
  final VoidCallback? onTap;

  final EdgeInsets padding;
  final double titleSize;
  final double statusSize;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tappable = onTap != null;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: 6),
            ],
            // 必须是 Expanded（不能用 Flexible）：Flexible 只分配空间、不强制占满，
            // 标题短时剩余空间不会重分配，后续 Spacer/三角会被拽到行中间。
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ),
            const SizedBox(width: 6),
            if (status != null)
              Text(
                status!,
                style: TextStyle(
                  fontSize: statusSize,
                  color: statusColor ?? cs.onSurfaceVariant,
                  fontFeatures: statusFontFeatures,
                ),
              ),
            if (tappable)
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 160),
                child: Icon(
                  Icons.expand_more,
                  size: 16,
                  color: cs.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}