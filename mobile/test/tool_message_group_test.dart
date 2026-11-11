import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:msgrepo_mobile/models/conversation.dart";
import "package:msgrepo_mobile/services/assistant/models.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/streaming_blocks.dart";
import "package:msgrepo_mobile/ui/assistant/widgets/tool_steps_group.dart";

/// task-80 回归（2026-11-11）：历史消息侧的「连续成功 tool 消息」聚合。
///
/// 背景：回合结束 `_reload()` 后消息从 DB 重新渲染，若不复用分组，
/// 流式阶段看到的「完成 N 步 · 全部成功」会消失、回到一堆零散工具块。
///
/// 硬规则：只聚合连续、成功回注的 tool 消息；失败回注 / 搜索命中 / 普通消息
/// 都切断连续段并保持单条；< 2 条不折叠；展开状态映射到 chat_page 的
/// `_expandedToolMsgIds`（本文件只测纯函数与受控展开，不依赖 ChatPage）。
const convo = "c1";

ChatMessage msg(String id, String role, String content, {int at = 0}) => ChatMessage(
      id: id,
      conversationId: convo,
      role: role,
      content: content,
      createdAt: at,
    );

ChatMessage toolOk(String id) => msg(id, ChatRole.tool, "✓ 已回注：没有 active 任务");
ChatMessage toolFailed(String id) =>
    msg(id, ChatRole.tool, "一个动作未能理解，已跳过：args 缺失");
ChatMessage userMsg(String id) => msg(id, ChatRole.user, "帮我看看今天有什么");
ChatMessage assistantMsg(String id) => msg(id, ChatRole.assistant, "我查到了三条。");

void main() {
  group("isFoldableToolMessage", () {
    test("成功回注的 tool 消息可折叠；失败回注不可", () {
      expect(isFoldableToolMessage(toolOk("t1")), isTrue);
      expect(isFoldableToolMessage(toolFailed("t2")), isFalse);
    });

    test("用户/助理消息不参与折叠", () {
      expect(isFoldableToolMessage(userMsg("u1")), isFalse);
      expect(isFoldableToolMessage(assistantMsg("a1")), isFalse);
    });
  });

  group("groupToolMessages（历史侧纯分组）", () {
    test("连续 3 条成功 → 一条折叠组", () {
      final items = groupToolMessages([
        userMsg("u1"),
        toolOk("t1"),
        toolOk("t2"),
        toolOk("t3"),
        assistantMsg("a1"),
      ]);
      expect(items, hasLength(3));
      expect(items[0], isA<SingleMessage>());
      final folded = items[1] as FoldedToolMessages;
      expect(folded.messages.map((m) => m.id).toList(), ["t1", "t2", "t3"]);
      expect(items[2], isA<SingleMessage>());
    });

    test("失败回注切断连续段，且自身保持单条", () {
      final items = groupToolMessages([
        toolOk("t1"),
        toolOk("t2"),
        toolFailed("bad"),
        toolOk("t3"),
        toolOk("t4"),
      ]);
      expect(items, hasLength(3));
      expect((items[0] as FoldedToolMessages).messages.map((m) => m.id).toList(),
          ["t1", "t2"]);
      expect((items[1] as SingleMessage).message.id, "bad");
      expect((items[2] as FoldedToolMessages).messages.map((m) => m.id).toList(),
          ["t3", "t4"]);
    });

    test("搜索命中的消息不折叠且切断连续段（保留高亮定位）", () {
      final items = groupToolMessages(
        [toolOk("t1"), toolOk("hit"), toolOk("t3"), toolOk("t4")],
        protectedMessageIds: {"hit"},
      );
      expect(items, hasLength(3));
      expect((items[0] as SingleMessage).message.id, "t1",
          reason: "命中前只有 1 条，不折叠");
      expect((items[1] as SingleMessage).message.id, "hit");
      expect((items[2] as FoldedToolMessages).messages.map((m) => m.id).toList(),
          ["t3", "t4"]);
    });

    test("单条成功不折叠", () {
      final items = groupToolMessages([toolOk("t1")]);
      expect(items.single, isA<SingleMessage>());
    });

    test("普通消息切断连续段（不同阶段不合并）", () {
      final items = groupToolMessages([
        toolOk("t1"),
        toolOk("t2"),
        assistantMsg("a1"),
        toolOk("t3"),
        toolOk("t4"),
      ]);
      expect(items.map((e) => e.runtimeType).toList(),
          [FoldedToolMessages, SingleMessage, FoldedToolMessages]);
    });

    test("minToCollapse 可调（3）", () {
      final items = groupToolMessages(
        [toolOk("t1"), toolOk("t2")],
        minToCollapse: 3,
      );
      expect(items.every((e) => e is SingleMessage), isTrue);
    });

    test("空列表安全", () {
      expect(groupToolMessages(const []), isEmpty);
    });
  });

  group("ToolStepsGroup 受控展开（历史侧）", () {
    ChatStreamSegment seg(String status) =>
        ChatStreamSegment(kind: ChatStreamSegmentKind.tool, startedAt: DateTime.now())
          ..status = status
          ..active = status == '执行中'
          ..endedAt = DateTime.now();

    Widget wrap(Widget child) =>
        MaterialApp(home: Scaffold(body: Column(children: [child])));

    testWidgets("expanded=false 时点摘要只回调、不展开（状态由上层持有）",
        (tester) async {
      var toggles = 0;
      await tester.pumpWidget(wrap(ToolStepsGroup(
        steps: [seg("已回注"), seg("已回注")],
        expanded: false,
        onToggleGroup: () => toggles++,
        onStepToggle: (_) {},
      )));
      expect(find.byType(ToolCallBlock), findsNothing);
      await tester.tap(find.byKey(const ValueKey("tool-steps-group-header")));
      await tester.pumpAndSettle();
      expect(toggles, 1);
      expect(find.byType(ToolCallBlock), findsNothing,
          reason: "受控模式下由上层改 expanded 才会展开");
    });

    testWidgets("expanded=true 时直接显示全部步骤", (tester) async {
      await tester.pumpWidget(wrap(ToolStepsGroup(
        steps: [seg("已回注"), seg("已回注"), seg("已回注")],
        expanded: true,
        onToggleGroup: () {},
        onStepToggle: (_) {},
      )));
      expect(find.byType(ToolCallBlock), findsNWidgets(3));
      expect(find.text("完成 3 步 · 全部成功"), findsOneWidget);
    });

    testWidgets("自定义 headerKey 可点击（多组同屏不冲突）", (tester) async {
      await tester.pumpWidget(wrap(Column(children: [
        ToolStepsGroup(
          steps: [seg("已回注"), seg("已回注")],
          headerKey: const ValueKey("g1-header"),
          onStepToggle: (_) {},
        ),
        ToolStepsGroup(
          steps: [seg("已回注"), seg("已回注")],
          headerKey: const ValueKey("g2-header"),
          onStepToggle: (_) {},
        ),
      ])));
      expect(find.byKey(const ValueKey("g1-header")), findsOneWidget);
      expect(find.byKey(const ValueKey("g2-header")), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey("g1-header")));
      await tester.pumpAndSettle();
      expect(find.byType(ToolCallBlock), findsNWidgets(2),
          reason: "只展开第一组");
    });
  });
}