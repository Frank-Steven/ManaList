import 'package:flutter/material.dart';

/// 空对话建议 chips（assistant-v4-ui §3.8）：按真实数据生成，最多 3 条。
///
/// 纯函数便于单测：收件箱有未处理 → 整理建议；今天有进行中任务 → 排程建议；
/// 两者皆无 → 通用「记一篇笔记」。
List<String> suggestionPrompts({
  required int pendingMessages,
  required int todayOpenTasks,
}) {
  final out = <String>[];
  if (pendingMessages > 0) {
    out.add('帮我整理收件箱（$pendingMessages 条未处理）');
  }
  if (todayOpenTasks > 0) {
    out.add('排一下今天的安排（$todayOpenTasks 项）');
  }
  if (out.isEmpty) out.add('记一篇笔记');
  return out.take(3).toList();
}

/// 建议 chips：横滑列表，点击即选用（由调用方决定填入输入框或直接发送）。
class SuggestionChips extends StatelessWidget {
  final List<String> prompts;
  final ValueChanged<String> onPick;

  const SuggestionChips({
    super.key,
    required this.prompts,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          for (final p in prompts)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                label: Text(p, style: const TextStyle(fontSize: 13)),
                backgroundColor: cs.secondaryContainer,
                side: BorderSide.none,
                shape: const StadiumBorder(),
                onPressed: () => onPick(p),
              ),
            ),
        ],
      ),
    );
  }
}
