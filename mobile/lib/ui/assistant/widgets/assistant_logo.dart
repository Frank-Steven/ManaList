import 'package:flutter/material.dart';

/// B43：助理 LOGO —— **唯一生产实现**（F45 v2 双星）。
///
/// 视觉真源：`work/designs/assistant-logo/logo.svg`（viewBox 0 0 419 405，
/// 两条 cubic、stroke 22 / 18、round cap/join）。这里按同一几何等比绘制，
/// 不做任何变体；颜色由调用方传入（生产用 `ColorScheme.primary`）。
///
/// 范围（KIMI 方案 task-32 / task-34 / F45 task-39）：本组件是**唯一** LOGO 实现。
/// B43 加载态显式传 `ColorScheme.primary`；F45 之后底部导航、两个空态、
/// 模型选择、最近操作四处也复用本组件（不再使用旧的机器人图标）。
class AssistantLogo extends StatelessWidget {
  const AssistantLogo({
    super.key,
    this.color,
    required this.size,
    this.strokeDp,
  });

  /// 描边颜色。null = 跟随 `IconTheme`（放进 Icon 类位置时随选中/未选中/深浅色），
  /// 再回退到主题 `ColorScheme.primary`。
  final Color? color;

  /// 绘制宽度（高度按 F45 viewBox 比例自动换算）。
  final double size;

  /// 可选：**屏幕上的目标有效线宽**（dp），主/小星同宽。
  ///
  /// null（默认）完全保留 F45 的 viewBox 线宽（大星 22 / 小星 18），
  /// 其它入口与 B43 加载态行为不变。传值时 painter 反算 viewBox 单位线宽，
  /// 使 canvas 缩放后实际落在屏幕上的线宽恰为 [strokeDp]。
  ///
  /// B45（2026-11-25）：底部导航 24dp 槽位里与相邻 Material 图标等粗，传 2。
  final double? strokeDp;

  /// F45 viewBox 宽高比 419 : 405。
  static const double aspectRatio = 419 / 405;

  /// F45 viewBox 宽度（线宽换算基准）。
  static const double viewBoxWidth = 419;

  /// 大星线宽（**viewBox 单位**，与 logo.svg 的 stroke-width 一致）。
  static const double mainStarStroke = 22;

  /// 小星线宽（**viewBox 单位**）。
  static const double smallStarStroke = 18;

  /// 给定绘制宽度下，大星在**设备像素**中的有效线宽。
  ///
  /// 期望值 = 22 × size / 419（绘制时 canvas 只缩放一次）；
  /// 若实现里把 strokeWidth 又乘了 scale，实际有效线宽会变成这个值的 scale 倍。
  static double effectiveMainStrokePx(double size) =>
      mainStarStroke * size / viewBoxWidth;

  /// 小星在设备像素中的有效线宽（同上）。
  static double effectiveSmallStrokePx(double size) =>
      smallStarStroke * size / viewBoxWidth;

  @override
  Widget build(BuildContext context) {
    // 颜色解析（KIMI task-39）：显式 color > IconTheme > 主题 primary。
    final Color resolvedColor = color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.primary;
    final double? dp = strokeDp;
    assert(dp == null || (dp > 0 && dp.isFinite),
        'strokeDp 必须是有限正值（导航约 2dp）；null 表示沿用 viewBox 线宽');
    return Semantics(
      label: '助理',
      child: ExcludeSemantics(
        child: SizedBox(
          width: size,
          height: size / aspectRatio,
          child: CustomPaint(
            painter: _AssistantLogoPainter(color: resolvedColor, strokeDp: dp),
          ),
        ),
      ),
    );
  }
}

class _AssistantLogoPainter extends CustomPainter {
  const _AssistantLogoPainter({required this.color, this.strokeDp});

  final Color color;

  /// 目标有效线宽（dp）；null = 沿用 viewBox 线宽（22 / 18）。
  final double? strokeDp;

  /// 大星（对位 logo.svg 第 5 行）。
  static final Path _mainStar = Path()
    ..moveTo(190, 55)
    ..cubicTo(190, 157.3, 235.9, 210, 325, 210)
    ..cubicTo(235.9, 210, 190, 262.7, 190, 365)
    ..cubicTo(190, 262.7, 144.1, 210, 55, 210)
    ..cubicTo(144.1, 210, 190, 157.3, 190, 55)
    ..close();

  /// 小星（对位 logo.svg 第 6 行）。
  static final Path _smallStar = Path()
    ..moveTo(300, 50)
    ..cubicTo(300, 89.6, 317.7, 110, 352, 110)
    ..cubicTo(317.7, 110, 300, 130.4, 300, 170)
    ..cubicTo(300, 130.4, 282.3, 110, 248, 110)
    ..cubicTo(282.3, 110, 300, 89.6, 300, 50)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final scale = size.width / AssistantLogo.viewBoxWidth;
    // F45 双星线宽（viewBox 单位）：大星 22、小星 18。
    // 注意：canvas 已按 scale 缩放，Paint 的 strokeWidth 必须用 **viewBox 单位**（22 / 18），
    // 不能再乘 scale —— 否则有效线宽会变成 22×scale²，图标明显偏细。
    // B45：传了 strokeDp 时改用「目标屏幕线宽 → viewBox 单位」的反算：
    // 屏幕线宽 = strokeWidth × scale，故 strokeWidth = strokeDp / scale
    // = strokeDp × viewBoxWidth / size.width。主/小星同宽（导航里与相邻图标等粗）。
    final double? dp = strokeDp;
    final double mainStrokeWidth = dp == null
        ? AssistantLogo.mainStarStroke
        : dp * AssistantLogo.viewBoxWidth / size.width;
    final double smallStrokeWidth = dp == null
        ? AssistantLogo.smallStarStroke
        : dp * AssistantLogo.viewBoxWidth / size.width;
    final main = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = mainStrokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color
      ..isAntiAlias = true;
    final small = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = smallStrokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color
      ..isAntiAlias = true;

    canvas.save();
    canvas.scale(scale, scale);
    canvas.drawPath(_mainStar, main);
    canvas.drawPath(_smallStar, small);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _AssistantLogoPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.strokeDp != strokeDp;
}
