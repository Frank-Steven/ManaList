import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/ai_client.dart';
import 'package:msgrepo_mobile/services/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// P2-1 回归：API key 与配对 token 不得以明文留在 SharedPreferences。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemorySecretStore secrets;

  setUp(() {
    secrets = InMemorySecretStore();
    AiClient.secretStore = secrets;
    SharedPreferences.setMockInitialValues({});
  });

  test('保存接口后：prefs 里没有 apiKey，安全存储里有', () async {
    const ep = AiEndpoint(
      id: 'e1',
      name: '大肥鱼',
      baseUrl: 'https://api.deepseek.com',
      apiKey: 'sk-secret-123',
      model: 'deepseek-flash',
    );
    await AiClient.instance.upsertEndpoint(ep);

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('ai_endpoints') ?? '';
    expect(raw, isNot(contains('sk-secret-123')), reason: '明文 key 不得进 prefs');

    expect(await secrets.read('ai_key_e1'), 'sk-secret-123');

    final back = await AiClient.instance.getRemoteEndpoints();
    expect(back.single.apiKey, 'sk-secret-123', reason: '读出来要能还原 key');
    expect(back.single.model, 'deepseek-flash');
  });

  test('旧版明文 key 会迁移到安全存储并从 prefs 移除', () async {
    SharedPreferences.setMockInitialValues({
      'ai_endpoints': jsonEncode([
        {
          'id': 'legacy',
          'name': '旧接口',
          'baseUrl': 'https://x.test/v1',
          'apiKey': 'sk-legacy-xyz',
          'model': 'm1',
        },
      ]),
    });

    final list = await AiClient.instance.getRemoteEndpoints();
    expect(list.single.apiKey, 'sk-legacy-xyz');
    expect(await secrets.read('ai_key_legacy'), 'sk-legacy-xyz');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ai_endpoints'), isNot(contains('sk-legacy-xyz')));
  });

  test('删除接口会一并清掉安全存储里的 key', () async {
    await AiClient.instance.upsertEndpoint(const AiEndpoint(
      id: 'e2',
      name: 'x',
      baseUrl: 'https://x.test',
      apiKey: 'sk-e2',
      model: 'm',
    ));
    expect(await secrets.read('ai_key_e2'), 'sk-e2');
    await AiClient.instance.deleteEndpoint('e2');
    expect(await secrets.read('ai_key_e2'), isNull);
  });

  test('配对 token 也走安全存储，且旧明文值被清理', () async {
    SharedPreferences.setMockInitialValues({'pair_token': 'legacy-token'});
    expect(await AiClient.instance.getDesktopToken(), 'legacy-token');
    expect(await secrets.read('pair_token'), 'legacy-token');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('pair_token'), isNull, reason: '迁移后应清除明文');

    await AiClient.instance.setDesktopToken('new-token');
    expect(await AiClient.instance.getDesktopToken(), 'new-token');
    expect(prefs.getString('pair_token'), isNull);
  });
}
