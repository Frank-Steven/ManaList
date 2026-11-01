# MsgRepo v3 重构操作文档

配套 `docs/design-v3.md`（v3.2）与 `docs/design-v3-details.md`（v1.0，机制定稿）执行。每阶段独立可构建、真机验证、单独 git 提交；任一阶段出问题只回滚该阶段（`git revert` 对应提交）。

## 总则

- 每阶段验收：`flutter analyze` 无错误 + `flutter test` 通过 + `flutter build apk --debug` 通过 + 真机过该阶段验证清单 + commit。
- 桌面端改动验收：`npm run build`（tsc）通过 + 既有测试通过 + 协议用 curl 验证。
- 分支策略：直接在 main 上按阶段提交（单人项目）；每阶段提交信息以 `v3-stage-N:` 前缀。
- **迁移策略（与 v2 不同）**：不做任何面向用户的旧版数据迁移，也不发布过渡版本（v3.2 起确认）——所有用户直接全新安装 v3。阶段 2 的 DB v8 迁移只服务开发期与测试。desktop 端同样全新安装（数据目录直接启用 `AndroidLocAI`，重新配对）。存档导入/导出在阶段 7 作为 v3 备份能力落地。
- **顺序约束**：阶段 1 是 2/5 的前置；阶段 2 是 3/4/6 的前置；阶段 3、4 互不依赖可并行；阶段 5 与 3/4 互不依赖可并行；阶段 6 依赖 1/2/5（协议 + 数据 + chat 通道）；阶段 7 最后。
- 每阶段同步维护本文件末尾「进度记录」表。
- 实机安装一律用 `adb install -r` 覆盖安装（保留数据）；**禁用 `flutter install`**（它会先卸载导致数据丢失，已有教训）。

## 阶段 0｜存档导出基础（已完成，过渡版本取消后转为阶段 7 的实现基础）

> 本阶段最初定位为「过渡版本 v2.9」。v3.2 确认无需过渡、用户直接重装后，过渡版本取消；已落地的 zip 导出服务、设置页入口与测试**保留**，作为阶段 7 存档功能（重写为直读 v8 结构 + 补齐导入）的实现基础。

已交付内容：

- `mobile/lib/services/archive_export_service.dart`：事务快照读全量表 → 按 details §5 格式组装 zip（含 v2 时代的 links → 锚点导出转换，该转换逻辑在阶段 7 重写时移除）。
- `mobile/lib/ui/settings_page.dart`：「数据」分区 + 「导出存档」入口（进度/完成统计/路径展示）。
- `mobile/test/archive_export_test.dart`：5 用例全绿；全量 327 测试无回归；新增依赖 `archive: ^4.5.2`。

已知实现决策（阶段 7 重写时沿用或修正）：links 与 linked_task_id 双写按 (message, task) 去重；marker 以空格分隔追加正文末尾；attachments 导出为解码后 JSON；appVersion 硬编码需跟随 pubspec；files.json 的 source/created_at 在 v2 模型下取近似值。

## 阶段 1｜契约先行（shared + desktop 类型）

改动：

- `shared/schemas/`：新增 `task-anchor.schema.json`、`chat-request.schema.json`、`chat-response.schema.json`、`model-config.schema.json`；`raw-message.schema.json` 的 `import` 标 deprecated；`sync-request/response.schema.json` 标 superseded。
- `desktop/src/types.ts`：镜像类型同步（ChatRequest、ChatEvent、ModelConfig、TaskAnchor）。
- `mobile/lib/services/assistant/`：建包骨架，定义与 schema 对齐的 Dart 模型类（本阶段只落类型与解析，不接 UI）。

验证：schema 样例互相校验通过；`npm run build` 通过；mobile 侧模型类单测。

## 阶段 2｜DB v8：锚点 / 文件 / 对话 / 提案

改动：

- `mobile/lib/services/database.dart`：version 8——新建 `task_anchors` / `files` / `conversations` / `chat_messages` / `change_proposals`（含 `batch_id`）；`message_task_links` 与 `linked_task_id` 迁移为锚点（正文末尾追加 marker）后 DROP links 表；`notes` 加列 `attachments`。
- `mobile/lib/models/`：新增 `anchor.dart`（含 marker 正则常量与 `stripAnchorMarkers`）、`file_entry.dart`、`conversation.dart`、`change_proposal.dart`。
- `mobile/lib/services/anchor_service.dart`（新）：插入/移除 marker（消息走受限写入 + `edited_at`）、残迹化（`residualizeForTask`）、按 task/按 target 双向查询、渲染预取缓存。
- `computeContentHash` 全部调用点接入 strip（details §1.4）：采集入库、编辑保存、手动添加。
- 测试：`db_v8_migration_test`、`anchor_service_test`、`anchor_syntax_test`、`content_hash_marker_test`。

验证：DB v7→v8 迁移后旧 links 全部转为锚点且正文 marker 一致；锚点 CRUD 与残迹化正确；含 marker 消息与原通知文本哈希一致。

## 阶段 3｜库页重组：三分区 + 文件区 + 移除导入

改动：

- `mobile/lib/ui/library/library_page.dart`（新）：三分区「笔记 / 消息 / 文件」；`lib/ui/notes/`、`lib/ui/messages/` 迁入其下。
- `mobile/lib/ui/library/files_page.dart`（新）：文件区 CRUD（导入 file_picker/image_picker、重命名、删除前引用检查、系统打开/分享）。
- **移除导入**：删 `ui/messages/import_page.dart`、`services/import_service.dart`（QQ/微信解析器一并删除）、`notification_bridge.dart` 的 `readSmsMessages` 与 Kotlin 侧短信读取代码、AndroidManifest 的 `READ_SMS` 权限。
- 底部导航先临时保持原 5 tab（库页作为消息/笔记的容器替换二者入口），阶段 6 再换三主 Tab，降低单阶段爆炸半径。
- 测试：删 `import_parse_test`、`import_isolate_test`；更新 `manifest_receivers_test`；新增文件区 CRUD 测试。

验证：三分区可用；文件导入/删除/引用检查正确；导入入口与短信权限彻底消失；通知采集不受影响（回归）。

## 阶段 4｜任务页合并 + 笔记 markdown 化 + 手动锚点

改动：

- `mobile/lib/ui/tasks/tasks_page.dart`（新）：列表/日/月/年视图切换；`lib/ui/schedule/` 视图组件迁入 `lib/ui/tasks/views/`；`todos_page.dart`、`schedule_page.dart` 废弃。
- `note_editor_page.dart` 改 markdown 双模式：预览态 flutter_markdown（新增依赖，提交信息注明）+ `TaskAnchorInlineSyntax` + chip builder；编辑态 `AnchorHighlightController`（TextEditingController 覆写 buildTextSpan 高亮 marker）。
- 手动锚点交互：笔记/消息选中文本 →「添加任务锚点」→ 选/建任务 → 插 marker 写表；plain 笔记先弹「转为 Markdown」确认。
- 双向跳转：任务详情显示锚点来源列表；消息/笔记锚点 chip 点击跳任务。
- 笔记附件：插入图片/文件 → 入 `files` 表 → 正文 `![name](file://id)`。
- 测试：`schedule_layout_test` 等随迁移更新 import；新增锚点渲染/跳转 UI 测试。

验证：四粒度视图在任务页可用且提醒回归通过；锚点双向跳转；marker 编辑/预览两态正确；代码块内 marker 样文本不解析。

## 阶段 5｜desktop → AndroidLocAI：改名 + 模型列表 + /v1/chat

改动：

- `desktop/package.json` / `electron-main.ts` / `scripts/make-icons.mjs`：改名 AndroidLocAI（productName、托盘、文案、图标、产出物名）；数据目录 `~/Library/Application Support/AndroidLocAI/`，不做旧目录迁移。
- 清理：删托盘 `/dashboard` 死链入口（electron-main.ts:261、connect.ts:85）、`demo` 脚本、v1 遗留数据文件（items.jsonl 等）。
- `config/default.json` 改 `models[]` + `defaultModelId` 结构；`config.ts` 适配；Ollama 保留代码但标 experimental、不进默认配置。
- `desktop/src/server.ts`：新增 `GET /v1/models`（列表 + 逐模型连通性）、`POST /v1/models/reload`、`POST /v1/chat`（按 modelConfigId 路由 SSE 透传，不解析工具块）；**删除 `POST /v1/process`** 与 `pipeline.ts`、`ai/evaluate.ts`、`ai/junk-rules.ts`。
- `limit.ts`：SerialGate 改按模型分闸；`electron-main.ts` health 探测改遍历 models。
- 测试：删 `pipeline.test.ts`、`ai/multidraft.test.ts`、`ai/prompt-vocabulary.test.ts`；新增模型配置加载与 `/v1/models`、`/v1/chat` 路由测试。

验证：curl `/v1/models` 返回列表与连通性；curl `/v1/chat` SSE 流式（mock provider）；托盘显示新名与逐模型状态；dmg 打包安装一次。

## 阶段 6｜助理：对话管理 + 待确认区 + 原子工具链

改动：

- `mobile/lib/services/assistant/`：`tool_spec.dart`（说明书单一事实源）、`tool_parser.dart`（围栏状态机，details §2.2）、`proposal_service.dart`（校验/落库/去重键）、`proposal_executor.dart`（权限边界/执行/回注对话/撤销队列）。
- `mobile/lib/ui/assistant/`：`conversations_page.dart`（对话列表）、`chat_page.dart`（流式 + 附件 chip + 提案卡片）、`attachment_picker.dart`（库内多选）、`approvals_page.dart`（batch 分组待确认区：组折叠/全选/类型过滤/junk 默认勾选/历史区）、`model_picker.dart`。
- `ai_client.dart` 重构：`POST /v1/chat` 路由（电脑在线走电脑，离线走对话绑定远程配置）；附件正文内联展开。
- 底部导航换三主 Tab「库 / 任务 / 助理」；设置页移除 AI 接口配置段（平移进 model_picker）。
- 测试：`tool_parser_test`、`proposal_flow_test`、`approvals_grouping_test`；更新 `endpoint_config_test`。

验证：端到端——对话 → AI 输出工具块 → 提案落待确认区 → 逐条/批量审批 → 生效并可撤销；归档任务写操作被拒；流中断部分提案保留；拔线走远程。

## 阶段 7｜inbox.triage + 存档导入/导出 + 收尾

改动：

- `mobile/lib/services/assistant/tools/inbox_triage.dart`（新）：提案生成器（details §4）——junk 规则预过滤 → 10 条/批子调用（原批量评估提示词迁移至此）→ 映射为 `message.set_priority` / `task.create` 提案；上限 50。
- 批处理管线残余删除：`ai_processing.dart`、`auto_process.dart`、`ai_panel.dart` 及配套测试（有价值用例迁入 `inbox_triage_test`）。
- 存档功能重写：`archive_export_service.dart` 改为直读 v8 结构（`task_anchors` 直读、notes.attachments、files 表；移除 links 转换逻辑）；新增 `archive_import_service.dart`（details §5.3：格式校验 → 空库守卫 → 单事务入库全量保留原 id → marker 一致性警告列表）；设置页加「导入存档」。
- **App 改名 Manalist**：用户可见名称全部替换（AndroidManifest `android:label`、MaterialApp title、开屏/关于页文案）；`applicationId`/pubspec name 等标识符保持不变（改名即新安装已满足「全新安装」策略，动标识符只会带来 Kotlin 目录与测试的无效 churn）；desktop 端维持 AndroidLocAI 不变。
- README 重写（含 Manalist 命名）；design-v2.md 标注 superseded 指向 design-v3；docs 全量刷新。
- 测试：`inbox_triage_test`、`archive_roundtrip_test`。

验证（端到端回归清单，真机）：采集 → 助理对话打锚点/建任务 → 待确认区审批 → 任务四视图 → 笔记 markdown/附件 → inbox.triage 批量审批 → 导出存档 → 全新安装导入完整还原 → 断线走远程 → 重连配对。

## 回滚与数据安全

- 每阶段独立 commit，回滚 = revert 该 commit。
- 无过渡版本、无旧数据迁移桥梁（v3.2 确认）：破坏性删除（阶段 3 的导入/短信、阶段 7 的批管线）无需等待任何前置发布。
- DB v8 迁移（阶段 2）只服务开发/测试；迁移失败保底：v7 库不动，最坏情况新表为空可重建。
- 实机安装纪律：只用 `adb install -r`；`flutter install` 会先卸载清数据，禁用。

## 进度记录

| 阶段 | commit | 状态 |
|---|---|---|
| 阶段 0（存档导出基础；过渡版本已取消，转阶段 7 基础） | 106aac7 | 已完成 |
| 阶段 1（契约先行） | b1b3cae | 已完成 |
| 阶段 2（DB v8） | c633156 | 已完成 |
| 阶段 3（库页重组 + 移除导入） | 0cbc4f4 | 已完成 |
| 阶段 4（任务合并 + markdown + 手动锚点） | 426a9cc | 已完成 |
| 阶段 5（AndroidLocAI） | 6afbd81 | 已完成 |
| 阶段 6（助理 + 待确认区） | ee1758c | 已完成 |
| 阶段 7（inbox.triage + 存档导入/导出重写 + 改名 Manalist + 收尾） | c8fa147 | 已完成 |
