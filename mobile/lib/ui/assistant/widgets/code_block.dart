import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_markdown/flutter_markdown.dart";
import "package:markdown/markdown.dart" as md;

/// F21 第③阶段：Markdown fenced code block 渲染。
///
/// 要求：**横向滚动不换行、不撑宽容器**（SingleChildScrollView + softWrap:false）
/// ＋ 右上角**常驻**复制按钮（命中 ≥44dp），复制后轻提示；
/// 只替换 `pre` 元素，普通段落/列表/表格的渲染完全不碰。
class MarkdownCodeBlock extends StatelessWidget {
  const MarkdownCodeBlock({
    super.key,
    required this.code,
    required this.colorScheme,
  });

  final String code;
  final ColorScheme colorScheme;

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: code));
    messenger?.showSnackBar(
      const SnackBar(
        content: Text("已复制代码"),
        duration: Duration(milliseconds: 1500),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey("markdown-code-block"),
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                key: const ValueKey("code-copy"),
                tooltip: "复制代码",
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                padding: EdgeInsets.zero,
                iconSize: 18,
                color: colorScheme.onSurfaceVariant,
                icon: const Icon(Icons.copy_outlined),
                onPressed: () => _copy(context),
              ),
            ],
          ),
          SingleChildScrollView(
            key: const ValueKey("code-scroll"),
            scrollDirection: Axis.horizontal,
            child: Text(
              code,
              softWrap: false,
              style: TextStyle(
                fontFamily: "monospace",
                fontSize: 13,
                height: 1.45,
                color: colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 把 Markdown 的 `pre`（fenced / 缩进代码块）换成 [MarkdownCodeBlock]。
/// 返回 null 表示「不接管」，交回 flutter_markdown 默认渲染。
class FencedCodeBuilder extends MarkdownElementBuilder {
  FencedCodeBuilder(this.colorScheme);

  final ColorScheme colorScheme;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final code = element.textContent.trimRight();
    if (code.isEmpty) return null;
    return MarkdownCodeBlock(code: code, colorScheme: colorScheme);
  }
}