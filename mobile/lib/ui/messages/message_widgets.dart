import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../../models/message.dart';
import '../../services/fold_markers.dart';
import '../../services/undo_service.dart';
import '../shared/priority_dot.dart';

/// 未处理分组键（设计 §5.1）。
const String kGroupPending = 'pending';

/// 已处理分组键（v2.6.3）：status=processed 且非垃圾的消息（AI 处理并确认过，
/// 关联任务未必完成；与「已完成」筛选键是两个维度）。
const String kGroupProcessed = 'processed';

/// 「已完成」筛选键（v2.4）：不占分组，选中时额外显示关联任务已完成的消息。
const String kFilterDone = 'done';

/// 分组展示顺序：未处理 → 已处理 → 垃圾（v2.6 去颜色化：红/黄/绿分组下线，
/// AI 评估的 priority 仍落库，只是列表不再按它分组/染色；v2.6.3 增已处理组）。
const List<String> kGroupOrder = [
  kGroupPending,
  kGroupProcessed,
  MessagePriority.junk,
];

/// 分组键规则（三组互斥）：垃圾（priority=junk）单独一组；status=processed
/// 归已处理；其余全部归未处理。
String messageGroupKey(Message m) {
  if (m.priority == MessagePriority.junk) return MessagePriority.junk;
  if (m.status == MessageStatus.processed) return kGroupProcessed;
  return kGroupPending;
}

/// 未完成分组键（2026-11-01 状态四分组）：已处理、有关联任务、但未全部完成。
const String kGroupUnfinished = 'unfinished';

/// 消息列表的展示分组顺序（2026-11-01 状态新规，取代原「未处理/已处理/垃圾 +
/// 已完成特殊筛选」）：未处理 → 未完成 → 完成 → 垃圾。
/// 「完成」复用 [kFilterDone] 的键值（'done'），语义升级为正式分组。
const List<String> kDisplayGroupOrder = [
  kGroupPending,
  kGroupUnfinished,
  kFilterDone,
  MessagePriority.junk,
];

/// 展示分组键（2026-11-01 状态新规，与关联任务联动）：
/// - 显式标记垃圾（priority=junk）恒为垃圾；
/// - 未标记已处理 → 未处理；
/// - 已处理：无关联任务 → 垃圾；关联任务全部完成 → 完成；否则 → 未完成。
String messageDisplayGroupKey(Message m,
    {required int linkedTaskCount, required bool linkedAllDone}) {
  if (m.priority == MessagePriority.junk) return MessagePriority.junk;
  if (m.status != MessageStatus.processed) return kGroupPending;
  if (linkedTaskCount == 0) return MessagePriority.junk;
  if (linkedAllDone) return kFilterDone;
  return kGroupUnfinished;
}

String messageGroupLabel(String key) => switch (key) {
      kGroupPending => '未处理',
      kGroupProcessed => '已处理',
      kGroupUnfinished => '未完成',
      MessagePriority.junk => '垃圾',
      kFilterDone => '完成',
      _ => key,
    };

/// 分组图标（2026-11-01 筛选 chip 图标化）。
IconData messageGroupIcon(String key) => switch (key) {
      kGroupPending => Icons.mark_email_unread_outlined,
      kGroupProcessed => Icons.fact_check_outlined,
      kGroupUnfinished => Icons.pending_actions_outlined,
      MessagePriority.junk => Icons.delete_outline,
      kFilterDone => Icons.task_alt,
      _ => Icons.label_outline,
    };

/// 分组分页（2026-11-01）：每个最小分类单元（来源/会话）首屏
/// [kGroupPageInitial] 条，点「显示更多」每次 +[kGroupPageStep]
/// （取代原全局最近 500 条截断）。
const int kGroupPageInitial = 10;
const int kGroupPageStep = 5;

/// 取一组消息当前应展示的前缀；shown 越界时收敛到全组。
List<T> pagedPrefix<T>(List<T> all, int shown) =>
    all.take(shown.clamp(0, all.length)).toList();

/// AI 评估三色的圆点颜色（仅 AI 面板展示评估结果用；v2.6 起消息列表
/// 不再按它染色）；未处理/垃圾返回 null（用空心圆点）。
Color? messageGroupDotColor(String key) => switch (key) {
      MessagePriority.red => Colors.red,
      MessagePriority.yellow => Colors.amber,
      MessagePriority.green => Colors.green,
      _ => null,
    };

/// 今天显示 HH:mm，否则 MM-dd HH:mm。
String formatMessageTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(d.hour)}:${two(d.minute)}';
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return hm;
  }
  return '${two(d.month)}-${two(d.day)} $hm';
}

/// 操作成功后的撤销 SnackBar（设计 §6，v2.4 重做）：「{label}」+ 撤销按钮 +
/// 底部细进度条（剩余时间，4 秒）。按住或鼠标悬停时暂停倒计时并回满，
/// 松开/移出后继续；超时自动关闭。撤销注册由调用方在调用本函数前完成。
void showUndoSnackBar(BuildContext context, String label,
    {VoidCallback? onUndone, ScaffoldMessengerState? messenger}) {
  final m = messenger ?? ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(
    SnackBar(
      // 关闭时机由内容里的进度控制器自管，时长设长避免系统提前收起
      duration: const Duration(days: 1),
      content: _UndoSnackContent(
        label: label,
        onExpired: m.hideCurrentSnackBar,
        onUndo: () async {
          m.hideCurrentSnackBar();
          await UndoService.instance.undoLatest();
          onUndone?.call();
        },
      ),
    ),
  );
}

/// 撤销 SnackBar 内容：文本 + 撤销按钮 + 底部剩余时间细条。
class _UndoSnackContent extends StatefulWidget {
  final String label;
  final VoidCallback onExpired;
  final VoidCallback onUndo;

  const _UndoSnackContent({
    required this.label,
    required this.onExpired,
    required this.onUndo,
  });

  @override
  State<_UndoSnackContent> createState() => _UndoSnackContentState();
}

class _UndoSnackContentState extends State<_UndoSnackContent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed && mounted) widget.onExpired();
      })
      ..forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 按住/悬停：暂停并回满（进度回 0 = 剩余时间重置）。
  void _hold() {
    _ctrl.stop();
    _ctrl.animateTo(0, duration: const Duration(milliseconds: 200));
  }

  /// 松开/移出：从满格重新倒计时。
  void _release() {
    _ctrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 与 SnackBar 主题联动的动作色（v2.6：深色模式深色底 + primary 动作色）
    final actionColor = Theme.of(context).snackBarTheme.actionTextColor ??
        cs.inversePrimary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _hold(),
      onTapUp: (_) => _release(),
      onTapCancel: _release,
      child: MouseRegion(
        onEnter: (_) => _hold(),
        onExit: (_) => _release(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(widget.label)),
                TextButton(
                  onPressed: widget.onUndo,
                  style: TextButton.styleFrom(foregroundColor: actionColor),
                  child: const Text('撤销'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) => LinearProgressIndicator(
                value: 1 - _ctrl.value,
                minHeight: 2,
                backgroundColor: Colors.transparent,
                color: actionColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 左滑露出的块状菜单按钮定义。
class SwipeAction {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const SwipeAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
}

/// 块状滑出菜单（设计 §5.1，v2.1 重做；2026-11-08 F3 手势统一：右滑 = 积极
/// 动作「归档/取出/移出垃圾」，左滑 = 消极/管理「垃圾/删除/任务」）：基于
/// flutter_slidable。
/// - 轻扫 ≥40dp 或快速甩动即展开，松手吸附全展/全关（openThreshold 压到
///   40dp 以内；甩动由库的 OpeningGesture 直接展开）；
/// - 展开后点动作块必触发（动作块由库渲染在行内容之外的独立层）；
/// - 展开后点击行内容或反扫收起；
/// - 不设 groupTag / SlidableAutoCloseBehavior：多行各自独立展开，互不干扰。
class SwipeActionRow extends StatefulWidget {
  final Widget child;

  /// 右滑（行首）露出的积极动作（ux-fixes §3.1-2）。
  final List<SwipeAction> startActions;

  /// 左滑（行尾）露出的消极/管理动作。
  final List<SwipeAction> actions;
  final bool swipeEnabled;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const SwipeActionRow({
    super.key,
    required this.child,
    this.startActions = const [],
    this.actions = const [],
    this.swipeEnabled = true,
    this.onTap,
    this.onLongPress,
  });

  @override
  State<SwipeActionRow> createState() => _SwipeActionRowState();
}

class _SwipeActionRowState extends State<SwipeActionRow>
    with SingleTickerProviderStateMixin {
  static const _actionWidth = 72.0;
  static const _openThresholdDp = 40.0;

  late final SlidableController _controller = SlidableController(this);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    // 展开时点击行内容 = 收起（不触发行点击）；收起时正常行点击
    if (_controller.ratio != 0) {
      _controller.close();
    } else {
      widget.onTap?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSwipe = widget.swipeEnabled &&
        (widget.actions.isNotEmpty || widget.startActions.isNotEmpty);
    final content = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      onLongPress: widget.onLongPress,
      child: widget.child,
    );
    if (!canSwipe) return content;
    final width = MediaQuery.sizeOf(context).width;
    return Slidable(
      controller: _controller,
      startActionPane: widget.startActions.isEmpty
          ? null
          : _buildPane(widget.startActions, width),
      endActionPane: widget.actions.isEmpty
          ? null
          : _buildPane(widget.actions, width),
      child: content,
    );
  }

  ActionPane _buildPane(List<SwipeAction> actions, double width) {
    return ActionPane(
      motion: const BehindMotion(),
      extentRatio: (actions.length * _actionWidth / width).clamp(0.1, 1.0),
      openThreshold: (_openThresholdDp / width).clamp(0.05, 0.9),
      children: [
        for (final a in actions)
          CustomSlidableAction(
            backgroundColor: Colors.transparent,
            padding: EdgeInsets.zero,
            onPressed: (_) => a.onTap(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
              child: Container(
                width: double.infinity,
                height: double.infinity,
                decoration: BoxDecoration(
                  color: a.color,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(a.icon, color: Colors.white, size: 20),
                    const SizedBox(height: 4),
                    Text(
                      a.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 消息卡片（v2.4 卡片化；v2.6 去颜色化；2026-11-01 第三批重构版式）：
/// 左侧标记 + 标题（群名/发送者）/正文（主视觉，最多 3 行）/来源脚注
/// （应用图标在分组吸顶头，不逐卡重复）+ 右侧时间。圆角 14、多选选中
/// 主色描边。标记规则（v2.6）：绑定任务的消息显示其任务优先级色点
/// （+ 任务角标）；未绑定 = 空心圆点；垃圾 = 灰色消息块 + 标题划线。
/// 关联任务已完成的消息标题划线变淡。
class MessageTile extends StatefulWidget {
  final Message message;
  final bool selecting;
  final bool selected;
  final bool swipeEnabled;

  /// 右滑露出的积极动作（归档/取出/移出垃圾，ux-fixes §3.1-2）。
  final List<SwipeAction> startActions;

  /// 左滑露出的消极/管理动作（垃圾/删除/任务）。
  final List<SwipeAction> actions;

  /// 嵌套模式（2026-11-01 嵌套卡片列表）：不作为独立卡片渲染
  /// （无外边距/底色/圆角），由父级分组卡片提供容器；
  /// 选中态改为整行底色高亮（原独立卡片的主色描边不适用）。
  final bool embedded;

  /// 关联任务已完成（v2.4「已完成」筛选）：标题划线降色。
  final bool linkedTaskDone;

  /// 关联任务的优先级（v2.6：绑定任务的消息标记显示任务优先级色点）。
  final String? linkedTaskPriority;
  /// 关联任务数量（N1 多对多）：>1 时标记处显示数量角标。
  final int linkedTaskCount;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const MessageTile({
    super.key,
    required this.message,
    this.selecting = false,
    this.selected = false,
    this.swipeEnabled = true,
    this.startActions = const [],
    this.actions = const [],
    this.embedded = false,
    this.linkedTaskDone = false,
    this.linkedTaskPriority,
    this.linkedTaskCount = 0,
    this.onTap,
    this.onLongPress,
  });

  @override
  State<MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<MessageTile> {

  void _handleTap() {
    // P3-2：非选中状态下点击 = 打开详情面板（正文 + 附件预览）。
    // 原地展开仍由右侧箭头按钮负责，避免两种行为抢同一个手势。
    widget.onTap?.call();
  }

  Widget _marker(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // v2.6：只有绑定任务的消息才显示颜色（其任务优先级色点）；其余空心圆点。
    // N1：一条消息可能关联多个任务，>1 时右下角改成数量角标。
    final taskPriority =
        widget.linkedTaskCount == 0 ? null : widget.linkedTaskPriority;
    final Widget dot = taskPriority == null
        ? Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: cs.outline, width: 1.5),
            ),
          )
        : Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: taskPriorityDotColor(taskPriority)),
          );
    if (widget.linkedTaskCount == 0) return dot;
    final Widget badge = widget.linkedTaskCount > 1
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: cs.primary,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '${widget.linkedTaskCount}',
              style: TextStyle(
                  fontSize: 10,
                  height: 1.2,
                  color: cs.onPrimary,
                  fontWeight: FontWeight.w600),
            ),
          )
        : Icon(Icons.task_alt,
            size: 12,
            color: widget.linkedTaskDone ? cs.outline : cs.primary);
    return SizedBox(
      width: 22,
      height: 20,
      child: Stack(
        children: [
          Positioned(left: 0, top: 0, child: dot),
          Positioned(right: 0, bottom: 0, child: badge),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final message = widget.message;
    final isJunk = message.priority == MessagePriority.junk;
    // U7（后半）：消息页「突出内容、弱化来源」。
    // - 正文为主视觉（15、onSurface、最多 3 行）；
    // - 标题（群名/发送者）降为次要信息（13、onSurfaceVariant）；
    // - 来源应用降到脚注级（11、outline）。
    // 若消息没有正文（纯标题通知），标题自动升级为主视觉，避免整卡变灰。
    final hasBody = message.body.isNotEmpty;
    final contentStyle = TextStyle(
      fontSize: 15,
      height: 1.35,
      color: isJunk
          ? cs.outline
          : (widget.linkedTaskDone ? cs.onSurfaceVariant : cs.onSurface),
      decoration:
          (isJunk || widget.linkedTaskDone) ? TextDecoration.lineThrough : null,
    );
    final titleStyle = hasBody
        ? TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: isJunk ? cs.outline : cs.onSurfaceVariant,
            decoration: (isJunk || widget.linkedTaskDone)
                ? TextDecoration.lineThrough
                : null,
          )
        : contentStyle;
    final timeStyle = TextStyle(fontSize: 12, color: cs.onSurfaceVariant);
    final sourceStyle = TextStyle(fontSize: 11, color: cs.outline);

    final body = SwipeActionRow(
      startActions: widget.startActions,
      actions: widget.actions,
      swipeEnabled: widget.swipeEnabled && !widget.selecting,
      onTap: _handleTap,
      onLongPress: widget.onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 多选勾选统一在行首（2026-11-01 与任务/文件区一致）
            if (widget.selecting)
              Padding(
                padding: const EdgeInsets.only(right: 10, top: 1),
                child: Icon(
                  widget.selected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  size: 20,
                  color: widget.selected ? cs.primary : cs.outline,
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: _marker(context),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 首行：标题（群名/发送者）+ 时间
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          message.title.isEmpty
                              ? '(无标题)'
                              : stripFoldMarkers(message.title),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(formatMessageTime(message.postedAt),
                          style: timeStyle),
                    ],
                  ),
                  // 正文为主视觉（最多 3 行）
                  if (message.body.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      message.body,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: contentStyle,
                    ),
                  ],
                  // 脚注：来源应用 · 会话（图标在分组吸顶头，不逐卡重复）
                  if (message.appName?.isNotEmpty == true ||
                      message.conversationTitle?.isNotEmpty == true) ...[
                    const SizedBox(height: 4),
                    Text(
                      (message.appName?.isNotEmpty == true
                              ? message.appName!
                              : message.packageName) +
                          (message.conversationTitle?.isNotEmpty == true
                              ? ' · ${stripFoldMarkers(message.conversationTitle!)}'
                              : ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sourceStyle,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // 嵌套模式：父级分组卡片提供容器，本行只做选中底色
    if (widget.embedded) {
      return Container(
        color: widget.selected
            ? cs.secondaryContainer.withValues(alpha: 0.5)
            : null,
        child: body,
      );
    }
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: isJunk ? cs.surfaceContainerHighest : cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        // 多选态选中 = 主色描边（与文件区卡片同一语言）
        side: widget.selected
            ? BorderSide(color: cs.primary, width: 1.5)
            : BorderSide.none,
      ),
      child: body,
    );
  }
}

/// 吸顶分组头（设计 §5.1）：始终显示在组首，点击折叠/展开。
class MessageGroupHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String groupKey;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;

  MessageGroupHeaderDelegate({
    required this.groupKey,
    required this.count,
    required this.collapsed,
    required this.onToggle,
  });

  /// v2.6：36 → 44，触控友好（≥44dp 触控区）。
  static const double kHeight = 44;

  @override
  double get minExtent => kHeight;

  @override
  double get maxExtent => kHeight;

  @override
  bool shouldRebuild(MessageGroupHeaderDelegate oldDelegate) =>
      groupKey != oldDelegate.groupKey ||
      count != oldDelegate.count ||
      collapsed != oldDelegate.collapsed;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final cs = Theme.of(context).colorScheme;
    final dotColor = messageGroupDotColor(groupKey);
    return Material(
      color: cs.surface,
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              if (dotColor != null) ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle, color: dotColor),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                messageGroupLabel(groupKey),
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface),
              ),
              const SizedBox(width: 8),
              Text('$count',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              const Spacer(),
              Icon(
                collapsed ? Icons.expand_more : Icons.expand_less,
                size: 20,
                color: cs.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 多选模式底部图标按钮条的一项。
class SelectionAction {
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  const SelectionAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
  });
}

/// 多选模式底部图标按钮条（设计 §5.1）。
class SelectionActionBar extends StatelessWidget {
  final List<SelectionAction> actions;

  const SelectionActionBar({super.key, required this.actions});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (final a in actions)
                IconButton(
                  tooltip: a.tooltip,
                  onPressed: a.enabled ? a.onTap : null,
                  icon: Icon(a.icon),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
