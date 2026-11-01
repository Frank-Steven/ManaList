import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/models/message.dart';
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
    await db.execute(
        'CREATE TABLE chapters(id TEXT PRIMARY KEY, notebook_id TEXT NOT NULL, name TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)');
    appDb.debugAttachDatabase(db);
    UndoService.instance.clear();
    final now = DateTime.now().millisecondsSinceEpoch;
    await appDb.insertConversation(
        Conversation(id: convId, title: '测试对话', createdAt: now, updatedAt: now));
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
              conversationId: convId, batchId: 'b-x', block: block(0, tool, args));

      expect((await h('task.create', {'description': '无标题'})),
          isA<ProposalValidationFailure>());
      expect((await h('task.explode', {})), isA<ProposalValidationFailure>());
      expect((await h('task.update', {'id': 'ghost', 'title': 'x'})),
          isA<ProposalValidationFailure>(),
          reason: '目标存在性校验');
      expect((await h('inbox.triage', {'scope': {'limit': 51}})),
          isA<ProposalValidationFailure>(),
          reason: 'inbox.triage 上限 50，超出报错让 AI 分批（details §4）');
      expect((await h('inbox.triage', {'scope': {'status': 'archived'}})),
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

  group('审批 → 执行 → 回注 → 撤销', () {
    test('task.create 全链路：applied + 任务入库 + tool 消息回注 + 撤销回 pending',
        () async {
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-c',
        block: block(0, 'task.create', {'title': '买菜', 'priority': 'important'}),
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

    test('task.delete 带锚点：撤销恢复任务行 + 锚点行 + 正文 marker/content_hash/edited_at',
        () async {
      const origBody = '记得买菜 ⟦task:$anchorId1⟧';
      await insertMessage(db, 'm1', origBody);
      await db.update('messages', {'edited_at': 12345},
          where: 'id = ?', whereArgs: ['m1']);
      await insertTask(db, 't1', title: '买菜');
      await appDb.insertAnchor(anchor(anchorId1, 't1', 'm1', label: '买菜'));
      final hashBefore = computeContentHash('com.test', '标题m1', origBody, 2000);

      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-da',
        block: block(0, 'task.delete', {'id': 't1'}),
      );
      final exec = await executor.approve('amsg-da_b0');
      expect(exec.ok, isTrue);
      expect(exec.message, contains('撤销将一并恢复'));

      // 删除后：任务行/锚点行删除，正文残迹化
      expect(await appDb.getTaskById('t1'), isNull);
      expect(await appDb.anchorsForTask('t1'), isEmpty);
      expect((await appDb.getMessageById('m1'))!.body, '记得买菜 [任务:买菜]');

      // 撤销（_undo 快照经 change_proposals 落库 JSON 往返后仍完整）
      expect(await executor.undoApplied('amsg-da_b0'), isTrue);
      expect((await appDb.getTaskById('t1'))?.title, '买菜');
      expect((await appDb.anchorsForTask('t1')).single.id, anchorId1);
      final restored =
          (await db.query('messages', where: 'id = ?', whereArgs: ['m1']))
              .single;
      expect(restored['body'], origBody, reason: 'marker 精确复原');
      expect(restored['content_hash'], hashBefore);
      expect(restored['edited_at'], 12345);
    });

    test('note.append 与 note.replace_section', () async {
      await db.insert('notebooks',
          {'id': 'nb1', 'name': '本', 'sort': 0, 'created_at': 1000});
      await db.insert('chapters',
          {'id': 'ch1', 'notebook_id': 'nb1', 'name': '章', 'sort': 0, 'created_at': 1000});
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
        block: block(0, 'note.append', {'noteId': noteId, 'content': '## 周二\n雨'}),
      );
      expect((await executor.approve('amsg-n2_b0')).ok, isTrue);
      expect((await appDb.getNoteById(noteId))?.content, contains('## 周二\n雨'));

      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-n3',
        block: block(0, 'note.replace_section',
            {'noteId': noteId, 'heading': '周一', 'content': '阴天'}),
      );
      expect((await executor.approve('amsg-n3_b0')).ok, isTrue);
      final content = (await appDb.getNoteById(noteId))!.content;
      expect(content, contains('## 周一\n阴天'));
      expect(content, contains('## 周二\n雨'), reason: '只替换标题界定的区段');

      // 找不到标题 → 执行失败置 failed
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-n4',
        block: block(0, 'note.replace_section',
            {'noteId': noteId, 'heading': '周三', 'content': 'x'}),
      );
      final exec = await executor.approve('amsg-n4_b0');
      expect(exec.ok, isFalse);
      expect(exec.message, contains('找不到'));
      expect((await appDb.getProposalById('amsg-n4_b0'))?.status,
          ProposalStatus.failed);
    });

    test('anchor.create 走 AnchorService，定位失败置 failed', () async {
      await insertMessage(db, 'm1', '记得买菜的正文');
      await insertTask(db, 't1', title: '买菜');
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-a1',
        block: block(0, 'anchor.create', {
          'targetType': 'message',
          'targetId': 'm1',
          'taskId': 't1',
          'anchorText': '买菜',
        }),
      );
      expect((await executor.approve('amsg-a1_b0')).ok, isTrue);
      final anchors = await appDb.anchorsForTask('t1');
      expect(anchors.single.targetId, 'm1');
      expect((await appDb.getMessageById('m1'))?.body, contains('⟦task:'));

      // 定位失败：anchorText 不存在 → failed
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-a2',
        block: block(0, 'anchor.create', {
          'targetType': 'message',
          'targetId': 'm1',
          'taskId': 't1',
          'anchorText': '不存在的文本',
        }),
      );
      final exec = await executor.approve('amsg-a2_b0');
      expect(exec.ok, isFalse);
      expect((await appDb.getProposalById('amsg-a2_b0'))?.status,
          ProposalStatus.failed);
    });

    test('message.set_priority 执行与撤销', () async {
      await insertMessage(db, 'm1', '推广短信');
      await service.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-p',
        block: block(0, 'message.set_priority',
            {'messageId': 'm1', 'priority': 'junk'}),
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
}
