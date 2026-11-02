import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../ai_client.dart';
import '../model_capabilities.dart';
import 'models.dart';

/// 组装远程（OpenAI 兼容）通道的消息序列（纯函数，便于单测）：
/// - [attachments] 非空时前置一条附件上下文 user 消息：含内联图像
///   （dataBase64）且 [vision] 时用 content parts（text + 逐图 image_url
///   data URL），否则纯文本——非 vision 模型附带图像会被端点拒绝；
/// - tool 角色折叠为带前缀的 user 消息。
/// 与 desktop buildProviderMessages（server.ts）的组装规则保持一致。
@visibleForTesting
List<Map<String, dynamic>> buildRemoteMessages(
  List<ChatMessageModel> messages, {
  List<ChatAttachment> attachments = const [],
  bool vision = false,
}) {
  final out = <Map<String, dynamic>>[];
  if (attachments.isNotEmpty) {
    final blocks = attachments.map((a) => a.content).join('\n\n');
    final intro = '以下是与本次对话相关的库内容（供引用定位）：\n\n$blocks';
    final images = vision
        ? attachments
            .where((a) => a.dataBase64 != null && a.dataBase64!.isNotEmpty)
            .toList()
        : const <ChatAttachment>[];
    if (images.isEmpty) {
      out.add({'role': 'user', 'content': intro});
    } else {
      out.add({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': intro},
          for (final a in images)
            {
              'type': 'image_url',
              'image_url': {
                'url':
                    'data:${a.mimeType ?? 'image/png'};base64,${a.dataBase64}',
              },
            },
        ],
      });
    }
  }
  for (final m in messages) {
    if (m.role == ChatRole.tool) {
      out.add({'role': 'user', 'content': '[工具执行结果]\n${m.content}'});
    } else {
      out.add({'role': m.role, 'content': m.content});
    }
  }
  return out;
}

/// desktop `GET /v1/models` 返回的一个模型条目（design-v3 §6.2）。
class DesktopModelEntry {
  final String id;
  final String name;
  final String provider;
  final String model;

  /// 连通性探测结果；null = 尚未探测。
  final bool? reachable;

  /// 视觉能力三态（B11）：优先取 desktop 上报的 effective `visionStatus`，
  /// 老版本 desktop 没有该字段时回退到 `vision` 布尔值（true=支持，其余=未确认）。
  final VisionSupport visionSupport;

  /// 兼容字段：旧调用方仍可读「是否支持」的布尔结论。
  bool get vision => visionSupport == VisionSupport.supported;

  const DesktopModelEntry({
    required this.id,
    required this.name,
    required this.provider,
    required this.model,
    this.reachable,
    VisionSupport? visionSupport,
  }) : visionSupport = visionSupport ?? VisionSupport.unknown;

  factory DesktopModelEntry.fromJson(Map<String, dynamic> json) {
    // desktop 新版本上报 visionStatus；旧版本只有 vision 布尔。
    // 旧布尔 false 无法区分「用户关闭」与「未配置」，故只把 true 当成支持，
    // 其余留给 unknown（不冒充支持，也不谎报关闭）。
    final status = parseVisionSupport(json['visionStatus'] as String?) ??
        (json['vision'] == true
            ? VisionSupport.supported
            : VisionSupport.unknown);
    return DesktopModelEntry(
      id: json['id'] as String,
      name: json['name'] as String? ?? json['id'] as String,
      provider: json['provider'] as String? ?? ModelProvider.openaiCompat,
      model: json['model'] as String? ?? '',
      reachable: json['reachable'] as bool?,
      visionSupport: status,
    );
  }
}

/// 助理对话通道（design-v3 §3.6/§5.4、details §2.4）：
/// 复用 AiClient 的路由/配对/HTTP 基建，提供 /v1/chat SSE 解析与
/// 离线远程（OpenAI 兼容）通道。
///
/// 路由策略：
/// 1. 对话绑定的 modelConfigId 命中本地远程端点 → 直连该远程端点
///    （无论电脑端是否在线——绑定远程就是明确要求走它）；
/// 2. 否则电脑端在线 → POST /v1/chat（modelConfigId 透传给 desktop 路由，
///    远程端点 id 对 desktop 无意义，置空让 desktop 用默认模型）；
/// 3. 电脑端离线 → 默认远程端点（OpenAI 兼容 /chat/completions，SSE 自行解析）。
///
/// 工具说明书由调用方（assistant_service）组装进消息序列，本类不持有说明书。
class AssistantClient {
  AssistantClient._();

  static final AssistantClient instance = AssistantClient._();

  /// 独立通道实例（inbox.triage 子调用用，details §4）：与共享 [instance]
  /// 的在途请求/取消标记互不影响——子调用在回合流中途发起，
  /// 若共用单例会踩掉主对话的 _activeClient 簿记。
  AssistantClient.independent();

  http.Client? _http;
  http.Client? _activeClient;
  bool _cancelled = false;

  http.Client get _client => _http ??= AiClient.clientFactory();

  /// 中断在途对话（已产出的事件保留，details §2.2：未闭合块整体丢弃）。
  void cancelActive() {
    _cancelled = true;
    closeClient();
  }

  void closeClient() {
    final c = _http;
    _http = null;
    _activeClient = null;
    if (c != null) c.close();
  }

  /// 测试注入：替换底层 client / 复位取消标记。
  void debugReset() {
    _cancelled = false;
    _modelsCache = null;
    _modelsCacheAt = null;
    closeClient();
  }

  // ---- 电脑端模型列表（model_picker 展示用） ----

  /// GET /v1/models；401 时自动配对一次重试。电脑端离线时抛 AiException。
  Future<({List<DesktopModelEntry> models, String? defaultModelId})>
      getDesktopModels() async {
    final ai = AiClient.instance;
    final baseUrl = await ai.getDesktopBaseUrl();
    Future<http.Response> request(String token) => _client.get(
          Uri.parse('$baseUrl/v1/models'),
          headers: {if (token.isNotEmpty) 'Authorization': 'Bearer $token'},
        );
    var resp = await request(await ai.getDesktopToken())
        .timeout(const Duration(seconds: 5));
    if (resp.statusCode == 401) {
      final (token, _) = await ai.pairDesktop();
      resp = await request(token).timeout(const Duration(seconds: 5));
    }
    if (resp.statusCode != 200) {
      throw AiException('拉取模型列表失败 HTTP ${resp.statusCode}');
    }
    final data = (jsonDecode(resp.body) as Map).cast<String, dynamic>();
    final models = ((data['models'] as List?) ?? const [])
        .map((e) => DesktopModelEntry.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    return (models: models, defaultModelId: data['defaultModelId'] as String?);
  }

  /// /v1/models 结果缓存（isVisionCapable 用）：60s TTL，
  /// 避免每个对话回合都多发一次请求。
  ({List<DesktopModelEntry> models, String? defaultModelId})? _modelsCache;
  DateTime? _modelsCacheAt;

  /// 目标模型是否支持图像输入（多模态）。路由顺序与 [chat] 一致：
  /// 1. [modelConfigId] 命中远程端点 → 该端点的 vision 配置；
  /// 2. 电脑端在线 → /v1/models 中目标模型（[modelConfigId] ?? 默认模型）的
  ///    vision（结果缓存 60s）；
  /// 3. 离线 → 默认远程端点的 vision。
  ///
  /// B11：端点/模型的 vision 只是「用户意图」，最终是否支持由
  /// [resolveVisionSupport] 结合已知模型能力表判定（未配置 + 已知模型 → 支持；
  /// 显式 false → 关闭；未知模型 → 不冒充支持）。
  /// 探测失败仍按不支持处理：不附带图像，但不阻断对话。
  Future<bool> isVisionCapable(String? modelConfigId) async {
    final ai = AiClient.instance;
    try {
      if (modelConfigId != null) {
        for (final e in await ai.getRemoteEndpoints()) {
          if (e.id == modelConfigId) {
            return visionAllowsImages(
                resolveVisionSupport(model: e.model, configured: e.vision));
          }
        }
      }
      if (await ai.isDesktopOnline()) {
        final cachedAt = _modelsCacheAt;
        if (_modelsCache == null ||
            cachedAt == null ||
            DateTime.now().difference(cachedAt) >=
                const Duration(seconds: 60)) {
          _modelsCache = await getDesktopModels();
          _modelsCacheAt = DateTime.now();
        }
        final cache = _modelsCache!;
        final targetId = modelConfigId ?? cache.defaultModelId;
        for (final m in cache.models) {
          if (m.id == targetId) return visionAllowsImages(m.visionSupport);
        }
        return false;
      }
      final endpoint = await ai.defaultRemoteEndpoint();
      if (endpoint == null) return false;
      return visionAllowsImages(
          resolveVisionSupport(model: endpoint.model, configured: endpoint.vision));
    } catch (_) {
      // 离线抖动 / 模型列表拉取失败等：按不支持处理
      return false;
    }
  }

  // ---- 对话 ----

  /// 发起一轮对话，产出 ChatEvent 流（token_delta / done / error）。
  ///
  /// [messages] 为完整请求消息序列（含说明书前言），按时间升序；
  /// [attachments] 为本轮展开后的附件上下文块（带 [#note:标题] 引用头）；
  /// [modelConfigId] 为对话绑定的模型配置（desktop 模型 id 或远程端点 id）。
  Stream<ChatEvent> chat({
    required String conversationId,
    required List<ChatMessageModel> messages,
    List<ChatAttachment> attachments = const [],
    String? modelConfigId,
  }) async* {
    _cancelled = false;
    final ai = AiClient.instance;

    // 1. 对话绑定的远程端点优先
    if (modelConfigId != null) {
      for (final e in await ai.getRemoteEndpoints()) {
        if (e.id == modelConfigId) {
          yield* _chatViaRemote(e, messages, attachments);
          return;
        }
      }
    }

    // 2. 电脑端在线 → /v1/chat
    if (await ai.isDesktopOnline()) {
      // 远程端点 id 对 desktop 无意义（上面未命中说明不是远程 id，
      // 但保险起见只在命中 desktop 模型语义时透传——未知 id 置空走默认）
      yield* _chatViaDesktop(
        conversationId: conversationId,
        messages: messages,
        attachments: attachments,
        modelConfigId: modelConfigId,
      );
      return;
    }

    // 3. 离线 → 默认远程端点
    final endpoint = await ai.defaultRemoteEndpoint();
    if (endpoint == null) {
      yield const ChatError('LinkModel 不在线且未配置远程 AI 接口（助理 → 模型配置）');
      return;
    }
    yield* _chatViaRemote(endpoint, messages, attachments);
  }

  // ---- 电脑端通道：POST /v1/chat，SSE（data: {...}） ----

  Stream<ChatEvent> _chatViaDesktop({
    required String conversationId,
    required List<ChatMessageModel> messages,
    required List<ChatAttachment> attachments,
    String? modelConfigId,
  }) async* {
    final ai = AiClient.instance;
    final baseUrl = await ai.getDesktopBaseUrl();

    http.Request buildRequest(String token) {
      final req = http.Request('POST', Uri.parse('$baseUrl/v1/chat'));
      req.headers['Content-Type'] = 'application/json';
      if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      req.body = jsonEncode({
        'conversationId': conversationId,
        'messages': [for (final m in messages) m.toJson()],
        if (attachments.isNotEmpty)
          'attachments': [for (final a in attachments) a.toJson()],
        if (modelConfigId != null) 'modelConfigId': modelConfigId,
        'stream': true,
      });
      return req;
    }

    final client = _client;
    _activeClient = client;
    try {
      var streamed = await client
          .send(buildRequest(await ai.getDesktopToken()))
          .timeout(const Duration(seconds: 15));
      if (streamed.statusCode == 401) {
        // 自动配对（沿用 /v1/process 惯例）：401 时调一次 /v1/pair 并重试
        await streamed.stream.bytesToString();
        final (token, _) = await ai.pairDesktop();
        streamed = await client
            .send(buildRequest(token))
            .timeout(const Duration(seconds: 15));
      }
      if (streamed.statusCode != 200) {
        final errBody = await streamed.stream.bytesToString();
        throw AiException('LinkModel 对话失败 HTTP ${streamed.statusCode}：$errBody');
      }
      var sawDone = false;
      await for (final line
          in _lines(streamed.stream).timeout(const Duration(seconds: 240))) {
        // SSE（data: 前缀）与裸 NDJSON 都容忍
        final payload =
            line.startsWith('data:') ? line.substring(5).trim() : line;
        if (payload.isEmpty || payload == '[DONE]') continue;
        ChatEvent ev;
        try {
          ev = ChatEvent.parseLine(payload);
        } catch (_) {
          continue; // 无法识别的行跳过，不中断流
        }
        if (ev is ChatDone) sawDone = true;
        yield ev;
      }
      if (!sawDone && !_cancelled) {
        yield const ChatError('连接中断，未收到完成事件');
      }
    } on AiException catch (e) {
      yield ChatError(e.message);
    } catch (e) {
      if (_activeClient == null || _cancelled) return; // 被 cancelActive 中断
      yield ChatError('无法连接 LinkModel：$e');
    } finally {
      if (_activeClient == client) _activeClient = null;
    }
  }

  // ---- 远程通道：OpenAI 兼容 /chat/completions，SSE 自行解析 ----

  /// [attachments] 为本轮展开后的附件上下文块；端点声明 vision 时
  /// 内联图像以 content parts 发送，否则仅文本（组装见 buildRemoteMessages）。
  Stream<ChatEvent> _chatViaRemote(AiEndpoint endpoint,
      List<ChatMessageModel> messages, List<ChatAttachment> attachments) async* {
    final hint = AiClient.endpointConfigHint(endpoint.baseUrl);
    if (hint != null) {
      yield ChatError(hint);
      return;
    }
    final url = AiClient.joinEndpointUrl(endpoint.baseUrl, 'chat/completions');
    final req = http.Request('POST', Uri.parse(url));
    req.headers['Content-Type'] = 'application/json';
    if (endpoint.apiKey.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer ${endpoint.apiKey}';
    }
    req.body = jsonEncode({
      'model': endpoint.model,
      'temperature': 0,
      'stream': true,
      'messages': buildRemoteMessages(messages,
          attachments: attachments,
          vision: visionAllowsImages(
              resolveVisionSupport(model: endpoint.model, configured: endpoint.vision))),
    });

    final client = _client;
    _activeClient = client;
    try {
      final streamed =
          await client.send(req).timeout(const Duration(seconds: 30));
      if (streamed.statusCode != 200) {
        final errBody = await streamed.stream.bytesToString();
        yield ChatError('远程接口返回 ${streamed.statusCode} @ $url：'
            '${AiClient.describeUpstreamError(errBody)}');
        return;
      }
      await for (final line
          in _lines(streamed.stream).timeout(const Duration(seconds: 180))) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') break;
        Map<String, dynamic> json;
        try {
          json = (jsonDecode(data) as Map).cast<String, dynamic>();
        } catch (_) {
          continue;
        }
        final choices = json['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final delta = (choices.first as Map)['delta'];
        final content = (delta is Map) ? delta['content'] : null;
        if (content is String && content.isNotEmpty) {
          yield ChatTokenDelta(content);
        }
      }
      yield const ChatDone();
    } catch (e) {
      if (_activeClient == null || _cancelled) return; // 被 cancelActive 中断
      yield ChatError('远程接口调用失败：$e');
    } finally {
      if (_activeClient == client) _activeClient = null;
    }
  }

  /// StreamedResponse 字节流 → utf8 分行（跨 chunk 的行缓存拼接）。
  /// 与 AiClient._lines 同算法（性能修复 O03 的版本）。
  Stream<String> _lines(http.ByteStream stream) {
    final pending = StringBuffer();
    return stream.transform(utf8.decoder).expand((chunk) {
      pending.write(chunk);
      final text = pending.toString();
      final lines = <String>[];
      var consumed = 0;
      var nl = text.indexOf('\n');
      while (nl >= 0) {
        final line = text.substring(consumed, nl).trim();
        if (line.isNotEmpty) lines.add(line);
        consumed = nl + 1;
        nl = text.indexOf('\n', consumed);
      }
      if (consumed > 0) {
        pending
          ..clear()
          ..write(text.substring(consumed));
      }
      return lines;
    });
  }
}
