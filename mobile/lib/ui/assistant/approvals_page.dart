import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
      // B16：当前 chip 类别若已不在 pending 里（批次被拒/通过完），回退到
      // 「全部」——否则列表空、chip 消失，而 AppBar 仍显示 N。
      if (_categoryFilter != null &&
          !pending.any((p) =>
              ProposalService.toolCategory(p.tool) == _categoryFilter)) {
        _categoryFilter = null;
      }
      _history = all
          .where((p) => p.status != ProposalStatus.pending)
          .toList()
          .reversed
          .toList();
      _conversationTitles = {for (final c in conversations) c.id: c.title};
      _selected.removeWhere((id) => !pending.any((p) => p.id == id));
    });
  }

  /// B16：当前过滤器下**可见**的 pending 提案。
  ///
  /// 底部计数与「通过所选/拒绝所选」只作用于它 —— 此前直接用 `_pending`，
  /// 切换工具类型 chip 后会继续对看不见的条目计数/执行（筛选态与选择态脱节）。
  List<ChangeProposal> get _visiblePending => filterByCategory(
        _pending,
        _categoryFilter,
        categoryOf: ProposalService.toolCategory,
      );

  /// B16：当前可见且被选中的提案（批量动作的实际目标）。
  List<ChangeProposal> get _selectedVisible =>
      _visiblePending.where((p) => _selected.contains(p.id)).toList();

  Future<void> _approve(ChangeProposal p) async {
    // F3 §3.1-4：审批通过 = 中振；拒绝不振
    HapticFeedback.mediumImpact();
    setState(() => _busy = true);
    try {
      final exec = await ProposalExecutor.instance.approve(p.id);
      if (mounted && !exec.ok) _toast(exec.message);
      await _reload();
    } catch (e) {
      // B16：异常时给可见反馈，且必须复位 _busy（此前会永久卡死操作条）。
      if (mounted) _toast('操作失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject(ChangeProposal p) async {
    setState(() => _busy = true);
    try {
      await ProposalExecutor.instance.reject(p.id);
      await _reload();
    } catch (e) {
      if (mounted) _toast('操作失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approveSelected() async {
    // B16：目标 = 当前可见且被选中的集合（筛选态之外的条目不参与批量动作）。
    final targets = _selectedVisible;
    if (targets.isEmpty) return;
    setState(() => _busy = true);
    try {
      var failed = 0;
      for (final p in targets) {
        final exec = await ProposalExecutor.instance.approve(p.id);
        if (!exec.ok) failed++;
      }
      if (mounted && failed > 0) _toast('$failed 条执行失败，详见历史区');
      await _reload();
    } catch (e) {
      if (mounted) _toast('操作失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rejectSelected() async {
    final targets = _selectedVisible;
    if (targets.isEmpty) return;
    setState(() => _busy = true);
    try {
      for (final p in targets) {
        await ProposalExecutor.instance.reject(p.id);
      }
      await _reload();
    } catch (e) {
      if (mounted) _toast('操作失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  /// 组头文案：对话标题 + **当前可见**提案数（B16 残余修复）。
  ///
  /// [visibleCount] 必须是 filterByCategory 之后的集合大小：筛选后组头数字要与
  /// 实际显示的行数一致，否则会出现「组头写 3 项、下面只列出 1 条」的脱节。
  /// 无筛选时 visibleCount == g.proposals.length，显示与原来完全相同。
  String _groupTitle(ProposalBatch g, int visibleCount) {
    final convTitle = g.conversationId != null
        ? _conversationTitles[g.conversationId] ?? '已删除对话'
        : '未知来源';
    return '$convTitle · $visibleCount 项';
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
          // B16：没有待确认项时整条隐藏，不留死按钮。
          if (_pending.isNotEmpty) _buildActionBar(cs),
        ],
      ),
    );
  }

  /// B16：切换工具类型 chip。
  ///
  /// 除了改 filter，还要把「切走后不可见」的已选项从选择集合移除 ——
  /// 保证底部计数与批量动作永远只覆盖当前可见集合，
  /// 避免「选了 3 条 → 切到别的类别 → 按钮仍说 3 条却只执行 0 条」的脱节。
  void _onFilterChanged(String cat) {
    setState(() {
      _categoryFilter = _categoryFilter == cat ? null : cat;
      final visibleIds = _visiblePending.map((p) => p.id).toSet();
      _selected.removeWhere((id) => !visibleIds.contains(id));
    });
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
                onSelected:
                    _busy ? null : (v) => _onFilterChanged(cat),
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
          title: Text(_groupTitle(g, visible.length),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: TextButton(
            // B16：busy 期间禁用组头全选/清空。
            onPressed: _busy
                ? null
                : () {
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
          // B16：busy 期间禁用勾选，避免批量执行与选择态交叉。
          onChanged: _busy
              ? null
              : (v) => setState(() =>
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
    // B16：0 待确认项 → 不渲染；计数只算「当前可见且被选中」，
    // 与 _approveSelected/_rejectSelected 的目标集合严格一致。
    if (_pending.isEmpty) return const SizedBox.shrink();
    final n = _selectedVisible.length;
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
