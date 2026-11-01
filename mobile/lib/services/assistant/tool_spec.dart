/// 原子工具说明书（design-v3 §5.2、design-v3-details §2.4）：
/// 工具名、参数、示例与纪律说明的**单一事实源**，由 mobile 组装进 system prompt
/// （desktop /v1/chat 只透传、不持有说明书；双端提示词同步惯例已终结）。
library;

/// 工具类型：写工具一律落待确认区审批；只读工具直接执行并回注结果。
enum ToolKind { write, read }

class ToolSpec {
  final String name;
  final ToolKind kind;

  /// 人类可读的一句话说明（进提示词，也用于待确认区摘要兜底）。
  final String description;

  /// 参数说明（进提示词的自由文本，逐参数一行）。
  final String paramsDoc;

  /// 调用示例（```tool 块内容，进提示词）。
  final String example;

  /// 预留工具（如 inbox.triage）：不进提示词，调用一律拒绝。
  final bool reserved;

  const ToolSpec({
    required this.name,
    required this.kind,
    required this.description,
    required this.paramsDoc,
    required this.example,
    this.reserved = false,
  });
}

class ToolNames {
  static const taskCreate = 'task.create';
  static const taskUpdate = 'task.update';
  static const taskDelete = 'task.delete';
  static const taskList = 'task.list';
  static const taskSearch = 'task.search';
  static const noteCreate = 'note.create';
  static const noteAppend = 'note.append';
  static const noteReplaceSection = 'note.replace_section';
  static const noteRead = 'note.read';
  static const anchorCreate = 'anchor.create';
  static const anchorRemove = 'anchor.remove';
  static const librarySearch = 'library.search';
  static const messageSetPriority = 'message.set_priority';
  static const inboxTriage = 'inbox.triage';
}

/// 首版工具清单（design-v3 §5.2）。
const List<ToolSpec> kToolSpecs = [
  ToolSpec(
    name: ToolNames.taskCreate,
    kind: ToolKind.write,
    description: '新建一个任务',
    paramsDoc: 'title(必填, 不超过20字); description; kind: point|range(默认point); '
        'startAt/endAt: 本地时间 "YYYY-MM-DDTHH:mm"(point只需startAt, 无时间可省略); '
        'priority: important|normal|minor(默认normal); parentId: 父任务id(可选)',
    example:
        '{"tool":"task.create","args":{"title":"买菜","startAt":"2026-10-29T18:00"}}',
  ),
  ToolSpec(
    name: ToolNames.taskUpdate,
    kind: ToolKind.write,
    description: '修改一个未归档任务的一个或多个字段',
    paramsDoc: 'id(必填); 可改字段: title/description/kind/startAt/endAt/priority/'
        'status(active|done)。已归档任务不可修改',
    example:
        '{"tool":"task.update","args":{"id":"<任务id>","priority":"important"}}',
  ),
  ToolSpec(
    name: ToolNames.taskDelete,
    kind: ToolKind.write,
    description: '删除一个未归档任务',
    paramsDoc: 'id(必填)。已归档任务不可删除',
    example: '{"tool":"task.delete","args":{"id":"<任务id>"}}',
  ),
  ToolSpec(
    name: ToolNames.taskList,
    kind: ToolKind.read,
    description: '列出任务（只读，直接执行）',
    paramsDoc: 'status: active|done|archived(默认active); limit(默认50)',
    example: '{"tool":"task.list","args":{"status":"active","limit":20}}',
  ),
  ToolSpec(
    name: ToolNames.taskSearch,
    kind: ToolKind.read,
    description: '按标题/描述检索任务（只读，直接执行）',
    paramsDoc: 'query(必填)',
    example: '{"tool":"task.search","args":{"query":"买菜"}}',
  ),
  ToolSpec(
    name: ToolNames.noteCreate,
    kind: ToolKind.write,
    description: '新建一篇 markdown 笔记',
    paramsDoc: 'title(必填); content(markdown 正文); chapterId(可选, 缺省放入第一个章节)',
    example:
        '{"tool":"note.create","args":{"title":"购物清单","content":"- 牛奶\\n- 鸡蛋"}}',
  ),
  ToolSpec(
    name: ToolNames.noteAppend,
    kind: ToolKind.write,
    description: '向一篇笔记末尾追加内容',
    paramsDoc: 'noteId(必填); content(必填, 追加的 markdown 内容)',
    example:
        '{"tool":"note.append","args":{"noteId":"<笔记id>","content":"\\n补充一行"}}',
  ),
  ToolSpec(
    name: ToolNames.noteReplaceSection,
    kind: ToolKind.write,
    description: '替换一篇笔记中由标题界定的区段（避免全文覆盖）',
    paramsDoc: 'noteId(必填); heading(必填, markdown 标题文本, 不含 # 号); '
        'content(必填, 该区段的新正文, 不含标题行本身)',
    example:
        '{"tool":"note.replace_section","args":{"noteId":"<笔记id>","heading":"周二安排","content":"新内容"}}',
  ),
  ToolSpec(
    name: ToolNames.noteRead,
    kind: ToolKind.read,
    description: '读取一篇笔记（只读，直接执行）',
    paramsDoc: 'noteId(必填)',
    example: '{"tool":"note.read","args":{"noteId":"<笔记id>"}}',
  ),
  ToolSpec(
    name: ToolNames.anchorCreate,
    kind: ToolKind.write,
    description: '在库中目标（笔记/消息指定文本处，或整个文件）创建一个任务锚点',
    paramsDoc: 'targetType: note|message|file(必填); targetId(必填); taskId(必填); '
        'anchorText(笔记/消息必填: 正文中的定位文本, 锚点插到其首次出现处之后; file 不需要)',
    example:
        '{"tool":"anchor.create","args":{"targetType":"note","targetId":"<笔记id>","taskId":"<任务id>","anchorText":"买菜"}}',
  ),
  ToolSpec(
    name: ToolNames.anchorRemove,
    kind: ToolKind.write,
    description: '移除一个任务锚点（正文中的 marker 一并清除）',
    paramsDoc: 'anchorId(必填, 即正文中 ⟦task:<id>⟧ 的 id)',
    example: '{"tool":"anchor.remove","args":{"anchorId":"<锚点id>"}}',
  ),
  ToolSpec(
    name: ToolNames.librarySearch,
    kind: ToolKind.read,
    description: '检索库：笔记/消息/文件的标题与正文（只读，直接执行）',
    paramsDoc: 'query(必填); types: ["note","message","file"] 子集(可选, 默认全部)',
    example: '{"tool":"library.search","args":{"query":"报销"}}',
  ),
  ToolSpec(
    name: ToolNames.messageSetPriority,
    kind: ToolKind.write,
    description: '标记一条消息的优先级（一条消息一个提案）',
    paramsDoc: 'messageId(必填); priority: red|yellow|green|junk|none(必填)',
    example:
        '{"tool":"message.set_priority","args":{"messageId":"<消息id>","priority":"junk"}}',
  ),
  // 提案生成器（details §4）：只读执行免审批，产出落到待确认区。
  ToolSpec(
    name: ToolNames.inboxTriage,
    kind: ToolKind.read,
    description: '对指定范围的未处理消息批量评估（垃圾规则本地预过滤 + 模型分批评估），'
        '产出一组 message.set_priority / task.create 提案到待确认区；'
        '本身不直接改任何数据',
    paramsDoc: 'scope(必填): {status: 仅支持 "pending", limit: 1..50（默认50，'
        '超过50会报错，请分批调用）}',
    example: '{"tool":"inbox.triage","args":{"scope":{"status":"pending","limit":50}}}',
  ),
];

ToolSpec? toolSpecByName(String name) {
  for (final s in kToolSpecs) {
    if (s.name == name) return s;
  }
  return null;
}

/// 组装进 system prompt 的工具说明书（design-v3-details §2.4）。
/// [now] 注入当前本地时间，供模型解析相对日期。
String buildToolSpecPrompt(DateTime now) {
  String fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')} '
      '(周${'日一二三四五六'[d.weekday % 7]})';
  final buf = StringBuffer()
    ..writeln('你是 ManaList 的个人助理。用户可以与你对话，你可以通过「工具调用块」操作应用。')
    ..writeln('当前本地时间：${fmt(now)}。解析相对日期（如"明天""本周五"）以此为基准。')
    ..writeln()
    ..writeln('## 工具调用块格式')
    ..writeln('在回复中内嵌围栏块，一块一个原子调用（字段仅 tool / args）：')
    ..writeln('```tool')
    ..writeln('{"tool":"task.create","args":{"title":"买菜"}}')
    ..writeln('```')
    ..writeln('普通回复文本与工具块可任意交错；一个回合允许输出多个块。')
    ..writeln('推理过程可用 <think>...</think> 标签包裹（不会展示为正文）；'
        '一个回合中思考与正文可多次交替。')
    ..writeln()
    ..writeln('## 纪律（必须遵守）')
    ..writeln('1. 原子化：一个工具块只表达一个最小变更；做多件事就输出多个块。')
    ..writeln('2. 全量审批：写工具的调用不直接生效，会进入「待确认区」由用户人工审批；'
        '你只负责生成提案，不要声称已生效。')
    ..writeln('3. 只读工具（task.list/task.search/note.read/library.search）会直接执行并把结果回给你。')
    ..writeln('   inbox.triage 也会直接执行：它只读消息、产出提案到待确认区，'
        '执行后你会收到提案数量汇总，不要声称消息已被标记或任务已创建。')
    ..writeln('4. 已归档任务不可修改/删除；没有删除笔记/文件的工具；不要触碰设置与密钥。')
    ..writeln('5. 引用库中实体时使用其真实 id（附件以 [#note:标题] 等形式给出上下文）。')
    ..writeln()
    ..writeln('## 工具清单');
  for (final s in kToolSpecs) {
    if (s.reserved) continue;
    buf
      ..writeln('### ${s.name}（${s.kind == ToolKind.read ? '只读' : '写，需审批'}）')
      ..writeln(s.description)
      ..writeln('参数：${s.paramsDoc}')
      ..writeln('示例：${s.example}');
  }
  return buf.toString();
}
