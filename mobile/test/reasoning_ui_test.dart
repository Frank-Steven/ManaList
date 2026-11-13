import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:msgrepo_mobile/services/model_capabilities.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/context_meter.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/reasoning_pill_row.dart";

/// F36 方案A 回归（2026-11-13）：思考强度胶囊 + 档位面板 + 上下文估算。
///
/// 覆盖：能力判定三态、档位文案/默认映射、「off/null 不发参数」纯函数、
/// 胶囊行（不支持时隐藏思考胶囊）、面板（5 档 + 推荐徽标 + 选中高亮 + maxHeight）。
Widget wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: Column(children: [child])));

void main() {
  group("resolveReasoningSupport（保守白名单 + 显式优先）", () {
    test("已知推理模型 → true；普通模型 → false", () {
      expect(resolveReasoningSupport(model: "deepseek-reasoner"), isTrue);
      expect(resolveReasoningSupport(model: "deepseek-r1-distill-qwen"), isTrue);
      expect(resolveReasoningSupport(model: "kimi-k2-thinking"), isTrue);
      expect(resolveReasoningSupport(model: "glm-4.6-thinking"), isTrue);
      expect(resolveReasoningSupport(model: "qwq-32b"), isTrue);
      expect(resolveReasoningSupport(model: "o1"), isTrue);
      expect(resolveReasoningSupport(model: "o3-mini"), isTrue);
      expect(resolveReasoningSupport(model: "o4-mini"), isTrue);

      expect(resolveReasoningSupport(model: "deepseek-chat"), isFalse);
      expect(resolveReasoningSupport(model: "qwen-plus"), isFalse);
      expect(resolveReasoningSupport(model: "glm-5.3"), isFalse);
      expect(resolveReasoningSupport(model: ""), isFalse);
    });

    test("端点显式配置过 → 一律 true（用户表态优先）", () {
      expect(resolveReasoningSupport(model: "qwen-plus", configured: "high"),
          isTrue);
      expect(resolveReasoningSupport(model: "", configured: "off"), isTrue);
      expect(resolveReasoningSupport(model: "qwen-plus", configured: "  "),
          isFalse);
    });
  });

  group("shouldSendReasoningEffort（null/off 不发参数）", () {
    test("null 与 off 不发；low/medium/high 发；未知值不发", () {
      expect(shouldSendReasoningEffort(null), isFalse);
      expect(shouldSendReasoningEffort(""), isFalse);
      expect(shouldSendReasoningEffort("off"), isFalse);
      expect(shouldSendReasoningEffort("low"), isTrue);
      expect(shouldSendReasoningEffort("medium"), isTrue);
      expect(shouldSendReasoningEffort("high"), isTrue);
      expect(shouldSendReasoningEffort("weird"), isFalse);
    });
  });

  group("档位文案 / 默认映射", () {
    test("面板顺序：高 → 中 → 低 → 关闭 → 自动", () {
      expect(kReasoningOptions,
          <String?>["high", "medium", "low", "off", null]);
    });

    test("名称与描述齐全且各不相同", () {
      final labels = kReasoningOptions.map(reasoningOptionLabel).toList();
      expect(labels, ["高", "中", "低", "关闭", "自动"]);
      final descs =
          kReasoningOptions.map(reasoningOptionDescription).toSet();
      expect(descs.length, 5, reason: "5 档描述不得重复");
      expect(descs.any((d) => d.isEmpty), isFalse);
    });

    test("默认档只有「自动」；胶囊文案默认是「思考」", () {
      expect(isDefaultReasoningLevel(null), isTrue);
      for (final v in ["high", "medium", "low", "off"]) {
        expect(isDefaultReasoningLevel(v), isFalse);
      }
      expect(reasoningPillText(null), "思考");
      expect(reasoningPillText("high"), "思考 · 高");
      expect(reasoningPillText("off"), "思考 · 关闭");
    });
  });

  group("上下文圆环估算口径", () {
    test("历史字符/4 + 附件 token", () {
      expect(estimateContextTokens(historyChars: 400, attachmentTokens: 0), 100);
      expect(estimateContextTokens(historyChars: 0, attachmentTokens: 300), 300);
      expect(estimateContextTokens(historyChars: 1000, attachmentTokens: 50), 300);
      expect(estimateContextTokens(historyChars: 0, attachmentTokens: 0), 0);
    });

    test("文案必须标注「约」与「字符估算」", () {
      expect(contextEstimateText(16384, 32768), "约 50%（字符估算）");
      expect(contextEstimateText(0, 32768), "约 0%（字符估算）");
      expect(contextEstimateText(300, 32768).contains("约"), isTrue);
    });
  });

  group("ReasoningPillRow（胶囊行）", () {
    testWidgets("模型胶囊 + 思考胶囊 + 上下文圆环都在", (tester) async {
      var modelTaps = 0;
      var reasoningTaps = 0;
      await tester.pumpWidget(wrap(ReasoningPillRow(
        modelLabel: "DeepSeek V4.1",
        onModelTap: () => modelTaps++,
        reasoningText: "思考 · 高",
        reasoningActive: true,
        showReasoning: true,
        onReasoningTap: () => reasoningTaps++,
        usedTokens: 1600,
        limitTokens: 32768,
      )));
      expect(find.text("DeepSeek V4.1"), findsOneWidget);
      expect(find.text("思考 · 高"), findsOneWidget);
      expect(find.byType(ContextMeter), findsOneWidget);

      await tester.tap(find.text("DeepSeek V4.1"));
      expect(modelTaps, 1);
      await tester.tap(find.text("思考 · 高"));
      expect(reasoningTaps, 1);
    });

    testWidgets("不支持时隐藏思考胶囊，模型与圆环照常", (tester) async {
      await tester.pumpWidget(wrap(ReasoningPillRow(
        modelLabel: "qwen-plus",
        onModelTap: () {},
        reasoningText: "思考",
        reasoningActive: false,
        showReasoning: false,
        onReasoningTap: () {},
        usedTokens: 0,
        limitTokens: 32768,
      )));
      expect(find.text("qwen-plus"), findsOneWidget);
      expect(find.text("思考"), findsNothing);
      expect(find.byType(ContextMeter), findsOneWidget);
    });
  });

  group("ReasoningPanel（整宽档位面板）", () {
    testWidgets("5 个档位 + 只有一个「推荐」+ 选中项打勾", (tester) async {
      await tester.pumpWidget(wrap(ReasoningPanel(
        selected: "high",
        onSelect: (_) {},
        onClose: () {},
      )));
      expect(find.byKey(const ValueKey("reasoning-panel")), findsOneWidget);
      for (final level in kReasoningOptions) {
        expect(
            find.byKey(ValueKey("reasoning-option-${level ?? "auto"}")),
            findsOneWidget);
      }
      expect(find.byKey(const ValueKey("reasoning-recommended")),
          findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget,
          reason: "只有当前选中档有勾");
      expect(find.text("推理强度（仅对支持的模型生效）"), findsOneWidget);
    });

    testWidgets("点某档回调该档位；点关闭回调 onClose", (tester) async {
      String? picked;
      var closed = 0;
      await tester.pumpWidget(wrap(ReasoningPanel(
        selected: null,
        onSelect: (v) => picked = v,
        onClose: () => closed++,
      )));
      await tester.tap(find.byKey(const ValueKey("reasoning-option-low")));
      expect(picked, "low");
      await tester.tap(find.byKey(const ValueKey("reasoning-panel-close")));
      expect(closed, 1);
    });

    testWidgets("面板高度不超过 46% 屏高且可滚动", (tester) async {
      await tester.pumpWidget(wrap(ReasoningPanel(
        selected: null,
        onSelect: (_) {},
      )));
      final h = tester.getSize(find.byKey(const ValueKey("reasoning-panel"))).height;
      final screenH = tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(h, lessThanOrEqualTo(screenH * 0.46 + 1));
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });
  });
}