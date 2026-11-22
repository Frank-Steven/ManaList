import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'assistant_logo.dart';

/// B43 首次加载的不透明度曲线：o(θ) = 0.35 + 0.65 × (0.5 + 0.5 × cos θ)，
/// θ = 2π × phase（用户 2026-11-22 双重批准，T=800ms）。
///
/// phase 0 → 1.00、phase 0.5 → 0.35、phase 1 → 1.00，范围恒在 [0.35, 1.00]；
/// 只改透明度，无 saturation / 缩放 / 旋转 / 位移 / 发光。
double assistantLoadingOpacityAt(double phase) {
  final t = phase - phase.floorToDouble();
  return 0.35 + 0.65 * (0.5 + 0.5 * math.cos(2 * math.pi * t));
}

/// B43：助理页**首次加载**指示（64×约 62 的双星 + 13px 文案 + 800ms 透明度余弦）。
///
/// 约束（用户已批准的运行逻辑）：
/// 1. 只出现在首次加载、且由页面延迟 200ms 后才挂载 —— 极短加载不闪屏；
/// 2. 无最低展示时长、不做假进度、不人为拖延；
/// 3. `MediaQuery.disableAnimations` 为 true（reduced-motion）时**不动画**，
///    固定 opacity 1 的静态 LOGO + 文案；
/// 4. 出现即 `repeat()`，消失/dispose 即释放控制器。
class AssistantLoadingIndicator extends StatefulWidget {
  const AssistantLoadingIndicator({
    super.key,
    this.size = 64,
    this.label = '正在载入会话…',
  });

  /// LOGO 绘制宽度（高度按 F45 比例 ≈ 0.967 倍）。
  final double size;

  /// 文案（13px，`onSurfaceVariant`）。
  final String label;

  /// 用户批准的周期（定稿 800ms）。
  static const Duration period = Duration(milliseconds: 800);

  @override
  State<AssistantLoadingIndicator> createState() =>
      _AssistantLoadingIndicatorState();
}

class _AssistantLoadingIndicatorState extends State<AssistantLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: AssistantLoadingIndicator.period,
  );

  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _reduceMotion = reduce;
    if (reduce) {
      if (_ctrl.isAnimating) _ctrl.stop();
      // phase 0 → opacity 1：静态全不透明形态
      _ctrl.value = 0;
    } else if (!_ctrl.isAnimating) {
      _ctrl.repeat();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _ctrl,
            builder: (context, child) => Opacity(
              opacity:
                  _reduceMotion ? 1.0 : assistantLoadingOpacityAt(_ctrl.value),
              child: child,
            ),
            child: AssistantLogo(color: cs.primary, size: widget.size),
          ),
          const SizedBox(height: 14),
          Text(
            widget.label,
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
