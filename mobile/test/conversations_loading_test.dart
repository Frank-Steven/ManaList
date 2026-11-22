import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/ui/assistant/conversations_page.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/assistant_loading_indicator.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/assistant_logo.dart';

/// B43 首次加载动画（用户 2026-11-22 双重批准：T=800ms、opacity 0.35–1、200ms 延迟）。
///
/// 用 [ConversationsPageState.debugLoaderOverride] 注入可控数据闸门：
/// 不打真实网络、不用长 sleep，只推进 fake clock。
Conversation _conv(String id, {String title = '对话'}) => Conversation(
      id: id,
      title: title,
      createdAt: 1000,
      updatedAt: 1000,
    );

Widget _app(Widget home) => MaterialApp(
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: home,
    );

/// reduced-motion 注入：把 disableAnimations 打开（同 auto_scroll_title 的读取方式）。
Widget _appReducedMotion(Widget home) => MaterialApp(
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: home,
    );

void main() {
  tearDown(() {
    ConversationsPageState.debugLoaderOverride = null;
  });

  test('不透明度公式与周期：phase 0/0.5/1 → 1.00/0.35/1.00，T=800ms', () {
    expect(assistantLoadingOpacityAt(0), closeTo(1.0, 1e-9));
    expect(assistantLoadingOpacityAt(0.25), closeTo(0.675, 1e-9));
    expect(assistantLoadingOpacityAt(0.5), closeTo(0.35, 1e-9));
    expect(assistantLoadingOpacityAt(1), closeTo(1.0, 1e-9));
    expect(AssistantLoadingIndicator.period, const Duration(milliseconds: 800));
  });

  testWidgets('123ms 完成：全过程不出现加载 UI，也不闪空态', (tester) async {
    final gate = Completer<ConversationsLoadResult>();
    ConversationsPageState.debugLoaderOverride = () => gate.future;
    await tester.pumpWidget(_app(const ConversationsPage()));

    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在载入会话…'), findsNothing);
    expect(find.text('和助理一起整理你的库'), findsNothing);
    expect(find.text('新建对话'), findsNothing);
    // 加载中（含 0–200ms 窗口）不得出现任何新建引导（含 FAB）
    expect(find.byType(FloatingActionButton), findsNothing);

    gate.complete(const ConversationsLoadResult(conversations: []));
    await tester.pump(const Duration(milliseconds: 23));
    await tester.pump();
    expect(find.text('正在载入会话…'), findsNothing);
    expect(find.text('和助理一起整理你的库'), findsOneWidget);
    // 完成后恢复新建引导
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('>200ms：加载指示出现，且加载中不出现空态/新建引导', (tester) async {
    final gate = Completer<ConversationsLoadResult>();
    ConversationsPageState.debugLoaderOverride = () => gate.future;
    await tester.pumpWidget(_app(const ConversationsPage()));

    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('正在载入会话…'), findsNothing);

    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('正在载入会话…'), findsOneWidget);
    expect(find.text('和助理一起整理你的库'), findsNothing);
    expect(find.text('新建对话'), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);

    gate.complete(const ConversationsLoadResult(conversations: []));
    await tester.pump();
    expect(find.text('正在载入会话…'), findsNothing);
    expect(find.text('和助理一起整理你的库'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('完成后有会话：立即显示列表', (tester) async {
    ConversationsPageState.debugLoaderOverride = () async =>
        ConversationsLoadResult(conversations: [_conv('c1', title: '周末采购清单')]);
    await tester.pumpWidget(_app(const ConversationsPage()));
    await tester.pump();
    expect(find.text('周末采购清单'), findsOneWidget);
    expect(find.text('正在载入会话…'), findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('异常：reload future 抛出，finally 结束加载态并落到真空态', (tester) async {
    // 先用可控闸门让页面挂载、首次加载保持 pending（不产生未捕获异步错误）
    final firstGate = Completer<ConversationsLoadResult>();
    ConversationsPageState.debugLoaderOverride = () => firstGate.future;
    await tester.pumpWidget(_app(const ConversationsPage()));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('正在载入会话…'), findsOneWidget);

    final state =
        tester.state<ConversationsPageState>(find.byType(ConversationsPage));
    // 再把 loader 换成必抛：显式 await reload() 的 future 验证「不吞错」
    ConversationsPageState.debugLoaderOverride =
        () async => throw StateError('boom');
    await expectLater(state.reload(), throwsA(isA<StateError>()));
    await tester.pump();

    // finally 收尾：加载 UI 消失、落回真实空态（不是永久空白）
    expect(find.text('正在载入会话…'), findsNothing);
    expect(find.text('和助理一起整理你的库'), findsOneWidget);
    expect(find.text('新建对话'), findsOneWidget);

    // 旧闸门稍后完成：不得覆盖新状态，也不应有未捕获异步错误
    firstGate.complete(
        ConversationsLoadResult(conversations: [_conv('old', title: '旧快照')]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('旧快照'), findsNothing);
    expect(find.text('和助理一起整理你的库'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dispose 后：定时器与在途请求不再抛异常', (tester) async {
    final gate = Completer<ConversationsLoadResult>();
    ConversationsPageState.debugLoaderOverride = () => gate.future;
    await tester.pumpWidget(_app(const ConversationsPage()));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('正在载入会话…'), findsOneWidget);

    await tester.pumpWidget(_app(const SizedBox.shrink()));
    gate.complete(ConversationsLoadResult(conversations: [_conv('c1')]));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧 reload 不覆盖新快照（串行保护）', (tester) async {
    var calls = 0;
    final slow = Completer<ConversationsLoadResult>();
    ConversationsPageState.debugLoaderOverride = () {
      calls++;
      if (calls == 1) return slow.future;
      return Future<ConversationsLoadResult>.value(
          ConversationsLoadResult(conversations: [_conv('b', title: 'B 快照')]));
    };
    await tester.pumpWidget(_app(const ConversationsPage()));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('正在载入会话…'), findsOneWidget);

    final state =
        tester.state<ConversationsPageState>(find.byType(ConversationsPage));
    unawaited(state.reload());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('B 快照'), findsOneWidget);

    slow.complete(
        ConversationsLoadResult(conversations: [_conv('a', title: 'A 旧快照')]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('A 旧快照'), findsNothing);
    expect(find.text('B 快照'), findsOneWidget);
  });

  testWidgets('正常动效：400ms 时 opacity≈0.35（T/2 最低点）', (tester) async {
    await tester
        .pumpWidget(_app(const Scaffold(body: AssistantLoadingIndicator())));
    await tester.pump(const Duration(milliseconds: 400));
    final opacity = tester.widget<Opacity>(find.descendant(
      of: find.byType(AssistantLoadingIndicator),
      matching: find.byType(Opacity),
    ));
    expect(opacity.opacity, closeTo(0.35, 0.02));
  });

  testWidgets('reduced-motion：静态 opacity 1，无动画', (tester) async {
    await tester.pumpWidget(
        _appReducedMotion(const Scaffold(body: AssistantLoadingIndicator())));
    await tester.pump(const Duration(milliseconds: 400));
    final opacity = tester.widget<Opacity>(find.descendant(
      of: find.byType(AssistantLoadingIndicator),
      matching: find.byType(Opacity),
    ));
    expect(opacity.opacity, 1.0);
    expect(find.text('正在载入会话…'), findsOneWidget);
  });

  testWidgets('AssistantLogo 只缩放一次：838px 下主星有效线宽≈44px、小星≈36px', (tester) async {
    // 纯换算兜底：22×838/419 = 44；18×838/419 = 36
    expect(AssistantLogo.effectiveMainStrokePx(838), closeTo(44, 1e-9));
    expect(AssistantLogo.effectiveSmallStrokePx(838), closeTo(36, 1e-9));

    // 默认测试视口 800×600 会夹小 838px 的 LOGO；放大视口保证按 838 渲染。
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const size = 838.0;
    await tester.pumpWidget(
      // 裸 Center 没有方向上下文，Semantics 会因 label 无 textDirection 报错；
      // 这里补最小 Directionality（生产 AssistantLogo 本身不动）。
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: ValueKey('b43-logo-boundary'),
            child: AssistantLogo(color: Color(0xFF3F51B5), size: size),
          ),
        ),
      ),
    );

    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('b43-logo-boundary')));

    // toImage / toByteData 是真实异步（GPU/引擎侧），必须在 runAsync 里跑；
    // 直接 await 会在 fake async 环境挂起（曾导致整套测试超时）。
    final ui.Image? raster = await tester
        .runAsync<ui.Image>(() => boundary.toImage(pixelRatio: 1.0));
    expect(raster, isNotNull);
    final ui.Image image = raster!;
    // image.toByteData 返回 Future<ByteData?>，runAsync 泛型需与之一致（ByteData?）
    final ByteData? raw = await tester.runAsync<ByteData?>(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba));
    expect(raw, isNotNull);
    final ByteData data = raw!;

    // 以**实际光栅宽度**换算比例：838 若被测试面板夹小也不会误判；
    // 若实现把 strokeWidth 又乘了 scale，实测会是期望值的 scale 倍（838 下≈2 倍）。
    final double scale = image.width / AssistantLogo.viewBoxWidth;
    final double expectedMain = AssistantLogo.mainStarStroke * scale;
    final double expectedSmall = AssistantLogo.smallStarStroke * scale;

    // 主星左尖 viewBox (55,210)，端帽是直径 = 线宽的圆。
    final mainRun = _verticalInkRun(data,
        width: image.width,
        height: image.height,
        x: (55 * scale).round(),
        yCenter: (210 * scale).round());
    expect(mainRun, closeTo(expectedMain, 4),
        reason:
            '主星有效线宽应≈${expectedMain.toStringAsFixed(1)}px；约为其 2 倍即说明 strokeWidth 被二次缩放');

    // 小星左尖 viewBox (248,110)。
    final smallRun = _verticalInkRun(data,
        width: image.width,
        height: image.height,
        x: (248 * scale).round(),
        yCenter: (110 * scale).round());
    expect(smallRun, closeTo(expectedSmall, 4),
        reason: '小星有效线宽应≈${expectedSmall.toStringAsFixed(1)}px（二次缩放会是 2 倍）');

    image.dispose();
  });

  // ---- F45（task-45）：真实空态的图标边界（隔离 widget 补验，非真机覆盖）----

  testWidgets('F45: 真实空态用 48px 新双星（onSurfaceVariant），加载指示已消失', (tester) async {
    ConversationsPageState.debugLoaderOverride = () async =>
        const ConversationsLoadResult(conversations: <Conversation>[]);
    await tester.pumpWidget(_app(const ConversationsPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // 真空态文案（既有，未改）
    expect(find.text('和助理一起整理你的库'), findsOneWidget);
    expect(find.text('新建对话'), findsOneWidget);
    // B43 加载指示/占位都不在
    expect(find.text('正在载入会话…'), findsNothing);

    // F45：空态图标 = 新双星，恰好一个，48px，颜色跟随 onSurfaceVariant
    final logoFinder = find.byType(AssistantLogo);
    expect(logoFinder, findsOneWidget, reason: '空态只应有一个新双星');
    final logo = tester.widget<AssistantLogo>(logoFinder);
    expect(logo.size, 48, reason: '与替换前的 Icon(size: 48) 一致');
    final cs =
        Theme.of(tester.element(find.byType(ConversationsPage))).colorScheme;
    expect(logo.color, cs.onSurfaceVariant,
        reason: '空态图标颜色应跟随 colorScheme.onSurfaceVariant');
  });
}

/// 在 [x] 列上，以 [yCenter] 为中心量 alpha>32 的连续墨迹长度（量线宽用）。
int _verticalInkRun(ByteData data,
    {required int width,
    required int height,
    required int x,
    required int yCenter}) {
  int alphaAt(int y) {
    if (y < 0 || y >= height || x < 0 || x >= width) return 0;
    return data.getUint8((y * width + x) * 4 + 3);
  }

  var y = yCenter;
  if (alphaAt(y) <= 32) {
    // 端帽中心可能落在亚像素上：在 ±2px 内找有墨的起始行
    for (var dy = 1; dy <= 2; dy++) {
      if (alphaAt(yCenter + dy) > 32) {
        y = yCenter + dy;
        break;
      }
      if (alphaAt(yCenter - dy) > 32) {
        y = yCenter - dy;
        break;
      }
    }
  }
  var top = y;
  while (alphaAt(top - 1) > 32) {
    top--;
  }
  var bottom = y;
  while (alphaAt(bottom + 1) > 32) {
    bottom++;
  }
  return bottom - top + 1;
}
