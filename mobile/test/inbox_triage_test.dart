import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/conversation.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/ai_client.dart';
import 'package:msgrepo_mobile/services/assistant/models.dart';
import 'package:msgrepo_mobile/services/assistant/proposal_service.dart';
import 'package:msgrepo_mobile/services/assistant/tool_parser.dart';
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

  /// 最近一次子调用送进模型的 user content（B15 断言「未选消息没进 triage」用）。
  String lastUserContent = '';
  Stream<ChatEvent> fakeSubCall(
      List<ChatMessageModel> messages, String? modelConfigId) async* {
    calls++;
    if (calls == failOnCall) {
      yield const ChatError('模型挂了');
      return;
    }
    final userContent = messages.last.content;
    lastUserContent = userContent;
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
    lastUserContent = '';
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

  group('B15 只处理选定消息（选中集合 = triage 范围）', () {
    /// 取本次 triage 真正送进模型的消息 id（假流的 user content 里带 messageId）。
    Set<String> sentIds() => {
          for (final m in RegExp(r'"messageId":"([^"]+)"')
              .allMatches(lastUserContent))
            m.group(1)!,
        };

    test('有选中集合时：未选消息不进 triage、不产生提案', () async {
      await insertMessage(db, 'm-sel1', '普通消息一');
      await insertMessage(db, 'm-sel2', '普通消息二');
      await insertMessage(db, 'm-other1', '未选消息一');
      await insertMessage(db, 'm-other2', '未选消息二');

      final summary = await triage.run(
        conversationId: convId,
        batchId: 'amsg-sel',
        idPrefix: 'amsg-sel_b0',
        args: {
          'scope': {'status': 'pending', 'limit': 50}
        },
        selectedMessageIds: const ['m-sel1', 'm-sel2'],
      );

      final proposals = await appDb.getProposals();
      expect(proposals, isNotEmpty);
      final touched = {for (final p in proposals) p.payload['messageId']};
      expect(touched, {'m-sel1', 'm-sel2'},
          reason: '未选消息不得产生提案（B15 核心）');
      expect(sentIds(), {'m-sel1', 'm-sel2'}, reason: '未选消息不得进入 triage 子调用');
      expect(summary, contains('2 条消息'), reason: '汇总口径应等于选中范围');
    });

    test('未传 / 空选中集合：保持原「全量 pending」行为不变', () async {
      await insertMessage(db, 'm1', '普通消息一');
      await insertMessage(db, 'm2', '普通消息二');
      final summary = await runTriage();
      expect(summary, contains('2 条消息'));
      expect(
          {for (final p in await appDb.getProposals()) p.payload['messageId']},
          {'m1', 'm2'});
    });

    test('选中即范围：已处理（非 pending）的选中消息同样会被处理', () async {
      await insertMessage(db, 'm-done', '已处理过的消息');
      await insertMessage(db, 'm-pending', '待处理消息');
      await db.update('messages', {'status': 'processed'},
          where: 'id = ?', whereArgs: ['m-done']);

      await triage.run(
        conversationId: convId,
        batchId: 'amsg-mixed',
        idPrefix: 'amsg-mixed_b0',
        args: {
          'scope': {'status': 'pending', 'limit': 50}
        },
        selectedMessageIds: const ['m-done', 'm-pending'],
      );

      expect(
          {for (final p in await appDb.getProposals()) p.payload['messageId']},
          {'m-done', 'm-pending'},
          reason: '范围由选中集合决定，status 只用于未选中的默认范围');
    });

    test('ProposalService.handleToolBlock 把选中集合转发给 triage', () async {
      await insertMessage(db, 'm-sel1', '普通消息一');
      await insertMessage(db, 'm-other1', '未选消息一');

      const block = ParsedToolBlock(
        index: 0,
        tool: ToolNames.inboxTriage,
        args: {
          'scope': {'status': 'pending', 'limit': 50}
        },
        raw: '{}',
      );
      final outcome = await ProposalService.instance.handleToolBlock(
        conversationId: convId,
        batchId: 'amsg-fwd',
        block: block,
        selectedMessageIds: const ['m-sel1'],
      );

      expect(outcome, isA<ReadToolResult>());
      final mine =
          (await appDb.getProposals()).where((p) => p.batchId == 'amsg-fwd');
      expect({for (final p in mine) p.payload['messageId']}, {'m-sel1'},
          reason: '转发丢失会导致未选消息也被处理');
    });

    test('selectedMessageIdsOf：只取 message 类型附件，去重保序', () {
      expect(
          selectedMessageIdsOf(const [
            ChatAttachment(type: ChatAttachmentType.message, id: 'a'),
            ChatAttachment(type: ChatAttachmentType.note, id: 'n1'),
            ChatAttachment(type: ChatAttachmentType.message, id: 'b'),
            ChatAttachment(type: ChatAttachmentType.message, id: 'a'),
            ChatAttachment(type: ChatAttachmentType.file, id: 'f1'),
          ]),
          ['a', 'b']);
      expect(selectedMessageIdsOf(const []), isEmpty);
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

  // ---- A01：回复/查询/疑问类消息不得误建任务（2026-11-02 真机反例） ----

  group('A01：回复/查询类误建兜底', () {
    /// 让本轮所有消息都回同一批草稿（构造真机反例用）。
    void replyWith(List<Map<String, dynamic>> drafts) {
      triage.subCallOverride = (messages, modelConfigId) async* {
        final userContent = messages.last.content;
        final ids = [
          for (final m
              in RegExp(r'"messageId":"([^"]+)"').allMatches(userContent))
            m.group(1)!,
        ];
        yield ChatTokenDelta(jsonEncode([
          for (final id in ids)
            {
              'messageId': id,
              'priority': 'green',
              'reason': '被问时间',
              'taskDrafts': drafts,
            },
        ]));
        yield const ChatDone();
      };
    }

    List<ChangeProposal> tasksOf(List<ChangeProposal> all) =>
        all.where((p) => p.tool == ToolNames.taskCreate).toList();

    test('真机反例：「帮我看下明天的会几点开始」→ 丢弃「查会议时间回张三」', () async {
      await insertMessage(db, 'm-ask', '帮我看下明天的会几点开始');
      replyWith([
        {'title': '查会议时间回张三', 'kind': 'point', 'priority': 'normal'},
      ]);

      final summary = await runTriage();
      final all = await appDb.getProposals();

      expect(tasksOf(all), isEmpty, reason: 'A01：纯查询/疑问不得建任务');
      expect(summary, contains('丢弃 1 条非行动草稿'));
      // 消息本身仍照常分类（优先级提案不受影响）
      expect(all.where((p) => p.tool == ToolNames.messageSetPriority),
          isNotEmpty);
    });

    test('「回复张三」无时间无交付物 → 丢弃', () async {
      await insertMessage(db, 'm-reply', '张三：明天几点到？');
      replyWith([
        {'title': '回复张三', 'kind': 'point', 'priority': 'normal'},
      ]);

      final summary = await runTriage();
      expect(tasksOf(await appDb.getProposals()), isEmpty);
      expect(summary, contains('丢弃 1 条'));
    });

    test('「明晚8点前把表发我」→ 明确时间仍建任务（不误杀）', () async {
      await insertMessage(db, 'm-do', '明晚8点前把表发我');
      replyWith([
        {
          'title': '给张三发表',
          'kind': 'point',
          'startAt': '2026-11-03T20:00',
          'priority': 'important',
        },
      ]);

      final summary = await runTriage();
      final tasks = tasksOf(await appDb.getProposals());
      expect(tasks, hasLength(1), reason: '明确时间的事项必须保留草稿');
      expect(tasks.single.payload['title'], '给张三发表');
      expect(tasks.single.payload['startAt'], '2026-11-03T20:00');
      expect(summary, isNot(contains('丢弃')), reason: '本轮没有需要丢弃的草稿');
    });

    test('支付回执 / 闲聊 → 不误建任务', () async {
      await insertMessage(db, 'm-pay', '您账户发生快捷支付扣款人民币42.76元');
      await insertMessage(db, 'm-chat', '哈哈今晚吃啥，随便');
      // 默认 fakeSubCall 对这两条不给草稿
      final summary = await runTriage();

      expect(tasksOf(await appDb.getProposals()), isEmpty);
      expect(summary, isNot(contains('丢弃')));
    });

    test('shouldDropTriageTaskDraft 纯函数边界（时间/交付物豁免、普通待办不误伤）', () {
      TriageTaskDraft d(String title, {String? description, DateTime? startAt}) =>
          TriageTaskDraft(
            title: title,
            description: description,
            kind: 'point',
            startAt: startAt,
            priority: 'normal',
          );

      expect(shouldDropTriageTaskDraft(d('回复张三')), isTrue);
      expect(shouldDropTriageTaskDraft(d('查会议时间回张三')), isTrue);
      expect(
          shouldDropTriageTaskDraft(
              d('回复张三', startAt: DateTime(2026, 11, 3, 20))),
          isFalse,
          reason: '有明确时间 → 保留');
      expect(
          shouldDropTriageTaskDraft(d('回复张三', description: '顺带把报名表交了')),
          isFalse,
          reason: '有明确交付物 → 保留');
      expect(shouldDropTriageTaskDraft(d('交周报')), isFalse,
          reason: '普通待办不能被误伤');
      expect(shouldDropTriageTaskDraft(d('买菜')), isFalse);
    });
  });
}
