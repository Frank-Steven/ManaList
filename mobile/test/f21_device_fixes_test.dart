import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:msgrepo_mobile/services/assistant/assistant_service.dart" show TurnPhase;
import "package:msgrepo_mobile/ui/assistant/widgets/auto_scroll_title.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/turn_activity_bar.dart";

/// task-84 回归（2026-11-11，真机缺陷 B22/B23/B24）。
///
/// B22：回合结束后活动条常驻 → 必须由 active 显式门控；
/// B23：停止键竖排贴边 → 宽度 ≥72、单行、右侧留 8dp；
/// B24：长标题滚动仍省略号/空白帧 → 滚动层按 TextPainter 完整宽度布局、无 ellipsis。
const _longTitle =
    "整理十月报销与发票（含 3 张截图、上海虹桥高铁票 553 元、本周五前提交、抄送财务）";

Widget wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: Column(children: [child])));

void main() {
  group("B22 活动条 active 门控", () {
    testWidgets("active:false 时即使阶段是 generating 也不显示活动条", (tester) async {
      await tester.pumpWidget(wrap(const TurnActivityBar(
        phase: TurnPhase.generating,
        active: false,
        onStop: null,
      )));
      expect(find.byKey(const ValueKey("turn-activity-bar")), findsNothing);
      expect(find.text("正在回复…"), findsNothing);
      expect(find.byType(ActivityPulseDot), findsNothing);
    });

    testWidgets("active:false 但有 pending → 静态待确认文案（无呼吸无停止）",
        (tester) async {
      await tester.pumpWidget(wrap(const TurnActivityBar(
        phase: TurnPhase.generating,
        active: false,
        pendingCount: 2,
        onStop: null,
      )));
      expect(find.text("等待你确认 2 条提案"), findsOneWidget);
      expect(find.byType(ActivityPulseDot), findsNothing);
      expect(find.byKey(const ValueKey("turn-activity-stop")), findsNothing);
    });

    testWidgets("active:true 时正常进入进行中态", (tester) async {
      await tester.pumpWidget(wrap(TurnActivityBar(
        phase: TurnPhase.thinking,
        active: true,
        onStop: () {},
      )));
      expect(find.text("正在思考…"), findsOneWidget);
      expect(find.byType(ActivityPulseDot), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 900));
    });
  });

  group("B23 停止键尺寸/单行/贴边", () {
    testWidgets("宽度 ≥72、高度 ≥48、右侧留 8dp、文案单行", (tester) async {
      await tester.pumpWidget(wrap(TurnActivityBar(
        phase: TurnPhase.generating,
        active: true,
        onStop: () {},
      )));
      final stopRect =
          tester.getRect(find.byKey(const ValueKey("turn-activity-stop")));
      expect(stopRect.width, greaterThanOrEqualTo(72));
      expect(stopRect.height, greaterThanOrEqualTo(48));

      final barRect =
          tester.getRect(find.byKey(const ValueKey("turn-activity-bar")));
      final rightGap = barRect.right - stopRect.right;
      expect(rightGap, greaterThanOrEqualTo(8), reason: "右侧至少 8dp");
      expect(rightGap, lessThanOrEqualTo(16), reason: "不应无谓拉大间距");

      final label = tester.widget<Text>(find.descendant(
        of: find.byKey(const ValueKey("turn-activity-stop")),
        matching: find.text("停止"),
      ));
      expect(label.maxLines, 1);
      expect(label.softWrap, isFalse);
      expect(find.text("停止"), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 900));
    });
  });

  group("B24 标题滚动层宽度", () {
    Widget titleWrap({double width = 180, bool reduceMotion = false}) =>
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduceMotion),
            child: Scaffold(
              appBar: AppBar(
                title: SizedBox(
                  width: width,
                  child: const AutoScrollTitle(text: _longTitle),
                ),
              ),
            ),
          ),
        );

    testWidgets("滚动层子 Text 宽度 > 视口，且不使用 ellipsis", (tester) async {
      await tester.pumpWidget(titleWrap());
      await tester.pump(const Duration(milliseconds: 100));

      final text = tester.widget<Text>(find.text(_longTitle));
      expect(text.overflow, isNot(TextOverflow.ellipsis),
          reason: "滚动态不得使用省略号（否则平移时出现空白帧）");

      final textRect = tester.getRect(find.text(_longTitle));
      expect(textRect.width, greaterThan(180),
          reason: "子 Text 必须按完整宽度布局，不能被视口裁成 180");
    });

    testWidgets("视口高度有限（非 Infinity）——B24 真机炸点回归", (tester) async {
      await tester.pumpWidget(titleWrap());
      await tester.pump(const Duration(milliseconds: 100));
      final viewportSize =
          tester.getSize(find.byKey(const ValueKey("auto-scroll-viewport")));
      expect(viewportSize.height.isFinite, isTrue,
          reason: "ClipRect 高度必须有限（此前 180×Infinity 导致 NaN）");
      expect(viewportSize.height, greaterThan(0));
      expect(viewportSize.width, 180);
    });

    testWidgets("接近滚动端点时内容右缘覆盖视口（无空白帧）", (tester) async {
      await tester.pumpWidget(titleWrap());
      await tester.pump(const Duration(milliseconds: 100));

      final textWidth = tester.getRect(find.text(_longTitle)).width;
      final hostWidth = tester.getSize(find.byType(AutoScrollTitle)).width;
      final overflow = textWidth - hostWidth;
      expect(overflow, greaterThan(0));

      // 时长按组件口径推算：clamp(overflow / 42px·s⁻¹, 4s, 20s)；
      // pump 到「接近端点」再看几何，避免正好落在 reverse 拐点上。
      final ms = (overflow / 42 * 1000).round().clamp(4000, 20000);
      await tester.pump(Duration(milliseconds: ms - 60));

      final textRect = tester.getRect(find.text(_longTitle));
      final hostRect = tester.getRect(find.byType(AutoScrollTitle));
      expect((textRect.right - hostRect.right).abs(), lessThan(10),
          reason: "端点附近文字右缘应覆盖视口右缘（无空白帧）");
    });

    testWidgets("reduce motion 时走静态分支（保留省略号）", (tester) async {
      await tester.pumpWidget(titleWrap(reduceMotion: true));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey("auto-scroll-viewport")), findsNothing);
      final text = tester.widget<Text>(find.text(_longTitle));
      expect(text.overflow, TextOverflow.ellipsis);
    });
  });
}