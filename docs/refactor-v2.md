# MsgRepo v2 重构操作文档

> v3 手册见 [refactor-v3.md](refactor-v3.md)（v3 起应用改名 Manalist）。本文档保留作历史参考。

配套 `docs/design-v2.md` 执行。每阶段独立可构建、真机验证、单独 git 提交；任一阶段出问题只回滚该阶段（`git revert` 对应提交）。

## 总则

- 每阶段验收：`flutter analyze` 无错误 + `flutter build apk --debug` 通过 + 真机过该阶段验证清单 + commit。
- 桌面端改动验收：`npm run build`（tsc）通过 + 协议用 curl 验证。
- 分支策略：直接在 main 上按阶段提交（单人项目）；每阶段提交信息以 `v2-stage-N:` 前缀。
- 兼容：旧手机端 ↔ 新电脑端靠保留的 `/v1/sync`；旧 token 在自动配对流程中继续有效。
- **顺序约束**：阶段 1 是所有阶段的前置；阶段 2/3/5 互不依赖但都依赖 1；阶段 4 依赖 3（共用任务编辑器）；阶段 6 依赖 2（消息入口）；阶段 7 依赖 6（协议）；阶段 8 最后。

## 阶段 1｜数据层 v2

改动：

- `mobile/lib/models.dart` → 拆为 `models/message.dart`、`models/task.dart`、`models/note.dart`（保留旧 RawMessage/StructuredItem 至阶段 8，标记 deprecated）。
- `mobile/lib/services/database.dart`：DB v4——新增 `messages`/`tasks`/`notebooks`/`chapters/`notes` 建表 + §1.5 迁移（只增不删，旧表保留）；DAO：messages（分组查询/批量状态/优先级）、tasks（周期交集查询 `overlap(start,end)`、CRUD）、笔记三级 CRUD。
- `mobile/lib/services/undo_service.dart`（新）：内存队列（TTL 10s、弹栈撤销、入队截断、复合逆操作）。
- `mobile/lib/services/text_width.dart`（新）：名称宽度计量（全角/中文=2、ASCII=1、emoji grapheme cluster=2，上限 36）。
- 周期工具：`mobile/lib/services/date_ranges.dart`（今天/本周/本月/本季度/本年/逐年的 [start,end)）。

验证：安装启动（迁移跑通，旧 84 条消息与新表并存）；dao 自测页面临时用 main() 断言（或 dev 菜单），不新增正式测试脚手架。

## 阶段 2｜消息模块

改动：

- `mobile/lib/ui/messages/messages_page.dart`（新）：分组列表（未处理→红黄绿→垃圾，吸顶组头）、行标记（空心点/色点/任务角标/垃圾灰块）。
- `mobile/lib/ui/messages/swipe_menu.dart`（新）：块状左滑菜单（按状态出菜单项）。
- `mobile/lib/ui/messages/selection_bar.dart`（新）：多选底部图标条，能力交集逻辑（纯函数 `commonCapabilities(messages)`）。
- `mobile/lib/ui/messages/archived_page.dart`（新）：归档页（取出/删除）。
- `mobile/lib/ui/messages/filter_row.dart`（新）：统一 Chip 筛选行（状态多选 + 应用）。
- 所有操作接 UndoService + SnackBar 撤销。
- 创建任务接阶段 3 的编辑器（阶段 2 先跳占位）。

验证：分组/标记正确；四个状态各自的滑动菜单；多选交集禁用；归档/取出/垃圾互转 + 10s 撤销；筛选生效。

## 阶段 3｜待办模块

改动：

- `mobile/lib/ui/todos/todos_page.dart`（新）：§3 全分组单页列表（含"年度任务"逐年分节、已完成/已归档沉底）。
- `mobile/lib/ui/tasks/task_editor.dart`（新）：§7 全字段编辑器（宽度计量条、类型切换、时间选择、优先级、年度开关、来源跳转、删除）。
- 勾选完成/取消完成、归档，全部进撤销队列。
- 阶段 2 的"创建任务"接入本编辑器。

验证：九个分组内容正确（跨年任务出现在正确的年节）；编辑器各约束（36 宽度、emoji、时间段、年度任务钳制）；完成→撤销；从消息创建任务双链。

## 阶段 4｜日程模块

改动（纯函数布局先行，UI 后接）：

- `mobile/lib/ui/schedule/layout.dart`（新，纯函数）：`layoutYearLane()`（泳道填充/跳位/跨年延伸标记）、`assignDayNames()`（45° 名称空位分配 + OBB 碰撞）、月视图网格计算。自测：main() 断言覆盖用户给的全部规则。
- `mobile/lib/ui/schedule/year_view.dart`（新）：§2.1（季度行×月块、三泳道红黄绿、当前月高亮、延伸样式、月粒度拖拽、年度任务）。
- `mobile/lib/ui/schedule/month_view.dart`（新）：§2.2（周网格、日格节点/线段、今天高亮、日粒度拖拽）。
- `mobile/lib/ui/schedule/day_view.dart`（新）：§2.3（时间轴、捏合缩放、断点线段、当前时间竖线、45° 名称层与虚线、5min 拖拽）。
- `mobile/lib/ui/schedule/schedule_page.dart`（新）：粒度切换（等宽分段）+ 今天 + 上跳 + 下钻导航。
- 任务点击 → 阶段 3 编辑器；拖拽改时间写库 + 撤销。

验证（对照用户框架逐条）：年视图泳道顺序/跳位/延伸/跨年不保留位置/月拖拽/禁跨年跨度；月视图周日开头/今天高亮；日视图缩放/名称显示条件/两类虚线/空位不足不显示/5min 吸附；三视图互跳。

## 阶段 5｜笔记模块

改动：

- `mobile/lib/ui/notes/notebooks_page.dart`、`chapters_page.dart`、`note_editor_page.dart`（新）：三级导航 + 纯文本编辑（退出自动保存）。
- 增删改排序；级联删除进撤销队列。

验证：三级增删改；级联删除撤销整体回滚；内容落库。

## 阶段 6｜AI 客户端 + 设置 + 流式展示

改动：

- `mobile/lib/services/ai_client.dart`（新）：§8.1 路由（health 探测 30s 缓存）+ 远程 API 配置存储（多套）+ SSE 解析。
- `mobile/lib/services/process_panel.dart` + `mobile/lib/ui/messages/ai_panel.dart`（新）：§8.3 底部流式面板（token 滚动 + 计数 + 草稿确认/批量确认）。
- `desktop/src/server.ts`：`POST /v1/process`（请求=消息批，NDJSON：token/progress/done，输出=priority+taskDraft）；`POST /v1/pair`（自动配对）；`/v1/sync` 标 deprecated。
- `desktop/src/ai/openai-compat.ts`：stream 模式逐 token 回调。
- `desktop/src/ai/prompt.ts`：输出 schema 换 §8.2 精简结构（沿用时间策略与注册表描述资产）。
- `mobile/lib/ui/settings_page.dart` 重做：外观（等宽三段）、提示词、AI 接口管理、连接状态、采集过滤。
- 消息"自动处理/重新处理"接入 AiClient + 面板。

验证：curl `/v1/process` 流式（token 事件间隔到达）；电脑在线走电脑、拔线走远程（配一个 dummy 远程验证路由）；面板滚动展示；草稿确认落 tasks；自动配对（删 token 后 401→自动重配成功）。

## 阶段 7｜电脑端 Electron 打包

改动：

- `desktop/electron/main.ts`（新）：Tray 菜单（状态/设备/模型/配对/自启/退出）、内嵌 server + adb 看护（吸收 connect.ts）、模型进程管理。
- `desktop/package.json`：electron + electron-builder 依赖与脚本（`electron` / `dist`）；dashboard 静态资源与 `/dashboard`、`/api/items` 移除。
- `docs/` 更新电脑端章节。

验证：`npm run electron` 菜单栏图标出现、菜单各项生效、插拔手机状态联动；`npm run dist` 出 dmg（本机安装一次）；旧手机端连新服务（/v1/sync 仍可用）。

## 阶段 8｜收尾

- 提醒调度改挂 tasks（kind/priority/reminderOffsets 默认规则）；旧 items/inbox/item_detail 页面与旧 models 删除；registry_service/sync_client 移除（AI 走 ai_client）。
- README 重写；docs v1 文件头加 superseded 标注指向 design-v2。
- 端到端回归清单（真机）：采集→AI 评估→转任务→三视图展示→拖拽→待办勾选→笔记→撤销→断线走远程→重连自动配对。

## 回滚与数据安全

- 每阶段独立 commit，回滚= revert 该 commit（数据库迁移只增不删，旧版本 App 重装的 DB 降级：sqflite 版本高于代码版本会报错——为此 DB 版本号在每阶段只升一次，回滚代码时保留 v4 读写兼容层直到阶段 8）。
- 迁移失败保底：旧表不动，最坏情况新表为空可重建。

## 进度记录

| 阶段 | commit | 状态 |
|---|---|---|
| 阶段 0（设计文档） | 4d98108 | 已完成 |
| 阶段 1（数据层 v2：DB v4 + UndoService） | 3a5c7f6 | 已完成 |
| 阶段 2（消息模块） | 77afd90 | 已完成 |
| 阶段 3（待办模块 + 任务编辑器） | 6fc7fe2 | 已完成 |
| 阶段 4（日程年/月/日三视图） | 2410737 | 已完成 |
| 阶段 5（笔记模块） | f584482 | 已完成 |
| 5-tab 壳（穿插） | 7bc8681 | 已完成 |
| 阶段 6（AI 客户端路由 + 流式面板 + 设置页） | 2198af8 | 已完成 |
| 阶段 7（电脑端 Electron 托盘应用） | 7784323 | 已完成 |
| v2.1 批（时间尺度 + 待办分页 + 日视图缩放 + 左滑重做 + SnackBar 修订） | 7cc07bb、321ee11 | 已完成 |
| v2.2 设计文档（年度视图 + 子任务，仅文档） | 52a75a4 | 10830b6 已实现 |
| v2.3（选中-调整 + 无限滚动 + 详情面板 + 页签徽标 + 段选器圆角修复） | 待实现 | bbcffec 已实现 |
| v2.3-fix（真机回归：月视图坐标系/日视图 ppm/年视图顶对齐/待办默认页签） | 待实现 | f9d2471 已实现 |
| v2.4（细节打磨 22 条 + 消息导入预留设计） | 待实现 | 已实现（日程 66049cd / 待办 e1f6ab3 / 消息 2b8de98 / AI c7fc37d / Toast 64bd6fa；第 22 条消息导入仅设计文档） |
| 阶段 8（收尾：v1 代码清除 + 提醒改挂 tasks + README/docs 整理） | 08873f1 | 已完成（真机端到端回归清单待人工执行） |
