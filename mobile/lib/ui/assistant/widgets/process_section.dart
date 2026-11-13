import 'package:flutter/material.dart';

import 'expandable_header.dart';

/// F31：正文已输出后，思考链/工具调用仍保留，但默认折叠。
///
/// 只负责「折叠容器 + 摘要行」；内部子项由调用方传入，
/// 折叠态不构建子项（避免思考/工具块各自的展开状态在重建时抖动）。
class ProcessSection extends StatefulWidget {
  const ProcessSection({
    super.key,
    required this.summary,
    required this.children,
    this.initiallyExpanded = false,
  });

  /// 摘要行文案，例如「过程 · 思考 3s · 3 步工具（1 步失败）」。
  final String summary;
  final List<Widget> children;
  final bool initiallyExpanded;

  @override
  State<ProcessSection> createState() => _ProcessSectionState();
}

class _ProcessSectionState extends State<ProcessSection> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // task-91：统一头部（三角在右），Key 保留给 process_section_test。
          ExpandableHeader(
            key: const ValueKey('process-toggle'),
            title: widget.summary,
            expanded: _open,
            onTap: () => setState(() => _open = !_open),
            // 右内边距 = 12(本行) + 内层卡片缩进12 + 内层头部8，减掉外框1dp边框，
            // 让外层三角与内层各行的三角落在同一条右竖线上（真机曾差 26px）。
            padding: const EdgeInsets.fromLTRB(12, 8, 20.5, 8),
            titleSize: 12,
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: widget.children,
              ),
            ),
        ],
      ),
    );
  }
}
