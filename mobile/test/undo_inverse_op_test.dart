import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/assistant/proposal_executor.dart';
import 'package:msgrepo_mobile/services/assistant/proposal_service.dart';
import 'package:msgrepo_mobile/services/assistant/tool_parser.dart';
import 'package:msgrepo_mobile/services/crdt.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/services/undo_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables, insertTask;

/// 撤销 = 逆 op（crdt.md §5）：
/// 撤销操作本身进 op_log、actor=user（撤销由人触发）；
/// 撤销后再审批同一提案 → 因人的撤销 op 漂移 base 而 superseded。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  final appDb = AppDatabase.instance;
  final service = ProposalService.instance;
  final executor = ProposalExecutor.instance;

  const convId = 'conv-1';

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createBaseTables(db);
    appDb.debugAttachDatabase(db);
    UndoService.instance.clear();
    final now = DateTime.now().millisecondsSinceEpoch;
    await appDb.insertConversation(
        Conversation(id: convId, title: '测试对话', createdAt: now, updatedAt: now));
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    UndoService.instance.clear();
    appDb.debugDetachDatabase();
    await db.close();
  });

  Future<List<Map<String, Object?>>> opsOn(String target) => db.query('op_log',
      where: 'target = ?', whereArgs: [target], orderBy: 'lamport ASC');

  test('task.update：执行落助理 op，撤销落 user 的 restore 逆 op', () async {
    await insertTask(db, 't1', title: '旧标题');
    await service.handleToolBlock(
      conversationId: convId,
      batchId: 'u1',
      block: const ParsedToolBlock(
          index: 0, tool: 'task.update', args: {'id': 't1', 'title': '新标题'}, raw: '{}'),
    );
    expect((await executor.approve('u1_b0')).ok, isTrue);

    final target = taskFieldTarget('t1', 'title');
    var ops = await opsOn(target);
    expect(ops.single['actor'], OpActor.assistant(convId));

    expect(await executor.undoApplied('u1_b0'), isTrue);
    expect((await appDb.getTaskById('t1'))?.title, '旧标题');

    // 撤销 = 任务行回插 + 前缀级 restore 逆 op（actor=user，撤销由人触发）
    final restoreOps = await db.query('op_log',
        where: 'target = ? AND actor = ?',
        whereArgs: [taskPrefix('t1'), OpActor.user]);
    expect(restoreOps.single['payload'], contains('restored'));

    // 提案退回 pending；再批时 title 字段当前版本仍是助理 op → LWW 放行重放
    expect((await appDb.getProposalById('u1_b0'))?.status,
        ProposalStatus.pending);
    final exec = await executor.approve('u1_b0');
    expect(exec.ok, isTrue);
    expect((await appDb.getTaskById('t1'))?.title, '新标题');
  });

  test('task.delete：执行落 tombstone，撤销恢复任务并落 user 逆 op', () async {
    await insertTask(db, 't1', title: '要删的');
    await service.handleToolBlock(
      conversationId: convId,
      batchId: 'u2',
      block: const ParsedToolBlock(
          index: 0, tool: 'task.delete', args: {'id': 't1'}, raw: '{}'),
    );
    expect((await executor.approve('u2_b0')).ok, isTrue);
    expect(await appDb.getTaskById('t1'), isNull);

    final tombstones = await db.query('op_log',
        where: 'kind = ?', whereArgs: [OpKind.tombstone]);
    expect(tombstones.single['actor'], OpActor.assistant(convId));

    expect(await executor.undoApplied('u2_b0'), isTrue);
    expect((await appDb.getTaskById('t1'))?.title, '要删的');

    // 恢复路径在任务前缀下落 user 的逆 op（restore 标记）
    final restoreOps = await db.query('op_log',
        where: "target LIKE 'tasks:t1:%' AND actor = ?",
        whereArgs: [OpActor.user]);
    expect(restoreOps, isNotEmpty);

    // 撤销与并发交叉：删除提案退回 pending 后再批，
    // 人的 restore op 使 base 漂移 → superseded（人的撤销优先，不直接再删）
    expect((await appDb.getProposalById('u2_b0'))?.status,
        ProposalStatus.pending);
    final exec = await executor.approve('u2_b0');
    expect(exec.ok, isFalse);
    expect((await appDb.getProposalById('u2_b0'))?.status,
        ProposalStatus.superseded);
    expect(await appDb.getTaskById('t1'), isNotNull, reason: '任务未被再次删除');
  });
}
