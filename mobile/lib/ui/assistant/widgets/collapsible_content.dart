import "package:flutter/material.dart";

/// F21 第③阶段：助理长报告折叠。
///
/// 关键口径：**只有内容真实越过 [maxHeight] 才显示「查看全文」**——
/// 用真实布局结果（ScrollController.maxScrollExtent）判断，绝不按字符数硬猜；
/// 展开后原地续读（不跳转、不弹页），选择文本仍然可用（NeverScrollableScrollPhysics）。
class CollapsibleContent extends StatefulWidget {
  const CollapsibleContent({
    super.key,
    required this.child,
    this.maxHeight = 200,
    this.fadeSurface,
    this.collapsedLabel = "查看全文",
    this.expandedLabel = "收起",
  });

  final Widget child;
  final double maxHeight;

  /// 渐变遮罩的底色（通常传当前 surface，保证渐变融入背景）。
  final Color? fadeSurface;
  final String collapsedLabel;
  final String expandedLabel;

  @override
  State<CollapsibleContent> createState() => _CollapsibleContentState();
}

class _CollapsibleContentState extends State<CollapsibleContent> {
  final ScrollController _scroll = ScrollController();
  bool _overflowing = false;
  bool _expanded = true; // F27：默认展开，用户可手动折叠

  @override
  void initState() {
    super.initState();
    _scheduleOverflowCheck();
  }

  @override
  void didUpdateWidget(covariant CollapsibleContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleOverflowCheck();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scheduleOverflowCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final over = _scroll.position.maxScrollExtent > 0.5;
      if (over != _overflowing) setState(() => _overflowing = over);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_expanded) {
      // F27：默认展开，始终显示「收起」供用户手动折叠
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [widget.child, _toggleButton(widget.expandedLabel)],
      );
    }
    final surface = widget.fadeSurface ?? cs.surface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: widget.maxHeight),
              child: SingleChildScrollView(
                controller: _scroll,
                physics: const NeverScrollableScrollPhysics(),
                child: widget.child,
              ),
            ),
            if (_overflowing)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(
                    height: 48,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          surface.withValues(alpha: 0),
                          surface,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (_overflowing) _toggleButton(widget.collapsedLabel),
      ],
    );
  }

  Widget _toggleButton(String label) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        key: const ValueKey("collapsible-toggle"),
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        onPressed: () {
          setState(() => _expanded = !_expanded);
          _scheduleOverflowCheck();
        },
        child: Text(label, style: const TextStyle(fontSize: 13)),
      ),
    );
  }
}

/// 用户 pill 长文折叠：默认 [maxLines] 行，**真实超过才**给「展开全文/收起」。
class CollapsibleLines extends StatefulWidget {
  const CollapsibleLines({
    super.key,
    required this.text,
    this.style,
    this.maxLines = 3,
    this.collapsedLabel = "展开全文",
    this.expandedLabel = "收起",
  });

  final String text;
  final TextStyle? style;
  final int maxLines;
  final String collapsedLabel;
  final String expandedLabel;

  @override
  State<CollapsibleLines> createState() => _CollapsibleLinesState();
}

class _CollapsibleLinesState extends State<CollapsibleLines> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.computeLineMetrics().length > widget.maxLines;
        final body = Text(
          widget.text,
          style: widget.style,
          maxLines: _expanded || !overflows ? null : widget.maxLines,
          overflow: _expanded || !overflows
              ? TextOverflow.clip
              : TextOverflow.ellipsis,
        );
        if (!overflows) return body;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            body,
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey("pill-toggle"),
                style: TextButton.styleFrom(
                  minimumSize: const Size(44, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded ? widget.expandedLabel : widget.collapsedLabel,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}