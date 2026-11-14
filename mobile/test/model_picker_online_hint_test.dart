import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:msgrepo_mobile/services/ai_client.dart";
import "package:msgrepo_mobile/services/secret_store.dart";
import "package:msgrepo_mobile/ui/assistant/model_picker.dart";
import "package:shared_preferences/shared_preferences.dart";

/// B25 回归（2026-11-14）：模型配置页把函数对象当变量插值，UI 渲染出
/// `Closure: (bool) => String from Function 'onlineStatusHint':.(online)`。
///
/// 修法只改插值写法（`$name(args)` → `${name(args)}`），文案仍来自
/// 既有 `onlineStatusHint(bool)`；这里从页面层断言「离线/在线」文案出现、
/// 且任何地方都不再出现 `Closure:`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AiClient.secretStore = InMemorySecretStore();
    AiClient.instance.debugResetOnlineCache();
    AiClient.instance.debugResetEndpointWrites();
  });

  tearDown(() {
    AiClient.clientFactory = () => http.Client();
    AiClient.instance.closeClient();
    AiClient.instance.debugResetOnlineCache();
  });

  Future<void> pumpPicker(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: ModelPickerPage()));
    await tester.pumpAndSettle();
  }

  testWidgets("离线：显示「离线」，不出现 Closure: 源码串", (tester) async {
    // 探活 / 模型列表都失败 → 视为电脑离线（不需要真实网络）。
    AiClient.clientFactory =
        () => MockClient((req) async => http.Response("offline", 503));

    await pumpPicker(tester);

    expect(find.textContaining("离线"), findsWidgets,
        reason: "在线状态行必须显示既有 onlineStatusHint(false) 的文案");
    expect(find.textContaining("Closure:"), findsNothing,
        reason: "B25：不得再把函数对象插值成源码串");
    expect(find.textContaining("onlineStatusHint"), findsNothing);
  });

  testWidgets("在线：显示「模型由 LinkModel 管理」，同样不出现 Closure:",
      (tester) async {
    AiClient.clientFactory = () => MockClient((req) async {
          if (req.url.path == "/v1/health") {
            return http.Response("ok", 200);
          }
          if (req.url.path == "/v1/models") {
            return http.Response(
                jsonEncode({"defaultModelId": null, "models": []}), 200);
          }
          return http.Response("not found", 404);
        });

    await pumpPicker(tester);

    expect(find.textContaining("模型由 LinkModel 管理"), findsWidgets);
    expect(find.textContaining("Closure:"), findsNothing);
  });
}