import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/ui/assistant/approvals_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables;

/// 待确认区（B16）回归：
/// 1) 0 条待确认项时底部「通过所选/拒绝所选」整条隐藏（不留死按钮）；
///    即使历史区有内容也不显示 —— 证明门控是 `_pending` 而不是「有提案就显示」。
/// 2) 切换工具类型 chip 后，已选但不可见的条目不再计入底部 n：
///    计数按「当前可见 ∩ 已选」重算，与批量动作目标一致。
///
/// 用 sqflite_common_ffi 内存库跑真 SQLite（与 proposal_flow_test 同范式），
/// widget 级测试必须在 tester.runAsync 里跑：FakeAsync 区会让 DB 调用挂死。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  final appDb = AppDatabase.instance;

  Future<void> settle(WidgetTester tester, [int times = 12]) async {
    for (var i = 0; i < times; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  ChangeProposal proposal(
    String id, {
    required String tool,
    required String summary,
    required Map<String, dynamic> payload,
    String status = ProposalStatus.pending,
    int createdAt = 1000,
  }) =>
      ChangeProposal(
        id: id,
        conversationId: 'conv-1',
        batchId: 'batch-1',
        tool: tool,
        summary: summary,
        payload: payload,
        status: status,
        createdAt: createdAt,
      );

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createBaseTables(db);
    appDb.debugAttachDatabase(db);
    final now = DateTime.now().millisecondsSinceEpoch;
    await appDb.insertConversation(
        Conversation(id: 'conv-1', title: '测试对话', createdAt: now, updatedAt: now));
  });

  tearDown(() async {
    appDb.debugDetachDatabase();
    await db.close();
  });

  testWidgets('0 条待确认项：底部操作条不渲染（历史区有内容也不显示）', (tester) async {
    await tester.runAsync(() async {
      // 只有一条已拒绝的历史提案：pending 为空
      await appDb.insertProposal(proposal('p-hist',
          tool: 'task.create',
          summary: '新建任务「历史项」',
          status: ProposalStatus.rejected,
          payload: const {'title': '历史项'}));

      await tester.pumpWidget(const MaterialApp(home: ApprovalsPage()));
      await settle(tester);

      expect(find.text('没有待审批的提案'), findsOneWidget);
      expect(find.text('历史（1）'), findsOneWidget,
          reason: '历史区照常显示，用来证明门控是 pending 数量');
      expect(find.textContaining('通过所选'), findsNothing,
          reason: '0 待确认项时不得留死按钮（B16-1）');
      expect(find.text('拒绝所选'), findsNothing);
    });
  });

  testWidgets('切换工具类型 chip：已选但不可见的条目不再计入底部 n', (tester) async {
    await tester.runAsync(() async {
      // A：消息标记（junk → 默认勾选）；B：任务创建（默认不勾选）
      await appDb.insertProposal(proposal('p-msg',
          tool: 'message.set_priority',
          summary: '把消息 m1 标为 junk',
          payload: const {'messageId': 'm1', 'priority': 'junk'}));
      await appDb.insertProposal(proposal('p-task',
          tool: 'task.create',
          summary: '新建任务「买菜」',
          payload: const {'title': '买菜', 'kind': 'point'},
          createdAt: 2000));

      await tester.pumpWidget(const MaterialApp(home: ApprovalsPage()));
      await settle(tester);

      // 两条都在「全部」下可见；A 默认勾选
      expect(find.text('通过所选（1）'), findsOneWidget);
      expect(find.textContaining('标为 junk'), findsWidgets);
      // 同一 batch 成一组：无筛选时组头按组内总数
      expect(find.text('测试对话 · 2 项'), findsOneWidget,
          reason: '无筛选：组头计数 = 组内总数');

      // 切到「任务」chip：A 不可见 → 选择集合清掉 A，计数归 0
      await tester.tap(find.widgetWithText(FilterChip, '任务'));
      await tester.pump();

      expect(find.text('通过所选（0）'), findsOneWidget,
          reason: '计数必须只算当前可见的已选项（B16-2）');
      expect(find.text('拒绝所选'), findsOneWidget,
          reason: '仍有待确认项，操作条本身继续显示（只是禁用）');
      expect(find.textContaining('标为 junk'), findsNothing,
          reason: '消息标记卡片已被筛选隐藏');
      expect(find.textContaining('买菜'), findsWidgets);
      // B16 残余修复：组头计数也要跟着可见集合走（否则会「写 2 项、只列 1 条」）
      expect(find.text('测试对话 · 1 项'), findsOneWidget,
          reason: '筛选后组头计数应等于可见集合大小');
      expect(find.text('测试对话 · 2 项'), findsNothing,
          reason: '筛选后不得再显示组内总数');
    });
  });
}
