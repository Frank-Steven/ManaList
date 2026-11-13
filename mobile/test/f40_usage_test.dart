import "dart:convert";
import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:msgrepo_mobile/services/ai_client.dart";
import "package:msgrepo_mobile/services/assistant/assistant_client.dart";
import "package:msgrepo_mobile/services/assistant/assistant_service.dart";
import "package:msgrepo_mobile/services/assistant/models.dart";
import "package:msgrepo_mobile/services/database.dart";
import "package:msgrepo_mobile/services/secret_store.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/context_meter.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:sqflite_common_ffi/sqflite_ffi.dart";

import "task_anchors_test.dart" show createBaseTables;

/// F40 回归（2026-11-13）：上游真实 token usage。
///
/// 覆盖：remote 请求体带 stream_options；usage chunk → ChatUsage 且不进正文；
/// 4xx 兼容性重试（只一次、第二次不带参、无 usage 不伪造）；desktop usage 帧；
/// service 暴露 lastUsage；圆环/面板真实 vs 估算口径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 本套件用真实 loopback mock server，必须还原真实网络栈。
  HttpOverrides.global = null;
  sqfliteFfiInit();

  final ai = AiClient.instance;
  final client = AssistantClient.instance;

  HttpServer? server;
  final bodies = <Map<String, dynamic>>[];

  Future<String> startServer(void Function(HttpRequest req) handler) async {
    server = await HttpServer.bind("127.0.0.1", 0);
    server!.listen(handler);
    return "http://127.0.0.1:${server!.port}";
  }

  Future<Map<String, dynamic>> readBody(HttpRequest req) async {
    final raw = await utf8.decoder.bind(req).join();
    // desktop 通道在 /v1/chat 之前会先打一次无 body 的探活请求：jsonDecode('') 会抛，
    // 且这条空请求不属于「业务请求体」，不参与 bodies 断言。
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      decoded = null;
    }
    final map = decoded is Map
        ? decoded.cast<String, dynamic>()
        : <String, dynamic>{};
    if (map.isNotEmpty) bodies.add(map);
    return map;
  }

  void sse(HttpRequest req, List<String> events) {
    req.response
      ..statusCode = 200
      ..headers.set("Content-Type", "text/event-stream; charset=utf-8");
    for (final e in events) {
      req.response.add(utf8.encode("data: $e\n\n"));
    }
    req.response.close();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AiClient.secretStore = InMemorySecretStore();
    ai.debugResetOnlineCache();
    ai.closeClient();
    client.debugReset();
    bodies.clear();
  });

  tearDown(() async {
    await server?.close(force: true);
    server = null;
    client.debugReset();
    ai.closeClient();
  });

  group("ChatUsage 模型层", () {
    test("OpenAI usage 对象 → ChatUsage（含缓存命中）", () {
      final u = ChatUsage.fromOpenAi({
        "prompt_tokens": 200,
        "completion_tokens": 40,
        "total_tokens": 240,
        "prompt_tokens_details": {"cached_tokens": 64},
      });
      expect(u.promptTokens, 200);
      expect(u.completionTokens, 40);
      expect(u.totalTokens, 240);
      expect(u.cachedPromptTokens, 64);
    });

    test("字段缺失按 0 处理，不抛", () {
      final u = ChatUsage.fromOpenAi({});
      expect(u.promptTokens, 0);
      expect(u.completionTokens, 0);
      expect(u.totalTokens, 0);
      expect(u.cachedPromptTokens, isNull);
    });

    test("desktop usage 帧可经 parseLine 还原，且 toJson 往返一致", () {
      final ev = ChatEvent.parseLine(
          '{"type":"usage","promptTokens":200,"completionTokens":40,"totalTokens":240,"cachedPromptTokens":64}');
      expect(ev, isA<ChatUsage>());
      final u = ev as ChatUsage;
      expect(u.promptTokens, 200);
      expect(u.cachedPromptTokens, 64);
      final round = ChatEvent.fromJson(u.toJson()) as ChatUsage;
      expect(round.totalTokens, 240);
    });
  });

  group("remote 通道（OpenAI 兼容）", () {
    Future<void> useRemoteEndpoint(String base) async {
      await ai.setDesktopBaseUrl("http://127.0.0.1:9"); // 视为电脑离线
      await ai.upsertEndpoint(AiEndpoint(
          id: "remote-f40", name: "F40", baseUrl: "$base/v1", model: "m1"));
    }

    test("① 请求体带 stream_options.include_usage", () async {
      final base = await startServer((req) async {
        await readBody(req);
        sse(req, [
          jsonEncode({
            "choices": [
              {
                "delta": {"content": "好"}
              }
            ]
          }),
          "[DONE]",
        ]);
      });
      await useRemoteEndpoint(base);

      await client
          .chat(conversationId: "c1", messages: const [
            ChatMessageModel(role: ChatRole.user, content: "hi"),
          ], modelConfigId: "remote-f40")
          .toList();

      expect(bodies.length, 1);
      expect(bodies.single["stream_options"], {"include_usage": true});
    });

    test("② usage chunk → ChatUsage，且正文不含 usage 文本", () async {
      final base = await startServer((req) async {
        await readBody(req);
        sse(req, [
          jsonEncode({
            "choices": [
              {
                "delta": {"content": "正文内容"}
              }
            ]
          }),
          jsonEncode({
            "choices": [],
            "usage": {
              "prompt_tokens": 200,
              "completion_tokens": 40,
              "total_tokens": 240,
              "prompt_tokens_details": {"cached_tokens": 64}
            }
          }),
          "[DONE]",
        ]);
      });
      await useRemoteEndpoint(base);

      final events = await client
          .chat(conversationId: "c2", messages: const [
            ChatMessageModel(role: ChatRole.user, content: "hi"),
          ], modelConfigId: "remote-f40")
          .toList();

      final text = events
          .whereType<ChatTokenDelta>()
          .map((e) => e.delta)
          .join();
      expect(text, "正文内容");
      expect(text.contains("240"), isFalse, reason: "usage 不得混进正文");
      final usage = events.whereType<ChatUsage>().single;
      expect(usage.promptTokens, 200);
      expect(usage.cachedPromptTokens, 64);
      expect(events.last, isA<ChatDone>());
    });

    test("③ 首次 4xx → 去掉 stream_options 重试一次；无 usage 也不伪造", () async {
      var calls = 0;
      final base = await startServer((req) async {
        await readBody(req);
        calls++;
        if (calls == 1) {
          req.response.statusCode = 400;
          req.response.write("unknown field: stream_options");
          await req.response.close();
          return;
        }
        sse(req, [
          jsonEncode({
            "choices": [
              {
                "delta": {"content": "降级成功"}
              }
            ]
          }),
          "[DONE]",
        ]);
      });
      await useRemoteEndpoint(base);

      final events = await client
          .chat(conversationId: "c3", messages: const [
            ChatMessageModel(role: ChatRole.user, content: "hi"),
          ], modelConfigId: "remote-f40")
          .toList();

      expect(calls, 2, reason: "只重试一次");
      expect(bodies.first["stream_options"], isNotNull);
      expect(bodies.last.containsKey("stream_options"), isFalse,
          reason: "重试请求必须去掉 stream_options");
      expect(events.whereType<ChatUsage>(), isEmpty,
          reason: "没有 usage 就不能伪造");
      expect(events.whereType<ChatTokenDelta>().single.delta, "降级成功");
      expect(events.last, isA<ChatDone>());
    });
  });

  group("desktop 通道", () {
    test("④ usage 帧 → ChatUsage", () async {
      final base = await startServer((req) async {
        // 探活请求（GET /v1/health，无 body）先给干净的 200，
        // 不要让它走 SSE 分支：否则探活拿到事件流、且 JSON 解析路径变脏。
        if (req.uri.path == "/v1/health") {
          req.response.statusCode = 200;
          await req.response.close();
          return;
        }
        await readBody(req);
        req.response
          ..statusCode = 200
          ..headers.set("Content-Type", "text/event-stream; charset=utf-8");
        for (final ev in [
          {"type": "token_delta", "delta": "你好"},
          {"type": "reasoning_delta", "delta": "想一想"},
          {"type": "usage", "promptTokens": 200, "completionTokens": 40, "totalTokens": 240},
          {"type": "done"},
        ]) {
          req.response.add(utf8.encode("data: ${jsonEncode(ev)}\n\n"));
        }
        await req.response.close();
      });
      await ai.setDesktopBaseUrl(base);
      await ai.setDesktopToken("tok");

      final events = await client
          .chat(conversationId: "c4", messages: const [
            ChatMessageModel(role: ChatRole.user, content: "hi"),
          ])
          .toList();

      final usage = events.whereType<ChatUsage>().single;
      expect(usage.promptTokens, 200);
      expect(usage.totalTokens, 240);
      expect(events.whereType<ChatTokenDelta>().single.delta, "你好");
    });
  });

  group("service 暴露 lastUsage", () {
    late Database db;
    final appDb = AppDatabase.instance;
    final service = AssistantService.instance;
    late AssistantClient realClient;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      AiClient.secretStore = InMemorySecretStore();
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await createBaseTables(db);
      appDb.debugAttachDatabase(db);
      realClient = service.client;
      service.client = _UsageMockClient();
      service.debugReset();
    });

    tearDown(() async {
      service.client = realClient;
      service.debugReset();
      appDb.debugDetachDatabase();
      await db.close();
    });

    test("⑤ 回合结束后 handle.lastUsage 是最新一次真实 usage", () async {
      final conv = await service.createConversation();
      final handle = service.startTurn(conversation: conv, text: "统计一下");
      await handle.events
          .firstWhere((e) => e is AssistantTurnDone || e is AssistantTurnError);
      expect(handle.lastUsage, isNotNull);
      expect(handle.lastUsage!.promptTokens, 321);
      expect(handle.lastUsage!.completionTokens, 12);
      expect(handle.lastUsage!.cachedPromptTokens, 100);
    });
  });

  group("圆环与面板口径（⑥⑦）", () {
    Widget wrap(Widget child) =>
        MaterialApp(home: Scaffold(body: Center(child: child)));

    const real = ChatUsage(
      promptTokens: 200,
      completionTokens: 40,
      totalTokens: 240,
      cachedPromptTokens: 64,
    );

    testWidgets("⑥ 有真实 usage：百分比按 promptTokens，sheet 标注真实与缓存",
        (tester) async {
      await tester.pumpWidget(wrap(const ContextMeter(
        usedTokens: 200,
        usage: real,
      )));
      expect(find.text("1%"), findsOneWidget, reason: "200/32768 ≈ 1%");
      await tester.tap(find.text("1%"));
      await tester.pumpAndSettle();

      expect(find.text("上下文已用 1%"), findsOneWidget);
      expect(find.textContaining("真实"), findsWidgets);
      expect(find.textContaining("上次请求真实输入 200 tokens"), findsOneWidget);
      expect(find.textContaining("缓存命中 64 tokens"), findsOneWidget);
      expect(find.textContaining("上限仍按 32k 估算"), findsOneWidget);
      // 真实口径下不得出现估算条目（F42 后名字是「字符估算（历史+附件）」）
      expect(find.text("字符估算（历史+附件）"), findsNothing);
      expect(find.text("附件（估算）"), findsNothing);
    });

    testWidgets("⑦ 无 usage：保持字符估算口径，不伪装真实", (tester) async {
      await tester.pumpWidget(wrap(const ContextMeter(usedTokens: 2400)));
      expect(find.text("7%"), findsOneWidget);
      await tester.tap(find.text("7%"));
      await tester.pumpAndSettle();
      // F42：估算条目名覆盖「历史+附件」全口径，说明里如实写历史已计入。
      expect(find.text("字符估算（历史+附件）"), findsOneWidget);
      expect(find.text("附件（估算）"), findsNothing);
      expect(find.textContaining("历史正文"), findsOneWidget);
      expect(find.textContaining("未计入"), findsOneWidget);
      expect(find.textContaining("对话历史未计入"), findsNothing);
      expect(find.textContaining("真实输入"), findsNothing);
    });
  });
}

/// 只回「正文 + usage + done」的假通道（测 service 的 lastUsage）。
class _UsageMockClient extends AssistantClient {
  _UsageMockClient() : super.independent();

  @override
  Stream<ChatEvent> chat({
    required String conversationId,
    required List<ChatMessageModel> messages,
    List<ChatAttachment> attachments = const [],
    String? modelConfigId,
    String? reasoning,
  }) async* {
    yield const ChatTokenDelta("收到");
    yield const ChatUsage(
      promptTokens: 321,
      completionTokens: 12,
      totalTokens: 333,
      cachedPromptTokens: 100,
    );
    yield const ChatDone();
  }

  @override
  void cancelActive() {}
}