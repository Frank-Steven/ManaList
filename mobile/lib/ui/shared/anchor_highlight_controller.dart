import 'package:flutter/material.dart';

import '../../services/assistant/models.dart';

/// 编辑态锚点高亮控制器（design-v3-details §1.3 定稿：纯文本 + marker 高亮，
/// 不做 WYSIWYG 部件内嵌）。覆写 [buildTextSpan]，把 `⟦task:<uuid>⟧` marker
/// 段渲染为带底色的 TextSpan——文本本身仍是 marker 原文，光标/选择/删除
/// 行为完全正常。
class AnchorHighlightController extends TextEditingController {
  AnchorHighlightController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final cs = Theme.of(context).colorScheme;
    final highlight = TextStyle(
      backgroundColor: cs.primary.withValues(alpha: 0.12),
      color: cs.primary,
    );
    final value = text;
    final matches = anchorMarkerPattern.allMatches(value).toList();
    if (matches.isEmpty) {
      return TextSpan(style: style, text: value);
    }
    final children = <InlineSpan>[];
    var last = 0;
    for (final m in matches) {
      if (m.start > last) {
        children.add(TextSpan(text: value.substring(last, m.start)));
      }
      children.add(TextSpan(text: m.group(0), style: highlight));
      last = m.end;
    }
    if (last < value.length) {
      children.add(TextSpan(text: value.substring(last)));
    }
    return TextSpan(style: style, children: children);
  }
}
