# ManaList UI 布局与层次结构规范

> 状态：v1.1（2026-11-01）
> 适用：mobile/（Flutter，Material 3）。本文档是 UI 结构的唯一标准：新页面/新组件必须先对齐本规范；既有页面按 §8 整改清单逐步收编。
> 背景：v3 重构后应用变为「库 / 任务 / 助理 / 设置」四主 Tab，页面数量与呈现方式（tab / push / bottom sheet / dialog）快速增长，层次职责出现模糊（典型：库页「容器 TabBar + 内嵌页各自 AppBar」的双层头部）。本规范统一结构标准。
> v1.1：应用定名 **ManaList**、桌面网关定名 **LinkModel**；设置升为第四主 Tab；任务视图切换器统一为 AppBar.bottom TabBar；库分区顺序定稿「消息/笔记/文件」；分区与视图位置持久化记忆；甘特交互定稿（§6.2）。
> v1.2（2026-11-08）：助理域交互/外观/配置的现行标准改由 `docs/assistant-v4.md` 承载（§6.3 仅保留结构落位）；锚点改对象级关联后，正文行内锚点 chip 不复存在（§7 锚点条目同步更新，见 `docs/anchors-v2.md`）；人体工学细则见 `docs/ux-fixes-2026-11.md` §3。

---

## 1. 层次模型（L0–L5）

```
L0  应用壳      HomeShell（NavigationBar 四主 Tab + IndexedStack 懒构建保活）
L1  主 Tab 页   库 / 任务 / 助理 / 设置 —— 平级，承载各自领域的主列表
L2  页内分区    主 Tab 页内部的二级组织（库的「消息/笔记/文件」、任务的「列表/日/月/年/年度」）
L3  详情        单个实体的只读/轻操作视图 —— 一律 bottom sheet
L4  编辑与创建  需要键盘长时间停留的内容生产 —— 一律全屏 push 页
L5  模态        确认、短输入、选择器 —— dialog 或小型 bottom sheet
```

铁律：

1. **层级不可跳跃呈现**：L3 详情只能从 L1/L2 列表或锚点 chip 打开；L4 只能从 L1/L2/L3 进入。
2. **同类实体同层呈现**：消息详情与任务详情同级（都是 L3 sheet）；笔记编辑与手动添加消息同级（都是 L4 全屏）。不允许同一类实体此处 sheet、彼处全屏。
3. **层级只增不嵌**：sheet 上不再叠 sheet（L3 上的操作去 L5 dialog 或跳 L4 全屏，不收第二个 sheet）。

## 2. 呈现方式决策表

| 用途 | 呈现 | 理由 |
|---|---|---|
| 四大领域切换 | 底部 NavigationBar（L0/L1） | 平级、常驻、带角标 |
| 页内分区/视图切换 | 容器页头部的分段控件（TabBar 或 SegmentedButton） | 同级视图、不出新页面 |
| 实体详情（消息/任务/文件） | `showModalBottomSheet`（L3） | 快速看一眼即走，不打断列表位置 |
| 内容编辑/创建（笔记、任务编辑器、手动添加消息） | 全屏 push（L4） | 键盘长驻、需要完整 AppBar 操作区 |
| 二级列表导航（笔记本→章节→笔记列表） | 全屏 push | 有独立标题与返回栈 |
| 选择器（任务选择、附件选择、模型选择） | 任务/小型选择用 sheet（L5）；附件/模型这类多选+管理用全屏 push | 选择复杂度分界：单选即走=sheet，需管理/多选=push |
| 确认与短输入（删除确认、改名） | `showDialog`（L5） | 阻塞决策，最小打扰 |
| 反馈与撤销 | SnackBar（UndoService 10s 队列） | 全局统一，不走 dialog |

## 3. 头部（AppBar）单一归属规则

**每一屏有且只有一个 AppBar，由当前屏最外层 Scaffold 持有。**

- L1 主 Tab 页持有 AppBar：标题 = 领域名（「库」「任务」「助理」），actions 放领域级入口（如助理页的待确认区/模型/设置齿轮）。
- L2 分区页**不持有 AppBar**：分区的标题已由容器 Tab/分段控件表达；分区级操作（如消息筛选、文件导入）上收进容器 AppBar 的 actions，或放入分区内容的首行工具条。
- L3 sheet：用 sheet 内自绘标题栏（拖拽柄 + 标题 + 关闭/操作），**不套 Scaffold/AppBar**。
- L4 push 页：自有 AppBar（返回 + 标题 + 编辑操作）。

> 现状违规：库页的笔记/消息/文件三个内嵌分区页各有 AppBar，与库页 TabBar 形成双层头部（v3 阶段 3 的已知过渡态）。整改见 §8。

## 4. 操作入口位置约定

| 操作级别 | 位置 | 示例 |
|---|---|---|
| 领域主创建 | L1 页 FAB（唯一右下角）或 AppBar 首位 action，二选一全领域统一为 **FAB** | 库·笔记=新建笔记；库·消息=手动添加；库·文件=导入文件；任务=新建任务；助理=新对话 |
| 页面级操作 | AppBar actions（≤3 个，超出进溢出菜单） | 归档箱、筛选、视图切换 |
| 分区级操作 | 分区内容首行工具条（chip 行/图标行） | 消息筛选 chip 行 |
| 条目级操作 | 左滑菜单（主操作）+ 长按（上下文菜单）+ 行内图标（轻状态） | 消息归档/垃圾、文本选段加锚点 |
| 批量操作 | 多选态底部操作条（能力交集逻辑沿用 `commonCapabilities` 纯函数） | 消息多选、待确认区批量通过 |
| 破坏性操作 | 必须经 L5 确认对话框（标题=动作+对象，正文=影响说明，确认键用警示色） | 删除任务、删除文件（含引用计数提示）、拒绝提案 |
| 可撤销操作 | 成功后 SnackBar + UndoService，**不弹确认** | 归档、完成、提案通过 |

冲突裁决：破坏性且不可完整撤销的操作（删除文件本体、删除对话）才弹确认；凡是「撤销能完整恢复状态」的操作一律走 SnackBar 撤销，不打断流。

## 5. 导航与状态保持

- **Tab 切换**：`HomeShell` IndexedStack 保活 + 懒构建（`_builtTabs`）；切入刷新走 GlobalKey `reload()`；外部切页请求一律走 `AppUiState.setTab`（HomeShell 是唯一落点，F08 教训：禁止各自直接改导航）。
- **push 返回**：编辑器类页面返回即保存（快照比较避免冗余写库）；列表类 push 页返回后由父页 reload。
- **sheet**：`isScrollControlled: true` + 高度约束（默认 85% 屏高）；sheet 内跳转（如消息详情→任务详情）用「收当前 sheet 再开目标」而非堆叠。
- **跨页跳转**（锚点双向跳转）：统一走 `task_navigation.dart` 的 `showTaskDetailSheet` / `openAnchorTarget`，禁止各页面自写跳转逻辑。

## 6. 各页面结构落位

### 6.1 库（L1）

```
AppBar「库」  actions: [归档箱(消息分区时)]
TabBar(AppBar.bottom)  消息 | 笔记 | 文件   ← 唯一分区切换器（消息带未读角标）
├─ 消息分区   筛选 chip 行 + 分组列表 + FAB 手动添加      （默认分区）
├─ 笔记分区   首行工具条(搜索/排序) + 列表 + FAB 新建笔记本
└─ 文件分区   面包屑 + 文件夹/文件树形列表 + FAB 导入（落当前文件夹）
```

- 分区顺序定稿「消息/笔记/文件」：消息是采集入口（带角标），首次默认展示消息分区；当前分区持久化记忆（`ui_library_section`）。
- 分区定位外部入口：`AppUiState.openLibrary(section)`（通知横幅等）。
- 消息详情（L3 sheet）→ 锚点 chip → 任务详情（L3 sheet，收一开一）。
- 多选态底部操作条含「发送给助理」：选对话（sheet）→ 所选条目追加为该对话草稿附件。
- 文件分区树形管理：文件夹为 `files.folder` 路径字段的虚拟树（无独立文件夹表），支持新建文件夹、多选移动、导入落当前文件夹。

### 6.2 任务（L1）

```
AppBar「任务」  actions: [现在(仅甘特档显示)]
TabBar(AppBar.bottom)  列表 | 日 | 月 | 年 | 年度   ← 与库页同一样式
└─ 视图区（IndexedStack 懒构建，甘特懒构建）
```

- 默认「列表」；当前视图持久化记忆（`ui_tasks_view_mode`）。主 Tab 位置不记忆，启动恒落「库」。
- FAB 新建任务（多选态隐藏）；条目点击 → 任务详情 sheet；详情内「编辑」→ L4 编辑器 push。
- 任务详情 sheet 分区：基本信息 / 时间 / 优先级 / **来源锚点**（图标区分 message/note/file，点击反向跳转）/ 子任务 / 操作（完成、归档、删除）。
- 甘特交互定稿：日视图名称标记区高度固定；甘特下方任务列表为展开/收起双模态（期导航工具条末端切换，取消拖拽调高）；月/年视图初始定位到当前周/当月；泳道分行红色靠上、绿色靠下。
- 任务编辑器表单自动流转：标题 → 描述 → 时间 → 优先级 → 保存（FocusNode 链 + 滚动高亮，选择类字段不弹键盘）。

### 6.3 助理（L1）

> 助理域的交互、外观、配置体验细节以 `docs/assistant-v4.md` 为现行标准（2026-11-08 起）；本节只保留结构落位与导航约定。

```
AppBar「助理」  actions: [待确认区(带 pending 数角标) | 模型]
对话列表 + FAB 新对话
└─ 对话页（push, L4 变体：全屏对话流 + 底部输入条 + 附件 chip）
```

- 待确认区（push 页）：batch 分组卡片 → 底部固定「通过所选 / 拒绝所选」操作条；历史折叠区。
- 模型选择器（push 页）：LinkModel 接口（电脑端）置顶只读 + 远程端点 CRUD；从对话页进入时为选择模式。
- 附件：对话附件选择页与库页同构（三分区多选）；库内多选「发送给助理」追加为对话草稿附件（`conversations.draft_attachments`），对话页附件 bar 展示草稿，发送后清空。
- 设置不再是助理页入口——它是第四主 Tab（§6.4）。

### 6.4 设置（L1）

分区顺序固定：外观 / 数据（导出·导入存档）/ 采集过滤 / 保活 / 关于（ManaList 版本与 LinkModel 网关说明）。AI 相关配置只存在于助理域（模型选择器），设置页不再出现。设置页 State 私有，切入时用 UniqueKey 重建刷新。

## 7. 组件与模式标准

- **列表行**：标题 1 行省略 + 副标题 1 行（时间/来源）；状态色点遵循消息优先级（红/黄/绿/垃圾灰）与任务状态（active 主色/done 绿删除线/archived 灰）既有语义，不新增颜色体系。
- **锚点展示**：对象级锚点（`docs/anchors-v2.md`）统一以「关联任务」chip 区呈现于对象详情页/任务详情「来源锚点」区（图标 + 任务标题 + 状态色），列表行用链环小角标；任何页面不得自绘锚点样式。正文行内 chip（`AnchoredMarkdownBody` 的 marker 渲染）已随锚点 v2 废弃。
- **提案卡片**：工具图标 + 摘要 + 状态标（pending 黄/applied 绿/rejected 灰/failed 红），对话页内联与待确认区卡片同构（同一组件两种密度）。
- **空态**：图标 + 一句引导文案 + 主操作按钮（指向该分区 FAB 同一动作）。
- **错误反馈**：瞬时错误=SnackBar；需留痕错误=AppLog + 设置页「最近错误」；AI 流式错误=对话内 error 气泡。
- **主题**：唯一入口 `ColorScheme.fromSeed(indigo)` 双 scheme 缓存；主题切换走 ThemeFader 快照方案；SnackBar 一律走全局 `snackBarThemeFor` 封装。

## 8. 文件组织与命名

```
lib/ui/<domain>/           # 领域目录：library/ tasks/ assistant/ messages/ notes/ settings...
  <page>_page.dart         # L1/L2 页面（StatefulWidget + 公开 State 供 GlobalKey reload）
  <entity>_detail_sheet.dart   # L3 详情
  <entity>_editor.dart     # L4 编辑器
  views/                   # 复杂自绘视图（tasks/views/）
lib/ui/shared/             # 跨域组件（anchored_markdown、anchor_highlight_controller、theme_fader）
lib/services/              # 与 UI 解耦的逻辑（*_service）；UI 不直接写 SQL
lib/services/assistant/    # 助理域服务（tool_spec/parser/proposal_*）
```

规则：页面类名=文件名去后缀的 PascalCase；对外刷新口统一为 `XxxPageState.reload()`；跨页导航辅助统一收 `task_navigation.dart` 式的 `<domain>_navigation.dart`。

## 9. 现状不合规清单与整改计划

| # | 违规点 | 整改 | 优先级 |
|---|---|---|---|
| 1 | 库页双层头部（容器 TabBar + 三内嵌页各自 AppBar） | 三内嵌页移除 AppBar，归档箱等操作上收库页 AppBar（按分区分显隐），分区操作落首行工具条 | ✅ 6ff0c13 |
| 2 | 领域主创建入口不一（部分 AppBar action、部分页内按钮） | 统一 FAB（§4） | ✅ 6ff0c13 |
| 3 | 任务「年度」档曾缺失 | 已修复（五档切换器 + `_jumpToTask` 年度映射恢复） | ✅ d532d25 |
| 4 | 删除任务撤销不恢复锚点 | 已修复（TaskDeletionSnapshot 快照任务行+锚点行+正文原文，撤销整体回写） | ✅ d532d25 |
| 5 | 选择器呈现不一（task_picker 是 sheet、attachment/model_picker 是 push） | 符合 §2 分界（单选即走=sheet、多选管理=push），仅统一视觉密度 | 低 |
| 6 | 消息分区的 AI 面板删除后残留的入口空洞排查 | 随阶段 7 已完成 | ✅ c8fa147 |
| 7 | 提案卡片在对话页与待确认区是两套实现 | 抽取同构组件（§7） | ✅ 8e62264 |
| 8 | 旧命名残留（`MsgRepoApp` 类名、注释中的 v2 术语） | 逐步清扫，不动 public 行为 | 低 |
| 9 | 任务页双层头部（TasksPage 段选器 + TaskListView 内层 AppBar「待办」） | 比照库页模式收编：TaskListView 交出 AppBar，任务页 AppBar 标题「任务」，多选态落首行工具条 | ✅ 7b4707e |

整改以「新代码先合规、旧代码按优先级收编」执行；每完成一项在此表标注 commit。
