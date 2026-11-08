import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_store.dart';
import 'package:uuid/uuid.dart';

import '../services/app_log.dart';

/// 是否是「电脑端没启动 / 网络不可达」这类**预期内**的离线异常。
///
/// E03（2026-10-25）：移动端大部分时间电脑端都不在线，health 探测失败是常态而不是
/// 错误；只有这两类异常属于「离线预期」：
/// - [TimeoutException]：2s 探测超时（.timeout）；
/// - [SocketException]：连接被拒 / 主机不可达 / DNS 失败。
///   package:http 1.6 会把 socket 错误包成 `ClientException`，但其同时
///   `implements SocketException`（io_client.dart 的 _ClientSocketException），
///   所以这里按 SocketException 判断即可，不需要单独认 ClientException。
///
/// **不算离线预期**（仍要留痕，别掩盖真问题）：TLS/证书（HandshakeException）、
/// 响应解析（FormatException）、裸 ClientException（如连接被提前关闭）等。
bool isExpectedOfflineError(Object error) =>
    error is TimeoutException || error is SocketException;

/// health 探测失败时的留痕策略（E03 降噪，纯分支、便于单测）：
/// - 离线预期 → 只 debugPrint，**不写 AppLog**（否则设置页「最近错误」会被
///   `ai.health` 刷屏，用户分不清真故障）；
/// - 其余异常 → 照旧 `AppLog.instance.warn('ai.health', ...)`。
@visibleForTesting
void reportHealthProbeError(Object error, StackTrace stack) {
  if (isExpectedOfflineError(error)) {
    debugPrint('ai.health 离线（预期，不计入最近错误）：$error');
    return;
  }
  AppLog.instance.warn('ai.health', error, stack);
}

/// AI 接口配置（设计 §8.1/§9）。电脑端条目自动生成（isDesktop=true），不持久化、不可删；
/// 远程接口以 JSON 列表存 shared_preferences。
class AiEndpoint {
  final String id;
  final String name;
  final String baseUrl;
  final String apiKey;
  final String model;
  final bool isDesktop;

  /// 图像输入（多模态）三态（B11）：null = 未配置（按模型能力表推断），
  /// true = 支持，false = 用户显式关闭。
  ///
  /// 旧版本把缺省值写死成 false，无法区分「用户关闭」与「从未配置」，导致
  /// DeepSeek V4.1 Flash 1017 这类实际支持视觉的端点被误判为不支持。判定统一走
  /// services/model_capabilities.dart 的 resolveVisionSupport。
  final bool? vision;

  /// 最近一次连通性测试的失败原因（v4 批次 C 诊断共享）：
  /// 模型选择器行 / 对话页错误横幅 / 配置向导三处显示同一份；
  /// null = 上次测试成功（或从未失败）。
  final String? lastError;

  /// 最近一次测试成功的往返延迟（毫秒）；失败或从未测试时为 null。
  final int? lastLatencyMs;

  const AiEndpoint({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.apiKey = '',
    this.model = '',
    this.isDesktop = false,
    this.vision,
    this.lastError,
    this.lastLatencyMs,
  });

  factory AiEndpoint.fromJson(Map<String, dynamic> json) {
    // 兼容旧配置（B11）：旧版本 toJson 无条件写 vision（缺省 false），所以
    // 「false 且没有 visionExplicit 标记」无法区分用户关闭与从未配置 → 视为未配置，
    // 交给模型能力表推断；旧配置里存过 true 的保留为显式开启；
    // 新配置总会带 visionExplicit: true，此后 false 才是「用户显式关闭」。
    final rawVision = json['vision'];
    final explicit = json['visionExplicit'] == true;
    final bool? vision = switch (rawVision) {
      true => true,
      false => explicit ? false : null,
      _ => null,
    };
    return AiEndpoint(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      baseUrl: json['baseUrl'] as String? ?? '',
      apiKey: json['apiKey'] as String? ?? '',
      model: json['model'] as String? ?? '',
      vision: vision,
      lastError: json['lastError'] as String?,
      lastLatencyMs: json['lastLatencyMs'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        // 只有用户显式选择时才落盘，并带 visionExplicit 标记；
        // 未配置（null）时不写这两个键，读回来仍是 null。
        if (vision != null) 'vision': vision,
        if (vision != null) 'visionExplicit': true,
        if (lastError != null) 'lastError': lastError,
        if (lastLatencyMs != null) 'lastLatencyMs': lastLatencyMs,
      };

  /// [vision] 用闭包以便把值设回 null（恢复「未配置」），与 Task.copyWith 同一范式。
  /// [lastError]/[lastLatencyMs] 同理：测试成功时闭包返回 null 清掉旧诊断。
  AiEndpoint copyWith({
    String? name,
    String? baseUrl,
    String? apiKey,
    String? model,
    bool? Function()? vision,
    String? Function()? lastError,
    int? Function()? lastLatencyMs,
  }) =>
      AiEndpoint(
        id: id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        isDesktop: isDesktop,
        vision: vision != null ? vision() : this.vision,
        lastError: lastError != null ? lastError() : this.lastError,
        lastLatencyMs:
            lastLatencyMs != null ? lastLatencyMs() : this.lastLatencyMs,
      );
}

class AiException implements Exception {
  final String message;
  AiException(this.message);
  @override
  String toString() => message;
}

/// 连通性测试的结构化结果（v4 批次 C）：配置向导要模型列表做下拉，
/// 选择器要延迟做行内状态，纯文字的 testEndpoint 已不够用。
class EndpointTestResult {
  final String message;
  final List<String> modelIds;
  final int latencyMs;
  const EndpointTestResult({
    required this.message,
    this.modelIds = const [],
    required this.latencyMs,
  });
}

/// AI 基建客户端（v3）：电脑端配对 / health 探测 / 远程端点 CRUD 与连通性测试。
///
/// v2 的 /v1/process 批量评估管线（process/AiEvent/批量提示词）已随阶段 7 删除：
/// 批量评估重生为助理工具 inbox.triage（services/assistant/tools/inbox_triage.dart，
/// 提示词与解析器迁移至该文件）；对话与模型调用走 AssistantClient（/v1/chat），
/// 本类只为它提供路由/配对/HTTP 基建（clientFactory、端点列表、配对 token）。
class AiClient {
  AiClient._();

  static final AiClient instance = AiClient._();

  static const desktopEndpointId = 'desktop';
  static const desktopName = 'LinkModel 接口';
  static const defaultDesktopBaseUrl = 'http://127.0.0.1:8765';

  // 与 v1 SyncClient 共用同一组 key，旧配对 token / 地址直接兼容
  static const _keyToken = 'pair_token';
  static const _keyBaseUrl = 'base_url';
  static const _keyEndpoints = 'ai_endpoints';
  static const _keyDefaultEndpoint = 'ai_default_endpoint';
  static const _keyDeviceName = 'desktop_device_name';

  /// 凭据存储（P2-1）：key 与配对 token 走安全存储；测试可替换为内存实现。
  static SecretStore secretStore = SecureSecretStore();

  static String _secretKeyFor(String endpointId) => 'ai_key_$endpointId';

  // ---- O06：HTTP 客户端复用 ----
  //
  // 整个实例复用一个 client（连接池也跟着复用），关闭时丢弃并重建，
  // 保证任何路径都不会复用「已关闭」的实例。
  /// 客户端工厂：测试可替换以注入 fake client / 统计创建次数。
  static http.Client Function() clientFactory = () => http.Client();

  http.Client? _http;

  /// 复用的 HTTP 客户端（首次使用时创建）。
  http.Client get _client => _http ??= clientFactory();

  /// 关闭并丢弃复用的客户端（测试收尾用）；下次请求会重新创建。
  void closeClient() {
    final c = _http;
    _http = null;
    if (c != null) c.close();
  }

  // ---- 接口配置 CRUD ----

  Future<String> getDesktopBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyBaseUrl) ?? defaultDesktopBaseUrl;
  }

  Future<void> setDesktopBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyBaseUrl, url);
  }

  /// 电脑端自动条目（置顶、不可删）。
  Future<AiEndpoint> desktopEndpoint() async => AiEndpoint(
        id: desktopEndpointId,
        name: desktopName,
        baseUrl: await getDesktopBaseUrl(),
        isDesktop: true,
      );

  Future<List<AiEndpoint>> getRemoteEndpoints() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyEndpoints);
    if (json == null) return [];
    List<AiEndpoint> parsed;
    try {
      parsed = (jsonDecode(json) as List)
          .map((e) => AiEndpoint.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (e, st) {
      AppLog.instance.warn('ai.read-endpoints', e, st);
      return [];
    }

    // P2-1：密钥单独从安全存储取；同时把旧版明文 key 迁移出去。
    var migrated = false;
    final withKeys = <AiEndpoint>[];
    for (final e in parsed) {
      final stored = await secretStore.read(_secretKeyFor(e.id)) ?? '';
      final legacy = e.apiKey;
      if (legacy.isNotEmpty && stored.isEmpty) {
        await secretStore.write(_secretKeyFor(e.id), legacy);
        migrated = true;
      }
      withKeys.add(e.copyWith(apiKey: legacy.isNotEmpty ? legacy : stored));
    }
    if (migrated) {
      await _saveRemoteEndpoints(withKeys);
      AppLog.instance.warn('ai.migrate-keys',
          StateError('已把 ${withKeys.length} 个接口的明文 key 迁入安全存储'));
    }
    return withKeys;
  }

  Future<void> _saveRemoteEndpoints(List<AiEndpoint> endpoints) async {
    final prefs = await SharedPreferences.getInstance();
    // P2-1：密钥进安全存储，SharedPreferences 里只留不含 key 的配置。
    final plain = <Map<String, dynamic>>[];
    for (final e in endpoints) {
      if (e.apiKey.isNotEmpty) {
        await secretStore.write(_secretKeyFor(e.id), e.apiKey);
      } else {
        await secretStore.delete(_secretKeyFor(e.id));
      }
      plain.add(e.toJson()..remove('apiKey'));
    }
    await prefs.setString(_keyEndpoints, jsonEncode(plain));
  }

  Future<void> upsertEndpoint(AiEndpoint endpoint) async {
    final list = await getRemoteEndpoints();
    final i = list.indexWhere((e) => e.id == endpoint.id);
    if (i >= 0) {
      list[i] = endpoint;
    } else {
      list.add(endpoint);
    }
    await _saveRemoteEndpoints(list);
  }

  Future<void> deleteEndpoint(String id) async {
    if (id == desktopEndpointId) return;
    final list = await getRemoteEndpoints();
    list.removeWhere((e) => e.id == id);
    await secretStore.delete(_secretKeyFor(id));
    await _saveRemoteEndpoints(list);
    if (await getDefaultEndpointId() == id) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyDefaultEndpoint);
    }
  }

  /// 默认远程接口 id；null 表示未选（电脑端始终自动优先，不参与默认选择）。
  Future<String?> getDefaultEndpointId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDefaultEndpoint);
  }

  Future<void> setDefaultEndpointId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDefaultEndpoint, id);
  }

  Future<AiEndpoint?> defaultRemoteEndpoint() async {
    final list = await getRemoteEndpoints();
    if (list.isEmpty) return null;
    final id = await getDefaultEndpointId();
    for (final e in list) {
      if (e.id == id) return e;
    }
    return list.first;
  }

  String newEndpointId() => const Uuid().v4();

  // ---- 电脑端配对 / 探测 ----

  // P2-1：配对 token 同样是凭据，一起放进安全存储；旧值自动迁移一次。
  Future<String> getDesktopToken() async {
    final stored = await secretStore.read(_keyToken) ?? '';
    if (stored.isNotEmpty) return stored;
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(_keyToken) ?? '';
    if (legacy.isNotEmpty) {
      await secretStore.write(_keyToken, legacy);
      await prefs.remove(_keyToken);
    }
    return legacy;
  }

  Future<void> setDesktopToken(String token) async {
    await secretStore.write(_keyToken, token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyToken); // 清掉可能存在的明文旧值
  }

  /// POST /v1/pair（免认证）：无 body 取当前 token，reset=true 重新签发。
  /// 返回 (token, deviceName)。
  Future<(String, String)> pairDesktop({bool reset = false}) async {
    final baseUrl = await getDesktopBaseUrl();
    final resp = await _client
        .post(
          Uri.parse('$baseUrl/v1/pair'),
          headers: {'Content-Type': 'application/json'},
          body: reset ? '{"reset":true}' : null,
        )
        .timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) {
      throw AiException('配对失败 HTTP ${resp.statusCode}');
    }
    final data = (jsonDecode(resp.body) as Map).cast<String, dynamic>();
    final token = data['token'] as String? ?? '';
    if (token.isEmpty) throw AiException('配对响应缺少 token');
    await setDesktopToken(token);
    final deviceName = data['deviceName'] as String? ?? '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDeviceName, deviceName);
    return (token, deviceName);
  }

  /// 最近一次配对返回的电脑端设备名。
  Future<String> getDesktopDeviceName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDeviceName) ?? '';
  }

  bool? _desktopOnlineCache;
  DateTime? _desktopOnlineAt;

  /// 测试接口：清掉 30s 在线缓存（不同用例指向不同 mock server 时用）。
  @visibleForTesting
  void debugResetOnlineCache() {
    _desktopOnlineCache = null;
    _desktopOnlineAt = null;
  }

  /// 电脑端在线探测：GET /v1/health，超时 2s，结果缓存 30s（设计 §8.1）。
  Future<bool> isDesktopOnline({bool force = false}) async {
    final cachedAt = _desktopOnlineAt;
    if (!force &&
        _desktopOnlineCache != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < const Duration(seconds: 30)) {
      return _desktopOnlineCache!;
    }
    final baseUrl = await getDesktopBaseUrl();
    var ok = false;
    try {
      final resp = await _client
          .get(Uri.parse('$baseUrl/v1/health'))
          .timeout(const Duration(seconds: 2));
      ok = resp.statusCode == 200;
    } catch (e, st) {
      // E03：电脑端没启动（连不上/超时）是常态 → 只 debugPrint；其余真问题仍进 AppLog
      reportHealthProbeError(e, st);
      ok = false;
    }
    _desktopOnlineCache = ok;
    _desktopOnlineAt = DateTime.now();
    return ok;
  }

  /// 测试接口连通（旧签名，返回描述文字）；诊断落盘与结构化结果见
  /// [testEndpointDetailed]。失败抛 AiException。
  Future<String> testEndpoint(AiEndpoint endpoint) async =>
      (await testEndpointDetailed(endpoint)).message;

  /// 测试接口连通（结构化版）：电脑端打 /v1/pair（顺带刷新 token），
  /// 远程打 /v1/models 并解析模型列表、测量往返延迟。
  ///
  /// 远程端点的诊断会持久化到 [AiEndpoint.lastError]/[AiEndpoint.lastLatencyMs]
  ///（诊断共享：选择器行 / 对话错误横幅 / 配置向导读同一份）；
  /// 未保存过的端点（向导里还没落盘的临时配置）找不到记录，静默跳过。
  Future<EndpointTestResult> testEndpointDetailed(AiEndpoint endpoint) async {
    if (endpoint.isDesktop) {
      final watch = Stopwatch()..start();
      final (_, deviceName) = await pairDesktop();
      await isDesktopOnline(force: true);
      watch.stop();
      return EndpointTestResult(
        message: '已连接${deviceName.isNotEmpty ? '：$deviceName' : ''}',
        latencyMs: watch.elapsedMilliseconds,
      );
    }
    Future<AiException> fail(String message) async {
      await recordEndpointTestResult(endpoint.id, error: message);
      return AiException(message);
    }

    final hint = endpointConfigHint(endpoint.baseUrl);
    if (hint != null) throw await fail(hint);
    final headers = <String, String>{};
    if (endpoint.apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${endpoint.apiKey}';
    }
    final url = joinEndpointUrl(endpoint.baseUrl, 'models');
    final watch = Stopwatch()..start();
    final http.Response resp;
    try {
      resp = await _client
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      throw await fail('无法连接 $url：$e');
    }
    watch.stop();
    if (resp.statusCode != 200) {
      final detail = describeUpstreamError(resp.body);
      throw await fail(
          'HTTP ${resp.statusCode} @ $url${detail.isEmpty ? '' : '：$detail'}');
    }
    // 成功时把模型 id 列出来（U1/N2）：上游只校验 /models 不校验模型名，
    // 用户很容易填成版本号（如 DeepSeek-V41-Flash）导致真实调用 400。
    final ids = <String>[];
    try {
      final data = (jsonDecode(resp.body) as Map).cast<String, dynamic>();
      final list = data['data'];
      if (list is List) {
        for (final m in list) {
          if (m is Map && m['id'] is String) ids.add(m['id'] as String);
        }
      }
    } catch (e, st) { AppLog.instance.warn('ai.parse-models', e, st); }
    final latency = watch.elapsedMilliseconds;
    await recordEndpointTestResult(endpoint.id, latencyMs: latency);
    final String message;
    if (ids.isEmpty) {
      message = '连通正常';
    } else {
      final shown = ids.take(5).join('、');
      message =
          '连通正常（${ids.length} 个模型：$shown${ids.length > 5 ? '…' : ''}）';
    }
    return EndpointTestResult(
        message: message, modelIds: ids, latencyMs: latency);
  }

  /// 把一次连通性测试的诊断写到已保存的端点上；端点不存在（临时配置）时跳过。
  /// 成功：error 传 null（清掉旧失败记录）+ latencyMs；失败：error 传原因、延迟清空。
  Future<void> recordEndpointTestResult(String endpointId,
      {String? error, int? latencyMs}) async {
    final list = await getRemoteEndpoints();
    final i = list.indexWhere((e) => e.id == endpointId);
    if (i < 0) return;
    list[i] = list[i].copyWith(
      lastError: () => error,
      lastLatencyMs: () => error == null ? latencyMs : null,
    );
    await _saveRemoteEndpoints(list);
  }

  /// 拼接 baseUrl 与接口路径：去掉尾部多余斜杠，避免 `//` 之类的 404（N2 诊断）。
  static String joinEndpointUrl(String baseUrl, String path) {
    final trimmed = baseUrl.trim();
    final noTrail = trimmed.replaceAll(RegExp(r'/+$'), '');
    return noTrail.isEmpty ? path : '$noTrail/$path';
  }

  /// 从上游响应里提取人类可读的错误信息（N2）。
  ///
  /// 上游常把真正原因放在 error.message 里（如 DeepSeek 的
  /// 「The supported API model names are …」），直接截断原始 JSON 会把它切掉。
  static String describeUpstreamError(String body) {
    final text = body.trim();
    if (text.isEmpty) return '';
    try {
      final data = jsonDecode(text);
      if (data is Map) {
        final err = data['error'];
        final msg = err is Map
            ? err['message']
            : (err is String ? err : data['message']);
        if (msg is String && msg.trim().isNotEmpty) return msg.trim();
      }
    } catch (_) {
      // 预期分支：上游返回的不是 JSON（纯文本错误），下面按原文截断即可
    }
    return text.length > 240 ? '${text.substring(0, 240)}…' : text;
  }

  /// 常见配置错误的前置提示（N2）：返回 null 表示没发现明显问题。
  /// 背景：DeepSeek 同时提供两种格式——Anthropic 格式的 base_url 是
  /// https://api.deepseek.com/anthropic ，而本应用走 OpenAI 兼容的
  /// /chat/completions 与 /models；把 Anthropic 地址填进来只会得到 401/404。
  static String? endpointConfigHint(String baseUrl) {
    final b = baseUrl.trim();
    final lower = b.toLowerCase();
    if (b.isEmpty) {
      return 'Base URL 为空：请填写接口地址（如 https://api.deepseek.com）';
    }
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return 'Base URL 需以 http:// 或 https:// 开头';
    }
    if (lower.endsWith('/anthropic') || lower.contains('/anthropic/')) {
      return '该地址是 Anthropic 兼容格式（…/anthropic），而本应用使用 OpenAI 兼容格式。'
          'DeepSeek 请改为 https://api.deepseek.com（去掉 /anthropic）。';
    }
    return null;
  }
}
