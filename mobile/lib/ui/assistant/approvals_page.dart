import 'package:flutter/material.dart';

import '../../services/assistant/approvals_grouping.dart';
import '../../services/assistant/models.dart';
import '../../services/assistant/proposal_executor.dart';
import '../../services/assistant/proposal_service.dart';
import '../../services/database.dart';
import 'widgets/proposal_card.dart';

/// 待确认区（design-v3 §5.1、details §3）：
/// pending 提案按 batch 分组（可折叠、组头全选/清空、工具类型过滤 chip），
/// 单条/批量通过与拒绝；历史区（applied/rejected/failed）带 applied 撤销入口。
/// 默认勾选策略：仅 message.set_priority(junk) 默认勾选（details §3.3），
/// 选择态仅存内存，不落库。
class ApprovalsPage extends StatefulWidget {
  const ApprovalsPage({super.key});

  @override
  State<ApprovalsPage> createState() => _ApprovalsPageState();
}

class _ApprovalsPageState extends State<ApprovalsPage> {
  List<ChangeProposal> _pending = [];
  List<ChangeProposal> _history = [];
  Map<String, String> _conversationTitles = {};

  /// 选择态（内存）；新出现的 pending 提案按默认策略初始化一次。
  final Set<String> _selected = {};
  final Set<String> _seenProposalIds = {};
  final Set<String> _collapsed = {};
  String? _categoryFilter;
  bool _historyExpanded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final db = AppDatabase.instance;
    final pending = await db.getProposals(status: ProposalStatus.pending);
    final all = await db.getProposals();
    final conversations = await db.getConversations();
    // 新提案按默认勾选策略初始化选择态（details §3.3）
    for (final p in pending) {
      if (_seenProposalIds.add(p.id) && ProposalService.defaultSelected(p)) {
        _selected.add(p.id);
      }
    }
    if (!mounted) return;
    setState(() {
      _pending = pending;
      _history = all
          .where((p) => p.status != ProposalStatus.pending)
          .toList()
          .reversed
          .toList();
      _conversationTitles = {for (final c in conversations) c.id: c.title};
      _selected.removeWhere((id) => !pending.any((p) => p.id == id));
    });
  }

  Future<void> _approve(ChangeProposal p) async {
    setState(() => _busy = true);
    final exec = await ProposalExecutor.instance.approve(p.id);
    if (mounted && !exec.ok) _toast(exec.message);
    await _reload();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _reject(ChangeProposal p) async {
    await ProposalExecutor.instance.reject(p.id);
    await _reload();
  }

  Future<void> _approveSelected() async {
    final targets =
        _pending.where((p) => _selected.contains(p.id)).toList();
    if (targets.isEmpty) return;
    setState(() => _busy = true);
    var failed = 0;
    for (final p in targets) {
      final exec = await ProposalExecutor.instance.approve(p.id);
      if (!exec.ok) failed++;
    }
    if (mounted && failed > 0) _toast('$failed 条执行失败，详见历史区');
    await _reload();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _rejectSelected() async {
    final targets =
        _pending.where((p) => _selected.contains(p.id)).toList();
    for (final p in targets) {
      await ProposalExecutor.instance.reject(p.id);
    }
    await _reload();
  }

  Future<void> _undo(ChangeProposal p) async {
    final ok = await ProposalExecutor.instance.undoApplied(p.id);
    if (mounted) _toast(ok ? '已撤销，提案退回待确认区' : '撤销失败');
    await _reload();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  String _groupTitle(ProposalBatch g) {
    final convTitle = g.conversationId != null
        ? _conversationTitles[g.conversationId] ?? '已删除对话'
        : '未知来源';
    return '$convTitle · ${g.proposals.length} 项';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final groups = groupProposalsByBatch(_pending);
    return Scaffold(
      appBar: AppBar(title: Text('待确认区（${_pending.length}）')),
      body: Column(
        children: [
          _buildFilterChips(cs),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              children: [
                if (groups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Text('没有待审批的提案',
                          style: TextStyle(color: cs.onSurfaceVariant)),
                    ),
                  ),
                for (final g in groups) ..._buildGroup(g, cs),
                _buildHistory(),
              ],
            ),
          ),
          _buildActionBar(cs),
        ],
      ),
    );
  }

  Widget _buildFilterChips(ColorScheme cs) {
    final present = <String>{
      for (final p in _pending) ProposalService.toolCategory(p.tool),
    };
    if (present.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          for (final cat in present)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(kToolCategoryLabels[cat] ?? cat),
                selected: _categoryFilter == cat,
                onSelected: (v) =>
                    setState(() => _categoryFilter = v ? cat : null),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildGroup(ProposalBatch g, ColorScheme cs) {
    final visible = filterByCategory(g.proposals, _categoryFilter,
        categoryOf: ProposalService.toolCategory);
    if (visible.isEmpty) return const [];
    final collapsed = _collapsed.contains(g.key);
    final selectedInGroup =
        visible.where((p) => _selected.contains(p.id)).length;
    return [
      // 组头：对话标题 + 计数 + 全选/清空 + 折叠
      Material(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        child: ListTile(
          dense: true,
          leading: Icon(collapsed ? Icons.expand_more : Icons.expand_less,
              size: 20),
          title: Text(_groupTitle(g),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: TextButton(
            onPressed: () {
              setState(() {
                if (selectedInGroup == visible.length) {
                  for (final p in visible) {
                    _selected.remove(p.id);
                  }
                } else {
                  for (final p in visible) {
                    _selected.add(p.id);
                  }
                }
              });
            },
            child: Text(
                selectedInGroup == visible.length ? '清空' : '全选',
                style: const TextStyle(fontSize: 12)),
          ),
          onTap: () => setState(() => collapsed
              ? _collapsed.remove(g.key)
              : _collapsed.add(g.key)),
        ),
      ),
      if (!collapsed)
        for (final p in visible) _buildProposalTile(p),
      const SizedBox(height: 8),
    ];
  }

  Widget _buildProposalTile(ChangeProposal p) {
    return Row(
      children: [
        Checkbox(
          value: _selected.contains(p.id),
          onChanged: (v) => setState(() =>
              v == true ? _selected.add(p.id) : _selected.remove(p.id)),
        ),
        Expanded(
          child: ProposalCard(
            proposal: p,
            density: ProposalCardDensity.full,
            onApprove: _busy ? null : () => _approve(p),
            onReject: _busy ? null : () => _reject(p),
          ),
        ),
      ],
    );
  }

  Widget _buildHistory() {
    if (_history.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        ListTile(
          dense: true,
          leading: Icon(
              _historyExpanded ? Icons.expand_less : Icons.expand_more,
              size: 20),
          title: Text('历史（${_history.length}）'),
          onTap: () =>
              setState(() => _historyExpanded = !_historyExpanded),
        ),
        if (_historyExpanded)
          for (final p in _history)
            ProposalCard(
              proposal: p,
              density: ProposalCardDensity.full,
              onUndo: p.status == ProposalStatus.applied && !_busy
                  ? () => _undo(p)
                  : null,
            ),
      ],
    );
  }

  Widget _buildActionBar(ColorScheme cs) {
    final n = _selected.length;
    return SafeArea(
      top: false,
      child: Container(
        color: cs.surfaceContainer,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: _busy || n == 0 ? null : _approveSelected,
                child: Text('通过所选（$n）'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                onPressed: _busy || n == 0 ? null : _rejectSelected,
                child: const Text('拒绝所选'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
