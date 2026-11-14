import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:msgrepo_mobile/services/ai_client.dart";
import "package:msgrepo_mobile/services/context_window.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/attachment_cards.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/context_meter.dart";

/// F41 回归（2026-11-13）：上下文上限「可获取」，不再硬编码 32k。
void main() {
  // F44 用户口径：fromEndpoint > 模型表 > configured > 兜底（与 F41 相反）。
  group("resolveContextWindow 优先级（F44 新顺序）", () {
    test("① fromEndpoint 覆盖模型表与 configured", () {
      final info = resolveContextWindow(
        model: "deepseek-flash",
        configured: 200000,
        fromEndpoint: 128000,
      );
      expect(info.tokens, 128000);
      expect(info.source, ContextWindowSource.endpoint,
          reason: "端点自报最可信，即使模型表/手填都指向别的值");
    });

    test("② 模型表覆盖 configured", () {
      final info = resolveContextWindow(
        model: "deepseek-flash",
        configured: 200000,
      );
      expect(info.tokens, 1000000);
      expect(info.source, ContextWindowSource.modelTable,
          reason: "官方文档可引用的表优先于用户可能过时的手填");
    });

    test("③ configured 覆盖兜底（模型表不认识）", () {
      final info = resolveContextWindow(
        model: "some-unknown-model",
        configured: 200000,
      );
      expect(info.tokens, 200000);
      expect(info.source, ContextWindowSource.configured);
    });

    test("端点自报单独生效（无 configured）", () {
      final info = resolveContextWindow(
        model: "deepseek-flash",
        fromEndpoint: 128000,
      );
      expect(info.tokens, 128000);
      expect(info.source, ContextWindowSource.endpoint);
    });

    test("模型表覆盖兜底", () {
      final info = resolveContextWindow(model: "deepseek-flash");
      expect(info.tokens, 1000000);
      expect(info.source, ContextWindowSource.modelTable);
    });

    test("全空 → 32768 + assumed", () {
      final info = resolveContextWindow(model: "unknown-model");
      expect(info.tokens, kAssumedContextTokenLimit);
      expect(info.tokens, 32768);
      expect(info.source, ContextWindowSource.assumed);
    });

    test("0 / 负数 视为未提供，继续往下走", () {
      expect(
          resolveContextWindow(
                  model: "deepseek-flash", configured: 0, fromEndpoint: -1)
              .source,
          ContextWindowSource.modelTable);
      expect(
          resolveContextWindow(model: "x", configured: 0, fromEndpoint: 0)
              .source,
          ContextWindowSource.assumed);
    });
  });

  group("模型表（只收官方可引用型号）", () {
    test("deepseek 系列 → 1M", () {
      for (final m in [
        "deepseek-flash",
        "DeepSeek-Flash",
        "deepseek-v4.1-flash",
        "deepseek-v4-pro",
        "1017",
        "deepseek-flash-20261101",
      ]) {
        expect(knownContextWindowFor(m), 1000000, reason: m);
      }
    });

    test("未知模型 / 短串不做子串误命中", () {
      expect(knownContextWindowFor("qwen-plus"), isNull);
      expect(knownContextWindowFor("kimi-k2"), isNull);
      expect(knownContextWindowFor("qwen-1017"), isNull,
          reason: "1017 只做整名别名匹配");
      expect(knownContextWindowFor("1017x"), isNull);
      expect(knownContextWindowFor(""), isNull);
    });

    test("上限文案格式化：混刻度（十进制 k + 1024 进制 k）", () {
      expect(formatContextWindowTokens(32768), "32k", reason: "32×1024");
      expect(formatContextWindowTokens(1000000), "1M");
      expect(formatContextWindowTokens(128000), "128k", reason: "128,000 十进制");
      expect(formatContextWindowTokens(131072), "128k", reason: "128×1024");
      expect(formatContextWindowTokens(200000), "200k");
      expect(formatContextWindowTokens(32767), "33k", reason: "不可整除时四舍五入");
    });
  });

  group("F44 新增模型表项（官方文档可引用）", () {
    test("qwen 四型号 + glm-5.3-flash → 1M + modelTable", () {
      for (final m in [
        "qwen3.7-plus",
        "qwen3.7-max",
        "qwen3.8-flash",
        "qwen3.8-max",
        "glm-5.3-flash",
        "Qwen3.8-Max",
      ]) {
        expect(knownContextWindowFor(m), 1000000, reason: m);
        final info = resolveContextWindow(model: m);
        expect(info.tokens, 1000000, reason: m);
        expect(info.source, ContextWindowSource.modelTable, reason: m);
      }
    });

    test("官方抓不到的不收录：kimi / doubao 仍在兜底", () {
      expect(knownContextWindowFor("kimi-k3.1-pro"), isNull);
      expect(knownContextWindowFor("doubao-seed-2-1-pro"), isNull);
      expect(resolveContextWindow(model: "kimi-k3.1-pro").source,
          ContextWindowSource.assumed);
    });
  });

  group("F44 端点自报解析（/models）", () {
    test("五种键名都能识别；0/字符串/缺失 → null", () {
      for (final key in [
        "context_length",
        "max_model_len",
        "max_input_tokens",
        "context_window",
        "context_window_tokens",
      ]) {
        expect(
            AiClient.contextWindowFromModelEntry(<dynamic, dynamic>{
              key: 131072,
            }),
            131072,
            reason: key);
      }
      expect(
          AiClient.contextWindowFromModelEntry(
              <dynamic, dynamic>{"context_length": 0}),
          isNull);
      expect(
          AiClient.contextWindowFromModelEntry(
              <dynamic, dynamic>{"context_length": "131072"}),
          isNull);
      expect(AiClient.contextWindowFromModelEntry(<dynamic, dynamic>{}),
          isNull);
    });

    test("id 匹配优先；单条生效；多条目冲突 → null", () {
      final entries = <Map<dynamic, dynamic>>[
        {"id": "other", "context_length": 32768},
        {"id": "m1", "context_length": 1000000},
      ];
      expect(
          AiClient.pickContextWindowFromModels(
              entries: entries, model: "m1"),
          1000000,
          reason: "优先取 id 与 endpoint.model 相等的条目");
      expect(
          AiClient.pickContextWindowFromModels(
              entries: <Map<dynamic, dynamic>>[
                {"id": "m1", "max_model_len": 128000}
              ],
              model: "m1"),
          128000);
      expect(
          AiClient.pickContextWindowFromModels(
              entries: entries, model: "m2"),
          isNull,
          reason: "多个冲突不猜");
      expect(
          AiClient.pickContextWindowFromModels(
              entries: <Map<dynamic, dynamic>>[
                {"id": "m1"}
              ],
              model: "m1"),
          isNull);
    });

    test("DeepSeek /models 不返回窗口 → 仍经模型表得到 1M", () {
      final reported = AiClient.pickContextWindowFromModels(
          entries: <Map<dynamic, dynamic>>[
            {"id": "deepseek-flash"}
          ],
          model: "deepseek-flash");
      expect(reported, isNull);
      final info =
          resolveContextWindow(model: "deepseek-flash", fromEndpoint: reported);
      expect(info.tokens, 1000000);
      expect(info.source, ContextWindowSource.modelTable);
    });
  });

  group("F44 附件预算按真实上限", () {
    test("budgetLevel(100000, 1000000) 不超限；旧 32k 会超限", () {
      expect(budgetLevel(100000, 1000000), isNot(BudgetLevel.over));
      expect(budgetLevel(100000, kDefaultContextTokenLimit), BudgetLevel.over);
    });
  });

  group("面板/圆环口径", () {
    Widget wrap(Widget child) =>
        MaterialApp(home: Scaffold(body: Center(child: child)));

    testWidgets("5894 tokens + 1M → 1%（不是 18%）", (tester) async {
      await tester.pumpWidget(wrap(const ContextMeter(
        usedTokens: 5894,
        window: ContextWindowInfo(1000000, ContextWindowSource.modelTable),
      )));
      expect(find.text("1%"), findsOneWidget);
      expect(find.text("18%"), findsNothing);
    });

    // ---- F43：小于 1% 时显示 <1%，不要显示成 0% ----
    test("百分比文案四态（纯函数）", () {
      expect(contextPercentLabel(2100, 1000000), "<1%",
          reason: "0.21% 四舍五入为 0，但不能显示 0%");
      expect(contextPercentLabel(5894, 1000000), "1%");
      expect(contextPercentLabel(0, 32768), "0%", reason: "确实没用量为 0%");
      expect(contextPercentLabel(1200, 0), "0%", reason: "上限未知按 0");
      expect(contextPercentLabel(70000, 32768), "214%", reason: "超限照常显示");
    });

    testWidgets("胶囊与 sheet 都显示 <1%（不再出现 0%）", (tester) async {
      await tester.pumpWidget(wrap(const ContextMeter(
        usedTokens: 2100,
        window: ContextWindowInfo(1000000, ContextWindowSource.modelTable),
      )));
      expect(find.text("<1%"), findsOneWidget);
      expect(find.text("0%"), findsNothing);

      await tester.tap(find.byKey(const ValueKey("context-meter-pill")));
      await tester.pumpAndSettle();
      expect(find.text("上下文已用 <1%"), findsOneWidget);
      expect(find.text("上下文已用 0%"), findsNothing);
    });

    testWidgets("来源文案：模型能力表 / 估算 / 手动配置", (tester) async {
      /// 打开某个来源的 sheet：
      /// ① 先关掉上一个 case 残留的 sheet（否则 ModalBarrier/Scrim 会吃掉点击，
      ///    上一版就是因此报 “derived Offset would not hit test”）；
      /// ② tap 目标是 ContextMeter 的胶囊本体（key），不是里面那串百分比 Text。
      Future<void> openSheet(ContextWindowInfo info) async {
        if (find.byType(ModalBarrier).evaluate().isNotEmpty) {
          tester.state<NavigatorState>(find.byType(Navigator)).pop();
          await tester.pumpAndSettle();
        }
        await tester.pumpWidget(
            wrap(ContextMeter(usedTokens: 5894, window: info)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey("context-meter-pill")));
        await tester.pumpAndSettle();
      }

      await openSheet(
          const ContextWindowInfo(1000000, ContextWindowSource.modelTable));
      expect(find.textContaining("模型能力表"), findsWidgets);
      expect(find.textContaining("上限 1M"), findsWidgets);

      await openSheet(
          const ContextWindowInfo(32768, ContextWindowSource.assumed));
      expect(find.textContaining("估算"), findsWidgets);
      expect(find.textContaining("未获取到模型窗口"), findsWidgets);

      await openSheet(
          const ContextWindowInfo(200000, ContextWindowSource.configured));
      expect(find.textContaining("手动配置"), findsWidgets);
    });

    testWidgets("超限仍走红色（不因上限变大而退化）", (tester) async {
      await tester.pumpWidget(wrap(const ContextMeter(
        usedTokens: 1200000,
        window: ContextWindowInfo(1000000, ContextWindowSource.modelTable),
      )));
      expect(find.text("120%"), findsOneWidget);
    });
  });

  group("AiEndpoint.contextWindow 持久化", () {
    AiEndpoint make({int? window, int? reported}) => AiEndpoint(
          id: "e1",
          name: "接口",
          baseUrl: "https://api.example.com/v1",
          model: "deepseek-flash",
          contextWindow: window,
          contextWindowFromEndpoint: reported,
        );

    test("⑥ 缺省不写键，写入后 JSON 往返一致，copyWith 可设可清可保持", () {
      expect(make().contextWindow, isNull);
      expect(make().toJson().containsKey("contextWindow"), isFalse);

      final json = make(window: 1000000).toJson();
      expect(json["contextWindow"], 1000000);
      expect(AiEndpoint.fromJson(json).contextWindow, 1000000);

      final base = make();
      expect(base.copyWith(contextWindow: () => 200000).contextWindow, 200000);
      expect(
          make(window: 1000000).copyWith(contextWindow: () => null).contextWindow,
          isNull);
      expect(make(window: 128000).copyWith(name: "改名").contextWindow, 128000);
    });

    test("F44 contextWindowFromEndpoint：JSON 往返 + copyWith 三态", () {
      expect(make().contextWindowFromEndpoint, isNull);
      expect(
          make().toJson().containsKey("contextWindowFromEndpoint"), isFalse);

      final json = make(reported: 131072).toJson();
      expect(json["contextWindowFromEndpoint"], 131072);
      expect(AiEndpoint.fromJson(json).contextWindowFromEndpoint, 131072);

      final base = make();
      expect(
          base
              .copyWith(contextWindowFromEndpoint: () => 1000000)
              .contextWindowFromEndpoint,
          1000000);
      expect(
          make(reported: 131072)
              .copyWith(contextWindowFromEndpoint: () => null)
              .contextWindowFromEndpoint,
          isNull);
      expect(
          make(reported: 131072).copyWith(name: "改名").contextWindowFromEndpoint,
          131072);
    });
  });
}