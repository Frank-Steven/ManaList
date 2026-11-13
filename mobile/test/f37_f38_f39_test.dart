import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:msgrepo_mobile/ui/assistant/widgets/auto_scroll_title.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/chat_appbar.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/context_meter.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/reasoning_pill_row.dart";

/// F37 / F38 / F39 回归（2026-11-13）。
void main() {
  group("F37 长标题滚动可达", () {
    testWidgets("ChatAppBar 直接挂进 Scaffold.appBar + 长标题 → 进入滚动分支",
        (tester) async {
      // 关键：不包 SizedBox 定宽（真机里标题就是 AppBar 的自然宽度）。
      const longTitle =
          "think step by step about the weekly planning workflow and summarize";
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          appBar: ChatAppBar(
            title: longTitle,
            onRename: () {},
            onExport: () {},
            onClearAndRestart: () {},
            onDelete: () {},
          ),
          body: const SizedBox.shrink(),
        ),
      ));
      // 第一帧完成布局 → post-frame 里 setState 打开滚动分支 → 再 pump 出第二帧。
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();

      final viewportFinder =
          find.byKey(const ValueKey("auto-scroll-viewport"));
      expect(viewportFinder, findsOneWidget,
          reason: "真溢出时必须进入自动滚动分支");

      final viewportWidth = tester.getSize(viewportFinder).width;
      final textWidth = tester.getSize(find.text(longTitle)).width;
      expect(textWidth, greaterThan(viewportWidth),
          reason: "滚动层子 Text 必须比视口宽，否则物理上滚不起来");
      expect(tester.getSize(viewportFinder).height.isFinite, isTrue);
    });

    testWidgets("短标题不进入滚动分支（保持静态省略）", (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          appBar: ChatAppBar(
            title: "帮我整理收件箱",
            onRename: () {},
            onExport: () {},
            onClearAndRestart: () {},
            onDelete: () {},
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byKey(const ValueKey("auto-scroll-viewport")), findsNothing);
      expect(find.byType(AutoScrollTitle), findsOneWidget);
    });
  });

  group("F38 上下文胶囊与另外两个胶囊同尺寸", () {
    Widget wrap(Widget child) =>
        MaterialApp(home: Scaffold(body: Column(children: [child])));

    testWidgets("三个胶囊同高（32）+ 行右内边距 12 + 命中高 ≤36",
        (tester) async {
      await tester.pumpWidget(wrap(ReasoningPillRow(
        modelLabel: "DeepSeek V4.1 Flash",
        onModelTap: () {},
        reasoningText: "思考 · 高",
        reasoningActive: true,
        showReasoning: true,
        onReasoningTap: () {},
        usedTokens: 1600,
        limitTokens: 32768,
      )));

      final model =
          tester.getSize(find.byKey(const ValueKey("reasoning-model-pill")));
      final strength = tester
          .getSize(find.byKey(const ValueKey("reasoning-strength-pill")));
      final meter =
          tester.getSize(find.byKey(const ValueKey("context-meter-pill")));

      expect(model.height, 32);
      expect(strength.height, 32);
      expect(meter.height, 32, reason: "圆环胶囊必须与另两个同高");
      expect(strength.height, model.height);
      expect(meter.height, model.height);

      // 圆环不再被压在行右边缘：右内边距 12（与左 12 对称）。
      final rowRect = tester.getRect(find.byType(ReasoningPillRow));
      final meterRect =
          tester.getRect(find.byKey(const ValueKey("context-meter-pill")));
      expect(rowRect.right - meterRect.right, closeTo(12, 1));

      // 命中区：不为 48dp 撑高整行，但 ≥36。
      expect(ContextMeter.hitSize, 36);
      final meterWidgetRect =
          tester.getRect(find.byType(ContextMeter));
      expect(meterWidgetRect.height, lessThanOrEqualTo(36));
      expect(meterWidgetRect.height, greaterThanOrEqualTo(36));
    });
  });

  group("F39 模型胶囊不再画 ▾", () {
    testWidgets("没有 arrow_drop_down，点击仍触发跳转回调", (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ReasoningPillRow(
                modelLabel: "DeepSeek V4.1 Flash",
                onModelTap: () => taps++,
                reasoningText: "思考",
                reasoningActive: false,
                showReasoning: true,
                onReasoningTap: () {},
                usedTokens: 0,
                limitTokens: 32768,
              ),
            ],
          ),
        ),
      ));
      expect(find.byIcon(Icons.arrow_drop_down), findsNothing);
      await tester.tap(find.text("DeepSeek V4.1 Flash"));
      expect(taps, 1);
    });
  });
}