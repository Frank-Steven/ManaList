import 'package:flutter/material.dart';

import '../../../models/conversation.dart';
import '../../../services/assistant/models.dart';
import 'streaming_blocks.dart';

/// F21 第①阶段（审批稿「成功工具聚合」）：同一阶段**连续的成功工具回注**
/// 在默认态合成一条自然语言摘要（如「完成 3 步 · 全部成功」），点开才逐步展开。
///
/// 三条硬规则（与审批 HTML 一致，测试逐条钉住）：
/// 1. **只有成功回注**（`status == '已回注'` 且未失败）才可折叠；
/// 2. **待确认（pending）/ 失败 / 阻塞（执行中）不可折叠**，一律独立展示；
///    「破坏性审批」在本 App 里同样表现为待确认提案 ⇒ 天然落在独立分支；
/// 3. 连续成功步数 < [kMinStepsToCollapseSuccess] 时不折叠（单步套折叠只是噪音）。

/// 折叠所需的最小连续成功步数。
const int kMinStepsToCollapseSuccess = 2;

/// 该工具段是否可以并入「成功聚合」：只认已回注且未失败。
bool isFoldableToolSuccess(ChatStreamSegment segment) =>
    segment.kind == ChatStreamSegmentKind.tool &&
        !segment.failed &&
        segment.status == '已回注';

/// 流式渲染的一项：要么是折叠组，要么原样渲染单段。
sealed class ToolRunItem {
  const ToolRunItem();
}

/// 连续成功工具段的折叠组。
class FoldedToolSteps extends ToolRunItem {
  const FoldedToolSteps(this.steps);
  final List<ChatStreamSegment> steps;
}

/// 原样渲染的单段（文本/思考/待确认工具/失败工具/执行中工具）。
class SingleSegment extends ToolRunItem {
  const SingleSegment(this.segment);
  final ChatStreamSegment segment;
}

/// 把整段流按「连续成功工具段」切分为渲染项。
///
/// 文本、思考、待确认/失败/执行中的工具段都会**切断**聚合，
/// 保证「同一阶段」严格等于「中间没有别的分段」。
List<ToolRunItem> groupStreamSegments(
  List<ChatStreamSegment> segments, {
  int minToCollapse = kMinStepsToCollapseSuccess,
}) {
  final items = <ToolRunItem>[];
  var i = 0;
  while (i < segments.length) {
    final seg = segments[i];
    if (isFoldableToolSuccess(seg)) {
      var j = i;
      while (j < segments.length && isFoldableToolSuccess(segments[j])) {
        j++;
      }
      final steps = segments.sublist(i, j);
      if (steps.length >= minToCollapse) {
        items.add(FoldedToolSteps(steps));
      } else {
        for (final s in steps) {
          items.add(SingleSegment(s));
        }
      }
      i = j;
      continue;
    }
    items.add(SingleSegment(seg));
    i++;
  }
  return items;
}

/// 折叠摘要的自然语言标题：「完成 N 步 · 全部成功」。
String successStepsSummary(int count) => '完成 $count 步 · 全部成功';

// ---- 历史消息侧（task-80）：连续成功 tool 消息折叠 ----

/// 历史消息渲染项：折叠组 / 原样单条。
sealed class MessageRunItem {
  const MessageRunItem();
}

/// 连续成功 tool 消息的折叠组。
class FoldedToolMessages extends MessageRunItem {
  const FoldedToolMessages(this.messages);
  final List<ChatMessage> messages;
}

/// 原样渲染的单条消息（用户/助理/失败回注/搜索命中/单条成功…）。
class SingleMessage extends MessageRunItem {
  const SingleMessage(this.message);
  final ChatMessage message;
}

/// 该 tool 消息能否并入「成功聚合」：role=tool 且不是失败回注。
/// 「一个动作未能理解，已跳过」是失败回注（status=未能理解）→ 不折叠。
bool isFoldableToolMessage(ChatMessage message) =>
    message.role == ChatRole.tool &&
        !message.content.startsWith('一个动作未能理解');

/// 历史消息纯分组（task-80）：
/// - 连续、成功回注的 tool 消息 ≥ [minToCollapse] 条 → 折成 [FoldedToolMessages]；
/// - 失败回注、用户/助理消息、[protectedMessageIds]（搜索命中，需保留高亮定位）
///   都会**切断**连续段并原样单条渲染；
/// - < [minToCollapse] 条成功消息也保持单条（与流式侧一致）。
List<MessageRunItem> groupToolMessages(
  List<ChatMessage> messages, {
  int minToCollapse = kMinStepsToCollapseSuccess,
  Set<String> protectedMessageIds = const <String>{},
}) {
  bool foldable(ChatMessage m) =>
      isFoldableToolMessage(m) && !protectedMessageIds.contains(m.id);

  final items = <MessageRunItem>[];
  var i = 0;
  while (i < messages.length) {
    if (foldable(messages[i])) {
      var j = i;
      while (j < messages.length && foldable(messages[j])) {
        j++;
      }
      final run = messages.sublist(i, j);
      if (run.length >= minToCollapse) {
        items.add(FoldedToolMessages(run));
      } else {
        for (final m in run) {
          items.add(SingleMessage(m));
        }
      }
      i = j;
      continue;
    }
    items.add(SingleMessage(messages[i]));
    i++;
  }
  return items;
}

/// 折叠组：默认一行摘要，点开展开逐步（每步复用 [ToolCallBlock]）。
class ToolStepsGroup extends StatefulWidget {
  const ToolStepsGroup({
    super.key,
    required this.steps,
    required this.onStepToggle,
    this.initiallyExpanded = false,
    this.expanded,
    this.onToggleGroup,
    this.headerKey = const ValueKey('tool-steps-group-header'),
  });

  final List<ChatStreamSegment> steps;
  final void Function(ChatStreamSegment step) onStepToggle;
  final bool initiallyExpanded;

  /// 受控展开（历史消息侧用：状态映射到 chat_page 的 _expandedToolMsgIds，
  /// 重新 reload 后仍保持）。为 null 时用内部状态（流式侧保持原行为）。
  final bool? expanded;

  /// 受控模式下点摘要的回调；为 null 时内部自己翻转。
  final VoidCallback? onToggleGroup;

  /// 摘要行的 Key；历史同屏多组时必须传唯一 key（默认值给流式侧用）。
  final Key headerKey;

  @override
  State<ToolStepsGroup> createState() => _ToolStepsGroupState();
}

class _ToolStepsGroupState extends State<ToolStepsGroup> {
  late bool _expanded = widget.initiallyExpanded;

  bool get _isExpanded => widget.expanded ?? _expanded;

  void _toggle() {
    if (widget.onToggleGroup != null) {
      widget.onToggleGroup!();
    } else {
      setState(() => _expanded = !_expanded);
    }
  }

  int get _totalSeconds {
    var sum = 0;
    for (final s in widget.steps) {
      sum += s.elapsedSeconds;
    }
    return sum;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final count = widget.steps.length;
    final seconds = _totalSeconds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          key: widget.headerKey,
          borderRadius: BorderRadius.circular(8),
          onTap: _toggle,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline,
                    size: 16, color: cs.primary),
                const SizedBox(width: 6),
                Text(
                  successStepsSummary(count),
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (seconds > 0) ...[
                  const SizedBox(width: 6),
                  Text(
                    '$seconds s',
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
                const SizedBox(width: 4),
                Icon(
                  _isExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (_isExpanded)
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final step in widget.steps)
                  ToolCallBlock(
                    segment: step,
                    onToggle: () => widget.onStepToggle(step),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}