import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:msgrepo_mobile/services/ai_client.dart";
import "package:msgrepo_mobile/services/context_window.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/context_meter.dart";

/// F41 回归（2026-11-13）：上下文上限「可获取」，不再硬编码 32k。
void main() {
  group("resolveContextWindow 优先级（四档 + 兜底）", () {
    test("① configured 覆盖 endpoint 覆盖模型表", () {
      final info = resolveContextWindow(
        model: "deepseek-flash",
        configured: 200000,
        fromEndpoint: 128000,
      );
      expect(info.tokens, 200000);
      expect(info.source, ContextWindowSource.configured);
    });

    test("② endpoint 覆盖模型表（configured 缺失）", () {
      final info = resolveContextWindow(
        model: "deepseek-flash",
        fromEndpoint: 128000,
      );
      expect(info.tokens, 128000);
      expect(info.source, ContextWindowSource.endpoint);
    });

    test("③ 模型表覆盖兜底", () {
      final info = resolveContextWindow(model: "deepseek-flash");
      expect(info.tokens, 1000000);
      expect(info.source, ContextWindowSource.modelTable);
    });

    test("④ 全空 → 32768 + assumed", () {
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
    AiEndpoint make({int? window}) => AiEndpoint(
          id: "e1",
          name: "接口",
          baseUrl: "https://api.example.com/v1",
          model: "deepseek-flash",
          contextWindow: window,
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
  });
}