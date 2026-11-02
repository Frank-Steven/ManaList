import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/ai_client.dart';
import 'package:msgrepo_mobile/services/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// N2 诊断回归：Base URL 拼接与常见配置错误的前置提示。
/// v3 阶段 6：端点管理 UI 从设置页平移到助理页 model_picker，
/// CRUD 仍由 AiClient 承载（本文件末尾的平移回归组）。
void main() {
  group('joinEndpointUrl', () {
    test('去掉尾部斜杠，避免 //', () {
      expect(AiClient.joinEndpointUrl('https://api.deepseek.com/', 'chat/completions'),
          'https://api.deepseek.com/chat/completions');
      expect(AiClient.joinEndpointUrl('https://api.deepseek.com///', 'models'),
          'https://api.deepseek.com/models');
      expect(AiClient.joinEndpointUrl(' https://a.com/v1 ', 'models'),
          'https://a.com/v1/models');
    });
  });

  group('endpointConfigHint', () {
    test('正常的 OpenAI 兼容地址不报警', () {
      expect(AiClient.endpointConfigHint('https://api.deepseek.com'), isNull);
      expect(AiClient.endpointConfigHint('https://api.deepseek.com/v1'), isNull);
      expect(AiClient.endpointConfigHint('http://127.0.0.1:8080/v1'), isNull);
    });

    test('Anthropic 格式地址给出明确提示（真实踩过的坑）', () {
      final hint = AiClient.endpointConfigHint('https://api.deepseek.com/anthropic');
      expect(hint, isNotNull);
      expect(hint, contains('Anthropic'));
      expect(hint, contains('https://api.deepseek.com'));
      expect(
          AiClient.endpointConfigHint('https://api.deepseek.com/anthropic/v1'),
          isNotNull);
    });

    test('空地址 / 缺协议头也会提示', () {
      expect(AiClient.endpointConfigHint(''), isNotNull);
      expect(AiClient.endpointConfigHint('api.deepseek.com'), isNotNull);
    });
  });

  group('describeUpstreamError（N2）', () {
    test('优先取 error.message，而不是整段 JSON', () {
      const body = '{"error":{"message":"The supported API model names are deepseek-flash '
          'and deepseek-v4-pro","type":"invalid_request_error"}}';
      expect(AiClient.describeUpstreamError(body),
          'The supported API model names are deepseek-flash and deepseek-v4-pro');
    });

    test('没有 error 字段时退回 message 或原文', () {
      expect(AiClient.describeUpstreamError('{"message":"bad model"}'), 'bad model');
      expect(AiClient.describeUpstreamError('plain text error'), 'plain text error');
      expect(AiClient.describeUpstreamError(''), '');
    });

    test('超长非 JSON 正文按 240 字截断', () {
      final long = 'x' * 300;
      final out = AiClient.describeUpstreamError(long);
      expect(out.length, 241);
      expect(out.endsWith('…'), isTrue);
    });
  });

  group('端点 CRUD 平移回归（设置页 → model_picker，v3 阶段 6）', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      AiClient.secretStore = InMemorySecretStore();
    });

    test('upsert/默认/删除的往返不变，密钥走安全存储', () async {
      final ai = AiClient.instance;
      final e1 = AiEndpoint(
          id: ai.newEndpointId(),
          name: '远程A',
          baseUrl: 'https://a.example.com/v1',
          apiKey: 'sk-a',
          model: 'm1');
      await ai.upsertEndpoint(e1);
      await ai.setDefaultEndpointId(e1.id);

      final remotes = await ai.getRemoteEndpoints();
      expect(remotes.single.apiKey, 'sk-a', reason: '读取时从安全存储回填');
      // SharedPreferences 里不留明文 key
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('ai_endpoints'), isNot(contains('sk-a')));
      expect((await ai.defaultRemoteEndpoint())?.id, e1.id);

      await ai.deleteEndpoint(e1.id);
      expect(await ai.getRemoteEndpoints(), isEmpty);
      expect(await ai.getDefaultEndpointId(), isNull,
          reason: '删默认接口时清默认指针');
    });
  });

  // ---- B11：visual 三态的序列化与旧配置兼容 ----

  group('vision 三态（B11）', () {
    AiEndpoint make({bool? vision}) => AiEndpoint(
          id: 'e1',
          name: '远程A',
          baseUrl: 'https://a.example.com/v1',
          model: 'deepseek-v4.1-flash',
          vision: vision,
        );

    test('未配置：toJson 不写 vision/visionExplicit，读回仍是 null', () {
      final row = make().toJson();
      expect(row.containsKey('vision'), isFalse);
      expect(row.containsKey('visionExplicit'), isFalse);
      expect(AiEndpoint.fromJson(row).vision, isNull);
    });

    test('旧配置 vision:false（无 visionExplicit）→ 视为未配置，交给能力表', () {
      final restored = AiEndpoint.fromJson({
        'id': 'e1',
        'name': 'A',
        'baseUrl': 'https://a.example.com/v1',
        'model': 'deepseek-v4.1-flash',
        'vision': false,
      });
      expect(restored.vision, isNull,
          reason: '旧版本无条件写 false，无法区分用户意图，不能当成显式关闭');
    });

    test('旧配置 vision:true → 保留显式开启', () {
      final restored = AiEndpoint.fromJson({
        'id': 'e1',
        'name': 'A',
        'baseUrl': 'https://a.example.com/v1',
        'vision': true,
      });
      expect(restored.vision, isTrue);
    });

    test('新配置显式关闭（visionExplicit:true + false）→ 往返保留 false', () {
      final e = make(vision: false);
      final row = e.toJson();
      expect(row['vision'], isFalse);
      expect(row['visionExplicit'], isTrue);
      expect(AiEndpoint.fromJson(row).vision, isFalse);
    });

    test('copyWith 闭包可把显式关闭改回未配置（自动）', () {
      final off = make(vision: false);
      expect(off.copyWith(vision: () => null).vision, isNull);
      expect(off.copyWith(vision: () => true).vision, isTrue);
      expect(off.copyWith(name: 'B').vision, isFalse, reason: '不改 vision 时保持原值');
    });
  });
}