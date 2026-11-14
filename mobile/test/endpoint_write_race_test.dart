import "package:flutter_test/flutter_test.dart";
import "package:msgrepo_mobile/services/ai_client.dart";
import "package:msgrepo_mobile/services/secret_store.dart";
import "package:shared_preferences/shared_preferences.dart";

/// B31 回归（2026-11-14）：端点诊断写入的并发丢失。
///
/// 背景：recordEndpointTestResult / upsertEndpoint / deleteEndpoint 都是
/// 「getRemoteEndpoints 读整表 → 改一条 → 整表写回」，并发时后写覆盖先写
///（真机：模型配置页自动测试并发测 N 个端点 → 一条诊断都没留下）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ai = AiClient.instance;

  AiEndpoint ep(String id) =>
      AiEndpoint(id: id, name: "端点$id", baseUrl: "https://$id.example.com/v1");

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AiClient.secretStore = InMemorySecretStore();
    // B31：串行队列是单例字段，必须逐用例重置（防跨 zone 的 future 泄漏）。
    AiClient.instance.debugResetEndpointWrites();
  });

  test("① 不同端点并发测：每条的诊断都留下（B31 真机现象）", () async {
    await ai.upsertEndpoint(ep("a"));
    await ai.upsertEndpoint(ep("b"));
    await ai.upsertEndpoint(ep("c"));

    // 旧实现下三个并发任务各自基于同一份旧表整表写回 → 只剩最后一条。
    await Future.wait([
      ai.recordEndpointTestResult("a", latencyMs: 11, contextWindow: 111000),
      ai.recordEndpointTestResult("b", latencyMs: 22, contextWindow: 222000),
      ai.recordEndpointTestResult("c", latencyMs: 33, contextWindow: 333000),
    ]);

    final list = await ai.getRemoteEndpoints();
    final byId = {for (final e in list) e.id: e};
    expect(byId.keys.toSet(), {"a", "b", "c"}, reason: "三条端点都不能丢");
    expect(byId["a"]!.lastLatencyMs, 11);
    expect(byId["b"]!.lastLatencyMs, 22);
    expect(byId["c"]!.lastLatencyMs, 33);
    expect(byId["a"]!.contextWindowFromEndpoint, 111000);
    expect(byId["b"]!.contextWindowFromEndpoint, 222000);
    expect(byId["c"]!.contextWindowFromEndpoint, 333000);
  });

  test("①b 同一端点并发两次：结果是一次完整的写入，不出现半截字段", () async {
    await ai.upsertEndpoint(ep("x"));
    // 注：recordEndpointTestResult 每次写「整条诊断」（不是按字段合并），
    // 所以同一端点的并发语义 = 串行后谁最后写谁生效；关键是不能读旧表写回。
    await Future.wait([
      ai.recordEndpointTestResult("x", latencyMs: 66, contextWindow: 555000),
      ai.recordEndpointTestResult("x", latencyMs: 63, contextWindow: 666000),
    ]);

    final saved = (await ai.getRemoteEndpoints()).single;
    final pairs = <List<int?>>[
      [66, 555000],
      [63, 666000],
    ];
    expect(
        pairs.any((p) =>
            p[0] == saved.lastLatencyMs &&
            p[1] == saved.contextWindowFromEndpoint),
        isTrue,
        reason: "必须是两次调用之一的完整组合（latency 与 window 成对）");
  });

  test("② 顺序调用不回归：成功写 latency+window；失败记 error 且清 latency",
      () async {
    await ai.upsertEndpoint(ep("s"));
    await ai.recordEndpointTestResult("s", latencyMs: 87, contextWindow: 128000);
    var saved = (await ai.getRemoteEndpoints()).single;
    expect(saved.lastLatencyMs, 87);
    expect(saved.contextWindowFromEndpoint, 128000);
    expect(saved.lastError, isNull);

    await ai.recordEndpointTestResult("s", error: "HTTP 500：boom");
    saved = (await ai.getRemoteEndpoints()).single;
    expect(saved.lastError, contains("500"));
    expect(saved.lastLatencyMs, isNull, reason: "失败时延迟无意义");
    // F44 决策：失败**保留**上次成功拿到的自报窗口（不抹能力信息）。
    expect(saved.contextWindowFromEndpoint, 128000);
  });

  test("③ upsertEndpoint 与 recordEndpointTestResult 并发：name 与新窗口都保留",
      () async {
    await ai.upsertEndpoint(ep("u"));
    // 先提交改名，再提交诊断：串行化后应同时保留（旧实现会互相整表覆盖）。
    await Future.wait([
      ai.upsertEndpoint(const AiEndpoint(
          id: "u", name: "改名后", baseUrl: "https://u.example.com/v1")),
      ai.recordEndpointTestResult("u", latencyMs: 41, contextWindow: 262144),
    ]);

    final saved = (await ai.getRemoteEndpoints()).single;
    expect(saved.name, "改名后");
    expect(saved.lastLatencyMs, 41);
    expect(saved.contextWindowFromEndpoint, 262144);
  });
}