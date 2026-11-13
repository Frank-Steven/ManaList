import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/auto_scroll_title.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/context_meter.dart';

/// F21 实施回归（2026-11-11，按已审批设计稿 + DSH ContextMeter 实证）：
/// - 标题方案③：非溢出静止 / 溢出才自动滚 / 触摸即停 / 减少动态效果不滚；
/// - 上下文指示器：14px 圆环 + NN% + 点击底部 sheet，**只展示真实可得的
///   「附件（估算）」一行**与「按 32k 估算」说明；不得出现 DSH 的三分类
///   （系统提示词/工具定义/对话消息），也不得出现 433K/1M 之类编造总量。
void main() {
  group('formatTokenCount（边界）', () {
    test('0 / 三位数 / K / M', () {
      expect(formatTokenCount(0), '0');
      expect(formatTokenCount(-5), '0');
      expect(formatTokenCount(999), '999');
      expect(formatTokenCount(1000), '~1.0K');
      expect(formatTokenCount(50200), '~50.2K');
      expect(formatTokenCount(433000), '~433K');
      expect(formatTokenCount(1000000), '1M');
      expect(formatTokenCount(1200000), '1.2M');
    });
  });

  group('contextPercent（边界）', () {
    test('上下限与超限', () {
      expect(contextPercent(0, 32768), 0);
      expect(contextPercent(-1, 32768), 0);
      expect(contextPercent(327, 32768), 1);
      expect(contextPercent(16384, 32768), 50);
      expect(contextPercent(32768, 32768), 100);
      expect(contextPercent(65536, 32768), 200, reason: '超限要能显示 >100%');
      expect(contextPercent(100, 0), 0, reason: '上限未知按 0');
    });
  });

  group('ContextMeter（pill + 底部 sheet）', () {
    Widget wrap(Widget child) =>
        MaterialApp(home: Scaffold(body: Center(child: child)));

    testWidgets('折叠态 = 圆环 + NN%（14px 圆环 + tabular 百分比）', (tester) async {
      await tester.pumpWidget(wrap(const ContextMeter(usedTokens: 2400)));
      expect(find.text('7%'), findsOneWidget, reason: '2400/32768 ≈ 7%');
      // 按 key 精确定位圆环：Material/Scaffold 自身也会插入 CustomPaint
      // （painter 为 null），用 find.byType(CustomPaint).first 会抓错对象。
      final ring = tester.widget<CustomPaint>(
        find.byKey(const ValueKey('context-meter-ring')),
      );
      expect(ring.painter, isNotNull, reason: '圆环必须真的挂上 _MeterRingPainter');
      expect(find.byKey(const ValueKey('context-meter-ring')), findsOneWidget);
    });

    testWidgets('点击展开 sheet：「字符估算（历史+附件）」+ 按 32k 估算说明',
        (tester) async {
      await tester.pumpWidget(wrap(const ContextMeter(usedTokens: 2400)));
      await tester.tap(find.text('7%'));
      await tester.pumpAndSettle();

      expect(find.text('上下文已用 7%'), findsOneWidget);
      // F42：这个数是「历史正文 + 草稿附件」，条目名如实写成字符估算。
      expect(find.text('字符估算（历史+附件）'), findsOneWidget);
      expect(find.text('附件（估算）'), findsNothing, reason: 'F42：旧措辞不得回潮');
      expect(find.text('~2.4K'), findsOneWidget);
      expect(find.textContaining('按 32k 估算'), findsOneWidget);
      expect(find.textContaining('历史正文'), findsOneWidget);
      expect(find.textContaining('未计入'), findsOneWidget);
      expect(find.textContaining('对话历史未计入'), findsNothing,
          reason: 'F42：历史其实已计入，不能再说未计入');

      // 不得照抄 DSH 三分类
      expect(find.text('系统提示词'), findsNothing);
      expect(find.text('工具定义'), findsNothing);
      expect(find.text('对话消息'), findsNothing);
      // 不得出现编造的 433K / 1M 总量文案
      expect(find.textContaining('433K'), findsNothing);
      expect(find.textContaining('1M'), findsNothing);
    });

    testWidgets('无附件/零用量 → 0%，sheet 显示 0', (tester) async {
      await tester.pumpWidget(wrap(const ContextMeter(usedTokens: 0)));
      expect(find.text('0%'), findsOneWidget);
      await tester.tap(find.text('0%'));
      await tester.pumpAndSettle();
      expect(find.text('上下文已用 0%'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
    });

    testWidgets('上限未知（0）→ 0% 且说明写「上限未知」而不是编造数字',
        (tester) async {
      await tester.pumpWidget(
          wrap(const ContextMeter(usedTokens: 1200, limitTokens: 0)));
      expect(find.text('0%'), findsOneWidget);
      await tester.tap(find.text('0%'));
      await tester.pumpAndSettle();
      expect(find.textContaining('上限未知'), findsOneWidget);
    });

    testWidgets('超限：百分比 >100%，圆环用 error 色（可点击查看）', (tester) async {
      await tester.pumpWidget(wrap(const ContextMeter(usedTokens: 70000)));
      expect(find.text('214%'), findsOneWidget);
      await tester.tap(find.text('214%'));
      await tester.pumpAndSettle();
      expect(find.text('上下文已用 214%'), findsOneWidget);
    });
  });

  group('AutoScrollTitle（方案③）', () {
    Widget wrap(String text, {bool reduceMotion = false, double width = 180}) {
      return MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Scaffold(
            appBar: AppBar(
              title: SizedBox(width: width, child: AutoScrollTitle(text: text)),
            ),
            body: const SizedBox.shrink(),
          ),
        ),
      );
    }

    const shortText = '短标题';
    const longText =
        '整理十月报销与发票（含 3 张截图、上海虹桥高铁票 553 元、本周五前提交）';
    const viewportKey = ValueKey('auto-scroll-viewport');

    testWidgets('非溢出标题完全静止（不产生滚动层）', (tester) async {
      await tester.pumpWidget(wrap(shortText, width: 260));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(viewportKey), findsNothing,
          reason: '不溢出时不应进入滚动分支');
      expect(find.text(shortText), findsOneWidget);
    });

    testWidgets('溢出标题会自动滚动', (tester) async {
      await tester.pumpWidget(wrap(longText));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(viewportKey), findsOneWidget);

      double offsetOf(WidgetTester t) {
        for (final tr in t.widgetList<Transform>(find.byType(Transform))) {
          if (tr.transform.storage[12] != 0) return tr.transform.storage[12];
        }
        return 0;
      }

      final before = offsetOf(tester);
      await tester.pump(const Duration(milliseconds: 600));
      expect(offsetOf(tester), isNot(before), reason: '溢出标题应产生位移');
    });

    testWidgets('触摸/按住即暂停（不得出现停不下来的滚动）', (tester) async {
      await tester.pumpWidget(wrap(longText));
      await tester.pump(const Duration(milliseconds: 300));

      final gesture =
          await tester.startGesture(tester.getCenter(find.byType(AutoScrollTitle)));
      await tester.pump(const Duration(milliseconds: 100));

      double offsetOf(WidgetTester t) {
        for (final tr in t.widgetList<Transform>(find.byType(Transform))) {
          if (tr.transform.storage[12] != 0) return tr.transform.storage[12];
        }
        return 0;
      }

      final held = offsetOf(tester);
      await tester.pump(const Duration(milliseconds: 700));
      expect(offsetOf(tester), held, reason: '按住期间必须静止');
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));
    });

    testWidgets('系统「减少动态效果」时不自动滚（仍单行省略）', (tester) async {
      await tester.pumpWidget(wrap(longText, reduceMotion: true));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(viewportKey), findsNothing,
          reason: 'reduce motion 时不应启动自动滚动');
      expect(find.text(longText), findsOneWidget);
    });
  });
}
