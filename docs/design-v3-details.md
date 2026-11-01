# MsgRepo v3 细化方案（开放问题与核心机制定稿）

> 状态：v1.0（2026-10-28）
> 关系：本文档是 `docs/design-v3.md`（v3.1）的配套细化文档，逐项解决其 §9 的开放问题，并对锚点机制、工具协议、待确认区、存档格式四个核心机制给出可直接实施的技术定稿。冲突处以本文档为准，主文档 §9 已回写索引。

---

## 1. 锚点行内对象技术方案

### 1.1 marker 语法规范（定稿）

```
⟦task:<uuid>⟧
```

- 正则（全项目唯一事实源，mobile/desktop/测试共用同一常量）：
  `⟦task:([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})⟧`
- `<uuid>` 即 `task_anchors.id`，小写写入、读取大小写容忍。
- marker **不内嵌** label/任务标题：渲染时按 anchorId → task_anchors → tasks 联查标题；正文里只有 id，任务改名后所有锚点 chip 自动跟随，无需改正文。
- 同一正文允许任意多个 marker；同一任务可在多处出现（不同 anchorId）。

### 1.2 渲染管线（flutter_markdown）

- 新增 `TaskAnchorInlineSyntax extends InlineSyntax`（包：`markdown` 的 inline 语法扩展点），匹配上面的正则，产出 `Element.tag('taskanchor')` + attribute `id`。
- flutter_markdown 侧注册 `MarkdownElementBuilder`：把该 element 渲染为 chip 组件（图标 + 任务标题 + 状态色），点击跳任务详情；联查走 `AnchorService` 的内存缓存（按正文批量预取 anchorId 列表，避免逐 marker 查库）。
- **代码区保护**：`markdown` 包的 fenced code block / inline code span 不跑 inline syntax 解析，代码片段中的 marker 样文本天然不被转换。需测试固化（§6）。
- 消息详情、笔记预览、待确认区 diff 预览复用同一渲染管线。

### 1.3 编辑态方案（定稿：纯文本 + marker 高亮，不做 WYSIWYG 部件内嵌）

- 笔记编辑器维持双模式：编辑态 = `TextField` + 自定义 `AnchorHighlightController extends TextEditingController`，覆写 `buildTextSpan`，把 marker 匹配段渲染为带底色/圆角边框样式的 `TextSpan`（文本本身仍是 marker 原文，光标、选择、删除行为完全正常，整块删除体验通过样式即可接受）。
- 预览态 = flutter_markdown 渲染真 chip。
- 不引入 flutter_quill 等富文本框架：marker 是纯文本行内对象，纯文本方案无序列化双写风险，成本最低。
- **legacy plain 笔记**：marker 语法仍可用，但 plain 渲染下显示原文。交互定稿：在 plain 笔记上添加锚点时弹出「转为 Markdown」一次性确认，转换后 `content_format='markdown'`（纯文本是 markdown 合法子集，无损）。

### 1.4 content_hash 与 marker 剥离（定稿）

规则：**任何参与去重/哈希的文本必须先剥离 marker**。

- 新增工具函数 `stripAnchorMarkers(String)`（`mobile/lib/services/` 内，建议放 `anchor_service.dart` 同文件导出），实现为正则替换为空串，**不做**空白折叠（剥离后留下的空白差异同样参与哈希，与原采集文本不一致的风险由调用点控制——见下）。
- 调用点审计与改造：
  1. `computeContentHash`（通知采集入库去重）：入参先 strip。采集来的原文本不含 marker，此改动是防御性的；
  2. 消息编辑保存路径（v7 起的 edited_at 流程）与锚点插入/移除路径：**保存时重算并更新 `content_hash`**（对 strip 后文本），保证「同一通知再次送达」与库内已编辑消息仍判重一致；
  3. 手动添加消息（add_message_page）：同样先 strip。
- 测试点：含 marker 消息与原始通知文本哈希一致；连续插入/移除锚点后哈希不变。

### 1.5 消息受限写入与任务删除的残迹化

- 锚点服务是消息正文的唯一写入方之一（另一是现有编辑入口）：插入 = `anchorText` 首次出现处之后插入 `⟦task:id⟧`；移除 = 删除 marker 串。两者都写 `edited_at`。
- `anchorText` 定位失败（不存在）→ 提案执行置 `failed`；多处出现 → 取第一处并在执行结果中注明（AI 可在下一轮修正）。
- 删除任务（级联删 `task_anchors` 行）时同步残迹化：把该任务所有 marker 替换为锚点 label 纯文本（如 `[任务:买菜]`），内容不留空洞、不留死 id。实现：`AnchorService.residualizeForTask(taskId)` 在删除事务内执行。

---

## 2. 工具调用协议细化（原子提案链路）

### 2.1 输出块语法（定稿）

模型在回复中内嵌围栏块，一块一个原子调用：

````
```tool
{"tool":"task.create","args":{"title":"买菜","startAt":"2026-10-29T18:00"}}
```
````

- 围栏语言标识固定为 `tool`；块内为单个 JSON 对象，字段仅 `tool` / `args`。
- 助手可见文本与 tool 块可任意交错；一个回合允许多个块。
- 容错解析（沿用 evaluate.ts 经验）：容忍 ```json 误标、前后多余空白、尾随逗号修复不做（解析失败即丢弃该块并在对话中提示「一个动作未能理解，已跳过」）。

### 2.2 流式解析状态机（mobile `tool_parser.dart`）

状态：`TEXT → FENCE_OPEN(```tool) → IN_BLOCK(累积 JSON) → FENCE_CLOSE → TEXT`。
- TEXT 段增量上屏（`token_delta` 照常）；
- 进入 IN_BLOCK 后暂停该段上屏，块闭合 → 解析 → 校验通过则落一条 `change_proposals` 并发出 `proposal` 事件（对话页内联提案卡片即时出现）；
- 流中断（网络断/用户取消）：未闭合块整体丢弃，已落库的提案保留（它们本来就要人工审批，无危害）。

### 2.3 校验、幂等、权限

- 校验在 `proposal_service.dart`：每个工具一份 Dart 校验器（手工写字段检查，不引入 schema 运行时）；校验失败不落日，回写对话一条 tool 错误消息，AI 可下轮重试。
- 幂等与去重：提案去重键 = `(chat_message_id, block_index)`；流重试/重连重放同回合时按此键跳过已存在提案。审批执行幂等：payload 内目标 id 在执行时二次校验存在性，失败置 `failed`。
- 权限边界在 `proposal_executor.dart` 强制（与校验分离，双保险）：已归档任务拒绝 update/delete；无笔记/文件删除工具可调用；设置/密钥不可达。

### 2.4 提示词说明书

- 单一事实源在 mobile（`lib/services/assistant/tool_spec.dart`：工具名、参数说明、示例、原子化纪律、审批流程说明）。
- desktop `/v1/chat` 不持有说明书，只做透传；说明书由 mobile 组装进 system prompt。双端提示词同步惯例正式终结。

---

## 3. 待确认区 UX 细化

### 3.1 数据补充：`change_proposals` 增加 `batch_id`

一个 AI 回合（一条 assistant chat_message）产出的全部提案共享一个 `batch_id`（= chat_message_id 即可，不另造 uuid）。**回写主文档 §1.4 DDL**：

```sql
  batch_id TEXT,   -- 产出该提案的 assistant 消息 id；同回合提案为一组
```

### 3.2 列表组织与批量操作

- 分组：pending 提案按 batch 分组，组头显示对话标题 + 时间 + 提案计数（如「整理收件箱 · 12 项」）；组可折叠。
- 组内每条 = 原子卡片：工具图标 + 摘要 + 关键 diff（任务类显示标题/时间/优先级；note.replace_section 显示前后片段；anchor.create 显示目标摘录）。
- 操作：单条通过/拒绝；组头「全选/清空」；底部固定操作条「通过所选（n）/ 拒绝所选」。选择态仅存内存，不落库。
- 过滤：按工具类型 chip 过滤（任务/笔记/锚点/消息标记）。
- 历史：已审批（applied/rejected/failed）收进「历史」折叠区，applied 的带撤销入口。

### 3.3 审批纪律的默认选择策略

「全量人工审批」原则不变——任何提案都必须由人点「通过」才执行。允许的效率优化仅限**默认勾选**：
- `inbox.triage` 批次中的 `message.set_priority(junk)` 提案默认勾选；
- 其余一律默认不勾选。
即「默认勾选 + 人工一键通过」不违反审批原则，写入动作仍由人触发。

---

## 4. `inbox.triage` 工具细化（批处理管线重生）

- 定性：**提案生成器**。它是只读的（对应用数据无写入），因此 AI 调用后**无需审批即自动执行**；它的产出全部是一组原子提案，进待确认区。
- 参数：`{scope: {status:'pending', limit: 50}}`（首版只支持按消息状态 + 条数；上限 50，超出报错让 AI 分批）。
- 执行流程（mobile `tools/inbox_triage.dart`）：
  1. 取范围内消息 → `junk_rules.dart` 本地预过滤（命中垃圾规则的直接产出一个 `message.set_priority(junk)` 提案，不调模型，省 token）；
  2. 其余消息按 10 条/批（沿用 EVAL_BATCH_SIZE 经验值）组装子请求，走当前对话绑定的模型配置发 **独立子调用**（复用 AiClient 通道，system prompt 用迁移过来的原批量评估提示词，输出 schema 沿用「按 messageId 对应的 JSON 数组」）；
  3. 解析结果 → 逐条映射为提案：消息优先级 → `message.set_priority`；任务草稿 → `task.create`；
  4. 全部提案落 `change_proposals`（同一 batch_id），在对话中汇总「产生 n 条提案，请到待确认区审批」。
- 新增配套原子写工具 `message.set_priority`（一条消息一个提案），纳入主文档 §5.2 工具表。
- 子调用的 token 流不上屏（属后台执行），仅最终汇总上屏。

---

## 5. 存档格式定稿（v3 唯一格式，过渡版本与 v3 共用）

### 5.1 结构与字段

```
archive.zip
├── manifest.json
├── tasks.json
├── messages.json
├── anchors.json
└── library/
    ├── notebooks.json
    ├── files.json
    ├── notes/<noteId>.md
    └── files/<fileId>__<safeName>
```

- `manifest.json`：`{format:"msgrepo-archive", version:1, exportedAt:<epochMs>, appVersion:"x.y.z", counts:{tasks,messages,notes,files,anchors}}`。
- `tasks.json`：数组，字段与 DB 列同名 snake_case（含 `parent_id`；不导出 `status='archived'` 之外做任何过滤——全量导出含归档）。
- `messages.json`：同上（正文含 marker 原文；`content_hash` 导出但导入时按 §1.4 规则重算，不信任导出值）。
- `anchors.json`：`task_anchors` 全量。
- `library/notebooks.json`：`{notebooks:[...], chapters:[...]}`。
- `library/notes/<noteId>.md`：YAML front matter + 正文（正文即 markdown 原文，含 marker 与 `file://` 引用）：
  ```yaml
  ---
  id: <noteId>
  title: ...
  chapter_id: ...
  content_format: markdown
  created_at: 1699999999999
  updated_at: 1699999999999
  attachments: [<fileId>, ...]
  ---
  ```
- `library/files.json`：`[{id,name,mime_type,size,path,source,created_at}]`，`path` 为 zip 内相对路径 `library/files/<fileId>__<safeName>`（safeName 做文件名净化，id 前缀保证唯一，彻底解决重名冲突）。

### 5.2 导出流程（v3，基于 DB v8）

> v3.2 起过渡版本取消：不再存在「v2 导出 → v3 导入」桥梁，导出服务直接读 v8 结构。曾在 v2 代码上实现的导出（含 `message_task_links`/`linked_task_id` → 锚点的转换步骤）作废，zip 组装与设置页入口代码保留复用。

1. 事务快照读全量表（tasks / messages / task_anchors / notebooks / chapters / notes / files）；
2. 锚点直接读 `task_anchors` 写 anchors.json（正文中的 marker 天然随正文导出，无需转换步骤）；
3. 附件与文件区经 `attachment_store` 复制进 zip；
4. 写 manifest（counts 实测填充）；
5. 落盘到用户选择目录（首版：应用文档目录 + 路径展示；分享面板留作后续增强）。

### 5.3 导入流程（v3）

1. 解压 → 校验 `manifest.format/version`（不支持即拒绝并明示）；
2. **空库守卫**：库非空则拒绝导入并提示（首版不做合并）；
3. 单事务入库：notebooks/chapters → notes（front matter 解析）→ files（复制进 attachment_store，重写 notes 正文无需改动——`file://id` 引用按 id 保持有效）→ tasks（保持原 id，parent_id 引用随之有效）→ messages（按 §1.4 重算 content_hash）→ anchors；
4. 一致性校验：anchors 的 marker 必须在对应正文中存在；缺失的记入警告列表，导入完成后向用户展示（不阻断）；
5. **id 策略：全量保留原 id**。空库导入无冲突，且 marker/task 引用零改写，是「新版本不兼容旧存档、旧版本按新格式导出」策略成立的关键。

---

## 6. 测试计划（新增/改造清单）

新增（mobile/test/）：
- `anchor_syntax_test.dart`：marker 正则、strip、代码区内不解析、plain→markdown 转换入口；
- `anchor_service_test.dart`：插入/移除/残迹化、定位失败、多处出现取第一处；
- `content_hash_marker_test.dart`：§1.4 全部测试点；
- `tool_parser_test.dart`：围栏状态机、容错、流中断丢弃、去重键；
- `proposal_flow_test.dart`：校验→落库→审批→执行→回注对话→撤销 全链路；权限边界（归档任务拒绝）；
- `approvals_grouping_test.dart`：batch 分组、全选、默认勾选策略；
- `inbox_triage_test.dart`：预过滤跳过模型、分批、提案映射、上限报错；
- `archive_roundtrip_test.dart`：导出→导入往返一致；marker 一致性警告；非空库拒绝；
- `db_v8_migration_test.dart`：links/linked_task_id → 锚点迁移。

改造：`message_task_links_test`、`message_tile_multi_link_test`（改锚点语义）；`endpoint_config_test`（设置页→助理页迁移）；`manifest_receivers_test`（移除 READ_SMS）。

删除：`import_parse_test`、`import_isolate_test`、`ai_processing_test`、`auto_process_test`、`ai_panel_header_test`、`ai_discard_test`、`ai_health_noise_test`、`confirm_task_count_test*`、`auto_confirm_scope_test`（随批处理管线删除；其中有通用价值的用例迁入 `inbox_triage_test`）。

desktop（desktop/src 下）：删 `pipeline.test.ts`、`ai/multidraft.test.ts`、`ai/prompt-vocabulary.test.ts`；新增 `models` 配置加载与 `/v1/models`、`/v1/chat` 路由测试。

---

## 7. 对主文档 design-v3.md 的回写

- §1.4 `change_proposals` DDL 增加 `batch_id`（本文件 §3.1）——已回写；
- §5.2 工具表增加 `message.set_priority`——已回写；
- §9 开放问题改为「已细化问题索引」，逐项指向本文档章节；保留的风险项：本地模型输出可靠性（§2 容错+审批兜底即最终答案）、编辑态 chip（§1.3 定稿）。
