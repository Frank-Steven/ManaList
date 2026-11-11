import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:msgrepo_mobile/services/assistant/assistant_service.dart" show TurnPhase;
import "package:msgrepo_mobile/ui/assistant/widgets/input_bar.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/streaming_blocks.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/turn_activity_bar.dart";

/// F21 第②阶段回归（2026-11-11）：**全页唯一主进行态条**。
///
/// 钉住：① 阶段文案来自真实 TurnPhase、不伪造计划/总步数；② 次级只报已完成步数；
/// ③ 进行中只有一个循环动效（ActivityPulseDot），思考块/工具块/正文光标都不画；
/// ④ 停止键 ≥48dp 且回调生效；⑤ 有 pending 提案时静态「等待你确认 N 条」，无呼吸无停止；
/// ⑥ 输入栏 busy 不再出现第二个停止键（仅留占位）。
void main() {
  group("activityPrimaryText（真实阶段文案）", () {
    test("四个进行中阶段 + done/error", () {
      expect(activityPrimaryText(TurnPhase.starting), "正在连接模型…");
      expect(activityPrimaryText(TurnPhase.thinking), "正在思考…");
      expect(activityPrimaryText(TurnPhase.generating), "正在回复…");
      expect(activityPrimaryText(TurnPhase.tooling), "正在执行工具…");
      expect(activityPrimaryText(TurnPhase.done), "已完成");
      expect(activityPrimaryText(TurnPhase.error), "出错了");
    });

    test("不伪造计划/总步数：进行中文案不含「共 N 步」或「计划」", () {
      for (final p in [
        TurnPhase.starting,
        TurnPhase.thinking,
        TurnPhase.generating,
        TurnPhase.tooling,
      ]) {
        final text = activityPrimaryText(p);
        expect(text.contains("共"), isFalse);
        expect(text.contains("计划"), isFalse);
        expect(RegExp(r"[0-9]").hasMatch(text), isFalse,
            reason: "主文案不得出现任何数字（步数只走次级）");
      }
    });

    test("activityIsBusy：进行中 true，done/error false", () {
      expect(activityIsBusy(TurnPhase.thinking), isTrue);
      expect(activityIsBusy(TurnPhase.tooling), isTrue);
      expect(activityIsBusy(TurnPhase.done), isFalse);
      expect(activityIsBusy(TurnPhase.error), isFalse);
    });
  });

  group("次级/待确认文案", () {
    test("已完成步数：0 不显示，>0 用真实计数", () {
      expect(activitySecondaryText(0), isNull);
      expect(activitySecondaryText(2), "已完成 2 步");
      expect(activitySecondaryText(37), "已完成 37 步");
    });

    test("待确认文案带真实计数", () {
      expect(activityPendingText(1), "等待你确认 1 条提案");
      expect(activityPendingText(4), "等待你确认 4 条提案");
    });
  });

  group("TurnActivityBar（唯一主进行态）", () {
    Widget wrap(Widget child) =>
        MaterialApp(home: Scaffold(body: Column(children: [child])));

    testWidgets("进行中：主文案 + 已完成步数 + 唯一呼吸点 + 停止键", (tester) async {
      var stopped = 0;
      await tester.pumpWidget(wrap(TurnActivityBar(
        phase: TurnPhase.generating,
        completedSteps: 2,
        onStop: () => stopped++,
      )));
      expect(find.text("正在回复…"), findsOneWidget);
      expect(find.text("已完成 2 步"), findsOneWidget);
      expect(find.byType(ActivityPulseDot), findsOneWidget,
          reason: "进行中只有这一个循环动效");
      expect(find.text("停止"), findsOneWidget);

      final sz = tester.getSize(find.byKey(const ValueKey("turn-activity-stop")));
      expect(sz.height, greaterThanOrEqualTo(48));
      expect(sz.width, greaterThanOrEqualTo(48));

      await tester.tap(find.byKey(const ValueKey("turn-activity-stop")));
      expect(stopped, 1);
      await tester.pump(const Duration(milliseconds: 900));
    });

    testWidgets("有 pending 且不在生成：静态文案，无呼吸无停止", (tester) async {
      await tester.pumpWidget(wrap(TurnActivityBar(
        phase: TurnPhase.done,
        pendingCount: 3,
        onStop: () {},
      )));
      expect(find.text("等待你确认 3 条提案"), findsOneWidget);
      expect(find.byType(ActivityPulseDot), findsNothing);
      expect(find.text("停止"), findsNothing);
    });

    testWidgets("无 pending 且已完成：整条不占位", (tester) async {
      await tester.pumpWidget(wrap(const TurnActivityBar(phase: TurnPhase.done)));
      expect(find.byKey(const ValueKey("turn-activity-bar")), findsNothing);
    });
  });

  group("唯一动效：其他位置的循环动画已移除", () {
    ChatStreamSegment seg(ChatStreamSegmentKind kind) =>
        ChatStreamSegment(kind: kind, startedAt: DateTime.now())..active = true;

    Widget wrap(Widget child) =>
        MaterialApp(home: Scaffold(body: Column(children: [child])));

    testWidgets("思考块 active 不再有转圈进度", (tester) async {
      await tester.pumpWidget(wrap(ThinkingBlock(
        segment: seg(ChatStreamSegmentKind.thinking),
        onToggle: () {},
      )));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(BreathingDot), findsNothing);
    });

    testWidgets("工具块 active 不再有呼吸点", (tester) async {
      final s = seg(ChatStreamSegmentKind.tool)..status = "执行中";
      await tester.pumpWidget(wrap(ToolCallBlock(segment: s, onToggle: () {})));
      expect(find.byType(BreathingDot), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group("输入栏：busy 时不再有第二个停止键", () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    ChatInputBar bar({required bool showStopButton, required VoidCallback onCancel}) {
      final controller = TextEditingController();
      return ChatInputBar(
        controller: controller,
        busy: true,
        attachments: const [],
        metaOf: (_) => null,
        onRemoveAttachment: (_) {},
        onAddAttachments: () {},
        onPickScreenshots: () {},
        onSend: () {},
        onCancel: onCancel,
        showStopButton: showStopButton,
      );
    }

    testWidgets("showStopButton:false → 只有占位，无停止图标", (tester) async {
      var cancelled = 0;
      await tester.pumpWidget(wrap(bar(showStopButton: false, onCancel: () => cancelled++)));
      expect(find.byKey(const ValueKey("input-stop-placeholder")), findsOneWidget);
      expect(find.byIcon(Icons.stop), findsNothing);
      expect(cancelled, 0);
    });

    testWidgets("默认 true 时仍保留旧行为（回归保护）", (tester) async {
      var cancelled = 0;
      await tester.pumpWidget(wrap(bar(showStopButton: true, onCancel: () => cancelled++)));
      expect(find.byIcon(Icons.stop), findsOneWidget);
      await tester.tap(find.byIcon(Icons.stop));
      expect(cancelled, 1);
    });
  });
}