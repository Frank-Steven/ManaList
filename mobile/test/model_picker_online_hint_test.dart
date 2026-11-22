import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:msgrepo_mobile/services/ai_client.dart";
import "package:msgrepo_mobile/services/assistant/assistant_client.dart";
import "package:msgrepo_mobile/services/secret_store.dart";
import "package:msgrepo_mobile/ui/assistant/model_picker.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/assistant_logo.dart";
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
    // 关键：AssistantClient 会把 http.Client 与 /v1/models 结果缓存进单例。
    // 不复位的话，本文件里先跑的用例创建的 MockClient 会被后面的用例复用，
    // 导致桌面模型列表恒为空（模型行不渲染）。
    AssistantClient.instance.debugReset();
  });

  tearDown(() {
    AiClient.clientFactory = () => http.Client();
    AiClient.instance.closeClient();
    AiClient.instance.debugResetOnlineCache();
    AssistantClient.instance.debugReset();
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

  testWidgets("在线：显示「模型由 LinkModel 管理」，同样不出现 Closure:", (tester) async {
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

  // ---- F45（task-45）：桌面模型行的图标边界（隔离 widget 补验，非真机覆盖）----

  /// 在线 + 一条可探测的桌面模型；桌面 `GET /v1/models` 的字段按
  /// `assistant_client.dart` 的 DesktopModelEntry.fromJson 组装。
  void mockOnlineWithOneModel() {
    AiClient.clientFactory = () => MockClient((req) async {
          if (req.url.path == '/v1/health') {
            return http.Response('ok', 200);
          }
          if (req.url.path == '/v1/models') {
            // http.Response(String) 默认按 latin-1 编码 body，含中文会抛
            // 「Invalid argument (string): Contains invalid characters」。
            // 这里显式 UTF-8 字节 + charset 头，模拟真实桌面端的 JSON 响应。
            return http.Response.bytes(
                utf8.encode(jsonEncode(<String, Object?>{
                  'defaultModelId': 'm-1',
                  'models': <Map<String, Object?>>[
                    <String, Object?>{
                      'id': 'm-1',
                      'name': '测试模型甲',
                      'provider': 'openaiCompat',
                      'model': 'gpt-x',
                      'reachable': true,
                    },
                  ],
                })),
                200,
                headers: <String, String>{
                  'content-type': 'application/json; charset=utf-8',
                });
          }
          return http.Response('not found', 404);
        });
  }

  Finder desktopModelTile() => find
      .ancestor(
        of: find.textContaining('测试模型甲'),
        matching: find.byType(ListTile),
      )
      .first;

  /// 装载页面并**轮询等待**桌面模型行出现（_load 是 initState 里的多段 await，
  /// 单次 pumpAndSettle 不保证已经 setState 完）。
  Future<void> pumpPickerUntilModelRow(WidgetTester tester,
      {bool selectionMode = false}) async {
    await tester.pumpWidget(
        MaterialApp(home: ModelPickerPage(selectionMode: selectionMode)));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.textContaining('测试模型甲').evaluate().isNotEmpty) return;
    }
  }

  testWidgets('F45: 桌面模型行（浏览态）用 24px 新双星，不出 radio', (tester) async {
    mockOnlineWithOneModel();
    await pumpPickerUntilModelRow(tester);

    expect(find.textContaining('模型列表拉取失败'), findsNothing,
        reason: 'mock 应返回 200 的模型列表，不得走错误分支');
    expect(find.textContaining('测试模型甲'), findsWidgets, reason: '桌面模型行应渲染出来');
    final tile = desktopModelTile();
    expect(tile, findsOneWidget);

    final logoInTile =
        find.descendant(of: tile, matching: find.byType(AssistantLogo));
    expect(logoInTile, findsOneWidget, reason: '浏览态该行 leading 应换成新双星');
    final logo = tester.widget<AssistantLogo>(logoInTile);
    expect(logo.size, 24, reason: '桌面模型行图标 24px');
    final cs =
        Theme.of(tester.element(find.byType(ModelPickerPage))).colorScheme;
    expect(logo.color, cs.onSurfaceVariant,
        reason: '桌面模型行图标颜色应跟随 onSurfaceVariant');

    expect(
        find.descendant(
            of: tile, matching: find.byIcon(Icons.radio_button_off)),
        findsNothing);
    expect(
        find.descendant(
            of: tile, matching: find.byIcon(Icons.radio_button_checked)),
        findsNothing,
        reason: '浏览态不应出现 radio（radio 只在 selectionMode）');
  });

  testWidgets('F45: selectionMode 下该行仍是 radio（未选中=off），不出现新双星', (tester) async {
    mockOnlineWithOneModel();
    await pumpPickerUntilModelRow(tester, selectionMode: true);

    expect(find.textContaining('模型列表拉取失败'), findsNothing,
        reason: 'mock 应返回 200 的模型列表，不得走错误分支');
    final tile = desktopModelTile();
    expect(tile, findsOneWidget);
    // 当前模型不是 m-1 → 未选中态 radio_button_off
    expect(
        find.descendant(
            of: tile, matching: find.byIcon(Icons.radio_button_off)),
        findsOneWidget,
        reason: 'selectionMode 未选中行必须是 radio_button_off');
    expect(find.descendant(of: tile, matching: find.byType(AssistantLogo)),
        findsNothing,
        reason: 'selectionMode 行不得出现新双星');
  });
}
