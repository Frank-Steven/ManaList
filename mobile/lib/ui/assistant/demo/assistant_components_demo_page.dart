import 'package:flutter/material.dart';
import '../widgets/auto_scroll_title.dart';
import '../widgets/code_block.dart';
import '../widgets/collapsible_content.dart';
import '../widgets/context_meter.dart';
import '../widgets/streaming_blocks.dart';
import '../widgets/tool_steps_group.dart';
import '../widgets/turn_activity_bar.dart';
import '../../../services/assistant/assistant_service.dart' show TurnPhase;

/// F31：组件展示页（Frank 建议）——把所有静态/动态状态罗列到一个 demo 对话，
/// 逐个对着调样式，不受旧 chat_page 约束。
class AssistantComponentsDemoPage extends StatefulWidget {
  const AssistantComponentsDemoPage({super.key});
  @override
  State<AssistantComponentsDemoPage> createState() => _DemoState();
}

class _DemoState extends State<AssistantComponentsDemoPage> {
  bool _busy = true;
  final int _completedSteps = 2;

  ChatStreamSegment _toolSeg(String status, {bool failed = false, bool active = false}) {
    final s = ChatStreamSegment(kind: ChatStreamSegmentKind.tool, startedAt: DateTime.now())
      ..status = status
      ..failed = failed
      ..active = active
      ..summary = '读取任务列表'
      ..detail = '返回 50 条任务，含 3 条高优先级'
      ..toolName = 'task.list'
      ..endedAt = DateTime.now();
    return s;
  }

  ChatStreamSegment _thinkSeg({bool active = false}) {
    return ChatStreamSegment(kind: ChatStreamSegmentKind.thinking, startedAt: DateTime.now())
      ..text = '让我想想……先读取任务，再按优先级排序。'
      ..active = active
      ..endedAt = DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const SizedBox(width: 180, child: AutoScrollTitle(text: '组件展示页：全部静态/动态状态')),
        actions: [
          IconButton(
            icon: const Icon(Icons.play_arrow),
            onPressed: () => setState(() => _busy = !_busy),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _section('主进行态（各阶段）', [
            for (final p in TurnPhase.values)
              TurnActivityBar(
                phase: p,
                active: p != TurnPhase.done && p != TurnPhase.error,
                completedSteps: _completedSteps,
                pendingCount: p == TurnPhase.done ? 2 : 0,
                onStop: () {},
              ),
          ]),
          _section('思考块', [
            ThinkingBlock(segment: _thinkSeg(), onToggle: () {}),
            ThinkingBlock(segment: _thinkSeg(active: true), onToggle: () {}),
          ]),
          _section('工具块（成功/失败/执行中）', [
            ToolCallBlock(segment: _toolSeg('已回注'), onToggle: () {}),
            ToolCallBlock(segment: _toolSeg('未能理解，已跳过', failed: true), onToggle: () {}),
            ToolCallBlock(segment: _toolSeg('执行中', active: true), onToggle: () {}),
          ]),
          _section('工具聚合（2+ 成功）', [
            ToolStepsGroup(
              steps: [_toolSeg('已回注'), _toolSeg('已回注'), _toolSeg('已回注')],
              onStepToggle: (_) {},
            ),
          ]),
          _section('正文（短/长）', [
            const CollapsibleContent(child: Text('短回复')),
            CollapsibleContent(child: Column(children: List.generate(30, (i) => Text('第 $i 行长文')))),
          ]),
          _section('用户 pill（短/长）', [
            Align(alignment: Alignment.centerRight, child: _pill('好的')),
            Align(alignment: Alignment.centerRight, child: _pill('这是一段很长的用户消息，用来验证三行折叠与展开全文。' * 3)),
          ]),
          _section('代码块', [
            MarkdownCodeBlock(code: 'final result = computeSomething(alpha, beta, gamma, delta);', colorScheme: cs),
          ]),
          _section('上下文圆环', [
            const ContextMeter(usedTokens: 2400),
            const ContextMeter(usedTokens: 0),
            const ContextMeter(usedTokens: 70000),
          ]),
          _section('流式正文', [
            const FadeInStreamingText(text: '正在生成中的正文……', showCursor: false),
            const FadeInStreamingText(text: '已完成的正文。', settled: true),
          ]),
        ],
      ),
    );
  }

  Widget _pill(String text) => Container(
        constraints: const BoxConstraints(maxWidth: 300),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16), topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16), bottomRight: Radius.circular(4),
          ),
        ),
        child: CollapsibleLines(text: text, style: const TextStyle(color: Colors.white)),
      );

  Widget _section(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      );
}
