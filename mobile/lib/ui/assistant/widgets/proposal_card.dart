import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../services/assistant/approvals_grouping.dart';
import '../../../services/assistant/models.dart';
import '../../../services/assistant/proposal_service.dart';

/// 提案卡片密度（ui-structure §7：同一组件两种密度）。
enum ProposalCardDensity {
  /// 对话页内联：图标 + 摘要 + 状态标 + 「去审批」入口。
  compact,

  /// 待确认区：compact 内容 + 关键 diff + 通过/拒绝（或 applied 撤销）。
  full,
}

/// 提案卡片（ui-structure §7）：工具图标 + 摘要 + 状态标，
/// 对话页内联与待确认区卡片同构。
///
/// 状态标语义与配色：pending 黄 / applied 绿 / rejected 灰 / failed 红。
/// 各入口回调由所在页面注入；组件本身不触服务层。
class ProposalCard extends StatelessWidget {
  final ChangeProposal proposal;
  final ProposalCardDensity density;

  /// full 密度、pending 状态时的「通过」回调；null 时按钮置灰。
  final VoidCallback? onApprove;

  /// full 密度、pending 状态时的「拒绝」回调；null 时按钮置灰。
  final VoidCallback? onReject;

  /// applied 状态的「撤销」回调；null 时不显示。
  final VoidCallback? onUndo;

  /// compact 密度、pending 状态时的「去审批」回调；null 时不显示。
  final VoidCallback? onGoToApprovals;

  const ProposalCard({
    super.key,
    required this.proposal,
    this.density = ProposalCardDensity.compact,
    this.onApprove,
    this.onReject,
    this.onUndo,
    this.onGoToApprovals,
  });

  bool get _pending => proposal.status == ProposalStatus.pending;

  /// 状态标（图标 + 文案 + 语义色），§7 唯一事实源。
  static (IconData, String, Color) statusVisual(ColorScheme cs, String status) =>
      switch (status) {
        ProposalStatus.pending => (
            Icons.hourglass_top,
            '待审批',
            Colors.amber.shade700,
          ),
        ProposalStatus.applied => (
            Icons.check_circle_outline,
            '已生效',
            Colors.green.shade600,
          ),
        ProposalStatus.rejected => (Icons.block, '已拒绝', cs.onSurfaceVariant),
        ProposalStatus.failed => (Icons.error_outline, '失败', cs.error),
        _ => (Icons.hourglass_top, status, cs.onSurfaceVariant),
      };

  static IconData _toolIcon(String tool) =>
      switch (ProposalService.toolCategory(tool)) {
        'task' => Icons.task_alt,
        'note' => Icons.note_alt_outlined,
        'anchor' => Icons.anchor,
        'message' => Icons.mark_email_read_outlined,
        _ => Icons.build_outlined,
      };

  Widget _statusBadge(ColorScheme cs) {
    final (icon, label, color) = statusVisual(cs, proposal.status);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 2),
        Text(label, style: TextStyle(fontSize: 11, color: color)),
      ],
    );
  }

  /// 关键 diff：payload 的标量条目（跳过 `_undo` 等内部快照），至多 4 条。
  List<MapEntry<String, String>> _diffEntries() {
    final entries = <MapEntry<String, String>>[];
    for (final e in proposal.payload.entries) {
      if (e.key.startsWith('_')) continue;
      final v = e.value;
      entries.add(MapEntry(e.key, v is String ? v : jsonEncode(v)));
      if (entries.length >= 4) break;
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.symmetric(
          vertical: density == ProposalCardDensity.compact ? 4 : 2),
      child: density == ProposalCardDensity.compact
          ? _buildCompact(cs)
          : _buildFull(cs),
    );
  }

  Widget _buildCompact(ColorScheme cs) {
    return ListTile(
      dense: true,
      leading: Icon(_toolIcon(proposal.tool), size: 20),
      title: Text(proposal.summary,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13)),
      subtitle: Row(
        children: [
          Flexible(
            child: Text('${proposal.tool} · ',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          ),
          _statusBadge(cs),
        ],
      ),
      trailing: _pending && onGoToApprovals != null
          ? TextButton(onPressed: onGoToApprovals, child: const Text('去审批'))
          : null,
    );
  }

  Widget _buildFull(ColorScheme cs) {
    final diff = _diffEntries();
    final category =
        kToolCategoryLabels[ProposalService.toolCategory(proposal.tool)] ??
            proposal.tool;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          Icon(_toolIcon(proposal.tool), size: 20, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(proposal.summary,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Flexible(
                      child: Text('$category · ${proposal.tool} · ',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: cs.onSurfaceVariant)),
                    ),
                    _statusBadge(cs),
                  ],
                ),
                if (diff.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final e in diff)
                          Text('${e.key}: ${e.value}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11, color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (_pending) ...[
            TextButton(onPressed: onApprove, child: const Text('通过')),
            TextButton(onPressed: onReject, child: const Text('拒绝')),
          ] else if (proposal.status == ProposalStatus.applied &&
              onUndo != null)
            TextButton(onPressed: onUndo, child: const Text('撤销')),
        ],
      ),
    );
  }
}
