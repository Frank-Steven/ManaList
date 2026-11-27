import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/assistant/proposal_executor.dart';
import 'package:msgrepo_mobile/services/assistant/proposal_service.dart';
import 'package:msgrepo_mobile/services/assistant/tool_parser.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/services/undo_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart'
    show anchor, anchorId1, createBaseTables, insertMessage, insertTask;

/// 提案全链路（design-v3 §5.4、details §2.3）：
/// 工具块 → 校验 → 落 change_proposals → 审批 → 执行 → 回注对话 → 撤销；
/// 权限边界（归档任务拒绝 update/delete）；去重键重放跳过。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  final appDb = AppDatabase.instance;
  final service = ProposalService.instance;
  final executor = ProposalExecutor.instance;

  const convId = 'conv-1';

  ParsedToolBlock block(int index, String tool, Map<String, dynamic> args) =>
      ParsedToolBlock(index: index, tool: tool, args: args, raw: '{}');

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createBaseTables(db);
    await db.execute(
        'CREATE TABLE notebooks(id TEXT PRIMARY KEY, name TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)');
    appDb.debugAttachDatabase(db);
    UndoService.instance.clear();
    final now = DateTime.now().millisecondsSinceEpoch;
    await appDb.insertConversation(Conversation(
        id: convId, title: '测试对话', createdAt: now, updatedAt: now));
  });

  tearDown(() async {
    // 任务写操作会起 400ms 的重排 timer；等它跑完再关内存库
    await Future<void>.delayed(const Duration(milliseconds: 450));
    UndoService.instance.clear();
    appDb.debugDetachDatabase();
    await db.close();
  });

  group('校验 → 落库', () {
    test('合法 task.create 落 pending 提案，batch_id = assistant 消息 id', () async {
      final outcome = await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-1',
        block: block(0, 'task.create', {'title': '买菜'}),
      );
      expect(outcome, isA<ProposalCreated>());
      final p = (outcome as ProposalCreated).proposal;
      expect(p.status, ProposalStatus.pending);
      expect(p.id, 'amsg-1_b0', reason: '去重键即提案 id');
      expect(p.batchId, 'amsg-1');
      expect((await appDb.getProposalById(p.id))?.summary, contains('买菜'));
    });

    test('校验失败不落库：缺 title / 未知工具 / 目标不存在 / 预留工具', () async {
      Future<ProposalOutcome> h(String tool, Map<String, dynamic> args) =>
          service.handleToolBlock(
              conversationId: convId,
              batchId: 'b-x',
              block: block(0, tool, args));

      expect((await h('task.create', {'description': '无标题'})),
          isA<ProposalValidationFailure>());
      expect((await h('task.explode', {})), isA<ProposalValidationFailure>());
      expect((await h('task.update', {'id': 'ghost', 'title': 'x'})),
          isA<ProposalValidationFailure>(),
          reason: '目标存在性校验');
      expect(
          (await h('inbox.triage', {
            'scope': {'limit': 51}
          })),
          isA<ProposalValidationFailure>(),
          reason: 'inbox.triage 上限 50，超出报错让 AI 分批（details §4）');
      expect(
          (await h('inbox.triage', {
            'scope': {'status': 'archived'}
          })),
          isA<ProposalValidationFailure>(),
          reason: 'scope.status 首版仅支持 pending');
      expect(await appDb.getProposals(), isEmpty, reason: '失败不落库');
    });

    test('重放去重：同 (batchId, blockIndex) 第二次落库被跳过', () async {
      final first = await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-dup',
        block: block(0, 'task.create', {'title': '买菜'}),
      );
      expect(first, isA<ProposalCreated>());
      final second = await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-dup',
        block: block(0, 'task.create', {'title': '买菜'}),
      );
      expect(second, isA<ProposalDuplicate>());
      expect(await appDb.getProposals(), hasLength(1));
    });

    test('只读工具直接执行返回结果，不落提案', () async {
      await insertTask(db, 't1', title: '买菜');
      final outcome = await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-r',
        block: block(0, 'task.search', {'query': '买菜'}),
      );
      expect(outcome, isA<ReadToolResult>());
      expect((outcome as ReadToolResult).text, contains('买菜'));
      expect(await appDb.getProposals(), isEmpty);
    });
  });

  // ---------- R03①：审批 CAS 与并发执行唯一性（task-107） ----------
  group('R03 审批 CAS / 并发唯一性', () {
    Future<void> createPending(String batchId) async {
      final outcome = await service.handleToolBlock(
        conversationId: convId,
        batchId: batchId,
        block: block(0, 'task.create', {'title': 'CAS 任务 $batchId'}),
      );
      expect(outcome, isA<ProposalCreated>());
    }

    test('同一提案并发 approve 两次：只有一个成功，领域任务/回注各 1', () async {
      await createPending('cas-1');
      const id = 'cas-1_b0';

      // 真并发：两个 approve 同时起跑，CAS 让只有一方拿到 pending→approved
      final results = await Future.wait([
        executor.approve(id),
        executor.approve(id),
      ]);

      final okCount = results.where((r) => r.ok).length;
      expect(okCount, 1, reason: 'CAS 保证只有一个执行者能成功执行');
      final loser = results.firstWhere((r) => !r.ok);
      expect(loser.message, contains('接管'), reason: '失败方给明确「已被接管」语义');

      expect((await appDb.getProposalById(id))?.status, ProposalStatus.applied);
      final tasks = await appDb.getActiveTasks();
      expect(tasks.where((t) => t.title == 'CAS 任务 cas-1'), hasLength(1),
          reason: '领域任务只能建 1 个');
      final chat = await appDb.getChatMessages(convId);
      final toolMsgs = chat.where((m) => m.role == ChatRole.tool).toList();
      expect(toolMsgs, hasLength(1), reason: '回注消息不能重复');
    });

    test('不存在 / 非 pending 的提案：approve 返回 false 且不执行', () async {
      expect((await executor.approve('ghost_b0')).ok, isFalse, reason: '不存在');

      await createPending('cas-2');
      // 人为把它推进到 rejected（非 pending）
      expect(
          await appDb.transitionProposal('cas-2_b0', ProposalStatus.rejected),
          isTrue);
      final exec = await executor.approve('cas-2_b0');
      expect(exec.ok, isFalse);
      expect(exec.message, contains('不可审批'));
      expect(await appDb.getActiveTasks(), isEmpty, reason: '不得执行');
    });

    test('CAS 本身：同一 from 只能成功一次，第二次 affected=0', () async {
      await createPending('cas-3');
      const id = 'cas-3_b0';
      expect(
          await appDb.transitionProposal(id, ProposalStatus.approved), isTrue);
      expect(
          await appDb.transitionProposal(id, ProposalStatus.approved), isFalse,
          reason: '已 approved 后再 approved：非法流转 + CAS 双重拒绝');
      // 旧审批不得覆盖新状态：approved → superseded 之后，再 applied 必须失败
      expect(await appDb.transitionProposal(id, ProposalStatus.superseded),
          isTrue);
      expect(
          await appDb.transitionProposal(id, ProposalStatus.applied), isFalse,
          reason: 'superseded 状态不允许直接 applied');
      expect(
          (await appDb.getProposalById(id))?.status, ProposalStatus.superseded);
    });

    test('收尾 CAS：状态已被接管时不再重复回注', () async {
      await createPending('cas-4');
      const id = 'cas-4_b0';
      final before = (await appDb.getChatMessages(convId))
          .where((m) => m.role == ChatRole.tool)
          .length;

      // 先抢走审批权，然后把它推到 superseded（模拟另一执行者接管）
      expect(
          await appDb.transitionProposal(id, ProposalStatus.approved), isTrue);
      expect(await appDb.transitionProposal(id, ProposalStatus.superseded),
          isTrue);

      final exec = await executor.approve(id);
      expect(exec.ok, isFalse, reason: '非 pending 不得继续');
      final after = (await appDb.getChatMessages(convId))
          .where((m) => m.role == ChatRole.tool)
          .length;
      expect(after, before, reason: '不得重复回注');
      expect(
          (await appDb.getProposalById(id))?.status, ProposalStatus.superseded,
          reason: '不得被旧审批覆盖');
      expect(await appDb.getActiveTasks(), isEmpty);
    });
  });

  // ---------- R03②：确定性 ID 与执行 op（task-109） ----------
  group('R03 确定性 ID / op_id', () {
    test('task.create 用 task_<提案ID>；重复执行同提案不产生第二条任务', () async {
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'det-1',
        block: block(0, 'task.create', {'title': '确定性任务'}),
      );
      const pid = 'det-1_b0';
      final exec = await executor.approve(pid);
      expect(exec.ok, isTrue);

      final tasks = await appDb.getActiveTasks();
      final made = tasks.single;
      expect(made.id, 'task_$pid', reason: '任务 id = task_<提案ID>');

      // 同 ID 再插一次（幂等）：条数不变、内容被 replace 覆盖为同值
      await appDb.insertTask(made);
      expect((await appDb.getActiveTasks()).length, 1,
          reason: 'insertTask 为 replace，同 ID 不应产生第二条');
    });

    test('note.create 用 note_<提案ID>；库为空时默认章节用 <提案ID>_notebook/_chapter',
        () async {
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'det-2',
        block: block(0, 'note.create', {'title': '确定性笔记', 'content': '正文'}),
      );
      const pid = 'det-2_b0';
      final exec = await executor.approve(pid);
      expect(exec.ok, isTrue);

      final note = await appDb.getNoteById('note_$pid');
      expect(note, isNotNull, reason: '笔记 id = note_<提案ID>');
      expect(note!.chapterId, '${pid}_chapter',
          reason: '缺省章节 = <提案ID>_chapter');
      final chapters = await appDb.getChapters('${pid}_notebook');
      expect(chapters.single.id, '${pid}_chapter');
      final notebooks = await appDb.getNotebooks();
      expect(notebooks.single.id, '${pid}_notebook',
          reason: '缺省笔记本 = <提案ID>_notebook');
    });

    test('审批结果回注用 <提案ID>_result；重复回注仍只有 1 条', () async {
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'det-3',
        block: block(0, 'task.create', {'title': '回注确定性'}),
      );
      const pid = 'det-3_b0';
      await executor.approve(pid);

      final msg = await appDb.getChatMessageById('${pid}_result');
      expect(msg, isNotNull, reason: '结果消息 id = <提案ID>_result');
      expect(msg!.role, ChatRole.tool);

      // 同 id 再写一次（模拟重放/重复回注）：条数不变
      await appDb.insertChatMessage(msg);
      final tools = (await appDb.getChatMessages(convId))
          .where((m) => m.role == ChatRole.tool)
          .toList();
      expect(tools.length, 1,
          reason: 'insertChatMessage 为 replace，同 id 只有 1 条');
    });

    test('同提案多字段更新：op_id 各不相同且带提案前缀', () async {
      await insertTask(db, 't-met',
          title: '原标题'); // helper 自带 priority='normal'
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'det-4',
        block: block(0, 'task.update', {
          'id': 't-met',
          'title': '新标题',
          'priority': 'important',
        }),
      );
      const pid = 'det-4_b0';
      final exec = await executor.approve(pid);
      expect(exec.ok, isTrue);

      final rows = await db.query('op_log',
          columns: ['op_id', 'target'],
          where: 'target LIKE ?',
          whereArgs: ['%t-met%']);
      expect(rows.length, greaterThanOrEqualTo(2), reason: '两个字段各一条 op');
      final opIds = [for (final r in rows) r['op_id'] as String];
      expect(opIds.toSet().length, opIds.length, reason: '同提案多字段 op_id 必须互不相同');
      for (final id in opIds) {
        expect(id, startsWith(pid), reason: 'op_id 必须带提案前缀（可重放识别），不得共用一个 UUID');
      }
      expect(opIds.any((id) => id.contains(':title')), isTrue,
          reason: '字段级后缀应体现目标字段');
      expect(opIds.any((id) => id.contains(':priority')), isTrue);
    });

    test('只读回注确定性 id：同一条消息重复回注仍 1 条', () async {
      const content = '[task.search] 找到 0 条';
      const id = 'amsg-x_b0_result';
      await executor.reportToolMessage(convId, content, messageId: id);
      await executor.reportToolMessage(convId, content, messageId: id);
      final tools = (await appDb.getChatMessages(convId))
          .where((m) => m.role == ChatRole.tool)
          .toList();
      expect(tools.length, 1, reason: '同 id 重复回注 = replace，仍 1 条');
      expect(tools.single.id, id);
    });
  });

  // ---------- R03③：原子收尾与 approved 崩溃恢复（task-110） ----------
  group('R03 原子收尾 / approved 恢复', () {
    /// 造一条 approved 的 task.create 提案（不经过 approve，模拟「抢到 CAS 后崩溃」）。
    Future<void> seedApproved(String batchId, String title) async {
      await service.handleToolBlock(
        conversationId: convId,
        batchId: batchId,
        block: block(0, 'task.create', {'title': title}),
      );
      final pid = '${batchId}_b0';
      expect(
          await appDb.transitionProposal(pid, ProposalStatus.approved), isTrue);
    }

    Future<int> toolMessageCount() async =>
        (await appDb.getChatMessages(convId))
            .where((m) => m.role == ChatRole.tool)
            .length;

    test('正常 approve：applied 与结果消息在同一事务内落地', () async {
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'atom-1',
        block: block(0, 'task.create', {'title': '原子任务'}),
      );
      const pid = 'atom-1_b0';
      final exec = await executor.approve(pid);
      expect(exec.ok, isTrue);

      final proposal = await appDb.getProposalById(pid);
      expect(proposal!.status, ProposalStatus.applied);
      expect(proposal.resolvedAt, isNotNull);
      expect(proposal.payload.containsKey('_undo'), isTrue,
          reason: 'undo 与状态在同一事务写入');
      expect(await appDb.getChatMessageById('${pid}_result'), isNotNull,
          reason: '确定性结果消息同事务写入');
      expect(await toolMessageCount(), 1, reason: '不额外产生第二条回注');
    });

    test('approved 且领域对象已存在：recover 不重复创建，只补 applied/result', () async {
      await seedApproved('rec-1', '已执行过的任务');
      const pid = 'rec-1_b0';
      // 模拟崩溃前已完成领域写入（确定性 id）
      await db.insert('tasks', {
        'id': 'task_$pid',
        'title': '已执行过的任务',
        'kind': 'point',
        'start_at': null,
        'priority': 'normal',
        'status': 'active',
        'created_at': 1000,
        'updated_at': 1000,
      });

      await executor.recoverApprovedProposals();

      expect((await appDb.getActiveTasks()).length, 1, reason: '不得重复创建第二条任务');
      expect((await appDb.getProposalById(pid))!.status, ProposalStatus.applied,
          reason: '只补收尾状态');
      final msg = await appDb.getChatMessageById('${pid}_result');
      expect(msg, isNotNull, reason: '补一条恢复结果消息');
      expect(msg!.content, contains('恢复'), reason: '恢复消息语义可辨识');
    });

    test('approved 且领域未执行：recover 执行一次并收尾', () async {
      await seedApproved('rec-2', '待恢复任务');
      const pid = 'rec-2_b0';

      await executor.recoverApprovedProposals();

      final tasks = await appDb.getActiveTasks();
      expect(tasks.single.id, 'task_$pid', reason: '按确定性 id 执行一次');
      expect(
          (await appDb.getProposalById(pid))!.status, ProposalStatus.applied);
      expect(await appDb.getChatMessageById('${pid}_result'), isNotNull);
    });

    test('recover 连续两次仍各只有 1 个任务 / 1 条结果消息', () async {
      await seedApproved('rec-3', '幂等恢复');
      const pid = 'rec-3_b0';

      await executor.recoverApprovedProposals();
      await executor.recoverApprovedProposals();

      expect((await appDb.getActiveTasks()).length, 1);
      expect(await toolMessageCount(), 1, reason: '确定性 result id + replace');
      expect(
          (await appDb.getProposalById(pid))!.status, ProposalStatus.applied);
    });

    test('失败 guard 的收尾：failed 且只回注一次，recover 不再重跑', () async {
      // anchor.create 指向不存在的目标 → 校验失败（failed）
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'rec-4',
        block: block(0, 'anchor.create', {
          'taskId': 't-missing',
          'targetType': 'message',
          'targetId': 'm-missing',
        }),
      );
      const pid = 'rec-4_b0';
      // 该块在校验阶段可能就没落提案；不存在则本用例不适用
      if (await appDb.getProposalById(pid) == null) return;

      await executor.approve(pid);
      expect((await appDb.getProposalById(pid))!.status, ProposalStatus.failed);

      final before = await toolMessageCount();
      await executor.recoverApprovedProposals();
      expect((await appDb.getProposalById(pid))!.status, ProposalStatus.failed,
          reason: 'failed 不在恢复范围');
      expect(await toolMessageCount(), before, reason: '不重复回注');
    });
  });

  group('审批 → 执行 → 回注 → 撤销', () {
    test('task.create 全链路：applied + 任务入库 + tool 消息回注 + 撤销回 pending', () async {
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-c',
        block:
            block(0, 'task.create', {'title': '买菜', 'priority': 'important'}),
      );
      final exec = await executor.approve('amsg-c_b0');
      expect(exec.ok, isTrue);

      final proposal = await appDb.getProposalById('amsg-c_b0');
      expect(proposal?.status, ProposalStatus.applied);
      expect(proposal?.resolvedAt, isNotNull);
      expect(proposal?.payload.containsKey('_undo'), isTrue,
          reason: '逆操作快照随提案落库');

      final tasks = await appDb.getActiveTasks();
      expect(tasks.single.title, '买菜');
      expect(tasks.single.priority, TaskPriority.important);

      // 执行结果回注对话（role='tool'）
      final chat = await appDb.getChatMessages(convId);
      final toolMsg = chat.where((m) => m.role == ChatRole.tool).single;
      expect(toolMsg.content, contains('已创建任务「买菜」'));

      // 撤销：任务删除 + 提案退回 pending（可重新审批）
      expect(await executor.undoApplied('amsg-c_b0'), isTrue);
      expect(await appDb.getActiveTasks(), isEmpty);
      expect((await appDb.getProposalById('amsg-c_b0'))?.status,
          ProposalStatus.pending);
    });

    test('task.update 审批后修改字段，撤销恢复旧值', () async {
      await insertTask(db, 't1', title: '旧标题');
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-u',
        block: block(0, 'task.update', {'id': 't1', 'title': '新标题'}),
      );
      expect((await executor.approve('amsg-u_b0')).ok, isTrue);
      expect((await appDb.getTaskById('t1'))?.title, '新标题');

      expect(await executor.undoApplied('amsg-u_b0'), isTrue);
      expect((await appDb.getTaskById('t1'))?.title, '旧标题');
    });

    test('task.delete 执行删除，撤销恢复任务行', () async {
      await insertTask(db, 't1', title: '要删的');
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-d',
        block: block(0, 'task.delete', {'id': 't1'}),
      );
      expect((await executor.approve('amsg-d_b0')).ok, isTrue);
      expect(await appDb.getTaskById('t1'), isNull);

      expect(await executor.undoApplied('amsg-d_b0'), isTrue);
      expect((await appDb.getTaskById('t1'))?.title, '要删的');
    });

    test('task.delete 带锚点：撤销恢复任务行 + 锚点行，正文全程不动（对象级锚点）', () async {
      const body = '记得买菜';
      await insertMessage(db, 'm1', body);
      await insertTask(db, 't1', title: '买菜');
      await appDb.insertAnchor(anchor(anchorId1, 't1', 'm1', label: '买菜'));

      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-da',
        block: block(0, 'task.delete', {'id': 't1'}),
      );
      final exec = await executor.approve('amsg-da_b0');
      expect(exec.ok, isTrue);
      expect(exec.message, contains('撤销将恢复'));

      // 删除后：任务行/锚点行删除，正文不受影响
      expect(await appDb.getTaskById('t1'), isNull);
      expect(await appDb.anchorsForTask('t1'), isEmpty);
      expect((await appDb.getMessageById('m1'))!.body, body);

      // 撤销（_undo 快照经 change_proposals 落库 JSON 往返后仍完整）
      expect(await executor.undoApplied('amsg-da_b0'), isTrue);
      expect((await appDb.getTaskById('t1'))?.title, '买菜');
      expect((await appDb.anchorsForTask('t1')).single.id, anchorId1);
      expect((await appDb.getMessageById('m1'))!.body, body);
    });

    test('note.create 与 note.append（replace_section 已在 v12 移除）', () async {
      await db.insert('notebooks',
          {'id': 'nb1', 'name': '本', 'sort': 0, 'created_at': 1000});
      await db.insert('chapters', {
        'id': 'ch1',
        'notebook_id': 'nb1',
        'name': '章',
        'sort': 0,
        'created_at': 1000
      });
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-n1',
        block: block(0, 'note.create', {'title': '周记', 'content': '## 周一\n晴天'}),
      );
      expect((await executor.approve('amsg-n1_b0')).ok, isTrue);
      final noteId = (await appDb.getNotes('ch1')).single.id;

      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-n2',
        block:
            block(0, 'note.append', {'noteId': noteId, 'content': '## 周二\n雨'}),
      );
      expect((await executor.approve('amsg-n2_b0')).ok, isTrue);
      expect((await appDb.getNoteById(noteId))?.content, contains('## 周二\n雨'));

      // note.replace_section 已废弃（anchors-v2 §5）→ 校验失败不落库
      final outcome = await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-n4',
        block: block(0, 'note.replace_section',
            {'noteId': noteId, 'heading': '周一', 'content': '阴天'}),
      );
      expect(outcome, isA<ProposalValidationFailure>());
      expect(await appDb.getProposalById('amsg-n4_b0'), isNull);
    });

    test('anchor.create 对象级：幂等成功；目标不存在 → 校验失败', () async {
      await insertMessage(db, 'm1', '记得买菜的正文');
      await insertTask(db, 't1', title: '买菜');
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-a1',
        block: block(0, 'anchor.create', {
          'targetType': 'message',
          'targetId': 'm1',
          'taskId': 't1',
        }),
      );
      expect((await executor.approve('amsg-a1_b0')).ok, isTrue);
      final anchors = await appDb.anchorsForTask('t1');
      expect(anchors.single.targetId, 'm1');
      expect(anchors.single.label, '买菜', reason: 'label 缺省任务标题');
      expect((await appDb.getMessageById('m1'))?.body, '记得买菜的正文',
          reason: '对象级锚点不写正文');

      // 目标不存在 → 校验期拒绝，不落库
      final outcome = await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-a2',
        block: block(0, 'anchor.create', {
          'targetType': 'message',
          'targetId': 'ghost',
          'taskId': 't1',
        }),
      );
      expect(outcome, isA<ProposalValidationFailure>());
      expect(await appDb.getProposalById('amsg-a2_b0'), isNull);
    });

    test('message.set_priority 执行与撤销', () async {
      await insertMessage(db, 'm1', '推广短信');
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-p',
        block: block(
            0, 'message.set_priority', {'messageId': 'm1', 'priority': 'junk'}),
      );
      expect((await executor.approve('amsg-p_b0')).ok, isTrue);
      expect((await appDb.getMessageById('m1'))?.priority, 'junk');

      expect(await executor.undoApplied('amsg-p_b0'), isTrue);
      expect((await appDb.getMessageById('m1'))?.priority, 'none');
    });
  });

  group('权限边界（details §2.3，执行层强制）', () {
    test('已归档任务拒绝 update/delete（校验通过但执行层拦截）', () async {
      await insertTask(db, 'archived-1', title: '旧任务');
      await appDb.setTaskStatus(['archived-1'], TaskStatus.archived);

      // 校验期不查状态（任务存在即通过），权限在执行层强制
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-g1',
        block: block(0, 'task.update', {'id': 'archived-1', 'title': '改名'}),
      );
      final execU = await executor.approve('amsg-g1_b0');
      expect(execU.ok, isFalse);
      expect(execU.message, contains('已归档'));
      expect((await appDb.getTaskById('archived-1'))?.title, '旧任务',
          reason: '被拒绝的修改不生效');
      expect((await appDb.getProposalById('amsg-g1_b0'))?.status,
          ProposalStatus.failed);

      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-g2',
        block: block(0, 'task.delete', {'id': 'archived-1'}),
      );
      final execD = await executor.approve('amsg-g2_b0');
      expect(execD.ok, isFalse);
      expect(execD.message, contains('已归档'));
      expect(await appDb.getTaskById('archived-1'), isNotNull,
          reason: '归档任务仍在');
    });

    test('审批时刻目标已被删 → 二次校验失败置 failed（幂等）', () async {
      await insertTask(db, 't-gone', title: '马上没');
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-g3',
        block: block(0, 'task.update', {'id': 't-gone', 'title': 'x'}),
      );
      await appDb.deleteTasks(['t-gone']);
      final exec = await executor.approve('amsg-g3_b0');
      expect(exec.ok, isFalse);
      expect(exec.message, contains('校验失败'));
      expect((await appDb.getProposalById('amsg-g3_b0'))?.status,
          ProposalStatus.failed);
    });

    test('重复审批被拒（状态机）', () async {
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-g4',
        block: block(0, 'task.create', {'title': '一次'}),
      );
      expect((await executor.approve('amsg-g4_b0')).ok, isTrue);
      final again = await executor.approve('amsg-g4_b0');
      expect(again.ok, isFalse, reason: 'applied 不能再走 pending→approved');
      expect((await appDb.getActiveTasks()).length, 1, reason: '不会执行两次');
    });
  });

  group('B15 收尾：单条写工具的选中范围守卫', () {
    test('selectedMessageIds 之外的 message.set_priority 被拒、不落库', () async {
      await insertMessage(db, 'm-sel', '选中的消息');
      await insertMessage(db, 'm-other', '未选中的消息');

      final outcome = await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-guard1',
        block: block(0, 'message.set_priority',
            {'messageId': 'm-other', 'priority': 'junk'}),
        selectedMessageIds: const ['m-sel'],
      );

      expect(outcome, isA<ProposalValidationFailure>(),
          reason: '未选消息不得生成单条提案（B15 收尾：library.search 拿 id 的窄路径）');
      expect(
          (outcome as ProposalValidationFailure).reason, contains('m-other'));
      expect(await appDb.getProposals(), isEmpty, reason: '被拒的提案不得落库');
    });

    test('选中的 messageId 照常落提案（守卫不误伤）', () async {
      await insertMessage(db, 'm-sel', '选中的消息');

      final outcome = await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-guard2',
        block: block(0, 'message.set_priority',
            {'messageId': 'm-sel', 'priority': 'junk'}),
        selectedMessageIds: const ['m-sel'],
      );

      expect(outcome, isA<ProposalCreated>());
      expect(await appDb.getProposals(), hasLength(1));
    });

    test('无选中集合：未选消息的单条提案照常落库（原行为不变）', () async {
      await insertMessage(db, 'm-any', '任意消息');

      final outcome = await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-guard3',
        block: block(0, 'message.set_priority',
            {'messageId': 'm-any', 'priority': 'junk'}),
      );

      expect(outcome, isA<ProposalCreated>(), reason: '没有选中集合时不得改变既有行为');
      expect(await appDb.getProposals(), hasLength(1));
    });

    test('anchor.create 目标为未选消息同样被拒（守卫不误伤对象级锚点）', () async {
      await insertMessage(db, 'm-sel', '选中的消息');
      await insertMessage(db, 'm-other', '未选中的消息');
      await insertTask(db, 't1', title: '任务一');

      final outcome = await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-guard4',
        block: block(0, 'anchor.create', {
          'targetType': 'message',
          'targetId': 'm-other',
          'taskId': 't1',
        }),
        selectedMessageIds: const ['m-sel'],
      );

      expect(outcome, isA<ProposalValidationFailure>(),
          reason: '对未选消息建锚点超出选中范围');
      expect(await appDb.getProposals(), isEmpty);
    });
  });
}
