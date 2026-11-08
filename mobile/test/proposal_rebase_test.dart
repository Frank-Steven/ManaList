import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/assistant/proposal_executor.dart';
import 'package:msgrepo_mobile/services/assistant/proposal_service.dart';
import 'package:msgrepo_mobile/services/assistant/tool_parser.dart';
import 'package:msgrepo_mobile/services/crdt.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables, insertTask;

/// 提案 rebase 三态裁决（crdt.md §3.2）：
/// - 无并发改动 → 直接生效；
/// - 审批期间人改了同一字段 → superseded（人优先），可 resubmit 后再批；
/// - 审批期间另一助理改了同一字段 → 放行（LWW 后落者赢）；
/// - 人改了不相交字段 → 放行（共存）；
/// - task.delete 遇人修改 → superseded；
/// - 无 base 的旧提案 → 放行（向后兼容）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  final appDb = AppDatabase.instance;
  final service = ProposalService.instance;
  final executor = ProposalExecutor.instance;

  const convId = 'conv-1';

  ParsedToolBlock block(String tool, Map<String, dynamic> args) =>
      ParsedToolBlock(index: 0, tool: tool, args: args, raw: '{}');

  Future<void> propose(String batchId, String tool, Map<String, dynamic> args) =>
      service.handleToolBlock(
          conversationId: convId, batchId: batchId, block: block(tool, args));

  String pid(String batchId) => '${batchId}_b0';

  Future<Task> renamed(String id, String title) async =>
      (await appDb.getTaskById(id))!.copyWith(title: title);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createBaseTables(db);
    appDb.debugAttachDatabase(db);
    final now = DateTime.now().millisecondsSinceEpoch;
    await appDb.insertConversation(
        Conversation(id: convId, title: '测试对话', createdAt: now, updatedAt: now));
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    appDb.debugDetachDatabase();
    await db.close();
  });

  test('无并发改动：提案落库时带 base，审批直接生效', () async {
    await insertTask(db, 't1', title: '旧标题');
    await propose('b1', 'task.update', {'id': 't1', 'title': '新标题'});
    expect((await appDb.getProposalById(pid('b1')))!.payload['base'], isNotNull,
        reason: '落库时捕获 base');

    final exec = await executor.approve(pid('b1'));
    expect(exec.ok, isTrue);
    expect((await appDb.getTaskById('t1'))?.title, '新标题');
    expect((await appDb.getProposalById(pid('b1')))?.status,
        ProposalStatus.applied);
  });

  test('人改了同一字段 → superseded → resubmit → 可再批生效', () async {
    await insertTask(db, 't1', title: '旧标题');
    await propose('b2', 'task.update', {'id': 't1', 'title': '助理改'});

    // 审批期间人改了同一字段
    await appDb.updateTask(await renamed('t1', '人改'));

    final exec = await executor.approve(pid('b2'));
    expect(exec.ok, isFalse);
    expect(exec.message, contains('覆盖'));
    final p = await appDb.getProposalById(pid('b2'));
    expect(p?.status, ProposalStatus.superseded);
    expect((await appDb.getTaskById('t1'))?.title, '人改', reason: '人的修改不被覆盖');

    // 非 superseded 不能 resubmit；superseded 刷新 base 回 pending
    expect(await executor.resubmit(pid('b2')), isTrue);
    expect((await appDb.getProposalById(pid('b2')))?.status,
        ProposalStatus.pending);

    final exec2 = await executor.approve(pid('b2'));
    expect(exec2.ok, isTrue, reason: '重新提交后人已知情，可再批');
    expect((await appDb.getTaskById('t1'))?.title, '助理改');
  });

  test('另一助理改了同一字段 → 放行（LWW 后落者赢）', () async {
    await insertTask(db, 't1', title: '旧标题');
    await propose('b3', 'task.update', {'id': 't1', 'title': '本对话改'});

    // 审批期间另一对话的助理改了同一字段
    await appDb.updateTask(await renamed('t1', '别的助理改'),
        actor: OpActor.assistant('conv-other'));

    final exec = await executor.approve(pid('b3'));
    expect(exec.ok, isTrue, reason: '助理间冲突走 LWW，不 supersede');
    expect((await appDb.getTaskById('t1'))?.title, '本对话改');
  });

  test('人改了不相交字段 → 放行，两处修改共存', () async {
    await insertTask(db, 't1', title: '旧标题');
    await propose('b4', 'task.update', {'id': 't1', 'title': '新标题'});

    // 人改的是 priority，与提案的 title 不相交
    final t = await appDb.getTaskById('t1');
    await appDb.updateTask(t!.copyWith(priority: TaskPriority.important));

    final exec = await executor.approve(pid('b4'));
    expect(exec.ok, isTrue);
    final after = await appDb.getTaskById('t1');
    expect(after?.title, '新标题');
    expect(after?.priority, TaskPriority.important, reason: '人的修改保留');
  });

  test('task.delete 遇人修改 → superseded（人优先）', () async {
    await insertTask(db, 't1', title: '要删的');
    await propose('b5', 'task.delete', {'id': 't1'});

    // 审批期间人编辑了该任务任意字段
    await appDb.updateTask(await renamed('t1', '人改过了'));

    final exec = await executor.approve(pid('b5'));
    expect(exec.ok, isFalse);
    expect((await appDb.getProposalById(pid('b5')))?.status,
        ProposalStatus.superseded);
    expect(await appDb.getTaskById('t1'), isNotNull, reason: '任务未被删除');
  });

  test('task.delete 无并发 → 生效', () async {
    await insertTask(db, 't1', title: '要删的');
    await propose('b6', 'task.delete', {'id': 't1'});
    final exec = await executor.approve(pid('b6'));
    expect(exec.ok, isTrue);
    expect(await appDb.getTaskById('t1'), isNull);
  });

  test('无 base 的旧提案直接放行（向后兼容）', () async {
    await insertTask(db, 't1', title: '旧标题');
    await appDb.insertProposal(const ChangeProposal(
      id: 'legacy-1',
      conversationId: convId,
      batchId: 'legacy-batch',
      tool: 'task.update',
      summary: '改标题',
      payload: {'id': 't1', 'title': '老提案改'},
      createdAt: 1000,
    ));
    // 人改过字段也不拦：没有 base 无从裁决
    await appDb.updateTask(await renamed('t1', '人改'));

    final exec = await executor.approve('legacy-1');
    expect(exec.ok, isTrue);
    expect((await appDb.getTaskById('t1'))?.title, '老提案改');
  });

  test('message.set_priority 遇人改优先级 → superseded', () async {
    await db.insert('messages', {
      'id': 'm1', 'package_name': 'com.test', 'title': 't', 'body': 'b',
      'posted_at': 2000, 'capture_type': 'notification',
      'content_hash': 'h-m1', 'created_at': 2000,
    });
    await propose(
        'b7', 'message.set_priority', {'messageId': 'm1', 'priority': 'junk'});
    await appDb.updateMessagePriority(['m1'], 'red');

    final exec = await executor.approve(pid('b7'));
    expect(exec.ok, isFalse);
    expect((await appDb.getProposalById(pid('b7')))?.status,
        ProposalStatus.superseded);
    expect((await appDb.getMessageById('m1'))?.priority, 'red');
  });
}
