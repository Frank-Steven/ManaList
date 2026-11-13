import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/process_section.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/streaming_blocks.dart";

/// 真机回归（2026-11-13）：外层过程行的三角必须与内层各行的三角同一条右竖线。
/// 曾因外层右边距 12、内层 12(卡片缩进)+8 而差 26px。
void main() {
  testWidgets("过程行与内层行的三角右边缘对齐", (tester) async {
    final seg = ChatStreamSegment(
        kind: ChatStreamSegmentKind.tool, startedAt: DateTime.now())
      ..active = false
      ..summary = "列出任务"
      ..detail = "返回 50 条"
      ..status = "已回注";

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ProcessSection(
          summary: "过程 · 思考 · 3 步工具",
          initiallyExpanded: true,
          children: [ToolCallBlock(segment: seg, onToggle: () {})],
        ),
      ),
    ));

    final carets = find.byIcon(Icons.expand_more);
    expect(tester.widgetList(carets).length, 2,
        reason: "外层 + 内层各一个三角");
    final outer = tester.getRect(carets.at(0));
    final inner = tester.getRect(carets.at(1));
    expect((outer.right - inner.right).abs(), lessThan(0.6),
        reason: "三角必须同一条右竖线（真机曾差 26px）");
  });
}
