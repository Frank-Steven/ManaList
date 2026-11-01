/// inbox.triage 工具（design-v3-details §4）：**提案生成器**。
///
/// 本身是只读的（对应用数据无写入），AI 调用后无需审批即自动执行；
/// 产出全部是一组原子提案（message.set_priority / task.create），
/// 落 change_proposals（同一 batch_id），进待确认区由人工审批。
///
/// 流程：取范围内消息 → junk_rules 本地预过滤（命中直接产 junk 提案，
/// 不调模型）→ 其余按 [kTriageBatchSize] 条/批组子调用（复用
/// AssistantClient 通道与当前对话模型配置；子调用 token 流不上屏）→
/// 解析「按 messageId 对应的 JSON 数组」→ 映射为提案。
///
/// 批量评估提示词与解析器迁移自 v2 批处理管线（原 ai_client 的
/// _buildBatchSystemPrompt / parseBatchEvalOutput），分类参考表迁移自
/// 原 categories.dart——这三处是此处唯一事实源，原文件已随批管线删除。
library;

import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../../../models/message.dart';
import '../../ai_client.dart';
import '../../database.dart';
import '../../junk_rules.dart';
import '../assistant_client.dart';
import '../models.dart';
import '../tool_spec.dart';

/// 单次 triage 的消息数上限（details §4：超出上限报错让 AI 分批）。
const kTriageMaxLimit = 50;

/// 每批子调用的消息数（沿用 v2 EVAL_BATCH_SIZE 经验值）。
const kTriageBatchSize = 10;

/// 上下文裁剪（v2.6.1 省 Token 经验值）：标题 100 字符、正文 500 字符截断。
const triageTitleMaxChars = 100;
const triageBodyMaxChars = 500;

// ---- 分类参考（迁移自 categories.dart，仅供评估提示词使用） ----

class PromptCategory {
  final String key;
  final String displayName;
  final String description;
  final String? priorityHints;

  const PromptCategory({
    required this.key,
    required this.displayName,
    required this.description,
    this.priorityHints,
  });
}

/// 分类参考列表（辅助模型判断重要性与垃圾）。
const kPromptCategories = [
  PromptCategory(
    key: 'schedule',
    displayName: '日程',
    description: '有明确开始时间的事件：会议、约会、航班、火车、演出、预约等。',
    priorityHints: '开始时间在24小时内且不可错过（航班/会议）→ red；一般 → yellow；例行提醒 → green',
  ),
  PromptCategory(
    key: 'todo',
    displayName: '待办',
    description: '需要本人执行的动作：缴费、回复、提交材料、取快递、抢票等。',
    priorityHints: '有截止时间且临近 → red / yellow；无明确时间 → green；可做可不做 → green',
  ),
  PromptCategory(
    key: 'note',
    displayName: '笔记',
    description: '值得留存但无需行动的信息：地址、账号、推荐、知识点、他人发的有用内容等。',
    priorityHints: '通常 green；用户手动添加的笔记可为 yellow',
  ),
  PromptCategory(
    key: 'express',
    displayName: '快递物流',
    description: '快递收发、物流状态：到达待取、已揽收、派送中等。',
    priorityHints: '到达待取 → yellow；在途 → green',
  ),
  PromptCategory(
    key: 'bill',
    displayName: '账单缴费',
    description: '水电煤、话费、信用卡还款等账单通知。',
    priorityHints: '临近最后期限 → red；常规出账 → yellow',
  ),
  PromptCategory(
    key: 'coupon',
    displayName: '优惠营销',
    description: '优惠券、促销、活动推送、直播开播提醒等营销类通知，多为低价值信息。',
    priorityHints: '几乎总是 green；明显营销推送（含退订/秒杀等模板）→ junk；用户常关注的品牌且有明确截止时间可 yellow',
  ),
  PromptCategory(
    key: 'verification',
    displayName: '验证码',
    description: '一次性验证码、动态口令。',
    priorityHints: '收到时总是 red（即时使用），过期后无价值',
  ),
  PromptCategory(
    key: 'generic',
    displayName: '未分类',
    description: '兜底分类：无法归入其他任何分类时使用。',
    priorityHints: '默认 green',
  ),
];

// ---- 评估结果模型（迁移自 ai_client，名字随新主人改为 Triage*） ----

/// 任务草稿；startAt/endAt 已解析为本地时间。
class TriageTaskDraft {
  final String title;
  final String? description;
  final String kind; // TaskKind.point | TaskKind.range
  final DateTime? startAt;
  final DateTime? endAt;
  final String priority; // TaskPriority.important | normal | minor

  const TriageTaskDraft({
    required this.title,
    this.description,
    required this.kind,
    this.startAt,
    this.endAt,
    required this.priority,
  });

  static DateTime? _parseLocal(dynamic v) {
    if (v is! String || v.trim().isEmpty) return null;
    return DateTime.tryParse(v.trim().replaceFirst(' ', 'T'));
  }

  factory TriageTaskDraft.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] == 'range' ? 'range' : 'point';
    return TriageTaskDraft(
      title: (json['title'] as String? ?? '').trim(),
      description: (json['description'] as String?)?.trim(),
      kind: kind,
      startAt: _parseLocal(json['startAt']),
      // point 任务只保留单个时刻：模型偶尔会多写 endAt，这里直接丢弃（P1-1）
      endAt: kind == 'range' ? _parseLocal(json['endAt']) : null,
      priority:
          const ['important', 'normal', 'minor'].contains(json['priority'])
              ? json['priority'] as String
              : 'normal',
    );
  }
}

/// 单条消息的评估结果。
class TriageEvalResult {
  final String messageId;
  final String priority; // MessagePriority.red | yellow | green | junk
  final String reason;
  final List<TriageTaskDraft> taskDrafts;

  const TriageEvalResult({
    required this.messageId,
    required this.priority,
    required this.reason,
    this.taskDrafts = const [],
  });
}

/// 解析任务草稿：优先 `taskDrafts` 数组，兼容旧的单个 `taskDraft`。
/// 空标题的草稿直接丢弃（模型偶尔给空壳）。
List<TriageTaskDraft> parseTriageTaskDrafts(dynamic single, dynamic multi) {
  final out = <TriageTaskDraft>[];
  if (multi is List) {
    for (final e in multi) {
      if (e is! Map) continue;
      final d = TriageTaskDraft.fromJson(e.cast<String, dynamic>());
      if (d.title.trim().isNotEmpty) out.add(d);
    }
  }
  if (out.isEmpty && single is Map) {
    final d = TriageTaskDraft.fromJson(single.cast<String, dynamic>());
    if (d.title.trim().isNotEmpty) out.add(d);
  }
  return out;
}

/// 解析批量评估输出：取首个 [ 到末个 ] 的 JSON 数组，按 messageId 建 map。
/// 容忍 markdown 围栏/前后缀文字；数组中缺 messageId 或 id 不在批次内的
/// 元素忽略；完全没有合法数组时抛 AiException（整批报错）。
Map<String, TriageEvalResult> parseTriageEvalOutput(
    List<Message> batch, String content) {
  final start = content.indexOf('[');
  final end = content.lastIndexOf(']');
  if (start == -1 || end <= start) {
    throw AiException(
        '模型未返回 JSON 数组：${content.substring(0, content.length > 200 ? 200 : content.length)}');
  }
  List<dynamic> arr;
  try {
    arr = jsonDecode(content.substring(start, end + 1)) as List<dynamic>;
  } catch (e) {
    throw AiException('模型输出 JSON 解析失败：$e');
  }
  final known = {for (final m in batch) m.id};
  final results = <String, TriageEvalResult>{};
  for (final item in arr) {
    if (item is! Map) continue;
    final map = item.cast<String, dynamic>();
    final id = map['messageId'] as String?;
    if (id == null || !known.contains(id)) continue;
    results[id] = TriageEvalResult(
      messageId: id,
      priority: _normalizePriority(map['priority']),
      reason: map['reason'] as String? ?? '',
      taskDrafts: parseTriageTaskDrafts(map['taskDraft'], map['taskDrafts']),
    );
  }
  return results;
}

String _normalizePriority(dynamic v) {
  const valid = ['red', 'yellow', 'green', 'junk'];
  return valid.contains(v) ? v as String : 'green';
}

// ---- 提示词（迁移自 ai_client._buildBatchSystemPrompt 等，原批量评估提示词） ----

/// 批量评估系统提示词：schema 为结果数组，元素按 messageId 对应输入消息。
String buildTriageSystemPrompt() {
  final catList = kPromptCategories
      .map((c) =>
          '- ${c.key}（${c.displayName}）: ${c.description}'
          '${c.priorityHints != null ? ' 优先级提示：${c.priorityHints}' : ''}')
      .join('\n');
  return '你是消息评估助手。用户消息里有「消息列表」，为其中每条消息输出一个评估对象，'
      '整体组成一个 JSON 数组（顺序与输入一致）：\n'
      '[{"messageId":"输入消息的 messageId","priority":"red|yellow|green|junk",'
      '"reason":"一句话理由","taskDrafts":['
      '{"title":"...","description":"...","kind":"point|range","startAt":"YYYY-MM-DDTHH:mm",'
      '"endAt":"YYYY-MM-DDTHH:mm","priority":"important|normal|minor"}]}]\n'
      'priority 语义：red=重要、yellow=值得关注、green=一般、junk=垃圾（营销、推广、无用系统提示等）。'
      '判断重要与垃圾是首要职责。结合来源应用与会话语境判断（如银行/支付类通知多重要、'
      '应用商店的推广多为垃圾）。\n'
      'taskDrafts 规则（数组，最多 3 个；**没有可执行事项就给空数组 []**，这是常态）：\n'
      '- 判断标准只有一句：**用户还得动手去做**吗？说不清「做什么/对谁/什么时候」的一律不给草稿。\n'
      '- 一条消息里有多件互不相关的事，每件给一个草稿；同一件事的多个步骤仍只给一个草稿。\n'
      '- 消息本身不带可执行动作时（账号信息、地址、灵感、要买的东西等）**不要**给草稿；\n'
      '  「值得留存备查」不构成建任务的理由。\n'
      '- **以下一律给空数组 []**（这些不是待办）：\n'
      '  · 支付/扣款/消费回执（“您账户…发生快捷支付扣款人民币42.76”“支付成功”“到账通知”）；\n'
      '  · 应用更新/升级提示、应用商店推送、版本发布公告、系统升级完成；\n'
      '  · 群公告、有人在群里问话/@你、催你回复 —— 那是聊天，不是待办；\n'
      '    除非原消息明确约定了事项与时间（如“明晚8点前把表发我”“周五前交报名表”）；\n'
      '  · 系统状态提示（充电、USB、Wi-Fi/信号、电量、蓝牙）；\n'
      '  · 纯告知、营销、广告、验证码、物流泛通知（“预计明天送达”这类无动作的）。\n'
      '- **禁止把消息标题换个说法抄成任务**：「回复<某人/某群>」「更新<某应用>」「留意<某事>」这类模板化短语不是任务，\n'
      '  除非消息里给了明确的时间或交付物。\n'
      '- title 不超过 20 个字符（中文按 2 字符计），超长的细节放入 description。\n'
      '- kind=point 时点任务只需 startAt；kind=range 时段任务需要 startAt 和 endAt；'
      '没有明确时间的可执行事项省略 startAt/endAt（不定时任务）。\n'
      '- 同一件事的多步骤在主事项草稿里用换行列表写进 description；互不相关的事才拆成多个草稿。\n'
      '- 任务 priority：important=重要、normal=一般、minor=不重要。\n'
      '时间用本地时间字符串 "YYYY-MM-DDTHH:mm" 输出（不要自行换算毫秒），相对日期（如"本周五""下周一"）'
      '查用户消息里的日期对照表确定；解析出的时间必须晚于基准时间：若字面日期标注了"已过去"，顺延到下一个未来的同名日期。\n'
      '分类参考（辅助判断重要性与垃圾）：\n$catList\n'
      '只输出 JSON 数组。';
}

String _truncate(String text, int max) {
  final chars = text.characters;
  if (chars.length <= max) return text;
  return '${chars.take(max)}…（已截断）';
}

/// 子调用用户消息：基准时间 + 日期对照表 + 消息列表。
String buildTriageUserContent(List<Message> batch, DateTime now) {
  String fmt(DateTime d) =>
      '${d.year}年${d.month}月${d.day}日（周${'日一二三四五六'[d.weekday % 7]}）'
      ' ${d.hour}:${d.minute.toString().padLeft(2, '0')}';
  return jsonEncode({
    '基准时间': fmt(now),
    '日期对照表': buildTriageDateHints(now),
    '消息列表': [
      for (final m in batch)
        {
          'messageId': m.id,
          '消息时间': fmt(DateTime.fromMillisecondsSinceEpoch(m.postedAt)),
          '来源应用': m.appName,
          '会话': m.conversationTitle,
          '发送者': m.sender,
          '标题': _truncate(m.title, triageTitleMaxChars),
          '正文': _truncate(m.body, triageBodyMaxChars),
        },
    ],
  });
}

/// 日期对照表（周一为一周第一天）。
String buildTriageDateHints(DateTime base) {
  const weekChars = '日一二三四五六';
  String fmt(DateTime d) =>
      '${d.year}年${d.month}月${d.day}日（周${weekChars[d.weekday % 7]}）';
  DateTime day(int offset) =>
      DateTime(base.year, base.month, base.day + offset, base.hour, base.minute);
  final lines = ['今天=${fmt(day(0))}', '明天=${fmt(day(1))}', '后天=${fmt(day(2))}'];
  final dow = base.weekday - 1; // 周一=0
  const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  for (var i = 0; i < 7; i++) {
    lines.add('本${names[i]}=${fmt(day(i - dow))}${i - dow < 0 ? '（已过去）' : ''}');
  }
  for (var i = 0; i < 7; i++) {
    lines.add('下${names[i]}=${fmt(day(i - dow + 7))}');
  }
  return lines.join('\n');
}

// ---- 提案生成器 ----

class InboxTriage {
  InboxTriage._();

  static final InboxTriage instance = InboxTriage._();

  /// 子调用通道（测试注入假流；默认用独立 AssistantClient 实例——与主对话
  /// 共享单例的在途/取消状态隔离，子调用 token 流不上屏）。
  @visibleForTesting
  Stream<ChatEvent> Function(
      List<ChatMessageModel> messages, String? modelConfigId)? subCallOverride;

  /// 校验 scope 参数（details §4：首版只支持 status + limit，上限 50）。
  /// 通过返回 null，否则返回失败原因（供 proposal_service 校验器调用）。
  static String? validateScope(Map<String, dynamic> args) {
    final scope = args['scope'];
    if (scope is! Map) return '缺少必填参数: scope';
    final status = scope['status'] ?? MessageStatus.pending;
    if (status != MessageStatus.pending) {
      return 'scope.status 首版仅支持 pending（收到: $status）';
    }
    final limit = scope['limit'];
    if (limit != null && (limit is! num || limit < 1 || limit > kTriageMaxLimit)) {
      return 'scope.limit 须为 1..$kTriageMaxLimit 的整数（超出上限请分批调用）';
    }
    return null;
  }

  /// 执行一轮 triage：落提案到 change_proposals，返回对话汇总文本。
  ///
  /// [batchId] = 调用它的 assistant 消息 id（同回合提案为一组）；
  /// [idPrefix] = 去重键前缀（重放同回合时命中主键跳过）。
  Future<String> run({
    required String conversationId,
    required String batchId,
    required String idPrefix,
    required Map<String, dynamic> args,
  }) async {
    final db = AppDatabase.instance;
    final scope = (args['scope'] as Map).cast<String, dynamic>();
    final status = scope['status'] as String? ?? MessageStatus.pending;
    final limit = (scope['limit'] as num?)?.toInt() ?? kTriageMaxLimit;

    final messages = await db.getMessages(status: status, limit: limit);
    if (messages.isEmpty) {
      return '范围内没有 $status 消息，未产生提案。';
    }

    // 子调用沿用当前对话绑定的模型配置（details §4-2）
    final modelConfigId =
        (await db.getConversationById(conversationId))?.modelConfigId;

    var seq = 0;
    var created = 0;
    Future<void> addProposal(
        String tool, Map<String, dynamic> payload, String summary) async {
      final id = '${idPrefix}_t${seq++}';
      if (await db.getProposalById(id) != null) return; // 重放去重
      await db.insertProposal(ChangeProposal(
        id: id,
        conversationId: conversationId,
        batchId: batchId,
        tool: tool,
        summary: summary,
        payload: payload,
        status: ProposalStatus.pending,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      created++;
    }

    Future<void> proposePriority(Message m, String priority, String reason) {
      if (priority == m.priority) return Future.value(); // 与现状一致不产提案
      final suffix = reason.isEmpty ? '' : '（$reason）';
      return addProposal(
        ToolNames.messageSetPriority,
        {'messageId': m.id, 'priority': priority},
        '把消息「${m.title}」标为 $priority$suffix',
      );
    }

    // 1. junk 规则本地预过滤：命中直接产 junk 提案，不调模型（省 token）
    final toEval = <Message>[];
    var junkHits = 0;
    for (final m in messages) {
      final hit = junkRuleHit(m);
      if (hit != null) {
        junkHits++;
        await proposePriority(m, MessagePriority.junk, hit);
      } else {
        toEval.add(m);
      }
    }

    // 2. 其余按 10 条/批组子调用；单批失败不拖垮整轮
    var evalFailed = 0;
    for (var i = 0; i < toEval.length; i += kTriageBatchSize) {
      final batch = toEval.sublist(i,
          i + kTriageBatchSize > toEval.length ? toEval.length : i + kTriageBatchSize);
      Map<String, TriageEvalResult> results;
      try {
        results = await _evalBatch(batch, modelConfigId);
      } catch (_) {
        evalFailed += batch.length;
        continue;
      }
      // 3. 逐条映射为提案
      for (final m in batch) {
        final r = results[m.id];
        if (r == null) {
          evalFailed++;
          continue;
        }
        await proposePriority(m, r.priority, r.reason);
        for (final d in r.taskDrafts) {
          await addProposal(
            ToolNames.taskCreate,
            {
              'title': d.title,
              if (d.description != null && d.description!.isNotEmpty)
                'description': d.description,
              'kind': d.kind,
              if (d.startAt != null) 'startAt': _fmtLocal(d.startAt!),
              if (d.endAt != null) 'endAt': _fmtLocal(d.endAt!),
              'priority': d.priority,
            },
            '新建任务「${d.title}」（来自消息「${m.title}」）',
          );
        }
      }
    }

    // 4. 对话汇总（details §4-4）
    final buf = StringBuffer('inbox.triage 完成：范围内 ${messages.length} 条消息');
    if (junkHits > 0) buf.write('，其中 $junkHits 条命中垃圾规则（未调模型）');
    if (evalFailed > 0) buf.write('，$evalFailed 条评估失败');
    buf.write(created > 0
        ? '。产生 $created 条提案，请到待确认区审批。'
        : '，未产生提案。');
    return buf.toString();
  }

  /// 一批消息的独立子调用：拼提示词 → 走助理通道 → 累积输出 → 解析。
  Future<Map<String, TriageEvalResult>> _evalBatch(
      List<Message> batch, String? modelConfigId) async {
    final now = DateTime.now();
    final messages = [
      ChatMessageModel(
          role: ChatRole.user,
          content: '[系统说明]\n${buildTriageSystemPrompt()}'),
      ChatMessageModel(
          role: ChatRole.user, content: buildTriageUserContent(batch, now)),
    ];
    final call = subCallOverride ??
        (msgs, configId) => AssistantClient.independent().chat(
              conversationId: 'inbox.triage 子调用',
              messages: msgs,
              modelConfigId: configId,
            );
    final buf = StringBuffer();
    await for (final ev in call(messages, modelConfigId)) {
      switch (ev) {
        case ChatTokenDelta(:final delta):
          buf.write(delta);
        case ChatError(:final error):
          throw AiException(error);
        case ChatDone():
        case ChatProposalEvent():
          break; // 子调用不产工具块；桌面端也不透传 proposal 事件
      }
    }
    return parseTriageEvalOutput(batch, buf.toString());
  }

  static String _fmtLocal(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}T'
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
