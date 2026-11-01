import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/ui/messages/message_widgets.dart';

/// v2.6 回归：消息去颜色化——红/黄/绿分组下线，AI 评估的 priority 仍落库，
/// 但不再决定分组。v2.6.3：新增「已处理」分组（status=processed 且非垃圾），
/// 与「已完成」筛选键（关联任务 done，叠加维度）区分。
void main() {
  Message msg(String priority,
          {String status = MessageStatus.pending}) =>
      Message(
        id: 'm-$priority-$status',
        packageName: 'pkg',
        title: 't',
        body: 'b',
        postedAt: 0,
        captureType: 'notification',
        contentHash: 'h-$priority-$status',
        priority: priority,
        status: status,
        createdAt: 0,
      );

  test('分组键：pending 的红/黄/绿/未评估全部归未处理', () {
    expect(messageGroupKey(msg(MessagePriority.red)), kGroupPending);
    expect(messageGroupKey(msg(MessagePriority.yellow)), kGroupPending);
    expect(messageGroupKey(msg(MessagePriority.green)), kGroupPending);
    expect(messageGroupKey(msg(MessagePriority.none)), kGroupPending);
  });

  test('分组键：status=processed 且非垃圾归已处理（v2.6.3）', () {
    expect(
        messageGroupKey(msg(MessagePriority.none,
            status: MessageStatus.processed)),
        kGroupProcessed);
    expect(
        messageGroupKey(msg(MessagePriority.green,
            status: MessageStatus.processed)),
        kGroupProcessed);
  });

  test('分组键：垃圾优先于已处理（processed 的垃圾仍归垃圾组）', () {
    expect(messageGroupKey(msg(MessagePriority.junk)), MessagePriority.junk);
    expect(
        messageGroupKey(msg(MessagePriority.junk,
            status: MessageStatus.processed)),
        MessagePriority.junk);
  });

  test('分组顺序与筛选 chips：未处理/已处理/垃圾（归档页沿用）', () {
    expect(kGroupOrder,
        [kGroupPending, kGroupProcessed, MessagePriority.junk]);
    expect(messageGroupLabel(kGroupPending), '未处理');
    expect(messageGroupLabel(kGroupProcessed), '已处理');
    expect(messageGroupLabel(MessagePriority.junk), '垃圾');
  });

  // ---- 2026-11-01 状态新规（消息列表四分组，与关联任务联动） ----

  test('展示分组：未标记已处理 → 未处理；显式垃圾恒为垃圾', () {
    expect(
        messageDisplayGroupKey(msg(MessagePriority.none),
            linkedTaskCount: 2, linkedAllDone: false),
        kGroupPending);
    expect(
        messageDisplayGroupKey(
            msg(MessagePriority.junk, status: MessageStatus.processed),
            linkedTaskCount: 1,
            linkedAllDone: true),
        MessagePriority.junk,
        reason: '显式垃圾优先于一切');
  });

  test('展示分组：已处理按关联任务推导 完成/垃圾/未完成', () {
    final processed = msg(MessagePriority.none, status: MessageStatus.processed);
    expect(
        messageDisplayGroupKey(processed,
            linkedTaskCount: 0, linkedAllDone: false),
        MessagePriority.junk,
        reason: '已处理且无关联任务 → 垃圾');
    expect(
        messageDisplayGroupKey(processed,
            linkedTaskCount: 2, linkedAllDone: true),
        kFilterDone,
        reason: '关联任务全部完成 → 完成');
    expect(
        messageDisplayGroupKey(processed,
            linkedTaskCount: 2, linkedAllDone: false),
        kGroupUnfinished,
        reason: '有未完成的关联任务 → 未完成');
  });

  test('展示分组顺序：未处理/未完成/完成/垃圾', () {
    expect(kDisplayGroupOrder,
        [kGroupPending, kGroupUnfinished, kFilterDone, MessagePriority.junk]);
    expect(messageGroupLabel(kGroupUnfinished), '未完成');
    expect(messageGroupLabel(kFilterDone), '完成');
  });

  // ---- 2026-11-01 分组分页（每组首屏 10 条 + 显示更多 5 条） ----

  test('分组分页常量：首屏 10、步进 5', () {
    expect(kGroupPageInitial, 10);
    expect(kGroupPageStep, 5);
  });

  test('pagedPrefix：取前 N 条，越界收敛到全组', () {
    final all = List.generate(23, (i) => i);
    expect(pagedPrefix(all, kGroupPageInitial), hasLength(10));
    expect(pagedPrefix(all, kGroupPageInitial + kGroupPageStep), hasLength(15));
    expect(pagedPrefix(all, 999), hasLength(23), reason: '超出全长收敛');
    expect(pagedPrefix(all, 0), isEmpty);
    expect(pagedPrefix(all, -3), isEmpty, reason: '负数收敛为空');
  });
}
