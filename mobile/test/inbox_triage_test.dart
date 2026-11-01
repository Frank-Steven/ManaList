import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/ai_client.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/assistant/tool_spec.dart';
import 'package:msgrepo_mobile/services/assistant/tools/inbox_triage.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables, insertMessage;

/// inbox.triage 提案生成器（design-v3-details §4）：
/// junk 规则预过滤跳过模型、10 条/批分批、评估结果映射为
/// message.set_priority / task.create 提案（同一 batch_id）、上限报错、
/// 重放去重、子调用失败不拖垮整轮。
/// 解析器/草稿模型用例迁移自被删的 junk_rules_test（parse 组）与
/// ai_multidraft_test / point_task_invariant_test（AiTaskDraft 组）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  final appDb = AppDatabase.instance;
  final triage = InboxTriage.instance;

  const convId = 'conv-1';

  /// 假子调用：从用户消息里抓 messageId，逐条回固定评估结果。
  /// 调用次数记录在 [calls]；[failOnCall]（1 起计）指定的调用发 ChatError。
  int calls = 0;
  int failOnCall = -1;
  Stream<ChatEvent> fakeSubCall(
      List<ChatMessageModel> messages, String? modelConfigId) async* {
    calls++;
    if (calls == failOnCall) {
      yield const ChatError('模型挂了');
      return;
    }
    final userContent = messages.last.content;
    final ids = [
      for (final m in RegExp(r'"messageId":"([^"]+)"').allMatches(userContent))
        m.group(1)!,
    ];
    final arr = [
      for (final id in ids)
        {
          'messageId': id,
          'priority': id.endsWith('9') ? 'red' : 'green',
          'reason': '评估理由$id',
          if (id == 'm-task')
            'taskDrafts': [
              {
                'title': '交周报',
                'kind': 'point',
                'startAt': '2026-10-30T18:00',
                'priority': 'important',
              },
            ],
        },
    ];
    yield ChatTokenDelta(jsonEncode(arr));
    yield const ChatDone();
  }

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createBaseTables(db);
    appDb.debugAttachDatabase(db);
    final now = DateTime.now().millisecondsSinceEpoch;
    await appDb.insertConversation(
        Conversation(id: convId, title: '测试对话', createdAt: now, updatedAt: now));
    calls = 0;
    failOnCall = -1;
    triage.subCallOverride = fakeSubCall;
  });

  tearDown(() async {
    triage.subCallOverride = null;
    appDb.debugDetachDatabase();
    await db.close();
  });

  Future<String> runTriage({Map<String, dynamic>? scope}) => triage.run(
        conversationId: convId,
        batchId: 'amsg-1',
        idPrefix: 'amsg-1_b0',
        args: {'scope': scope ?? {'status': 'pending', 'limit': 50}},
      );

  group('scope 校验（上限 50，超上限报错）', () {
    test('合法 scope 通过', () {
      expect(InboxTriage.validateScope({'scope': {}}), isNull);
      expect(InboxTriage.validateScope({'scope': {'limit': 50}}), isNull);
      expect(
          InboxTriage.validateScope({
            'scope': {'status': 'pending', 'limit': 1}
          }),
          isNull);
    });

    test('缺 scope / 超上限 / 非 pending 状态报错', () {
      expect(InboxTriage.validateScope({}), contains('scope'));
      expect(InboxTriage.validateScope({'scope': {'limit': 51}}),
          contains('50'));
      expect(InboxTriage.validateScope({'scope': {'limit': 0}}), isNotNull);
      expect(InboxTriage.validateScope({'scope': {'status': 'processed'}}),
          contains('pending'));
    });

    test('tool_spec 中 inbox.triage 已摘掉 reserved 标记并进说明书', () {
      final spec = toolSpecByName(ToolNames.inboxTriage)!;
      expect(spec.reserved, isFalse);
      expect(spec.kind, ToolKind.read, reason: '提案生成器只读执行免审批');
      expect(buildToolSpecPrompt(DateTime(2026, 10, 28)),
          contains('inbox.triage'));
    });
  });

  group('提案生成', () {
    test('范围内无消息：不产提案、不调模型', () async {
      final summary = await runTriage();
      expect(summary, contains('没有 pending 消息'));
      expect(calls, 0);
      expect(await appDb.getProposals(), isEmpty);
    });

    test('junk 规则预过滤：命中直接产 junk 提案，不调模型', () async {
      await insertMessage(db, 'm-junk', '限时秒杀，点击领取优惠券');
      final summary = await runTriage();
      expect(calls, 0, reason: '命中规则的消息不送模型');
      expect(summary, contains('1 条命中垃圾规则'));
      expect(summary, contains('产生 1 条提案'));
      final p = (await appDb.getProposals()).single;
      expect(p.tool, ToolNames.messageSetPriority);
      expect(p.payload, {'messageId': 'm-junk', 'priority': 'junk'});
      expect(p.summary, contains('规则判定'));
      expect(p.batchId, 'amsg-1');
      expect(p.conversationId, convId);
      expect(p.status, ProposalStatus.pending);
      // 提案生成器走「只读执行免审批」路径：对话里回汇总文本
      expect(summary, contains('待确认区'));
    });

    test('模型结果映射为 set_priority / task.create 提案', () async {
      await insertMessage(db, 'm-task', '别忘了周五前交周报');
      await insertMessage(db, 'm2', '普通聊天');
      final summary = await runTriage();
      expect(calls, 1);
      expect(summary, contains('产生 3 条提案'));
      final proposals = await appDb.getProposals();
      expect(proposals, hasLength(3));
      final byId = {for (final p in proposals) p.payload['messageId']: p};
      final taskProposal =
          proposals.singleWhere((p) => p.tool == ToolNames.taskCreate);
      expect(taskProposal.payload, {
        'title': '交周报',
        'kind': 'point',
        'startAt': '2026-10-30T18:00',
        'priority': 'important',
      });
      expect(taskProposal.summary, contains('来自消息'));
      expect(byId['m-task']?.tool, ToolNames.messageSetPriority);
      expect(byId['m-task']?.payload['priority'], 'green');
      expect(byId['m2']?.payload['priority'], 'green');
      // 同一 batch_id 分组（details §3.1）
      expect(proposals.map((p) => p.batchId).toSet(), {'amsg-1'});
    });

    test('分批：25 条非垃圾消息 → 3 次子调用（10/10/5）', () async {
      for (var i = 0; i < 25; i++) {
        await insertMessage(db, 'm$i', '普通消息 $i');
      }
      final sizes = <int>[];
      triage.subCallOverride = (messages, modelConfigId) async* {
        sizes.add(RegExp(r'"messageId"')
            .allMatches(messages.last.content)
            .length);
        yield ChatTokenDelta(jsonEncode([
          for (final m in RegExp(r'"messageId":"([^"]+)"')
              .allMatches(messages.last.content))
            {'messageId': m.group(1), 'priority': 'green', 'reason': 'r'},
        ]));
        yield const ChatDone();
      };
      await runTriage();
      expect(sizes, [10, 10, 5]);
    });

    test('子调用失败不拖垮整轮：失败批计数进汇总，其余批照常落提案', () async {
      for (var i = 0; i < 12; i++) {
        await insertMessage(db, 'm$i', '普通消息 $i');
      }
      failOnCall = 1; // 第一批（10 条）失败，第二批（2 条）成功
      final summary = await runTriage();
      expect(summary, contains('10 条评估失败'));
      expect((await appDb.getProposals()).length, 2);
    });

    test('重放去重：同一 idPrefix 再跑一轮不重复落提案', () async {
      await insertMessage(db, 'm1', '普通消息');
      await runTriage();
      final first = await appDb.getProposals();
      final summary2 = await runTriage();
      expect(summary2, contains('未产生提案'));
      expect(await appDb.getProposals(), hasLength(first.length));
    });

    test('优先级与现状一致不产提案（降噪）', () async {
      await insertMessage(db, 'm9', '重要账单提醒'); // 假流给 m9 → red
      await db.update('messages', {'priority': 'red'},
          where: 'id = ?', whereArgs: ['m9']);
      final summary = await runTriage();
      expect(summary, contains('未产生提案'));
      expect(await appDb.getProposals(), isEmpty);
    });
  });

  group('parseTriageEvalOutput（迁移自 AiClient.parseBatchEvalOutput）', () {
    Message msg(String id) => Message(
          id: id,
          packageName: 'com.test',
          title: 't',
          body: 'b',
          postedAt: 1700000000000,
          captureType: 'notification',
          contentHash: 'h-$id',
          createdAt: 1700000000000,
        );
    final batch = [msg('a'), msg('b')];

    test('数组按 messageId 建 map', () {
      final out = parseTriageEvalOutput(batch, '''
[
  {"messageId":"a","priority":"red","reason":"重要账单",
   "taskDraft":{"title":"还信用卡","kind":"point","startAt":"2026-10-20T10:00","priority":"important"}},
  {"messageId":"b","priority":"junk","reason":"广告","taskDraft":null}
]''');
      expect(out.length, 2);
      expect(out['a']!.priority, 'red');
      expect(out['a']!.taskDrafts.single.title, '还信用卡');
      expect(out['a']!.taskDrafts.single.startAt, DateTime(2026, 10, 20, 10, 0));
      expect(out['b']!.priority, 'junk');
      expect(out['b']!.taskDrafts, isEmpty);
    });

    test('容忍 markdown 围栏与前后缀文字', () {
      final out = parseTriageEvalOutput(batch,
          '好的，结果如下：\n```json\n[{"messageId":"a","priority":"green","reason":"一般","taskDraft":null}]\n```\n以上。');
      expect(out['a']!.priority, 'green');
      expect(out.containsKey('b'), isFalse);
    });

    test('未知 messageId 与缺 id 元素忽略', () {
      final out = parseTriageEvalOutput(batch, '''
[
  {"messageId":"zzz","priority":"red","reason":"?","taskDraft":null},
  {"priority":"yellow","reason":"无 id","taskDraft":null},
  {"messageId":"b","priority":"yellow","reason":"值得关注","taskDraft":null}
]''');
      expect(out.length, 1);
      expect(out['b']!.priority, 'yellow');
    });

    test('非法 priority 归一为 green', () {
      final out = parseTriageEvalOutput(batch,
          '[{"messageId":"a","priority":"urgent","reason":"x","taskDraft":null}]');
      expect(out['a']!.priority, 'green');
    });

    test('无数组 / 坏 JSON 抛 AiException', () {
      expect(() => parseTriageEvalOutput(batch, '模型瞎说一通'),
          throwsA(isA<AiException>()));
      expect(() => parseTriageEvalOutput(batch, '[{"messageId":"a",]'),
          throwsA(isA<AiException>()));
    });
  });

  group('TriageTaskDraft（迁移自 ai_multidraft_test / point_task_invariant_test）',
      () {
    test('taskDrafts 数组 → 多个草稿', () {
      final drafts = parseTriageTaskDrafts(null, [
        {'title': '交周报', 'kind': 'point', 'priority': 'important'},
        {'title': '预约体检', 'kind': 'point', 'priority': 'normal'},
      ]);
      expect(drafts.length, 2);
      expect(drafts[0].title, '交周报');
      expect(drafts[1].title, '预约体检');
    });

    test('只有旧字段 taskDraft 时仍能解析（向后兼容）', () {
      final drafts = parseTriageTaskDrafts(
        {'title': '单条任务', 'kind': 'range', 'priority': 'minor'},
        null,
      );
      expect(drafts.single.title, '单条任务');
      expect(drafts.single.kind, 'range');
    });

    test('空标题草稿丢弃', () {
      final drafts = parseTriageTaskDrafts(null, [
        {'title': '', 'kind': 'point'},
        {'title': '  ', 'kind': 'point'},
      ]);
      expect(drafts, isEmpty);
    });

    test('kind=point 时丢弃模型多写的 endAt（P1-1）', () {
      final d = TriageTaskDraft.fromJson({
        'title': '交报告',
        'kind': 'point',
        'startAt': '2026-10-20T10:00',
        'endAt': '2026-10-25T18:00',
        'priority': 'normal',
      });
      expect(d.kind, 'point');
      expect(d.startAt, DateTime(2026, 10, 20, 10, 0));
      expect(d.endAt, isNull, reason: 'point 不应保留 endAt');
    });

    test('kind=range 时保留 endAt', () {
      final d = TriageTaskDraft.fromJson({
        'title': '出差',
        'kind': 'range',
        'startAt': '2026-10-20T10:00',
        'endAt': '2026-10-25T18:00',
      });
      expect(d.kind, 'range');
      expect(d.startAt, DateTime(2026, 10, 20, 10, 0));
      expect(d.endAt, DateTime(2026, 10, 25, 18, 0));
    });
  });
}
