import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:msgrepo_mobile/services/ai_client.dart';
import 'package:msgrepo_mobile/services/secret_store.dart';
import 'package:msgrepo_mobile/ui/assistant/model_setup_wizard.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 配置向导（assistant-v4-ui §5.2 / §9 验收：model_wizard_test）：
/// 模板数据完整性、失败分类建议、三步流程（模板预填 → 测连接分支 → 保存落盘）。
void main() {
  // Stepper 会把每一步的控制按钮都建进树里，用每步唯一的 Key 定位当前步按钮。
  Finder continueBtn(int step) =>
      find.byKey(ValueKey('wizard-continue-$step'));
  Finder cancelBtn(int step) => find.byKey(ValueKey('wizard-cancel-$step'));

  group('供应商模板数据', () {
    test('id 唯一、非自定义模板有 https 地址与推荐模型、自定义在最后', () {
      final ids = kProviderTemplates.map((t) => t.id).toList();
      expect(ids.toSet().length, ids.length, reason: '模板 id 不重复');
      for (final t in kProviderTemplates) {
        expect(t.name, isNotEmpty);
        expect(t.letter, isNotEmpty);
        if (!t.isCustom) {
          expect(t.baseUrl, startsWith('https://'),
              reason: '${t.name} 需要预填 https 地址');
          expect(t.suggestedModel, isNotEmpty,
              reason: '${t.name} 需要推荐模型名');
        }
      }
      expect(kProviderTemplates.last.isCustom, isTrue);
      expect(kProviderTemplates.where((t) => t.isCustom).length, 1);
    });
  });

  group('testFailureAdvice（失败分类提示）', () {
    test('401/403 → 密钥；404 → 路径；无法连接 → 网络；其余兜底', () {
      expect(testFailureAdvice('HTTP 401 @ x：bad key'), contains('密钥'));
      expect(testFailureAdvice('HTTP 403 @ x'), contains('密钥'));
      expect(testFailureAdvice('HTTP 404 @ x'), contains('路径'));
      expect(testFailureAdvice('无法连接 https://a：refused'), contains('网络'));
      expect(testFailureAdvice('HTTP 500 @ x'), contains('稍后再测'));
    });
  });

  group('三步流程（mock provider）', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      AiClient.secretStore = InMemorySecretStore();
      // B31：串行写队列是单例字段，跨 testWidgets 会残留属于旧 FakeAsync zone 的
      // 未完成 future → 本用例 await 它会永远 pending（pumpAndSettle 超时）。
      AiClient.instance.debugResetEndpointWrites();
    });

    tearDown(() {
      AiClient.clientFactory = () => http.Client();
      AiClient.instance.closeClient();
    });

    Future<void> openWizard(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showModelSetupWizard(context),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('模板预填 → 未测连接不放行 → 测通后模型下拉 → 保存落盘带诊断',
        (tester) async {
      AiClient.clientFactory = () => MockClient((req) async {
            if (req.url.path.endsWith('/models')) {
              return http.Response(
                  '{"data":[{"id":"deepseek-flash"},{"id":"deepseek-v4-pro"}]}',
                  200);
            }
            return http.Response('not found', 404);
          });
      await openWizard(tester);

      // 第一步：选 DeepSeek 模板 → 预填 baseUrl / 推荐模型 / 备注名
      await tester.tap(find.text('DeepSeek'));
      await tester.pumpAndSettle();
      await tester.tap(continueBtn(0));
      await tester.pumpAndSettle();

      // 第二步：预填的 baseUrl 可见；未测连接时「下一步」禁用
      expect(find.widgetWithText(TextField, 'https://api.deepseek.com'),
          findsOneWidget);
      expect(tester.widget<FilledButton>(continueBtn(1)).onPressed, isNull);

      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();
      expect(find.textContaining('连接成功'), findsOneWidget);
      expect(find.textContaining('2 个模型'), findsOneWidget);
      expect(tester.widget<FilledButton>(continueBtn(1)).onPressed, isNotNull,
          reason: '测通后放行');

      // 模型名变成下拉选择
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);

      await tester.tap(continueBtn(1));
      await tester.pumpAndSettle();

      // 第三步：备注名已按供应商预填（hintText 同为 'DeepSeek'，finder 会重复命中，取至少一个）；保存
      expect(find.widgetWithText(TextField, 'DeepSeek'), findsWidgets);
      await tester.tap(continueBtn(2));
      await tester.pumpAndSettle();

      // 向导退出，端点落盘：首个端点自动设为默认，诊断随保存写入
      expect(find.text('open'), findsOneWidget);
      final ai = AiClient.instance;
      final saved = (await ai.getRemoteEndpoints()).single;
      expect(saved.name, 'DeepSeek');
      expect(saved.baseUrl, 'https://api.deepseek.com');
      expect(saved.model, 'deepseek-flash');
      expect(await ai.getDefaultEndpointId(), saved.id);
      expect(saved.lastError, isNull);
      expect(saved.lastLatencyMs, isNotNull);
    });

    testWidgets('测试失败 → 分类提示 + 不放行；自定义模板可跳过但标黄未验证',
        (tester) async {
      AiClient.clientFactory = () => MockClient((req) async =>
          http.Response('{"error":{"message":"invalid api key"}}', 401));
      await openWizard(tester);

      await tester.tap(find.text('DeepSeek'));
      await tester.pumpAndSettle();
      await tester.tap(continueBtn(0));
      await tester.pumpAndSettle();

      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();
      expect(find.textContaining('401'), findsWidgets);
      expect(find.textContaining('密钥无效'), findsOneWidget);
      expect(tester.widget<FilledButton>(continueBtn(1)).onPressed, isNull,
          reason: '测试失败不放行');

      // 回第一步改选自定义 → 返回第二步：可跳过但显示「未验证」
      await tester.tap(cancelBtn(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义'));
      await tester.pumpAndSettle();
      await tester.tap(continueBtn(0));
      await tester.pumpAndSettle();
      expect(find.text('未验证'), findsOneWidget);
      expect(tester.widget<FilledButton>(continueBtn(1)).onPressed, isNotNull,
          reason: '自定义模板允许跳过测试');
    });
  });
}
