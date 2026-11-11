import 'dart:async';

import 'package:flutter/material.dart';

/// F21 审批稿「标题方案③」：**长标题自动滚动，且允许手动滚动/拖动**。
///
/// 三条硬规则（与审批 HTML 一致）：
/// 1. **非溢出标题一律静止**（不可拖动、无动画）；
/// 2. **禁止无法停止的滚动**：hover / 触摸 / 键盘聚焦 / 显式 [paused] 任一成立即停；
/// 3. 到端点往返（reverse），不是无限单向跑；系统开启「减少动态效果」
///    （[MediaQueryData.disableAnimations]）时完全不自动滚，只保留手动拖动。
///
/// 无障碍：视觉位移只改绘制，读屏始终读完整标题（[Semantics] 包全量文本 +
/// [ExcludeSemantics] 包动画层），不会重复朗读。
class AutoScrollTitle extends StatefulWidget {
  const AutoScrollTitle({
    super.key,
    required this.text,
    this.style,
    this.paused = false,
    this.pxPerSecond = 42,
    this.minDuration = const Duration(seconds: 4),
    this.maxDuration = const Duration(seconds: 20),
  });

  final String text;
  final TextStyle? style;

  /// 外部强制暂停（例如页面进入选择模式）。
  final bool paused;

  /// 自动滚动速度（逻辑像素/秒），用于按溢出宽度推算时长。
  final double pxPerSecond;
  final Duration minDuration;
  final Duration maxDuration;

  @override
  State<AutoScrollTitle> createState() => _AutoScrollTitleState();
}

class _AutoScrollTitleState extends State<AutoScrollTitle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.minDuration);

  bool _overflow = false;
  double _overflowWidth = 0;

  bool _interacting = false;
  bool _focused = false;
  bool _manualHold = false;
  double _manualOffset = 0;
  Timer? _resumeTimer;

  bool get _paused =>
      widget.paused || _interacting || _focused || _manualHold;

  @override
  void didUpdateWidget(covariant AutoScrollTitle old) {
    super.didUpdateWidget(old);
    if (old.paused != widget.paused) _syncPlayState();
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// 依据当前布局计算结果决定「是否溢出 / 动画是否该跑」。
  void _applyOverflow(double overflow, bool reduceMotion) {
    final shouldScroll = overflow > 1 && !reduceMotion;
    if (shouldScroll == _overflow && (overflow - _overflowWidth).abs() < 0.5) {
      return;
    }
    _overflowWidth = overflow;
    // 布局阶段不能 setState：挪到当前帧之后。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _overflow = shouldScroll);
      if (!shouldScroll) {
        _controller.stop();
        _controller.value = 0;
        _manualOffset = 0;
        return;
      }
      final ms = (overflow / widget.pxPerSecond * 1000).round();
      final clamped = ms.clamp(
        widget.minDuration.inMilliseconds,
        widget.maxDuration.inMilliseconds,
      );
      _controller.duration = Duration(milliseconds: clamped);
      _syncPlayState();
    });
  }

  void _syncPlayState() {
    if (!_overflow) return;
    if (_paused) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  void _setFlag(void Function() mutate) {
    if (!mounted) return;
    setState(mutate);
    _syncPlayState();
  }

  void _onDragStart(DragStartDetails _) {
    _resumeTimer?.cancel();
    _setFlag(() => _manualHold = true);
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _setFlag(() {
      _manualOffset = (_manualOffset + d.delta.dx)
          .clamp(-_overflowWidth, 0.0)
          .toDouble();
    });
  }

  void _onDragEnd([Object? _]) {
    _resumeTimer?.cancel();
    // 松手后停 2s 再恢复自动滚，避免「刚拖完就被抢走」。
    _resumeTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      _setFlag(() => _manualHold = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style ??
        Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ) ??
        const TextStyle(fontSize: 16, fontWeight: FontWeight.w600);
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout();
        final overflow = painter.width - constraints.maxWidth;
        _applyOverflow(overflow <= 1 ? 0 : overflow, reduceMotion);

        final staticText = Text(
          widget.text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: style,
        );

        if (!_overflow) {
          return Semantics(
            label: widget.text,
            child: ExcludeSemantics(child: staticText),
          );
        }

        return Semantics(
          label: widget.text,
          hint: '长标题，可左右拖动',
          child: ExcludeSemantics(
            child: Listener(
              onPointerDown: (_) => _setFlag(() => _interacting = true),
              onPointerUp: (_) => _setFlag(() => _interacting = false),
              onPointerCancel: (_) => _setFlag(() => _interacting = false),
              child: MouseRegion(
                onEnter: (_) => _setFlag(() => _interacting = true),
                onExit: (_) => _setFlag(() => _interacting = false),
                child: Focus(
                  onFocusChange: (has) => _setFlag(() => _focused = has),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: _onDragStart,
                    onHorizontalDragUpdate: _onDragUpdate,
                    onHorizontalDragEnd: _onDragEnd,
                    onHorizontalDragCancel: _onDragEnd,
                    child: ClipRect(
                      key: const ValueKey('auto-scroll-viewport'),
                      child: AnimatedBuilder(
                        animation: _controller,
                        builder: (context, child) {
                          final auto = -_overflowWidth * _controller.value;
                          final dx =
                              (auto + _manualOffset).clamp(-_overflowWidth, 0.0);
                          return Transform.translate(
                            offset: Offset(dx.toDouble(), 0),
                            child: child,
                          );
                        },
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            widget.text,
                            maxLines: 1,
                            softWrap: false,
                            style: style,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
