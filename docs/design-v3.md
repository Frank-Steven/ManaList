# MsgRepo v3 修改方案（库 · 任务 · 助理）

> 状态：草案 v3.2（2026-10-28）
> 前置：本文档基于现行 v2 设计（`docs/design-v2.md`，修订至 v2.7）与实际代码（DB v7）。
> 本文档定义 v3 的目标架构、修改点、重构点与实施计划。v3 落地后，`design-v2.md` 标注 superseded。
> v3.1 修订：锚点改为内容内联对象（弃用偏移定位）；AI 动作全部原子化并进入待确认区人工审批；批处理管线废弃、作为助理工具重生；Ollama 暂缓；QQ/微信解析器彻底移除；存档导入/导出与全新安装策略。
> v3.2 修订：**取消过渡版本**——确认无需过渡，所有用户直接全新安装 v3；存档导入/导出保留为 v3 的备份能力，但不再承担旧版迁移桥梁（§7 重写）。
> v3.3 命名定稿（2026-11-01）：手机端应用定名 **ManaList**，桌面网关定名 **LinkModel**（正文与历史提交中的 AndroidLocAI 即 LinkModel，MsgRepo 为仓库旧名）。UI 结构以 `docs/ui-structure.md` 为准。

---

## 0. 背景与目标

v2 确立了「日程+待办是应用本体，消息是数据源，AI 是可插拔服务」的架构。v3 在此基础上做四件事：

1. **信息载体统一**：消息、笔记、文件统一为「库」（Library），都是 AI 创建/维护任务的依据；消息不再与任务一一对应。消息页的导入功能（微信/QQ/短信）**整体移除**——QQ/微信官方无导出功能，解析器价值低，彻底删除；用户自行上传内容（含截图）一律进入笔记/文件。
2. **关联模型升级**：引入「任务锚点」（TaskAnchor）。锚点是**直接插入笔记或消息正文中的行内对象**（markdown 新增行内语法），不使用偏移定位；一个锚点连接一个任务，一个任务可被多个锚点连接，双向可跳转。
3. **AI 交互升级**：从「批处理评估管线」升级为**统一助理驱动**。对话可分管理（类 Agent 模式），库中的笔记/消息/文件可作为附件；AI 通过**原子化工具**操作应用，**所有 AI 动作一律生成原子变更提案、进入待确认区，由人工逐条审批**后生效。v2 的消息批处理评估管线废弃，其能力（批量筛选/草拟任务）改造为助理可调用的一项工具。
4. **电脑端改名 AndroidLocAI**，定位为本地 AI 统一接口（AI 网关），增加模型列表与模型配置。

### 0.1 设计原则（v3 新增硬约束）

- **原子化**：AI 的每个工具调用只表达一个最小变更（建一个任务、改一个字段、插一个锚点……），禁止复合操作。复合意图由 AI 拆成多个提案。
- **全量审批**：AI 不产生任何静默写入。所有工具调用的结果先落「待确认区」，用户逐条查看 diff/摘要，勾选后统一通过（也可单条通过/拒绝）。只读工具（查询、检索）除外。
- **干净迁移**：不做旧版本应用内数据迁移、不做 desktop 数据目录迁移，不发布过渡版本。所有用户直接全新安装 v3（v3.2 起确认）。存档导入/导出保留为 v3 自身的备份能力（§7），但不承担旧版数据的迁移桥梁。

### 0.2 新信息架构

```
┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐
│     库       │  │     任务     │  │        助理          │
│ ├─ 笔记      │  │ （待办+日程  │  │ ├─ 对话列表          │
│ ├─ 消息      │◄─┤  合并，时间  │◄─┤ ├─ 对话页            │
│ └─ 文件      │  │  时间尺度    │  │ ├─ 附件选择          │
└──────────────┘  │  派生视图）  │  │ ├─ 待确认区（审批）  │
        ▲         └──────────────┘  │ └─ 模型选择          │
        └── 任务锚点（行内对象，     └──────────┬───────────┘
            双向跳转）                         │ 原子工具 → 变更提案
                                      ┌────────┴────────┐
                                      │  AndroidLocAI   │ 电脑端 AI 网关
                                      │ （模型列表+配置）│ 127.0.0.1:8765
                                      └─────────────────┘
```

底部主 Tab 由 v2 的「消息 / 待办 / 日程 / 笔记 + 设置」改为三主 Tab + 设置：

| v2 | v3 |
|---|---|
| 消息、笔记 | **库**（内分：笔记 / 消息 / 文件 三个分区） |
| 待办、日程 | **任务**（单页，时间尺度视图切换） |
| —（新增） | **助理**（对话管理 + 待确认区 + 模型配置入口） |
| 设置 | 设置（移除 AI 接口配置段，移入助理） |

---

## 1. 数据模型变更（DB v7 → v8）

权威数据仍在手机端 SQLite（`mobile/lib/services/database.dart`），模型定义在 `mobile/lib/models/`。v8 一次性完成以下迁移（应用内迁移仅服务开发期与测试；正式用户走全新安装 + 存档导入，见 §7）。

### 1.1 新增表 `task_anchors`（任务锚点，核心新增）

```sql
CREATE TABLE task_anchors(
  id TEXT PRIMARY KEY,               -- uuid，与正文中的行内 marker id 一致
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  target_type TEXT NOT NULL,         -- 'message' | 'note' | 'file'
  target_id TEXT NOT NULL,           -- 对应 messages.id / notes.id / files.id
  label TEXT,                        -- 锚点显示名（缺省取任务标题快照）
  created_by TEXT NOT NULL,          -- 'user' | 'ai'
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_anchors_task ON task_anchors(task_id);
CREATE INDEX idx_anchors_target ON task_anchors(target_type, target_id);
```

**锚点 = 正文中的行内对象**。锚点 marker 作为文本直接插入笔记/消息内容，语法为新增 markdown 行内对象：

```
⟦task:<anchorId>⟧          （渲染为可点击 chip，显示任务标题）
```

- 不再使用任何偏移/locator 定位：marker 就在正文里，位置即语义；编辑导致的位置变化天然正确，不存在偏移漂移问题。
- 约束：一个锚点恰好连接一个任务（`task_id` 单值非空）；一个任务可被多个锚点引用（无上限）。删除任务级联删锚点行，同时把各正文中的 marker 替换为纯文本残迹（保留 label 文本，避免内容空洞）。
- 删除消息/笔记/文件时其锚点行级联删除（应用层 + 外键）。
- **消息正文的可写性变化**：v2 消息正文原则上只读（v7 起可编辑，有 `edited_at`）。v3 明确：消息正文允许**仅插入/移除锚点 marker** 的受限编辑（由锚点服务执行，走 `edited_at` 留痕），用户自由编辑消息正文的入口维持现状。
- **文件锚点**：文件是二进制，无法内联。文件锚点不插入内容，仅落 `task_anchors`（target_type='file'），语义为「整个文件关联此任务」，在文件详情与任务详情双向展示。
- 双向关联的落地：
  - 任务详情页 → 查 `task_id = ?` 锚点列表 → 点击跳转来源（消息详情/笔记编辑器/文件详情）并高亮对应 chip；
  - 笔记/消息渲染时 → flutter_markdown 自定义 InlineSyntax 把 `⟦task:id⟧` 渲染为 chip → 点击跳任务详情；
  - 消息/文件详情页 → 查 `target_type,target_id` 锚点列表展示与跳转。

### 1.2 既有表改造

**messages**
- 废弃字段 `linked_task_id`（v2 遗留 1:1 关联），v8 迁移时转为正文末尾追加一条锚点 marker + `task_anchors` 行。
- 废弃关联表 `message_task_links`（v6 引入）：逐行迁移为锚点（marker 追加到正文末尾，`created_by='user'`），迁移完成后 DROP TABLE。
- `capture_type='import'` 不再产生新值；`import_source` 字段保留只读（历史数据展示）。

**notes（笔记多模态 + markdown 化）**
- `content_format` 默认值从 `plain` 改为 `markdown`；现有 plain 笔记迁移时原样保留标记 `plain`（按纯文本渲染），新建笔记一律 markdown。
- 新增 `notes.attachments`（JSON 数组，引用 `files.id`），支撑多模态（图片/截图/任意文件挂在笔记下，经「文件区」统一管理）。正文中 `![alt](file://<fileId>)` 解析到本地附件存储（复用 `attachment_store.dart`）。截图创建笔记的场景由此覆盖：拍照/相册选图 → 新建笔记并插入图片。

**tasks**
- 表结构不变（v2 已完成待办/日程统一为 tasks，时间尺度由 `deriveTimeScale` 纯函数派生）。v3 的变化在 UI 合并（§4）与 AI 写权限（§5.3）。

### 1.3 新增表 `files`（库·文件区）

```sql
CREATE TABLE files(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  mime_type TEXT,
  size INTEGER,
  local_path TEXT NOT NULL,          -- attachment_store 管理的沙盒路径
  source TEXT NOT NULL,              -- 'user_upload' | 'ai_generated' | 'note_export'
  created_at INTEGER NOT NULL
);
```

文件区能力：导入（复用已有 `file_picker`；截图/照片走 `image_picker`）、重命名、删除、系统分享/打开、作为助理附件、被笔记/锚点引用。删除文件前检查引用（笔记 attachments、task_anchors），有引用时提示。

### 1.4 新增表 `conversations` / `chat_messages` / `change_proposals`（助理）

```sql
CREATE TABLE conversations(
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,               -- 首条用户消息截断生成，可改名
  model_config_id TEXT,              -- 该对话使用的模型配置（可后改）
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE chat_messages(
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  role TEXT NOT NULL,                -- 'user' | 'assistant' | 'tool'
  content TEXT NOT NULL,
  attachments TEXT,                  -- JSON: [{type:'note'|'message'|'file', id}]
  status TEXT NOT NULL,              -- 'streaming' | 'done' | 'error'
  created_at INTEGER NOT NULL
);
-- 待确认区：AI 动作的落点。所有写工具调用在此各落一行原子提案
CREATE TABLE change_proposals(
  id TEXT PRIMARY KEY,
  conversation_id TEXT REFERENCES conversations(id) ON DELETE SET NULL,
  batch_id TEXT,                     -- 产出该提案的 assistant 消息 id；同回合提案为一组（详见 design-v3-details §3.1）
  tool TEXT NOT NULL,                -- 工具名，如 'task.create'
  summary TEXT NOT NULL,             -- 人类可读摘要（列表展示用）
  payload TEXT NOT NULL,             -- JSON，原子变更的完整参数（审批通过后据此执行）
  status TEXT NOT NULL,              -- 'pending' | 'approved' | 'rejected' | 'applied' | 'failed'
  created_at INTEGER NOT NULL,
  resolved_at INTEGER
);
CREATE INDEX idx_proposals_status ON change_proposals(status);
```

- 提案与对话松耦合：删除对话不强制删提案（`SET NULL`），待确认区可独立存在。
- 审批通过 → 执行 payload → 置 `applied`（失败置 `failed` 并留错误）；执行结果回注原对话为 tool 消息，保持上下文连贯。
- 复用现有撤销队列：applied 的变更进入撤销队列，提供事后反悔通道。

### 1.5 v8 迁移清单（database.dart 升级到 version 8）

1. `CREATE TABLE task_anchors / files / conversations / chat_messages / change_proposals`；
2. `message_task_links` 与 `messages.linked_task_id` → 锚点（正文末尾追加 marker）；随后 DROP `message_task_links`；
3. `notes` 加列 `attachments TEXT`；
4. 迁移测试：`mobile/test/` 新增 `db_v8_migration_test.dart`（内存 SQLite 走 `sqflite_common_ffi`，沿用现有测试基建）。

### 1.6 v9 增量（2026-11-01，UI 批次落地）

- `files` 加列 `folder TEXT NOT NULL DEFAULT ''`：路径式虚拟文件夹（`/` 分段，`''` 为根目录），无独立文件夹表；
- `conversations` 加列 `draft_attachments TEXT NOT NULL DEFAULT '[]'`：对话草稿附件（JSON 数组 `[{type,id}]`），库内「发送给助理」与对话页附件 bar 的唯一事实源；
- 迁移测试：`mobile/test/db_v9_migration_test.dart`。

---

## 2. shared/ 契约更新

shared/schemas 仍是双端协议事实源，v3 更新如下（同步更新 `desktop/src/types.ts` 镜像类型）：

| 文件 | 动作 |
|---|---|
| `raw-message.schema.json` | captureType 中 `import` 标注 deprecated（不再产生新值） |
| `task-anchor.schema.json` | **新增**：锚点实体 schema（对齐 §1.1，含 marker 语法约定） |
| `chat-request.schema.json` | **新增**：`{conversationId, messages[], attachments[{type,id,content}], modelConfigId, stream}` |
| `chat-response.schema.json` | **新增**：SSE/NDJSON 事件流：`token_delta / proposal / done / error`。`proposal` 事件承载 AI 输出的原子工具调用（desktop 只透传不执行） |
| `model-config.schema.json` | **新增**：`{id, name, provider(openai-compat/mock), baseUrl, model, apiKeyEnv?}` |
| `sync-request/response.schema.json`、process 相关 | 标注 superseded：`/v1/process` 批处理协议随管线废弃（见 §6.3） |
| `registry/default.json` | 保留归档（分类注册表随批处理管线退出主流程，不再主动演进） |

---

## 3. mobile 端修改点

### 3.1 底部导航与页面重组（`mobile/lib/main.dart`）

- Tab 改为 **库 / 任务 / 助理**（+ 设置入口）。
- 新增 `lib/ui/library/library_page.dart`：顶部三分区切换「笔记 / 消息 / 文件」：
  - 笔记分区：迁移现有 `lib/ui/notes/`（notes_page / chapters_page / note_editor_page）；
  - 消息分区：迁移现有 `lib/ui/messages/`（messages_page / archived_page / message_detail_sheet 等），移除导入入口与 AI 面板入口（批处理管线废弃，见 §3.6）；
  - 文件分区：新增 `lib/ui/library/files_page.dart`（列表 + 导入 + 预览/分享 + 引用检查删除）。
- 新增 `lib/ui/tasks/tasks_page.dart`：合并 `lib/ui/todos/todos_page.dart` 与 `lib/ui/schedule/schedule_page.dart`（日程四粒度视图组件作为任务页视图模式保留复用）。
- 新增 `lib/ui/assistant/`：对话列表 `conversations_page.dart`、对话页 `chat_page.dart`、附件选择器 `attachment_picker.dart`、待确认区 `approvals_page.dart`、模型选择 `model_picker.dart`。

### 3.2 移除消息导入（微信/QQ/短信）——含解析器彻底删除

- 删除 UI：`lib/ui/messages/import_page.dart` 及消息页导入图标入口。
- 删除服务：`lib/services/import_service.dart` **整体删除**（QQ「消息管理器」导出文本解析器、微信两段式解析器一并删除，不保留、不改造——QQ/微信官方无导出能力，解析器没有可靠输入来源；用户场景改为截图/拍照 → 新建笔记）。
- 删除桥接：`notification_bridge.dart` 中 `readSmsMessages` 及 Kotlin 侧短信读取代码；移除 `READ_SMS` 权限声明；更新 `manifest_receivers_test`。
- 删除测试：`import_parse_test.dart`、`import_isolate_test.dart`；`message_batch_insert_test.dart` 保留（批量入库逻辑通知采集仍在用）。

### 3.3 笔记 markdown 化与多模态

- 渲染器选型确定：**flutter_markdown**（其底层 `markdown` 包支持注册自定义 `InlineSyntax`，用于锚点 marker 与 `file://` 图片解析；新增依赖需走正常 pubspec 引入）。
- `note_editor_page.dart` 改造为 markdown 编辑器（编辑/预览切换）。
- 笔记内插入附件/截图：文件选择器或 image_picker → 入 `files` 表 → 正文插入 `![name](file://id)`。
- 锚点交互：编辑/阅读模式选中文本（或光标处）→ 「添加任务锚点」→ 选已有任务或新建任务 → 正文插入 `⟦task:<id>⟧` + 写 `task_anchors`。

### 3.4 消息/任务详情双向跳转

- `message_detail_sheet.dart`：正文渲染锚点 chip（消息正文使用同一 markdown 渲染管线，只读模式）；长按选段「添加锚点」（受限编辑，§1.1）。
- `task_detail_panel.dart` / `task_tile.dart`：显示来源锚点列表（图标区分 message/note/file），点击反向跳转并高亮对应 chip。
- 改造测试：`message_task_links_test.dart`、`message_tile_multi_link_test.dart` 改写为锚点语义。

### 3.5 设置页清理

`lib/ui/settings_page.dart`：移除「AI 接口配置 / 配对 / 端点管理」整段 → 迁入助理页（§5.5）。保留：应用筛选、主题、提醒、**存档导入/导出（§7）**、关于。`endpoint_config_test.dart` 随之迁移更新。

### 3.6 AI 客户端重构（`lib/services/ai_client.dart` 等）

- `AiClient` 重构为助理客户端：组装对话请求（历史 + 附件正文 + 原子工具说明书）→ 优先走电脑端 AndroidLocAI 的 `POST /v1/chat`（SSE），离线走当前对话绑定的远程模型配置。
- **废弃并删除批处理管线相关**：`lib/services/ai_processing.dart`、`auto_process.dart`、`lib/ui/messages/ai_panel.dart` 及配套测试（`ai_processing_test`、`auto_process_test`、`ai_panel_header_test`、`ai_discard_test`、`ai_health_noise_test`、`confirm_task_count_test*`、`auto_confirm_scope_test` 等按影响面逐个评估删除或改写）。消息分区的 AI 面板入口移除。
- 批处理能力以工具形式保留（§5.4 `inbox.triage`）：其实现代码（提示词构建、结果解析）从 ai_processing 迁移收敛到 `lib/services/assistant/tools/` 内部。
- `junk_rules.dart` 保留为 `inbox.triage` 工具的本地预过滤组件。
- 附件内容内联：附件（笔记/消息正文、文件文本抽取）在请求前展开为上下文块，带 `[#note:标题]` 类引用头，供 AI 引用定位。

---

## 4. 「任务」合并（待办+日程）

数据层 v2 已统一（tasks 表 + `deriveTimeScale`），v3 只动 UI/导航层：

- 单页 `tasks_page.dart`：顶部视图切换「列表（待办语义）/ 日 / 月 / 年」，数据同源 tasks，按时间尺度过滤；
- 现有日程视图组件（`lib/ui/schedule/` 下 day/month/year/yearly_view + layout）整体迁入 `lib/ui/tasks/views/`，`schedule_page.dart` 废弃；
- `todos_page.dart` 废弃，待办列表逻辑并入任务页列表视图；共享组件 `lib/ui/tasks/task_tile/task_editor/task_detail_panel` 不变；
- 提醒服务（`reminder_service.dart`）不受影响；
- 测试：`task_scale_test`、`schedule_layout_test`、`month_view_test`、`year_view_test` 等跟随目录迁移更新 import，断言逻辑不变。

---

## 5. 「助理」设计（核心新增）

### 5.1 形态

- 对话管理：`conversations_page.dart` 对话列表（新建/改名/删除），类 Agent 模式——每个对话独立上下文、独立模型配置。
- 对话页 `chat_page.dart`：流式渲染、附件 chip、AI 回复中的工具调用以「提案卡片」内联展示（摘要 + 「前往待确认区」）。
- **待确认区 `approvals_page.dart`**（助理页一级入口，也可从对话页跳入）：
  - 列表展示所有 `pending` 提案，按时间/对话分组；
  - 每条提案为**原子变更卡片**：摘要 + 关键 diff（如任务标题、时间、目标笔记片段）；
  - 交互：逐条「通过 / 拒绝」，支持多选后批量通过；通过后立即执行并落撤销队列；
  - 空态、执行失败（`failed`）重试入口。
- 附件选择器：从库中勾选笔记/消息/文件（多选），请求时展开正文。

### 5.2 原子工具协议

本地小模型 function-calling 能力参差，沿用项目「提示词两端逐字一致 + 容错解析」的惯例：定义**结构化工具调用块**（模型输出中内嵌的 JSON 指令，客户端解析）。v3.1 起工具设计遵守两条硬约束：

1. **原子操作**：一个工具调用 = 一个最小变更。没有批量/复合工具；AI 要做多件事就输出多个调用块，每个生成一条独立提案。
2. **全部审批**：写工具的产出**永远不直接执行**，统一落 `change_proposals`（pending），由人工在待确认区逐条/勾选审批后执行。只读工具直接执行并把结果回注对话。

首版工具清单：

| 工具 | 类型 | 说明 |
|---|---|---|
| `task.create` | 写 | 新建一个任务（标题/描述/时间/优先级/父任务） |
| `task.update` | 写 | 修改一个**未归档**任务的一个或多个字段（单任务粒度） |
| `task.delete` | 写 | 删除一个未归档任务 |
| `task.list` / `task.search` | 只读 | 查询任务 |
| `note.create` | 写 | 新建一篇笔记（markdown） |
| `note.append` | 写 | 向一篇笔记末尾追加内容 |
| `note.replace_section` | 写 | 替换一篇笔记中由锚点/标题界定的区段（避免全文覆盖） |
| `note.read` | 只读 | 读取笔记 |
| `anchor.create` | 写 | 在一个目标（笔记/消息指定文本处、或整文件）创建一个锚点并连到一个任务 |
| `anchor.remove` | 写 | 移除一个锚点（正文中 marker 一并清除） |
| `library.search` | 只读 | 检索库（笔记/消息/文件标题与正文） |
| `message.set_priority` | 写 | 标记一条消息的优先级（原子，一条消息一个提案） |
| `inbox.triage` | 提案生成器（只读执行） | 对指定范围消息执行批量优先级评估与任务草拟；**产出不是写入，而是一组原子提案**（每条消息的优先级标为一个 `message.set_priority` 提案、每个任务草稿为一个 `task.create` 提案），全部进待确认区；执行流程细化见 design-v3-details §4 |

权限边界（执行层强制）：**AI 不可修改/删除已归档任务**；首版不提供笔记/文件的删除工具；不可触碰配对/密钥/设置。

### 5.3 锚点的 AI 创建

- 笔记/消息：AI 输出 `anchor.create {targetType, targetId, anchorText, taskRef}` → 生成提案；审批通过后客户端在正文定位 `anchorText` 首次出现处，在其后插入 `⟦task:<id>⟧` marker + 写表。定位失败（文本不存在）→ 执行失败置 `failed`，用户在待确认区可看到原因。
- 文件：`anchor.create {targetType:'file', targetId, taskRef}` → 只写表，不动内容。

### 5.4 执行流

`lib/services/assistant/`（新增）：
- `tool_parser.dart`：从模型流式输出中解析工具调用块（容错：markdown 围栏、多余空白，沿用 evaluate.ts 经验）；
- `proposal_service.dart`：调用块 → 校验（目标存在性、权限边界）→ 落 `change_proposals`；
- `proposal_executor.dart`：审批通过 → 执行 → 结果回注对话 + 撤销队列；
- 流式事件：`token_delta / proposal / done / error`（`proposal` 事件即一条待确认提案的落库通知）。

### 5.5 模型配置入口迁移

- 助理页顶栏「模型」按钮 → `model_picker.dart`：列出可用模型配置（电脑端 AndroidLocAI 经 `GET /v1/models` 上报的模型列表 + 手机端本地保存的远程端点配置），可新建/编辑/删除远程配置（即从设置页平移现有 `AiEndpoint` CRUD，电脑端条目仍自动置顶）。
- 每对话绑定一个模型配置（`conversations.model_config_id`），可随时切换。

---

## 6. desktop 端改造（AndroidLocAI）

代码位置：`desktop/`（Electron 托盘 + `127.0.0.1:8765` HTTP 服务）。

### 6.1 改名 AndroidLocAI（干净迁移，不做数据目录迁移）

- `package.json`：`name/productName` 改 `AndroidLocAI`；electron-builder 产出物名同步。
- 托盘：`electron-main.ts` 标题/菜单/通知文案改名；`scripts/make-icons.mjs` 重生成图标（如需新设计则替换 assets）。
- 数据目录直接使用 `~/Library/Application Support/AndroidLocAI/`，**不做旧 `MsgRepo` 目录迁移**——与手机端策略一致：用户全新安装，重新配对（`POST /v1/pair` 自动配对流程不变，成本仅一次 USB 连接）。
- 清理死链：托盘「打开仪表盘 `/dashboard`」（electron-main.ts:261、connect.ts:85）与 `package.json` 的 `demo` 脚本删除；`README.md` 重写。
- v1 遗留数据文件（`data/items.jsonl`、`hashes.json`、`hash_items.json`）从仓库清除。

### 6.2 模型列表 + 模型配置（config schema 变更）

`config/default.json` 从单模型改为：

```json
{
  "models": [
    {"id": "local-gemma", "name": "Gemma 4 26B (本地)", "provider": "openai-compat",
     "baseUrl": "http://127.0.0.1:8080/v1", "model": "gemma-4-26b-a4b-it"}
  ],
  "defaultModelId": "local-gemma"
}
```

- 配置加载（`config.ts`）改为读取 `models[]`；旧平铺配置不做自动改写（干净迁移策略，用户新装后手工配置一次即可，default.json 自带可用默认）。
- 新端点：`GET /v1/models`（模型列表 + 各模型连通性探测结果，供手机助理页拉取展示）；`POST /v1/models/reload`（重载配置）。
- 每个模型独立 health 探测缓存（`electron-main.ts` `checkAiBackend` 改为遍历 models）。
- **Ollama 暂缓**：无调试设施，v3 不投入。`ollama.ts` provider 代码保留但不出现在默认配置与文档中，标记 experimental；schema 的 provider 枚举暂只列 `openai-compat` / `mock`。

### 6.3 统一 AI 接口（批处理管线废弃）

- 新增 `POST /v1/chat`：接收手机端助理请求（含工具说明书与附件展开内容），按请求指定 `modelConfigId`（缺省 default）路由到对应 provider，SSE 透传 token 流；**不解析、不执行工具**（提案生成与执行都在手机端），只做提示词注入（与手机端逐字一致，沿用双端提示词同步惯例）与协议透传。
- **删除 `POST /v1/process`** 与配套：`pipeline.ts`、`ai/evaluate.ts`、`ai/junk-rules.ts`、`ai/multidraft.test.ts`、`ai/prompt-vocabulary.test.ts` 等。批处理能力按 §5.2 在手机端以 `inbox.triage` 工具重生（手机端离线远程通道同样需要该能力，放手机端更自洽）；双端提示词同步惯例随之下线，工具说明书改为手机端单一事实源。
- 保留 `POST /v1/pair`、`GET /v1/health`；`mock.ts` provider 保留（无模型跑通全链路，测试用）。
- 并发闸 `limit.ts` SerialGate 扩展为按模型分闸（不同本地后端可并行，同一后端仍串行）。
- 手机端离线直连远程 API 的能力保留（与 v2 一致的路由策略），desktop 不是唯一通路。

---

## 7. 存档导入/导出（v3 备份能力）

> v3.2 重写：过渡版本已取消（确认无需过渡，所有用户直接重装）。存档功能保留为 v3 的备份/迁移能力，在阶段 7 基于 DB v8 结构实现；不再存在「旧版本导出 → v3 导入」的桥梁路径。

### 7.1 v3 的导入/导出

- 设置页提供「导出存档 / 导入存档」：导出把 tasks、messages、笔记三级、文件区、`task_anchors` 按 §7.2 格式打成单个 zip；导入校验版本号后整体入库（空库导入；非空库拒绝并提示，首版不做合并）。
- 实现基础：过渡阶段已在 v2 代码上落地 zip 导出服务与设置页入口（`mobile/lib/services/archive_export_service.dart`），阶段 7 将其重写为直接读取 v8 结构（`task_anchors` 直读、notes.attachments、files 表），并补齐导入侧。

### 7.2 存档格式（v3 唯一格式）

```
archive.zip
├── manifest.json        # {format:"msgrepo-archive", version:1, exportedAt, appVersion}
├── tasks.json           # tasks 全量（含 parent_id 子任务关系）
├── messages.json        # messages 全量（正文含锚点 marker 文本）
├── library/
│   ├── notebooks.json   # 笔记本/章节结构
│   ├── notes/*.md       # 每篇笔记一个 markdown 文件，front matter 存元数据
│   └── files/*          # 文件区二进制（笔记附件、用户上传）
└── anchors.json         # task_anchors 全量（id 与正文 marker 对应）
```

要点：锚点随正文（marker 文本）+ anchors.json 双写导出，导入时以 anchors.json 为准校验正文 marker 一致性；附件按独立的 `library/files.json` 索引（定稿见 details §5.1）。格式版本号 `version` 用于后续演进。

---

## 8. 实施阶段（操作手册：`docs/refactor-v3.md`，体例参照 refactor-v2）

| 阶段 | 内容 | 验收 |
|---|---|---|
| 1 | 契约先行：shared/schemas 新增/更新，desktop `types.ts` 同步 | schema 校验测试通过 |
| 2 | DB v8：anchors/files/conversations/chat_messages/change_proposals + links 迁移 | `db_v8_migration_test` 通过 |
| 3 | 库页重组：三分区、文件区 CRUD、移除导入与短信桥接（含权限清理） | 三区可用；导入入口消失 |
| 4 | 任务页合并 + 笔记 markdown 化（flutter_markdown）+ 手动锚点 | 四粒度视图可用；锚点双向跳转通 |
| 5 | desktop AndroidLocAI：改名、模型列表、`/v1/models`、`/v1/chat`、删 `/v1/process` 管线 | 手机可拉模型列表并对话 |
| 6 | 助理页：对话管理 + 附件 + 工具解析 + **待确认区审批流** + 撤销 | AI 提案全量落待确认区，逐条审批生效 |
| 7 | `inbox.triage` 工具化（批能力重生）+ 存档导出重写（v8）与导入 + 设置页清理 | 导出→全新安装→导入完整还原；全量测试绿 |

每阶段配套更新既有测试并补新测试（锚点渲染/跳转、提案审批流、工具解析、模型列表路由、存档往返），沿用 `sqflite_common_ffi` 内存库测试基建。

---

## 9. 风险与开放问题（已细化，详见 `docs/design-v3-details.md`）

以下问题已在细化文档中定稿解决：

| 原问题 | 定稿结论 | 细化文档章节 |
|---|---|---|
| flutter_markdown 自定义行内语法与编辑态展示 | `InlineSyntax` + 编辑态 `AnchorHighlightController` 高亮（纯文本方案，不做 WYSIWYG）；代码区天然豁免 | details §1.2 / §1.3 |
| 消息正文插入 marker 与 content_hash 冲突 | 哈希前一律剥离 marker；编辑/锚点保存时重算更新 content_hash | details §1.4 |
| 待确认区堆积体验 | `batch_id` 分组 + 组内全选 + 工具类型过滤；仅 junk 标记提案默认勾选，通过动作仍须人工触发 | details §3 |
| 存档格式定稿（files 索引、front matter、导入策略） | `library/files.json` 索引 + id 前缀文件名；front matter 字段集定稿；空库守卫 + 全量保留原 id 导入 | details §5 |
| 本地模型输出原子工具块的可靠性 | 容错解析 + 流中断丢弃 + 全量人工审批兜底；错误提案不生效 | details §2 |
| Ollama provider | 暂缓（无调试设施），代码保留标记 experimental，不进默认配置 | §6.2 |

新增测试与既有测试改造/删除清单见 details §6。
