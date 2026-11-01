import 'models.dart';

/// 待确认区的 batch 分组（design-v3-details §3.2）：
/// 一个 AI 回合（batch_id = assistant 消息 id）产出的全部提案为一组。
/// 纯函数，approvals_page 与 approvals_grouping_test 共用。

class ProposalBatch {
  /// 组键：batchId；缺 batchId 的旧数据按提案自身 id 自成一组。
  final String key;
  final String? batchId;
  final String? conversationId;
  final List<ChangeProposal> proposals;

  /// 组内最新提案时间（组排序用）。
  final int latestAt;

  const ProposalBatch({
    required this.key,
    this.batchId,
    this.conversationId,
    required this.proposals,
    required this.latestAt,
  });
}

/// pending 提案按 batch 分组：组内按创建时间升序，组间按组内最新时间降序。
List<ProposalBatch> groupProposalsByBatch(List<ChangeProposal> pending) {
  final byKey = <String, List<ChangeProposal>>{};
  for (final p in pending) {
    byKey.putIfAbsent(p.batchId ?? p.id, () => []).add(p);
  }
  final groups = [
    for (final entry in byKey.entries)
      ProposalBatch(
        key: entry.key,
        batchId: entry.value.first.batchId,
        conversationId: entry.value.first.conversationId,
        proposals: entry.value
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
        latestAt:
            entry.value.map((p) => p.createdAt).reduce((a, b) => a > b ? a : b),
      ),
  ];
  groups.sort((a, b) => b.latestAt.compareTo(a.latestAt));
  return groups;
}

/// 工具类型过滤 chip 的分类标签（details §3.2：任务/笔记/锚点/消息标记）。
const Map<String, String> kToolCategoryLabels = {
  'task': '任务',
  'note': '笔记',
  'anchor': '锚点',
  'message': '消息标记',
  'other': '其他',
};

/// 一组提案按当前选择态/过滤条件的可见性辅助：
/// 返回组内被 [categoryFilter]（null = 不过滤）选中的提案。
List<ChangeProposal> filterByCategory(
        List<ChangeProposal> proposals, String? categoryFilter,
        {required String Function(String tool) categoryOf}) =>
    categoryFilter == null
        ? proposals
        : proposals.where((p) => categoryOf(p.tool) == categoryFilter).toList();
