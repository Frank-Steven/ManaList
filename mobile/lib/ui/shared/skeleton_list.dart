import 'dart:async';

import 'package:flutter/material.dart';

/// 加载骨架（ux-fixes §3.3-10）：行状占位条替代白屏转圈。
///
/// 防闪策略（「最小展示时长反打」）：
/// - 数据在 300ms 内到达 → 骨架从未出现，直接渲染内容；
/// - 骨架一旦出现 → 至少展示满 300ms 再让位给内容，避免一闪而过。
///
/// 骨架本身是 AlwaysScrollable 的 ListView，包在 RefreshIndicator 里时
/// 加载期下拉手势仍可用。
class DeferredSkeletonList extends StatefulWidget {
  final bool loading;
  final Widget child;
  final int rows;

  const DeferredSkeletonList({
    super.key,
    required this.loading,
    required this.child,
    this.rows = 6,
  });

  @override
  State<DeferredSkeletonList> createState() => _DeferredSkeletonListState();
}

class _DeferredSkeletonListState extends State<DeferredSkeletonList> {
  static const _delay = Duration(milliseconds: 300);
  static const _minShow = Duration(milliseconds: 300);

  bool _skeletonVisible = false;
  DateTime? _shownAt;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.loading) _scheduleShow();
  }

  @override
  void didUpdateWidget(DeferredSkeletonList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.loading && widget.loading) {
      _scheduleShow();
    } else if (oldWidget.loading && !widget.loading) {
      _handleLoaded();
    }
  }

  void _scheduleShow() {
    _timer?.cancel();
    _timer = Timer(_delay, () {
      if (mounted && widget.loading) {
        setState(() {
          _skeletonVisible = true;
          _shownAt = DateTime.now();
        });
      }
    });
  }

  void _handleLoaded() {
    if (!_skeletonVisible) {
      _timer?.cancel(); // 数据 300ms 内到达：骨架不出现
      return;
    }
    final elapsed = DateTime.now().difference(_shownAt!);
    final remaining = _minShow - elapsed;
    if (remaining <= Duration.zero) {
      setState(() => _skeletonVisible = false);
    } else {
      // 骨架已出现但未满 300ms：再留一会儿，避免闪烁
      _timer?.cancel();
      _timer = Timer(remaining, () {
        if (mounted) setState(() => _skeletonVisible = false);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.loading && !_skeletonVisible) return widget.child;
    if (!_skeletonVisible) {
      // 延迟期内：空白但保持可滚动（RefreshIndicator 可用）
      return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const []);
    }
    final cs = Theme.of(context).colorScheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      children: [
        for (var i = 0; i < widget.rows; i++)
          _SkeletonRow(color: cs.surfaceContainerHigh, index: i),
      ],
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  final Color color;
  final int index;

  const _SkeletonRow({required this.color, required this.index});

  @override
  Widget build(BuildContext context) {
    // 行宽错位一点，更像真实列表
    final titleWidthFactor = 0.55 + (index % 3) * 0.12;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FractionallySizedBox(
              widthFactor: titleWidthFactor,
              child: Container(
                height: 12,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              height: 10,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
