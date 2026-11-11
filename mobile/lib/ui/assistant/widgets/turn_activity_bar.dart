import "package:flutter/material.dart";

import "../../../services/assistant/assistant_service.dart" show TurnPhase;

/// F21 第②阶段（审批稿第 2 节）：**全页唯一的主进行态条**。
///
/// 设计约束（逐条有测试）：
/// 1. 固定在「消息流」与「输入栏」之间，不随消息滚走；
/// 2. 主文案来自**真实** [TurnPhase]，不伪造计划 / 总步数；次级只报**已完成**步数；
/// 3. 全页**只保留这一处循环动效**（[ActivityPulseDot]，900ms 呼吸）：
///    思考块进度圈、工具块呼吸点、正文末尾光标都已在源头移除；
/// 4. 停止键 ≥48dp，回调由页面注入（沿用现有 _cancel）；
/// 5. 有待确认提案且不在生成时，显示**静态**「等待你确认 N 条提案」，无呼吸、无停止。

/// 阶段 → 主文案（自然语言，只描述当前真实阶段）。
String activityPrimaryText(TurnPhase phase) => switch (phase) {
      TurnPhase.starting => "正在连接模型…",
      TurnPhase.thinking => "正在思考…",
      TurnPhase.generating => "正在回复…",
      TurnPhase.tooling => "正在执行工具…",
      TurnPhase.done => "已完成",
      TurnPhase.error => "出错了",
    };

/// 次级文案：只报已完成步数（0 步返回 null，不显示伪造总数）。
String? activitySecondaryText(int completedSteps) =>
    completedSteps > 0 ? "已完成 $completedSteps 步" : null;

/// 待确认提案的静态文案（N 来自真实 pending 计数）。
String activityPendingText(int pendingCount) => "等待你确认 $pendingCount 条提案";

/// 该阶段是否处于「进行中」（done/error 之外）。
bool activityIsBusy(TurnPhase phase) =>
    phase != TurnPhase.done && phase != TurnPhase.error;

/// 全页唯一的循环动效：900ms 呼吸圆点（透明度 + 轻微缩放往返）。
class ActivityPulseDot extends StatefulWidget {
  const ActivityPulseDot({super.key, this.size = 8, this.color});

  final double size;
  final Color? color;

  @override
  State<ActivityPulseDot> createState() => _ActivityPulseDotState();
}

class _ActivityPulseDotState extends State<ActivityPulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        return Opacity(
          opacity: 0.35 + 0.65 * t,
          child: Transform.scale(
            scale: 0.85 + 0.15 * t,
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
        );
      },
    );
  }
}

/// 主进行态条本体（固定在输入栏上方）。
class TurnActivityBar extends StatelessWidget {
  const TurnActivityBar({
    super.key,
    required this.phase,
    this.active = true,
    this.completedSteps = 0,
    this.pendingCount = 0,
    this.onStop,
  });

  final TurnPhase phase;

  /// B22：**是否有在途回合**的显式门控。
  /// 回合结束后 phase 可能残留 generate/thinking，仅靠阶段判断会让
  /// 活动条在空对话里常驻（真机缺陷）；busy 必须同时满足 active。
  final bool active;

  /// 本回合已完成的工具步数（真实计数，只增不减到回合结束）。
  final int completedSteps;

  /// 当前已加载的 pending 提案条数（真实计数）。
  final int pendingCount;

  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // B22：active && 阶段在进行中，才算「进行中」。
    final busy = active && activityIsBusy(phase);
    if (!busy && pendingCount <= 0) return const SizedBox.shrink();

    final secondary = busy ? activitySecondaryText(completedSteps) : null;
    return Container(
      key: const ValueKey("turn-activity-bar"),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          if (busy)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: ActivityPulseDot(),
            )
          else ...[
            Icon(Icons.pending_outlined,
                size: 16, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  busy
                      ? activityPrimaryText(phase)
                      : activityPendingText(pendingCount),
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (secondary != null)
                  Text(
                    secondary,
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ),
          if (busy && onStop != null)
            // B23：停止键 ≥72×48、单行不挤压主文案、右侧留 8dp。
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 72,
                height: 48,
                child: TextButton.icon(
                  key: const ValueKey("turn-activity-stop"),
                  onPressed: onStop,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    foregroundColor: cs.error,
                  ),
                  icon: Icon(Icons.stop, size: 16, color: cs.error),
                  label: Text(
                    "停止",
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(fontSize: 12, color: cs.error),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}