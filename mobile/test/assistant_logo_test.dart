import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/assistant_logo.dart';

/// F45（2026-11-22，KIMI task-39）：把助手入口统一换成新双星。
///
/// 锁定四件事：
/// 1. 颜色解析优先级：显式 `color` > `IconTheme` > 主题 `colorScheme.primary`；
/// 2. 放进 `NavigationDestination` 时随选中/未选中（IconTheme）变色，且语义只播报一次；
/// 3. 24 / 48 两种尺寸按 viewBox 比例换算高度；
/// 4. 五个入口都已替换、旧图标（radio / 用户 / 系统）保持不变、源码里不再有旧机器人图标。
///
/// 颜色断言用**真实光栅采样**（同 B43 的做法）：取不透明像素里出现最多的颜色，
/// 比读私有 painter 字段更贴近用户实际看到的像素。
const ValueKey<String> _boundaryKey = ValueKey<String>('f45-logo-boundary');

/// 把 [logo] 光栅化，返回不透明像素中出现次数最多的颜色。
Future<Color?> _dominantInkColor(WidgetTester tester, Widget logo) async {
  tester.view.physicalSize = const Size(240, 240);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: RepaintBoundary(key: _boundaryKey, child: logo),
      ),
    ),
  );
  await tester.pump();
  return _sampleBoundary(tester);
}

/// 采样当前已挂载的 `_boundaryKey` 边界内的主色（供导航场景复用）。
Future<Color?> _sampleBoundary(WidgetTester tester) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_boundaryKey));
  // toImage/toByteData 是真实异步，必须在 runAsync 里（fake async 会挂起）。
  final ui.Image? raster =
      await tester.runAsync<ui.Image>(() => boundary.toImage(pixelRatio: 1.0));
  expect(raster, isNotNull, reason: '光栅化失败');
  final ui.Image image = raster!;
  final ByteData? raw = await tester.runAsync<ByteData?>(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba));
  expect(raw, isNotNull, reason: '读取像素失败');
  final ByteData data = raw!;

  final counts = <int, int>{};
  for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
    if (data.getUint8(i + 3) < 200) continue;
    final rgb = (data.getUint8(i) << 16) |
        (data.getUint8(i + 1) << 8) |
        data.getUint8(i + 2);
    counts[rgb] = (counts[rgb] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  final best = counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  return Color(0xFF000000 | best);
}

void _expectInk(Color? actual, Color expected, String reason) {
  expect(actual, isNotNull, reason: reason);
  final a = actual!;
  expect((a.r - expected.r).abs(), lessThanOrEqualTo(0.05),
      reason: '$reason（R ${a.r} vs ${expected.r}）');
  expect((a.g - expected.g).abs(), lessThanOrEqualTo(0.05),
      reason: '$reason（G ${a.g} vs ${expected.g}）');
  expect((a.b - expected.b).abs(), lessThanOrEqualTo(0.05),
      reason: '$reason（B ${a.b} vs ${expected.b}）');
}

/// 底部导航同款外壳（4 个 destination，助理在索引 2）。
Widget _navHarness({required int selectedIndex}) => MaterialApp(
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: Scaffold(
        bottomNavigationBar: NavigationBar(
          selectedIndex: selectedIndex,
          destinations: const <NavigationDestination>[
            NavigationDestination(
                icon: Icon(Icons.inventory_2_outlined), label: '库'),
            NavigationDestination(
                icon: Icon(Icons.check_circle_outline), label: '任务'),
            NavigationDestination(
              icon: ExcludeSemantics(
                child: RepaintBoundary(
                  key: _boundaryKey,
                  // 与 main.dart 的生产用法一致（B45：24dp 槽位 2dp 描边）。
                  child: AssistantLogo(size: 24, strokeDp: 2),
                ),
              ),
              label: '助理',
            ),
            NavigationDestination(
                icon: Icon(Icons.settings_outlined), label: '设置'),
          ],
        ),
      ),
    );

/// 把 [directory] 下所有 .dart 拼成一个大字符串，供源码扫描断言用。
String _readDartSources(String directory) {
  final root = Directory(directory);
  expect(root.existsSync(), isTrue, reason: '目录不存在：$directory');
  final buffer = StringBuffer();
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      buffer.writeln(entity.readAsStringSync());
    }
  }
  return buffer.toString();
}

void main() {
  testWidgets('F45: 未传 color 时跟随 IconTheme（导航选中/未选中会变色）', (tester) async {
    const iconColor = Color(0xFF00C853);
    final inherited = await _dominantInkColor(
      tester,
      const IconTheme(
        data: IconThemeData(color: iconColor),
        child: AssistantLogo(size: 48),
      ),
    );
    _expectInk(inherited, iconColor, '未传 color 时应取 IconTheme.color');

    // 导航里：索引 2 → 助理选中；索引 0 → 助理未选中。两者颜色必须不同。
    await tester.pumpWidget(_navHarness(selectedIndex: 0));
    await tester.pump();
    final unselected = await _sampleBoundary(tester);
    await tester.pumpWidget(_navHarness(selectedIndex: 2));
    await tester.pump();
    final selected = await _sampleBoundary(tester);
    expect(unselected, isNotNull, reason: '导航未选中态应有可见描边');
    expect(selected, isNotNull, reason: '导航选中态应有可见描边');
    expect(selected, isNot(equals(unselected)),
        reason: '选中/未选中应随 NavigationBar 的 IconTheme 变色');
  });

  testWidgets('F45: 显式 color 优先于 IconTheme', (tester) async {
    const explicit = Color(0xFF1565C0);
    final ink = await _dominantInkColor(
      tester,
      const IconTheme(
        data: IconThemeData(color: Color(0xFFD50000)),
        child: AssistantLogo(size: 48, color: explicit),
      ),
    );
    _expectInk(ink, explicit, '显式 color 必须优先于 IconTheme');
  });

  testWidgets('F45: 未传 color 时解析值 = IconTheme.of().color（先读实际值再比对像素）',
      (tester) async {
    // 源码事实（flutter/src/widgets/icon_theme.dart:64-84 与 icon_theme_data.dart:51-60）：
    // IconTheme.of(context) 会把 null 字段用 IconThemeData.fallback() 兜底，而
    // fallback 的 color 是 0xFF000000 —— 所以 `IconTheme.of(context).color` **永远不会是 null**，
    // 生产链里 `?? colorScheme.primary` 那一级在有任何 IconTheme 祖先时不可达。
    // 因此本用例不再假设「primary 会生效」，而是：先在同一子树读**真实解析值**，
    // 再断言光栅颜色必须等于它（断言没有被放宽，只是对齐事实）。
    final scheme = ColorScheme.fromSeed(seedColor: Colors.teal);
    late BuildContext probe;
    await tester.pumpWidget(
      // 裸 Theme 没有方向上下文；AssistantLogo 自带 Semantics(label)，
      // 缺 textDirection 会直接抛断言。这里补最小 Directionality，
      // 不改变被测组件与任何颜色断言。
      Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: ThemeData(colorScheme: scheme),
          child: IconTheme(
            // 显式「无色」的 IconTheme，模拟唯一可能接近 null 的环境。
            data: const IconThemeData(),
            child: Builder(
              builder: (BuildContext context) {
                probe = context;
                return const Center(
                  child: RepaintBoundary(
                    key: _boundaryKey,
                    child: AssistantLogo(size: 48),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final Color? ambient = IconTheme.of(probe).color;
    final Color primary = Theme.of(probe).colorScheme.primary;
    // 1) 证明解析值非 null（fallback 兜底），这就是「primary 那一级不可达」的依据。
    expect(ambient, isNotNull,
        reason: 'IconTheme.of().color 由 IconThemeData.fallback() 兜底，不应为 null');
    // 2) 并证明它确实不等于主题 primary —— 否则本用例就是在误测 primary。
    expect(ambient, isNot(equals(primary)),
        reason: '有 IconTheme 兜底色时不应取到 colorScheme.primary');

    final ink = await _sampleBoundary(tester);
    _expectInk(ink, ambient!, '未传 color 时光栅色必须等于 IconTheme 解析值');
  });

  testWidgets('F45: 24/48 两种尺寸按 viewBox 比例换算高度', (tester) async {
    for (final size in <double>[24, 48]) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: AssistantLogo(size: size)),
        ),
      );
      await tester.pump();
      final measured = tester.getSize(find.byType(AssistantLogo));
      expect(measured.width, size, reason: '宽度必须精确等于传入 size');
      expect(measured.height, closeTo(size / AssistantLogo.aspectRatio, 0.01),
          reason: '高度按 419:405 比例换算');
    }
  });

  testWidgets('F45: 导航里 destination label 真实存在，且 LOGO 不重复播报', (tester) async {
    // 语义句柄必须在**测试体内**释放：addTearDown 在 flutter_test 的
    // "SemanticsHandle active" 校验之后执行，会报未释放。这里用 try/finally。
    final handle = tester.ensureSemantics();
    try {
      // 1) 独立使用：LOGO 自己播报「助理」。
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: AssistantLogo(size: 48)),
        ),
      );
      await tester.pump();
      // M3 NavigationBar 的 destination label 会被 MergeSemantics 合并，label 里可能还带
      // 「Tab 3 of 4」之类后缀，所以这里用 RegExp 匹配「包含助理」而不是精确相等。
      expect(find.bySemanticsLabel(RegExp('助理')), findsOneWidget,
          reason: '独立使用时 LOGO 自带 label「助理」');

      // 2) 放进真实 NavigationBar。
      await tester.pumpWidget(_navHarness(selectedIndex: 2));
      await tester.pumpAndSettle();

      // 2a) 标签 widget 真的渲染出来（与语义管线无关的独立事实）。
      expect(find.text('助理'), findsOneWidget, reason: '导航必须渲染「助理」标签');

      // 2b) 该 Text 所在语义节点必须真的携带「助理」（读节点本身，不靠 finder 猜）。
      final SemanticsNode labelNode = tester.getSemantics(find.text('助理'));
      expect(labelNode.label, contains('助理'),
          reason: '真实语义节点应携带「助理」标签，实际为「${labelNode.label}」');

      // 2c) 全语义树里「助理」只出现一份：LOGO 被 ExcludeSemantics 排除，不叠加播报。
      expect(find.bySemanticsLabel(RegExp('助理')), findsOneWidget,
          reason: '「助理」在语义树里应只有 1 个节点（导航 label），LOGO 不得再播报一次');

      // 2d) 结构性证明：导航里的 LOGO 确实包在 ExcludeSemantics 里。
      expect(
        find.ancestor(
          of: find.byType(AssistantLogo),
          matching: find.byType(ExcludeSemantics),
        ),
        findsWidgets,
        reason: '导航 LOGO 必须有 ExcludeSemantics 祖先',
      );
    } finally {
      handle.dispose();
    }
  });

  testWidgets('F45: 五个入口都换成新双星，旧图标不动', (tester) async {
    // 旧机器人图标的字面量用**相邻字面量拼接**（编译期常量）：运行期值是完整图标名，
    // 但源码里两个字面量之间隔着引号与空白，不会出现连续的那串字符，
    // 因此本文件自身也不会被下面的扫描命中。
    const legacyIcon = 'smart' '_toy';
    expect(_readDartSources('lib'), isNot(contains(legacyIcon)),
        reason: 'lib 下不应再有旧的机器人图标字面量');
    expect(_readDartSources('test'), isNot(contains(legacyIcon)),
        reason: 'test 下不应再有旧的机器人图标字面量');

    const assistantLogoUsages = <String>[
      'lib/main.dart',
      'lib/ui/assistant/conversations_page.dart',
      'lib/ui/assistant/chat_page.dart',
      'lib/ui/assistant/model_picker.dart',
      'lib/ui/recent_ops_page.dart',
    ];
    for (final path in assistantLogoUsages) {
      final source = File(path).readAsStringSync();
      expect(source, contains('AssistantLogo('),
          reason: '$path 应使用 AssistantLogo');
    }

    // 旧图标保留：模型选择仍是 radio，最近操作仍是 用户/系统 两个图标。
    final modelPicker =
        File('lib/ui/assistant/model_picker.dart').readAsStringSync();
    expect(modelPicker, contains('Icons.radio_button_checked'));
    expect(modelPicker, contains('Icons.radio_button_off'));
    expect(modelPicker, contains('widget.selectionMode'));

    final recentOps = File('lib/ui/recent_ops_page.dart').readAsStringSync();
    expect(recentOps, contains('Icons.person_outline'));
    expect(recentOps, contains('Icons.settings_suggest_outlined'));
  });

  // ---- B45（task-62）：导航 2dp 描边的接线与尺寸/语义回归（隔离 widget 补验）----

  testWidgets('B45: 导航入口实际传 strokeDp=2，24dp 尺寸/不传色/单份语义不变',
      (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(_navHarness(selectedIndex: 2));
      await tester.pumpAndSettle();

      final navLogoFinder = find.descendant(
          of: find.byType(NavigationBar), matching: find.byType(AssistantLogo));
      expect(navLogoFinder, findsOneWidget, reason: '导航里应只有一个助理 LOGO');
      final navLogo = tester.widget<AssistantLogo>(navLogoFinder);
      expect(navLogo.size, 24, reason: '导航槽位仍是 24dp（B45 只改描边）');
      expect(navLogo.strokeDp, 2, reason: 'B45：导航必须传 2dp 有效线宽');
      expect(navLogo.color, isNull,
          reason: '导航仍不传色 → 跟随 IconTheme（选中/未选中/深浅色）');
      expect(find.bySemanticsLabel(RegExp('助理')), findsOneWidget,
          reason: '语义仍只有一份（LOGO 被 ExcludeSemantics 排除）');

      // 生产接线复核：main.dart 的导航项确实带 strokeDp: 2（不只是改了 harness）。
      final mainSource = File('lib/main.dart').readAsStringSync();
      expect(mainSource, contains('AssistantLogo(size: 24, strokeDp: 2)'),
          reason: 'lib/main.dart 导航入口必须显式传 strokeDp: 2');
    } finally {
      handle.dispose();
    }
  });
}
