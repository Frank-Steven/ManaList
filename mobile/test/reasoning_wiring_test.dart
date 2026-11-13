import "package:flutter_test/flutter_test.dart";
import "package:msgrepo_mobile/services/ai_client.dart";
import "package:msgrepo_mobile/services/assistant/models.dart";
import "package:msgrepo_mobile/ui/assistant/model_setup_wizard.dart"
    show reasoningWizardHint;

/// F35 回归（2026-11-13）：推理强度的**模型/事件层**接线。
///
/// 请求体分支（reasoning_effort 发不发）在 assistant_client 的私有方法里，
/// 按任务口径「不可测就别硬改生产结构」→ 这里只覆盖：
/// ① ChatEvent.parseLine 解析 reasoning_delta（且与 token_delta 不串）；
/// ② AiEndpoint.reasoning 的 JSON 往返 / 缺省 null / copyWith 清空；
/// ③ 常量与向导说明文案（UI 侧的档位含义）。
void main() {
  group("ChatEvent.parseLine（reasoning_delta）", () {
    test("解析 reasoning_delta → ChatReasoningDelta", () {
      final ev = ChatEvent.parseLine(
          '{"type":"reasoning_delta","delta":"先算一下单价"}');
      expect(ev, isA<ChatReasoningDelta>());
      expect((ev as ChatReasoningDelta).delta, "先算一下单价");
    });

    test("reasoning_delta 与 token_delta 不互相串台", () {
      final token = ChatEvent.parseLine('{"type":"token_delta","delta":"正文"}');
      final reasoning =
          ChatEvent.parseLine('{"type":"reasoning_delta","delta":"思考"}');
      expect(token, isA<ChatTokenDelta>());
      expect(reasoning, isA<ChatReasoningDelta>());
      expect((token as ChatTokenDelta).delta, "正文");
    });

    test("toJson 往返保持类型与内容", () {
      const ev = ChatReasoningDelta("推理片段");
      final round = ChatEvent.fromJson(ev.toJson());
      expect(round, isA<ChatReasoningDelta>());
      expect((round as ChatReasoningDelta).delta, "推理片段");
    });

    test("未知类型仍抛 FormatException（回归保护）", () {
      expect(() => ChatEvent.parseLine('{"type":"nope"}'),
          throwsFormatException);
    });
  });

  group("AiEndpoint.reasoning（持久化）", () {
    AiEndpoint make({String? reasoning}) => AiEndpoint(
          id: "e1",
          name: "接口",
          baseUrl: "https://api.example.com/v1",
          model: "m1",
          reasoning: reasoning,
        );

    test("缺省为 null 且 toJson 不写 reasoning 键", () {
      final json = make().toJson();
      expect(make().reasoning, isNull);
      expect(json.containsKey("reasoning"), isFalse);
    });

    test("high 落盘并可从 JSON 读回", () {
      final json = make(reasoning: "high").toJson();
      expect(json["reasoning"], "high");
      final back = AiEndpoint.fromJson(json);
      expect(back.reasoning, "high");
    });

    test("off 也照原样落盘（显式关闭 ≠ 未配置）", () {
      final back = AiEndpoint.fromJson(make(reasoning: "off").toJson());
      expect(back.reasoning, AiEndpoint.reasoningOff);
    });

    test("旧配置（无 reasoning 键）读回 null", () {
      final back = AiEndpoint.fromJson({
        "id": "old",
        "name": "旧接口",
        "baseUrl": "https://old.example.com/v1",
      });
      expect(back.reasoning, isNull);
    });

    test("copyWith 可设置、可清回 null，未传则保持", () {
      final base = make();
      expect(base.copyWith(reasoning: () => "medium").reasoning, "medium");
      expect(
          make(reasoning: "high").copyWith(reasoning: () => null).reasoning,
          isNull);
      expect(make(reasoning: "low").copyWith(name: "改名").reasoning, "low");
    });

    test("档位常量与下拉选项一致", () {
      expect(AiEndpoint.reasoningOff, "off");
      expect(AiEndpoint.reasoningLevels,
          ["off", "low", "medium", "high"]);
      expect(AiEndpoint.reasoningLevels.contains(AiEndpoint.reasoningOff),
          isTrue);
    });
  });

  group("reasoningWizardHint（向导文案）", () {
    test("null / off / 具体档位 三种文案各不相同且点明是否发送", () {
      final auto = reasoningWizardHint(null);
      final off = reasoningWizardHint(AiEndpoint.reasoningOff);
      final high = reasoningWizardHint("high");

      expect(auto.contains("不发送"), isTrue);
      expect(off.contains("不发送"), isTrue);
      expect(high.contains("reasoning_effort"), isTrue);
      expect(high.contains("high"), isTrue);
      expect({auto, off, high}.length, 3);
    });
  });
}