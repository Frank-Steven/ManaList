import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/expandable_header.dart";

/// task-91 回归（2026-11-13）：统一展开行头部。
///
/// 约束：三角固定在**右**、只用 expand_more 旋转（不再出现 chevron_right / expand_less）；
/// 不可展开（onTap == null）时不显示三角；leading/status 可选。
void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: Column(children: [child])));

  testWidgets("收起态：三角在右、图标是 expand_more 且未旋转", (tester) async {
    await tester.pumpWidget(wrap(ExpandableHeader(
      title: "过程 · 思考 3s · 3 步工具",
      expanded: false,
      onTap: () {},
    )));

    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byIcon(Icons.expand_less), findsNothing);

    final headerRect = tester.getRect(find.byType(ExpandableHeader));
    final iconRect = tester.getRect(find.byIcon(Icons.expand_more));
    expect(headerRect.right - iconRect.right, lessThanOrEqualTo(12),
        reason: "三角必须贴在行尾（右侧）");
    expect(iconRect.left, greaterThan(headerRect.center.dx),
        reason: "三角在右半边，不在左侧");

    final rotation = tester.widget<AnimatedRotation>(find.byType(AnimatedRotation));
    expect(rotation.turns, 0);
  });

  testWidgets("展开态：同一个 expand_more 旋转 0.5 圈（180°）", (tester) async {
    await tester.pumpWidget(wrap(ExpandableHeader(
      title: "思考",
      expanded: true,
      onTap: () {},
    )));
    final rotation = tester.widget<AnimatedRotation>(find.byType(AnimatedRotation));
    expect(rotation.turns, 0.5);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    expect(find.byIcon(Icons.expand_less), findsNothing);
  });

  testWidgets("onTap == null：不显示三角、不可点击", (tester) async {
    var taps = 0;
    await tester.pumpWidget(wrap(const ExpandableHeader(
      title: "搜索库内容",
      expanded: false,
      onTap: null,
    )));
    expect(find.byIcon(Icons.expand_more), findsNothing);
    expect(find.byType(AnimatedRotation), findsNothing);
    await tester.tap(find.byType(ExpandableHeader));
    expect(taps, 0);
  });

  testWidgets("leading / status 可选；点击触发回调", (tester) async {
    var taps = 0;
    await tester.pumpWidget(wrap(ExpandableHeader(
      leading: const Icon(Icons.psychology_outlined, size: 15),
      title: "思考",
      status: "已思考 12s",
      statusColor: Colors.red,
      expanded: false,
      onTap: () => taps++,
    )));
    expect(find.byIcon(Icons.psychology_outlined), findsOneWidget);
    expect(find.text("已思考 12s"), findsOneWidget);
    final status = tester.widget<Text>(find.text("已思考 12s"));
    expect(status.style?.color, Colors.red);

    await tester.tap(find.byType(ExpandableHeader));
    expect(taps, 1);
  });

  testWidgets("超长标题省略而不是溢出报错", (tester) async {
    await tester.pumpWidget(wrap(SizedBox(
      width: 220,
      child: ExpandableHeader(
        title: "这是一个非常非常长的展开行标题，用来确认它会被省略而不是撑破布局",
        status: "已回注",
        expanded: false,
        onTap: () {},
      ),
    )));
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
  });
}