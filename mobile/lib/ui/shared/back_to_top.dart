import 'package:flutter/material.dart';

/// 长列表「回顶」小 FAB（ux-fixes §3.2-7）：滚动超过 3 屏后右下角出现
/// （与主 FAB 错层的小号按钮），点击 300ms easeOutCubic 回顶，到顶自动消失。
///
/// 用法：`ScrollableWithBackToTop(builder: (controller) => ListView(
///   controller: controller, ...))`。
class ScrollableWithBackToTop extends StatefulWidget {
  final Widget Function(ScrollController controller) scrollableBuilder;

  const ScrollableWithBackToTop({super.key, required this.scrollableBuilder});

  @override
  State<ScrollableWithBackToTop> createState() =>
      _ScrollableWithBackToTopState();
}

class _ScrollableWithBackToTopState extends State<ScrollableWithBackToTop> {
  final _controller = ScrollController();
  bool _show = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.hasClients || !mounted) return;
    final threshold = MediaQuery.sizeOf(context).height * 3;
    final show = _controller.offset > threshold;
    if (show != _show) setState(() => _show = show);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: widget.scrollableBuilder(_controller)),
        if (_show)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: '回到顶部',
              onPressed: () => _controller.animateTo(0,
                  // F4 §3.3-12：动画分档上限 300ms
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic),
              child: const Icon(Icons.arrow_upward, size: 20),
            ),
          ),
      ],
    );
  }
}
