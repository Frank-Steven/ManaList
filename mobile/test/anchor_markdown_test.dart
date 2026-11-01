import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/ui/shared/anchored_markdown.dart';

/// 锚点 markdown 渲染管线回归（design-v3-details §1.2）：
/// - TaskAnchorInlineSyntax 匹配 ⟦task:<uuid>⟧ → Element tag 'taskanchor' + id；
/// - 代码区保护：fenced code block / inline code 中的 marker 样文本不解析
///   （markdown 包天然豁免，此处固化）；
/// - AnchoredMarkdownBody 把 marker 渲染为可点击 chip（任务标题 + 点击回调）。
///
/// widget 测试不碰 DB：sqflite_ffi 与 widget 测试的 FakeAsync 区不兼容
/// （DB 调用挂死），联查数据走 [AnchoredMarkdownBody.debugData] 注入。
const kAnchorId = '12345678-1234-1234-1234-123456789abc';
const kAnchorId2 = '87654321-4321-4321-4321-cba987654321';

const kTask = Task(
  id: 't1',
  title: '买菜',
  kind: 'point',
  priority: 'normal',
  status: 'active',
  createdAt: 1000,
  updatedAt: 1000,
);

const kAnchor = TaskAnchor(
  id: kAnchorId,
  taskId: 't1',
  targetType: AnchorTargetType.note,
  targetId: 'n1',
  label: '买菜',
  createdBy: AnchorCreatedBy.user,
  createdAt: 1000,
);

List<md.Element> _collectTag(md.Document doc, String text, String tag) {
  final found = <md.Element>[];
  void walk(md.Node node) {
    if (node is md.Element) {
      if (node.tag == tag) found.add(node);
      node.children?.forEach(walk);
    }
  }

  doc.parse(text).forEach(walk);
  return found;
}

void main() {
  group('TaskAnchorInlineSyntax（纯解析层）', () {
    final doc = md.Document(inlineSyntaxes: [TaskAnchorInlineSyntax()]);

    test('正文中的 marker 解析为 taskanchor 元素并带 id', () {
      final found =
          _collectTag(doc, '记得买菜 ⟦task:$kAnchorId⟧ 顺路取快递', 'taskanchor');
      expect(found, hasLength(1));
      expect(found.single.attributes['id'], kAnchorId);
    });

    test('同一段落允许多个 marker', () {
      final found = _collectTag(
          doc, '⟦task:$kAnchorId⟧ 和 ⟦task:$kAnchorId2⟧', 'taskanchor');
      expect(found.map((e) => e.attributes['id']),
          [kAnchorId, kAnchorId2]);
    });

    test('inline code 中的 marker 样文本不解析', () {
      final found =
          _collectTag(doc, '示例 `⟦task:$kAnchorId⟧` 如上', 'taskanchor');
      expect(found, isEmpty, reason: 'inline code 不跑 inline syntax');
    });

    test('fenced code block 中的 marker 样文本不解析', () {
      final found = _collectTag(
          doc, '前文\n\n```\n⟦task:$kAnchorId⟧\n```\n\n后文', 'taskanchor');
      expect(found, isEmpty, reason: 'fenced code block 不跑 inline syntax');
    });

    test('非 uuid 的 ⟦task:xxx⟧ 不解析', () {
      final found = _collectTag(doc, '⟦task:不是uuid⟧', 'taskanchor');
      expect(found, isEmpty);
    });

    test('id 大小写容忍：大写写入也解析并归一小写', () {
      final upper = kAnchorId.toUpperCase();
      final found = _collectTag(doc, '⟦task:$upper⟧', 'taskanchor');
      expect(found.single.attributes['id'], kAnchorId);
    });
  });

  group('AnchoredMarkdownBody（widget，注入联查数据）', () {
    setUp(() {
      AnchoredMarkdownBody.debugData = (
        anchors: {kAnchorId: kAnchor},
        tasks: {'t1': kTask},
        files: const {},
      );
    });

    tearDown(() => AnchoredMarkdownBody.debugData = null);

    Widget host(String data, {ValueChanged<Task>? onOpenTask}) => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AnchoredMarkdownBody(data: data, onOpenTask: onOpenTask),
            ),
          ),
        );

    testWidgets('marker 渲染为任务标题 chip，点击回调任务', (tester) async {
      Task? opened;
      await tester.pumpWidget(host('今天要 ⟦task:$kAnchorId⟧ 别忘了',
          onOpenTask: (t) => opened = t));
      await tester.pumpAndSettle();
      expect(find.text('买菜'), findsOneWidget, reason: 'chip 显示任务标题');
      expect(find.textContaining('⟦task:'), findsNothing,
          reason: 'marker 原文不应出现在渲染结果里');

      await tester.tap(find.text('买菜'));
      expect(opened?.id, 't1');
    });

    testWidgets('fenced code block 中的 marker 样文本保持原文', (tester) async {
      await tester
          .pumpWidget(host('正文\n\n```\n⟦task:$kAnchorId⟧\n```\n'));
      await tester.pumpAndSettle();
      expect(find.textContaining(kAnchorId, findRichText: true),
          findsOneWidget,
          reason: '代码块里的 marker 样文本按原文显示');
      expect(find.text('买菜'), findsNothing, reason: '代码块里不生成 chip');
    });

    testWidgets('未知锚点（注入数据无此行）降级为弱化原文，不崩', (tester) async {
      await tester.pumpWidget(host('⟦task:$kAnchorId2⟧'));
      await tester.pumpAndSettle();
      expect(find.textContaining(kAnchorId2), findsOneWidget);
    });
  });
}
