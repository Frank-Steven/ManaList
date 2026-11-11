import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_markdown/flutter_markdown.dart";
import "package:flutter_test/flutter_test.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/code_block.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/collapsible_content.dart";

/// F21 第③阶段回归（2026-11-11）：长报告折叠 / fenced code 横滚复制 / 用户 pill 长文。
///
/// 关键口径：**只有真实溢出才出现按钮**（真实布局测量，不按字符数猜）。
final _cs = ColorScheme.fromSeed(seedColor: Colors.indigo);

Widget wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

const _code = "final result = computeSomething(alpha, beta, gamma, delta);";
const _longText =
    "这是一段很长的用户消息，用来验证三行折叠：第一行内容，第二行内容，第三行内容，第四行内容，第五行内容，第六行内容，第七行内容。";

Widget tallColumn() => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < 30; i++) Text("第 $i 行内容，用于制造真实溢出"),
      ],
    );

void main() {
  group("CollapsibleContent（助理长报告）", () {
    testWidgets("短内容：不出现「查看全文」", (tester) async {
      await tester.pumpWidget(wrap(const CollapsibleContent(
        child: SizedBox(height: 40, child: Text("短回复")),
      )));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey("collapsible-toggle")), findsNothing);
      expect(find.text("查看全文"), findsNothing);
    });

    testWidgets("长内容：限高 + 出现按钮；展开变大、可再收起", (tester) async {
      await tester.pumpWidget(wrap(CollapsibleContent(child: tallColumn())));
      await tester.pumpAndSettle();

      expect(find.text("查看全文"), findsOneWidget);
      final collapsedHeight =
          tester.getSize(find.byType(CollapsibleContent)).height;
      expect(collapsedHeight, lessThanOrEqualTo(260),
          reason: "折叠态 = 200dp 内容 + 按钮");

      await tester.tap(find.byKey(const ValueKey("collapsible-toggle")));
      await tester.pumpAndSettle();
      expect(find.text("收起"), findsOneWidget);
      expect(find.text("查看全文"), findsNothing);
      final expandedHeight =
          tester.getSize(find.byType(CollapsibleContent)).height;
      expect(expandedHeight, greaterThan(collapsedHeight + 100),
          reason: "展开后应露出全部内容");

      await tester.ensureVisible(
          find.byKey(const ValueKey("collapsible-toggle")));
      await tester.tap(find.byKey(const ValueKey("collapsible-toggle")));
      await tester.pumpAndSettle();
      expect(find.text("查看全文"), findsOneWidget);
    });
  });

  group("CollapsibleLines（用户 pill 长文）", () {
    const style = TextStyle(fontSize: 16, height: 1.5, color: Colors.white);

    testWidgets("短文本：无「展开全文」按钮", (tester) async {
      await tester.pumpWidget(wrap(const SizedBox(
        width: 300,
        child: CollapsibleLines(text: "好的，收到。", style: style),
      )));
      expect(find.byKey(const ValueKey("pill-toggle")), findsNothing);
    });

    testWidgets("长文本：3 行省略 + 展开全文/收起", (tester) async {
      await tester.pumpWidget(wrap(const SizedBox(
        width: 300,
        child: CollapsibleLines(text: _longText, style: style),
      )));
      expect(find.text("展开全文"), findsOneWidget);

      Text bodyText() =>
          tester.widget<Text>(find.textContaining("这是一段很长的用户消息"));
      expect(bodyText().maxLines, 3);

      await tester.tap(find.byKey(const ValueKey("pill-toggle")));
      await tester.pumpAndSettle();
      expect(bodyText().maxLines, isNull);
      expect(find.text("收起"), findsOneWidget);
    });
  });

  group("MarkdownCodeBlock（fenced code）", () {
    testWidgets("横向滚动 + 常驻复制按钮（≥44dp）", (tester) async {
      await tester.pumpWidget(wrap(SizedBox(
        width: 320,
        child: MarkdownCodeBlock(code: _code, colorScheme: _cs),
      )));
      expect(find.byKey(const ValueKey("code-scroll")), findsOneWidget);
      final scroll = tester.widget<SingleChildScrollView>(
          find.byKey(const ValueKey("code-scroll")));
      expect(scroll.scrollDirection, Axis.horizontal);

      final copySize = tester.getSize(find.byKey(const ValueKey("code-copy")));
      expect(copySize.width, greaterThanOrEqualTo(44));
      expect(copySize.height, greaterThanOrEqualTo(44));
    });

    testWidgets("点复制 → 写剪贴板 + 轻提示", (tester) async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await tester.pumpWidget(wrap(SizedBox(
        width: 320,
        child: MarkdownCodeBlock(code: _code, colorScheme: _cs),
      )));
      await tester.tap(find.byKey(const ValueKey("code-copy")));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      final copied = calls.where((c) => c.method == "Clipboard.setData");
      expect(copied, isNotEmpty, reason: "必须真的写剪贴板");
      expect((copied.first.arguments as Map)["text"], _code);
      expect(find.text("已复制代码"), findsOneWidget);
    });
  });

  group("MarkdownBody 集成：只替换 pre，普通段落不受影响", () {
    testWidgets("fenced code → MarkdownCodeBlock；段落仍正常渲染", (tester) async {
      const data = '这是普通段落。\n\n```dart\n$_code\n```\n\n结尾段落。';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownBody(
              data: data,
              builders: {"pre": FencedCodeBuilder(_cs)},
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownCodeBlock), findsOneWidget);
      expect(find.textContaining("这是普通段落"), findsOneWidget);
      expect(find.textContaining("结尾段落"), findsOneWidget);
    });
  });
}