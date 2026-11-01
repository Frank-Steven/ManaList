import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/assistant/approvals_grouping.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/assistant/proposal_service.dart';

/// 待确认区组织逻辑（design-v3-details §3.2/§3.3）：
/// batch 分组、组间排序、工具类型过滤、默认勾选策略。
/// 选择态仅存内存（UI 层），这里测纯函数部分。
void main() {
  ChangeProposal p(String id, String tool,
          {String? batchId,
          String? conversationId = 'c1',
          int createdAt = 1000,
          Map<String, dynamic> payload = const {}}) =>
      ChangeProposal(
        id: id,
        conversationId: conversationId,
        batchId: batchId,
        tool: tool,
        summary: id,
        payload: payload,
        createdAt: createdAt,
      );

  group('batch 分组', () {
    test('同 batchId 归一组；组内按创建时间升序；组间按组内最新时间降序', () {
      final groups = groupProposalsByBatch([
        p('p1', 'task.create', batchId: 'b1', createdAt: 1000),
        p('p2', 'task.create', batchId: 'b2', createdAt: 2000),
        p('p3', 'task.create', batchId: 'b1', createdAt: 3000),
        p('p4', 'task.create', batchId: 'b2', createdAt: 1500),
      ]);
      expect(groups.map((g) => g.key), ['b1', 'b2'],
          reason: 'b1 组内最新 3000 > b2 的 2000');
      expect(groups[0].proposals.map((x) => x.id), ['p1', 'p3']);
      expect(groups[1].proposals.map((x) => x.id), ['p4', 'p2'],
          reason: '组内按创建时间升序（DAO 已按 created_at ASC 返回）');
    });

    test('缺 batchId 的旧提案各自成组', () {
      final groups = groupProposalsByBatch([
        p('solo-1', 'task.create', batchId: null),
        p('solo-2', 'task.create', batchId: null, createdAt: 2000),
      ]);
      expect(groups.length, 2);
      expect(groups.map((g) => g.key), containsAll(['solo-1', 'solo-2']));
    });
  });

  group('工具类型过滤 chip', () {
    test('任务/笔记/锚点/消息标记四类', () {
      expect(ProposalService.toolCategory('task.create'), 'task');
      expect(ProposalService.toolCategory('task.update'), 'task');
      expect(ProposalService.toolCategory('note.append'), 'note');
      expect(ProposalService.toolCategory('note.replace_section'), 'note');
      expect(ProposalService.toolCategory('anchor.create'), 'anchor');
      expect(ProposalService.toolCategory('anchor.remove'), 'anchor');
      expect(ProposalService.toolCategory('message.set_priority'), 'message');
    });

    test('filterByCategory 只留目标类；null 不过滤', () {
      final list = [
        p('a', 'task.create'),
        p('b', 'note.append'),
        p('c', 'message.set_priority'),
      ];
      expect(
          filterByCategory(list, 'note',
                  categoryOf: ProposalService.toolCategory)
              .map((x) => x.id),
          ['b']);
      expect(
          filterByCategory(list, null, categoryOf: ProposalService.toolCategory)
              .length,
          3);
    });
  });

  group('默认勾选策略（details §3.3）', () {
    test('仅 message.set_priority(junk) 默认勾选', () {
      expect(
          ProposalService.defaultSelected(p('j', 'message.set_priority',
              payload: {'priority': MessagePriority.junk})),
          isTrue);
      expect(
          ProposalService.defaultSelected(p('r', 'message.set_priority',
              payload: {'priority': MessagePriority.red})),
          isFalse,
          reason: '非 junk 的优先级标记不默认勾选');
      expect(ProposalService.defaultSelected(p('t', 'task.create')), isFalse);
      expect(ProposalService.defaultSelected(p('n', 'note.append')), isFalse);
      expect(
          ProposalService.defaultSelected(p('a', 'anchor.create')), isFalse);
    });
  });
}
