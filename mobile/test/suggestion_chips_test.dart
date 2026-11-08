import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/suggestion_chips.dart';

/// 空对话建议 chips（assistant-v4-ui §3.8）：数据条件 → 建议文本映射。
void main() {
  test('收件箱有未处理 → 整理建议（带计数）', () {
    final r = suggestionPrompts(pendingMessages: 12, todayOpenTasks: 0);
    expect(r, ['帮我整理收件箱（12 条未处理）']);
  });

  test('今天有进行中任务 → 排程建议（带计数）', () {
    final r = suggestionPrompts(pendingMessages: 0, todayOpenTasks: 3);
    expect(r, ['排一下今天的安排（3 项）']);
  });

  test('两者都有 → 两条建议，收件箱在前', () {
    final r = suggestionPrompts(pendingMessages: 5, todayOpenTasks: 2);
    expect(r, ['帮我整理收件箱（5 条未处理）', '排一下今天的安排（2 项）']);
  });

  test('全空 → 通用「记一篇笔记」兜底', () {
    expect(suggestionPrompts(pendingMessages: 0, todayOpenTasks: 0),
        ['记一篇笔记']);
  });

  test('最多 3 条', () {
    expect(
        suggestionPrompts(pendingMessages: 9, todayOpenTasks: 9).length,
        lessThanOrEqualTo(3));
  });
}
