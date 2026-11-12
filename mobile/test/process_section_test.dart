import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:msgrepo_mobile/ui/assistant/widgets/process_section.dart';

Widget wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  group('ProcessSection（F31 正文后保留过程、默认折叠）', () {
    testWidgets('默认折叠：摘要可见、子项不可见', (tester) async {
      await tester.pumpWidget(wrap(const ProcessSection(
        summary: '过程 · 思考 3s · 2 步工具',
        children: [Text('思考内容'), Text('工具内容')],
      )));
      await tester.pumpAndSettle();

      expect(find.text('过程 · 思考 3s · 2 步工具'), findsOneWidget);
      expect(find.text('思考内容'), findsNothing);
      expect(find.text('工具内容'), findsNothing);
    });

    testWidgets('点击摘要展开子项，再点收起', (tester) async {
      await tester.pumpWidget(wrap(const ProcessSection(
        summary: '过程 · 思考 3s · 2 步工具',
        children: [Text('思考内容'), Text('工具内容')],
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('process-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('思考内容'), findsOneWidget);
      expect(find.text('工具内容'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('process-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('思考内容'), findsNothing);
    });

    testWidgets('initiallyExpanded=true 时直接展开', (tester) async {
      await tester.pumpWidget(wrap(const ProcessSection(
        summary: '过程',
        initiallyExpanded: true,
        children: [Text('思考内容')],
      )));
      await tester.pumpAndSettle();
      expect(find.text('思考内容'), findsOneWidget);
    });
  });
}
