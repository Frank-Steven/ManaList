import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/streaming_blocks.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/tool_steps_group.dart';

/// F21 第①阶段回归（2026-11-11）：成功工具回注聚合。
///
/// 钉住三条硬规则：
/// 1. 只有「已回注且未失败」的工具段可折叠；
/// 2. 待确认（含破坏性审批）/ 失败 / 执行中一律独立、永不折叠；
/// 3. 连续成功步数 < 2 时不折叠；文本/思考段会切断聚合。
ChatStreamSegment toolSeg(
  String status, {
  bool failed = false,
  int seconds = 0,
  String? detail,
}) {
  final start = DateTime.now().subtract(Duration(seconds: seconds));
  return ChatStreamSegment(kind: ChatStreamSegmentKind.tool, startedAt: start)
    ..status = status
    ..failed = failed
    ..active = status == '执行中'
    ..detail = detail
    ..endedAt = DateTime.now();
}

ChatStreamSegment textSeg(String text) =>
    ChatStreamSegment(kind: ChatStreamSegmentKind.text, startedAt: DateTime.now())
      ..text = text
      ..active = false;

void main() {
  group('isFoldableToolSuccess（只有已回注可折叠）', () {
    test('已回注 → 可折叠', () {
      expect(isFoldableToolSuccess(toolSeg('已回注')), isTrue);
    });

    test('待确认 / 执行中 / 未能理解 → 不可折叠', () {
      expect(isFoldableToolSuccess(toolSeg('待确认')), isFalse);
      expect(isFoldableToolSuccess(toolSeg('执行中')), isFalse);
      expect(isFoldableToolSuccess(toolSeg('未能理解，已跳过', failed: true)),
          isFalse);
    });

    test('失败标记优先于状态文本；文本段不参与', () {
      expect(isFoldableToolSuccess(toolSeg('已回注', failed: true)), isFalse);
      expect(isFoldableToolSuccess(textSeg('正文')), isFalse);
    });
  });

  group('groupStreamSegments（同阶段连续成功才折叠）', () {
    test('三个连续成功 → 一条折叠组', () {
      final items = groupStreamSegments([
        textSeg('我先查一下。'),
        toolSeg('已回注'),
        toolSeg('已回注'),
        toolSeg('已回注'),
      ]);
      expect(items, hasLength(2));
      expect(items[0], isA<SingleSegment>());
      final folded = items[1] as FoldedToolSteps;
      expect(folded.steps, hasLength(3));
    });

    test('待确认（含破坏性审批）独立，且会切断聚合', () {
      final items = groupStreamSegments([
        toolSeg('已回注'),
        toolSeg('已回注'),
        toolSeg('待确认'),
        toolSeg('已回注'),
        toolSeg('已回注'),
      ]);
      expect(items, hasLength(3));
      expect((items[0] as FoldedToolSteps).steps, hasLength(2));
      final pending = items[1] as SingleSegment;
      expect(pending.segment.status, '待确认');
      expect((items[2] as FoldedToolSteps).steps, hasLength(2));
    });

    test('失败步独立，不并入成功组', () {
      final items = groupStreamSegments([
        toolSeg('未能理解，已跳过', failed: true),
        toolSeg('已回注'),
        toolSeg('已回注'),
      ]);
      expect(items[0], isA<SingleSegment>());
      expect((items[0] as SingleSegment).segment.failed, isTrue);
      expect((items[1] as FoldedToolSteps).steps, hasLength(2));
    });

    test('正文/思考段切断聚合（不同阶段不合并）', () {
      final items = groupStreamSegments([
        toolSeg('已回注'),
        toolSeg('已回注'),
        textSeg('查到了：共 3 条。'),
        toolSeg('已回注'),
        toolSeg('已回注'),
      ]);
      expect(items.map((e) => e.runtimeType).toList(),
          [FoldedToolSteps, SingleSegment, FoldedToolSteps]);
    });

    test('单步成功不折叠（避免单步套一层折叠）', () {
      final items = groupStreamSegments([toolSeg('已回注')]);
      expect(items.single, isA<SingleSegment>());
    });

    test('minToCollapse 可调（3）', () {
      final items = groupStreamSegments(
        [toolSeg('已回注'), toolSeg('已回注')],
        minToCollapse: 3,
      );
      expect(items, hasLength(2));
      expect(items.every((e) => e is SingleSegment), isTrue);
    });

    test('摘要文案', () {
      expect(successStepsSummary(3), '完成 3 步 · 全部成功');
      expect(successStepsSummary(12), '完成 12 步 · 全部成功');
    });
  });

  group('ToolStepsGroup（折叠/展开）', () {
    Widget wrap(Widget child) =>
        MaterialApp(home: Scaffold(body: Column(children: [child])));

    testWidgets('默认折叠：只显示一条摘要，不渲染步骤', (tester) async {
      await tester.pumpWidget(wrap(ToolStepsGroup(
        steps: [
          toolSeg('已回注', seconds: 1),
          toolSeg('已回注'),
          toolSeg('已回注'),
        ],
        onStepToggle: (_) {},
      )));
      expect(find.text('完成 3 步 · 全部成功'), findsOneWidget);
      expect(find.byType(ToolCallBlock), findsNothing);
    });

    testWidgets('点摘要展开逐步，再点收起', (tester) async {
      await tester.pumpWidget(wrap(ToolStepsGroup(
        steps: [toolSeg('已回注'), toolSeg('已回注')],
        onStepToggle: (_) {},
      )));
      await tester.tap(find.byKey(const ValueKey('tool-steps-group-header')));
      await tester.pumpAndSettle();
      expect(find.byType(ToolCallBlock), findsNWidgets(2));

      await tester.tap(find.byKey(const ValueKey('tool-steps-group-header')));
      await tester.pumpAndSettle();
      expect(find.byType(ToolCallBlock), findsNothing);
    });

    testWidgets('展开后点单步会回调其 segment', (tester) async {
      final first = toolSeg('已回注', detail: '读取完成');
      ChatStreamSegment? toggled;
      await tester.pumpWidget(wrap(ToolStepsGroup(
        steps: [first, toolSeg('已回注')],
        onStepToggle: (s) => toggled = s,
      )));
      await tester.tap(find.byKey(const ValueKey('tool-steps-group-header')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ToolCallBlock).first);
      await tester.pumpAndSettle();
      expect(toggled, same(first));
    });
  });
}