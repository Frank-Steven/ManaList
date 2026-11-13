import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/assistant/models.dart';
import '../../../services/context_window.dart';

/// 上下文上限的**现值**：ManaList 没有 per-model `contextWindow`，
/// 全 App 沿用 32,768（assistant-v4-ui §3.6 的 kDefaultContextTokenLimit）。
/// 因此圆环百分比只是「按 32k 估算」，不是模型真实窗口。
const int kAssumedContextWindow = 32768;

/// 上下文占用百分比（= 附件估算 tokens / 上限）。边界：上限 ≤0 或用量 ≤0 → 0；
/// 不做上限截断（超限要能显示 >100%），负数按 0。
int contextPercent(int usedTokens, int limitTokens) {
  if (usedTokens <= 0 || limitTokens <= 0) return 0;
  return (usedTokens / limitTokens * 100).round();
}

/// token 数的人类可读格式：<1000 原样；<1e6 `~x.xK`；≥1e6 `x.xM`。
String formatTokenCount(int tokens) {
  if (tokens <= 0) return '0';
  if (tokens < 1000) return '$tokens';
  if (tokens < 1000000) {
    final k = tokens / 1000;
    final text = k >= 100 ? k.round().toString() : k.toStringAsFixed(1);
    return '~${text}K';
  }
  final m = tokens / 1000000;
  final text = m >= 10 ? m.round().toString() : m.toStringAsFixed(1);
  final trimmed =
      text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  return '${trimmed}M';
}

/// F21 审批稿：**上下文指示器（DSH ContextMeter 实证最小版）**。
///
/// 参照 DSH 真实组件（`@deepseek-ai/dsh-client-ui-conversation/lib/client.js`
/// :21481 起）：14×14 圆环、2px 描边、从 12 点顺时针、pill 里显示百分比、
/// 点击展开面板。
///
/// ⚠️ 与 DSH 的**刻意差异**（不照抄，因为数据不成立）：
/// - DSH 面板分「系统提示词 / 工具定义 / 对话消息」三类；本 App 的估算口径是
///   「**历史正文（字符数 ÷ 4）+ 草稿附件估算**」，面板只显示这一项合成值
///   （F42 已把条目名与说明改成如实描述）。工具定义已并入 `buildToolSpecPrompt`
///   的请求前言、系统提示词也没有单独计量，照抄三类会**重复计或编造**；
/// - 上限是 `kAssumedContextWindow = 32768`（App 现值，非模型窗口），所以
///   百分比与文案都明确写「按 32k 估算」。
///
/// 交互（移动端）：点击 → `showModalBottomSheet`，不做 hover 浮层。
/// 超预算时发送键仍由 input_bar 的 budgetLevel 逻辑禁用（本组件不接管）。
class ContextMeter extends StatelessWidget {
  const ContextMeter({
    super.key,
    required this.usedTokens,
    this.limitTokens = kAssumedContextWindow,
    this.onTap,
    this.usage,
    this.window,
  });

  /// 用于计算百分比的 token 数：有真实 usage 时是 promptTokens，否则是估算值。
  final int usedTokens;
  final int limitTokens;

  /// F40：上游真实 usage（null = 本会话还没拿到，按字符估算并如实标注）。
  final ChatUsage? usage;

  /// F41：解析出来的上下文窗口（含来源）；null = 老调用按 [limitTokens] 处理。
  final ContextWindowInfo? window;

  /// 实际参与百分比计算的上限：优先 window.tokens。
  int get effectiveLimitTokens => window?.tokens ?? limitTokens;

  /// 测试注入；默认打开底部 sheet。
  final VoidCallback? onTap;

  // F38（2026-11-13）：与另外两个胶囊（模型 / 思考强度）同口径——
  // minHeight 32、padding h10 v4、字号 12、圆环 16、ring-text gap 6。
  static const double ringSize = 16;
  static const double ringStroke = 2;

  /// 命中高度下限。F38 口径：**不再为 48dp 撑高整行** ——
  /// 行高上限 = pill 32 + 行上下 padding 2*2 = 36，命中高 ≥36 即可。
  /// （旧值 48 曾让圆环行比其他胶囊高一截、并被压在行右边缘。）
  static const double hitSize = 36;

  int get percent => contextPercent(usedTokens, effectiveLimitTokens);

  Color _arcColor(ColorScheme cs) {
    final limit = effectiveLimitTokens;
    if (limit > 0 && usedTokens > limit) return cs.error;
    if (limit > 0 && usedTokens > limit * 0.8) {
      return Colors.amber.shade800;
    }
    return cs.primary;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = _arcColor(cs);
    final limit = effectiveLimitTokens;
    final ratio = limit > 0
        ? (usedTokens / limit).clamp(0.0, 1.0).toDouble()
        : 0.0;

    final pill = Container(
      key: const ValueKey('context-meter-pill'),
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: ringSize,
            height: ringSize,
            child: CustomPaint(
              // 稳定的定位锚（测试断言用；不影响绘制与布局）。
              key: const ValueKey('context-meter-ring'),
              painter: _MeterRingPainter(
                ratio: ratio,
                track: cs.outlineVariant,
                color: color,
                strokeWidth: ringStroke,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$percent%',
            style: TextStyle(
              fontSize: 12,
              height: 1.1,
              color: cs.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );

    return Semantics(
      // F40/F41：真实 usage 与字符估算必须在无障碍层也能区分；
      // 同时带上上下文上限来源（模型表 / 端点 / 手动 / 估算）。
      label: [
        usage != null
            ? '上下文已用 $percent%（上次请求真实输入）'
            : '约 $percent%（字符估算）',
        if (window != null) window!.label,
      ].join('；'),
      button: true,
      child: InkResponse(
        onTap: onTap ??
            () => showContextMeterSheet(
                  context,
                  usedTokens: usedTokens,
                  limitTokens: limitTokens,
                  usage: usage,
                  window: window,
                ),
        radius: hitSize / 2,
        // F38 口径：命中高下限 36（= pill 32 + 行上下各 2），**不再为 48dp 撑高整行**；
        // 宽度仍随内容自然增长（F21 踩过：SizedBox(width:48) 把 pill 内部压到 30，
        // ring+gap+「214%」溢出 13px），所以只给最小尺寸、文字与圆环都不缩小。
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: hitSize,
            minHeight: hitSize,
          ),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: pill,
          ),
        ),
      ),
    );
  }
}

/// 展开面板（底部 sheet）。
///
/// - [usage] != null：显示**上游真实口径**（prompt/completion/total，含缓存命中），
///   明确写「真实」并注明上限仍按 32k 估算；
/// - [usage] == null：字符估算口径（历史正文 ÷ 4 + 草稿附件），不伪装成真实值。
Future<void> showContextMeterSheet(
  BuildContext context, {
  required int usedTokens,
  int limitTokens = kAssumedContextWindow,
  ChatUsage? usage,
  ContextWindowInfo? window,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final cs = Theme.of(sheetContext).colorScheme;
      final theme = Theme.of(sheetContext).textTheme;
      final limit = window?.tokens ?? limitTokens;
      final percent = contextPercent(usedTokens, limit);
      final hasLimit = limit > 0;
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('上下文已用 $percent%',
                  style: theme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              if (usage != null) ...[
                _usageRow(sheetContext, cs,
                    label: '真实输入（含系统提示词与历史）',
                    tokens: usage.promptTokens),
                const SizedBox(height: 6),
                _usageRow(sheetContext, cs,
                    label: '输出', tokens: usage.completionTokens),
                const SizedBox(height: 6),
                _usageRow(sheetContext, cs,
                    label: '合计', tokens: usage.totalTokens),
                const SizedBox(height: 10),
                Text(
                  '上次请求真实输入 ${usage.promptTokens} tokens（含系统提示词与历史）'
                  ' · 输出 ${usage.completionTokens} · 合计 ${usage.totalTokens}'
                  '${usage.cachedPromptTokens != null ? ' · 其中缓存命中 ${usage.cachedPromptTokens} tokens' : ''}'
                  '\n${window != null ? window.label : '上限仍按 32k 估算（上游未提供模型窗口）。'}',
                  style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
              ],
              if (usage == null) ...[
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: cs.primary,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      // F42：这个数字是「历史正文 + 草稿附件」，条目名不能再只写附件。
                      child: Text('字符估算（历史+附件）',
                          style: TextStyle(fontSize: 13, color: cs.onSurface)),
                    ),
                    Text(
                      formatTokenCount(usedTokens),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: cs.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  // F42：如实描述口径——历史已计入（历史正文 ÷ 4 + 草稿附件估算），
                  // 只有「系统说明 + 工具定义（请求前言）」没有计入。
                  // F41：上限与来源按解析结果写；window==null 的老调用保留 32k 说明。
                  '${window != null ? window.label : (hasLimit ? '按 32k 估算（$limitTokens tokens）' : '上限未知（模型未配置），分母按 32k 估算、百分比按 0 处理')}。'
                  '口径：历史正文（消息内容字符数 ÷ 4）+ 草稿附件估算。'
                  '系统说明与工具定义（请求前言）未计入。',
                  style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

/// 真实 usage 的一行：色块 + 标签 + 数字（tabular）。
Widget _usageRow(
  BuildContext context,
  ColorScheme cs, {
  required String label,
  required int tokens,
}) {
  return Row(
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: cs.primary,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(label,
            style: TextStyle(fontSize: 13, color: cs.onSurface)),
      ),
      Text(
        formatTokenCount(tokens),
        style: TextStyle(
          fontSize: 12.5,
          color: cs.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    ],
  );
}

class _MeterRingPainter extends CustomPainter {
  _MeterRingPainter({
    required this.ratio,
    required this.track,
    required this.color,
    required this.strokeWidth,
  });

  final double ratio;
  final Color track;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // 灰色底环（2px）
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = track,
    );
    if (ratio <= 0) return;
    // 从 12 点（-pi/2）顺时针画占用弧，linecap round
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * ratio,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _MeterRingPainter old) =>
      old.ratio != ratio ||
      old.color != color ||
      old.track != track ||
      old.strokeWidth != strokeWidth;
}
