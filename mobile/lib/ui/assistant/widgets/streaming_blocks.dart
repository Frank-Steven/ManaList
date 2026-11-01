import 'package:flutter/material.dart';

import '../../../services/assistant/tool_spec.dart';

/// 一轮流式回复的一个分段（2026-11-01）：
/// 思考块（<think> 标签）、工具块（```tool 围栏块）、正文文本段。
/// 一轮对话中 Agent 可多次「思考 → 输出 → 调工具 → 再思考」，
/// 各段按产生顺序排列，直到回合结束。
class ChatStreamSegment {
  ChatStreamSegment({required this.kind, required this.startedAt});

  final ChatStreamSegmentKind kind;
  final DateTime startedAt;
  DateTime? endedAt;

  /// 文本/思考段内容；工具段不用。
  String text = '';

  /// 仍在流入中（段落未闭合）。
  bool active = true;

  // ---- 工具段专有 ----
  int blockIndex = 0;
  String? toolName;

  /// 人类可读一句话摘要（proposal.summary，如「新建任务『买牛奶』」），
  /// 工具块标题优先用它而不是工具名。
  String? summary;

  /// 状态文本：执行中 / 待确认 / 已回注 / 未能理解，已跳过。
  String status = '执行中';

  /// 展开后的详情（自然语言描述 / 回注结果），不放裸 JSON。
  String? detail;

  /// 失败态（校验失败被跳过）。
  bool failed = false;

  /// 展开/收起。
  bool expanded = false;

  int get elapsedSeconds {
    final end = endedAt ?? DateTime.now();
    final s = end.difference(startedAt).inMilliseconds / 1000;
    return s < 0 ? 0 : s.round();
  }

  void settle() {
    active = false;
    endedAt ??= DateTime.now();
  }
}

enum ChatStreamSegmentKind { text, thinking, tool }

/// 工具名 →（人类可读名, 图标）（2026-11-01 工具块去裸代码化）。
/// 唯一事实源是 [ToolNames]，未知工具给通用兜底。
(String, IconData) toolDisplay(String? tool) => switch (tool) {
      ToolNames.taskCreate => ('新建任务', Icons.add_task),
      ToolNames.taskUpdate => ('修改任务', Icons.edit_calendar_outlined),
      ToolNames.taskDelete => ('删除任务', Icons.delete_outline),
      ToolNames.taskList => ('列出任务', Icons.format_list_bulleted),
      ToolNames.taskSearch => ('搜索任务', Icons.travel_explore_outlined),
      ToolNames.noteCreate => ('新建笔记', Icons.note_add_outlined),
      ToolNames.noteAppend => ('追加笔记内容', Icons.post_add_outlined),
      ToolNames.noteReplaceSection =>
        ('替换笔记区段', Icons.find_replace_outlined),
      ToolNames.noteRead => ('读取笔记', Icons.menu_book_outlined),
      ToolNames.anchorCreate => ('建立任务锚点', Icons.anchor_outlined),
      ToolNames.anchorRemove => ('移除锚点', Icons.link_off_outlined),
      ToolNames.librarySearch => ('搜索库内容', Icons.manage_search_outlined),
      ToolNames.messageSetPriority => ('标记消息优先级', Icons.label_outline),
      ToolNames.inboxTriage => ('整理收件箱', Icons.move_to_inbox_outlined),
      _ => ('工具调用', Icons.build_outlined),
    };

/// 「正在输入」呼吸圆点光标（2026-11-01 替代进度圈 + 文字块）：
/// 呼吸节奏（900ms 往返）的透明度/缩放振荡，显示在流式文本末尾。
class BreathingDot extends StatefulWidget {
  final double size;
  final Color? color;

  const BreathingDot({super.key, this.size = 7, this.color});

  @override
  State<BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<BreathingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

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
        final v = Curves.easeInOut.transform(_ctrl.value);
        return Opacity(
          opacity: 0.25 + 0.75 * v,
          child: Transform.scale(
            scale: 0.75 + 0.35 * v,
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration:
                  BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
        );
      },
    );
  }
}

/// 状态中的数字用等宽数字（timer/tabular figures），跳动时不晃。
TextStyle statusDigitsStyle(TextStyle? base) => (base ?? const TextStyle())
    .copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

/// 「延迟输出两个词」的截断点：流式文本先稳住换行位置，
/// 末尾两个词（CJK 无空白分隔时近似为 2 个字符）等后续文本到了再放行。
int holdBackTwoWords(String text) {
  if (text.isEmpty) return 0;
  final words = RegExp(r'\S+').allMatches(text).toList();
  if (words.length >= 3) return words[words.length - 2].start;
  // 不足三个词（纯 CJK 整段或刚起头）：按住末尾 2 个字符
  if (text.length > 4) return text.length - 2;
  return 0;
}

/// 流式文本：新增内容淡入；未落定（[settled] = false）时按住末尾
/// 两个词不放行，保证换行位置稳定。[showCursor] 时末尾挂呼吸圆点
/// 光标（回合进行中的活动指示，替代旧「正在输入…」块）。
class FadeInStreamingText extends StatefulWidget {
  final String text;

  /// true = 段落已闭合/回合已结束：全文显示，不再按住末尾。
  final bool settled;
  final TextStyle? style;

  /// 在文本末尾显示呼吸圆点光标（仅活动中的尾部文本段）。
  final bool showCursor;

  const FadeInStreamingText({
    super.key,
    required this.text,
    this.settled = false,
    this.style,
    this.showCursor = false,
  });

  @override
  State<FadeInStreamingText> createState() => _FadeInStreamingTextState();
}

class _FadeInStreamingTextState extends State<FadeInStreamingText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 280), value: 1);

  /// 已完全 opaque 的前缀长度。
  int _opaqueLen = 0;

  /// 当前实际显示到的长度（按住末尾两词后的截断点）。
  int _targetLen = 0;

  @override
  void initState() {
    super.initState();
    _opaqueLen = _targetLen = _targetOf(widget);
  }

  @override
  void didUpdateWidget(FadeInStreamingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = _targetOf(widget);
    if (target > _targetLen) {
      // 之前显示的部分转全不透明，新放行的一段淡入
      _opaqueLen = _targetLen;
      _targetLen = target;
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  int _targetOf(FadeInStreamingText w) =>
      w.settled ? w.text.length : holdBackTwoWords(w.text);

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    final len = _targetLen.clamp(0, text.length);
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    final color = base.color ?? Theme.of(context).colorScheme.onSurface;
    // 空文本也可以只显示光标（回合刚开始、首个 token 未到时）
    if (len == 0 && !widget.showCursor) return const SizedBox.shrink();
    final shown = text.substring(0, len);
    final opaqueEnd = _opaqueLen.clamp(0, len);
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Text.rich(
          TextSpan(children: [
            TextSpan(text: shown.substring(0, opaqueEnd)),
            TextSpan(
              text: shown.substring(opaqueEnd),
              style: TextStyle(
                  color: color.withValues(alpha: _ctrl.value)),
            ),
            if (widget.showCursor)
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.only(left: 3),
                  child: BreathingDot(
                      size: (base.fontSize ?? 14) * 0.5, color: color),
                ),
              ),
          ]),
          style: base,
        );
      },
    );
  }
}

/// 思考块（可展开/收起）：头部「思考 + 状态（思考中 Ns / 已思考 Ns）」，
/// 展开看推理全文；流式期间内容淡入。
class ThinkingBlock extends StatelessWidget {
  final ChatStreamSegment segment;
  final VoidCallback onToggle;

  const ThinkingBlock({
    super.key,
    required this.segment,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final statusStyle = statusDigitsStyle(
        TextStyle(fontSize: 11, color: cs.onSurfaceVariant));
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.psychology_outlined,
                      size: 15, color: cs.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text('思考',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurfaceVariant)),
                  const SizedBox(width: 6),
                  Text(
                    segment.active
                        ? '思考中 ${segment.elapsedSeconds}s'
                        : '已思考 ${segment.elapsedSeconds}s',
                    style: statusStyle,
                  ),
                  if (segment.active) ...[
                    const SizedBox(width: 6),
                    SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.5, color: cs.onSurfaceVariant)),
                  ],
                  const Spacer(),
                  Icon(
                      segment.expanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      size: 16,
                      color: cs.onSurfaceVariant),
                ],
              ),
            ),
          ),
          if (segment.expanded && segment.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: FadeInStreamingText(
                text: segment.text,
                settled: !segment.active,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

/// 工具块（可展开/收起，2026-11-01 去裸代码化）：
/// 头部「工具图标 + 自然语言标题（提案摘要，回退到工具可读名）+ 状态」，
/// 展开看自然语言详情 / 回注结果，不再显示参数 JSON。
class ToolCallBlock extends StatelessWidget {
  final ChatStreamSegment segment;
  final VoidCallback onToggle;

  const ToolCallBlock({
    super.key,
    required this.segment,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (displayName, icon) = toolDisplay(segment.toolName);
    final title = segment.summary ?? displayName;
    final hasDetail = (segment.detail ?? '').isNotEmpty;
    final statusColor = segment.failed
        ? cs.error
        : segment.active
            ? cs.primary
            : cs.onSurfaceVariant;
    final statusStyle = statusDigitsStyle(
        TextStyle(fontSize: 11, color: statusColor));
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: segment.failed ? cs.error : cs.outlineVariant,
            width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: hasDetail ? onToggle : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Icon(icon, size: 15, color: cs.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    segment.active
                        ? '${segment.status} ${segment.elapsedSeconds}s'
                        : segment.status,
                    style: statusStyle,
                  ),
                  if (segment.active) ...[
                    const SizedBox(width: 6),
                    const BreathingDot(size: 6),
                  ],
                  const Spacer(),
                  if (hasDetail)
                    Icon(
                        segment.expanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 16,
                        color: cs.onSurfaceVariant),
                ],
              ),
            ),
          ),
          if (segment.expanded && hasDetail)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(
                segment.detail!,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}
