import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/ai_client.dart';
import 'package:msgrepo_mobile/services/assistant/assistant_client.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// chat 通道（design-v3 §3.6/§6.3）：本地 mock HTTP server 验证
/// SSE 解析与路由——电脑在线走 /v1/chat（SSE data: 行），离线走对话
/// 绑定/默认的远程 OpenAI 兼容端点；断流未收 done 报 ChatError。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test 默认把 HttpClient 全部拦成 400；本套件用真实 loopback
  // mock server，必须还原真实网络栈。
  HttpOverrides.global = null;

  final ai = AiClient.instance;
  final client = AssistantClient.instance;

  HttpServer? server;
  Map<String, dynamic>? lastChatBody;

  Future<String> startServer(
      void Function(HttpRequest req) handler) async {
    server = await HttpServer.bind('127.0.0.1', 0);
    server!.listen(handler);
    return 'http://127.0.0.1:${server!.port}';
  }

  void sse(HttpRequest req, List<String> events) {
    req.response
      ..statusCode = 200
      ..headers.set('Content-Type', 'text/event-stream; charset=utf-8');
    for (final e in events) {
      req.response.add(utf8.encode('data: $e\n\n'));
    }
    req.response.close();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AiClient.secretStore = InMemorySecretStore();
    ai.debugResetOnlineCache();
    ai.closeClient();
    client.debugReset();
    lastChatBody = null;
  });

  tearDown(() async {
    await server?.close(force: true);
    server = null;
    client.debugReset();
    ai.closeClient();
  });

  test('电脑在线：POST /v1/chat，SSE token_delta/done 解析，模型 id 透传', () async {
    final base = await startServer((req) async {
      if (req.uri.path == '/v1/health') {
        req.response.statusCode = 200;
        req.response.close();
      } else if (req.uri.path == '/v1/chat') {
        lastChatBody =
            (jsonDecode(await utf8.decoder.bind(req).join()) as Map)
                .cast<String, dynamic>();
        sse(req, [
          jsonEncode({'type': 'token_delta', 'delta': '你好'}),
          jsonEncode({'type': 'token_delta', 'delta': '，世界'}),
          jsonEncode({'type': 'done'}),
        ]);
      } else {
        req.response.statusCode = 404;
        req.response.close();
      }
    });
    await ai.setDesktopBaseUrl(base);
    await ai.setDesktopToken('tok');

    final events = await client
        .chat(
          conversationId: 'conv-1',
          messages: const [
            ChatMessageModel(role: ChatRole.user, content: '说明书'),
            ChatMessageModel(role: ChatRole.user, content: '你好'),
          ],
          modelConfigId: 'local-gemma',
        )
        .toList();

    expect(events.whereType<ChatTokenDelta>().map((e) => e.delta).join(),
        '你好，世界');
    expect(events.last, isA<ChatDone>());
    expect(lastChatBody?['conversationId'], 'conv-1');
    expect(lastChatBody?['modelConfigId'], 'local-gemma');
    expect(lastChatBody?['stream'], isTrue);
    expect((lastChatBody?['messages'] as List).length, 2);
  });

  test('GET /v1/models 拉取模型列表', () async {
    final base = await startServer((req) async {
      if (req.uri.path == '/v1/models') {
        req.response
          ..statusCode = 200
          ..write(jsonEncode({
            'defaultModelId': 'local-gemma',
            'models': [
              {'id': 'local-gemma', 'name': 'Gemma 本地', 'provider': 'openai-compat',
               'baseUrl': 'http://127.0.0.1:8080/v1', 'model': 'gemma', 'reachable': true},
            ],
          }));
        req.response.close();
      } else {
        req.response.statusCode = 404;
        req.response.close();
      }
    });
    await ai.setDesktopBaseUrl(base);
    await ai.setDesktopToken('tok');

    final result = await client.getDesktopModels();
    expect(result.defaultModelId, 'local-gemma');
    expect(result.models.single.id, 'local-gemma');
    expect(result.models.single.reachable, isTrue);
  });

  test('电脑离线：走对话绑定的远程端点（OpenAI SSE）', () async {
    final base = await startServer((req) async {
      if (req.uri.path == '/v1/chat/completions') {
        lastChatBody =
            (jsonDecode(await utf8.decoder.bind(req).join()) as Map)
                .cast<String, dynamic>();
        sse(req, [
          jsonEncode({
            'choices': [
              {'delta': {'content': '远程回复'}}
            ]
          }),
          '[DONE]',
        ]);
      } else {
        req.response.statusCode = 404;
        req.response.close();
      }
    });
    // 电脑端指向一个没监听的端口 → 离线
    await ai.setDesktopBaseUrl('http://127.0.0.1:9');
    await ai.upsertEndpoint(AiEndpoint(
        id: 'remote-1', name: '测试远程', baseUrl: '$base/v1', model: 'm1'));

    final events = await client
        .chat(
          conversationId: 'conv-2',
          messages: const [
            ChatMessageModel(role: ChatRole.user, content: '说明书'),
            ChatMessageModel(role: ChatRole.tool, content: '工具结果'),
          ],
          modelConfigId: 'remote-1',
        )
        .toList();

    expect(events.whereType<ChatTokenDelta>().single.delta, '远程回复');
    expect(events.last, isA<ChatDone>());
    // tool 角色折叠为带前缀的 user 消息（与 desktop 折叠规则一致）
    final messages = lastChatBody?['messages'] as List;
    expect(messages.last['role'], 'user');
    expect(messages.last['content'] as String, contains('[工具执行结果]'));
    expect(lastChatBody?['model'], 'm1');
  });

  test('断流未收 done → ChatError（未闭合块由 tool_parser 丢弃）', () async {
    final base = await startServer((req) async {
      if (req.uri.path == '/v1/health') {
        req.response.statusCode = 200;
        req.response.close();
      } else if (req.uri.path == '/v1/chat') {
        await utf8.decoder.bind(req).join();
        sse(req, [jsonEncode({'type': 'token_delta', 'delta': '半截'})]);
      } else {
        req.response.statusCode = 404;
        req.response.close();
      }
    });
    await ai.setDesktopBaseUrl(base);
    await ai.setDesktopToken('tok');

    final events = await client
        .chat(conversationId: 'c', messages: const [
      ChatMessageModel(role: ChatRole.user, content: 'hi'),
    ]).toList();
    expect(events.whereType<ChatTokenDelta>().single.delta, '半截');
    expect(events.last, isA<ChatError>());
    expect((events.last as ChatError).error, contains('连接中断'));
  });

  test('电脑离线且未配置远程 → ChatError 提示配置', () async {
    await ai.setDesktopBaseUrl('http://127.0.0.1:9');
    final events = await client
        .chat(conversationId: 'c', messages: const [
      ChatMessageModel(role: ChatRole.user, content: 'hi'),
    ]).toList();
    expect(events.single, isA<ChatError>());
    expect((events.single as ChatError).error, contains('未配置远程'));
  });
}
