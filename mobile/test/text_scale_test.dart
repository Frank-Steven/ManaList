import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/ui/assistant/widgets/proposal_card.dart';
import 'package:msgrepo_mobile/ui/messages/message_widgets.dart';
import 'package:msgrepo_mobile/ui/shared/skeleton_list.dart';
import 'package:msgrepo_mobile/ui/tasks/task_tile.dart';

/// ux-fixes §3.4-16：1.3x 系统字号下关键组件不溢出、不破版；
/// §3.3-10：骨架屏「延迟出现 + 最小展示时长」防闪策略回归。
void main() {
  Widget scaled(Widget child) => MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: Scaffold(
            body: SizedBox(width: 360, child: SingleChildScrollView(child: child)),
          ),
        ),
      );

  ChangeProposal proposal(String status) => ChangeProposal(
        id: 'p-1',
        conversationId: 'conv-1',
        tool: 'task.create',
        summary: '新建任务「给产品经理发一份很长很长的会议纪要摘要以便确认」',
        payload: const {'title': '发会议纪要', 'priority': 'high'},
        status: status,
        createdAt: 1000,
      );

  group('1.3x 动态字号弹性（§3.4-16）', () {
    testWidgets('ProposalCard compact/full 各状态不溢出', (tester) async {
      await tester.pumpWidget(scaled(Column(children: [
        ProposalCard(proposal: proposal(ProposalStatus.pending)),
        ProposalCard(
          proposal: proposal(ProposalStatus.pending),
          density: ProposalCardDensity.full,
          onApprove: () {},
          onReject: () {},
        ),
        ProposalCard(
          proposal: proposal(ProposalStatus.applied),
          density: ProposalCardDensity.full,
          onUndo: () {},
        ),
        ProposalCard(proposal: proposal(ProposalStatus.rejected)),
      ])));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('MessageTile（含任务数量角标）不溢出', (tester) async {
      const message = Message(
        id: 'm-1',
        packageName: 'com.example.app',
        appName: '示例应用',
        sender: '张三',
        title: '这是一条标题相当长的消息用来验证字号放大后的换行表现',
        body: '正文内容 likewise 很长，需要在 1.3 倍字号下保持不溢出。',
        postedAt: 1000,
        captureType: 'notification',
        contentHash: 'h',
        createdAt: 1000,
      );
      await tester.pumpWidget(scaled(const Column(children: [
        MessageTile(message: message, linkedTaskCount: 3),
      ])));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('TaskTile（带子任务进度）不溢出', (tester) async {
      const task = Task(
        id: 't-1',
        title: '一项标题很长的任务：整理本周所有会议记录并归档到对应项目目录',
        kind: 'todo',
        createdAt: 1000,
        updatedAt: 1000,
      );
      await tester.pumpWidget(scaled(Column(children: [
        TaskTile(task: task, onTap: () {}, progress: (2, 5)),
      ])));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('骨架屏防闪（§3.3-10）', () {
    testWidgets('数据 300ms 内到达：骨架不出现，直接渲染内容', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: DeferredSkeletonList(loading: true, child: Text('内容')))));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: DeferredSkeletonList(loading: false, child: Text('内容')))));
      await tester.pump();
      expect(find.text('内容'), findsOneWidget);
    });

    testWidgets('骨架已出现后数据到达：至少再留 300ms 才让位', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: DeferredSkeletonList(loading: true, child: Text('内容')))));
      await tester.pump(const Duration(milliseconds: 350)); // 骨架已出现
      expect(find.text('内容'), findsNothing);

      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: DeferredSkeletonList(loading: false, child: Text('内容')))));
      await tester.pump();
      expect(find.text('内容'), findsNothing, reason: '最小展示时长内不让位');

      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('内容'), findsOneWidget);
    });
  });
}
