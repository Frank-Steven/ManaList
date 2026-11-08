# 任务锚点 v2：对象级锚点（简化重设计）

> 状态：v1.0（2026-11-08）
> 定位：取代 v3 的「正文行内 marker 锚点」方案（`design-v3.md` §1.1、`design-v3-details.md` §1）。锚点从「正文内的行内对象 `⟦task:id⟧`」简化为「库中基本对象上的关联」，**正文不再写入任何 marker**。
> 配套：并发与冲突语义见 `docs/crdt.md`；助理侧交互见 `docs/assistant-v4.md`。

---

## 1. 为什么简化

行内 marker 方案（v3.1 定稿）功能正确，但链路过长，每一环都要单独维护与测试：

| 复杂度来源 | 具体机制 | 维护成本 |
|---|---|---|
| marker 语法 | `⟦task:<uuid>⟧` 正则、flutter_markdown `InlineSyntax`、`MarkdownElementBuilder` chip 渲染 | 一条自定义解析/渲染管线 |
| 编辑态 | `AnchorHighlightController` 高亮 marker 原文、光标/选择/整块删除体验 | 与编辑器深度耦合 |
| 哈希冲突 | `stripAnchorMarkers` 剥离后重算 `content_hash`，采集/编辑/手动添加三处调用点审计 | 去重正确性长期脆弱 |
| 定位失败 | `anchorText` 首次出现定位、多处取第一处、失败置 `failed` | AI 提案失败率高、用户要读懂失败原因 |
| 生命周期 | 删除任务的正文残迹化（`[任务:买菜]`）、消息正文受限写入通道 | 正文被第三方（锚点服务）写入，违反「正文归作者」直觉 |
| 存档 | 正文 marker 与 anchors.json 双写 + 一致性校验 | 往返测试负担 |

这些机制服务的只是「点击正文中某段文字跳到任务」这一个体验。代价/收益失衡——**简化为对象级锚点后，全部消失**。

## 2. 新模型：锚点 = 对象 ↔ 任务 的关联

锚点只表达一件事：**这个对象与这个任务有关**。目标是库中的基本对象：

| target_type | 对象 | 锚点语义 |
|---|---|---|
| `message` | 一条消息 | 「这条消息关联此任务」 |
| `chapter` | 一篇笔记章节 | 「这一章（及其笔记集合）关联此任务」 |
| `file` | 一个文件 | 「整个文件关联此任务」（与 v3 相同） |

- 锚点**只落 `task_anchors` 表，永不触碰正文**。消息正文回归完全只读（受限写入通道取消）；笔记正文只有作者（人/AI 笔记工具）能写。
- `target_type` 保留 TEXT 开放枚举：后续如需笔记级（`note`）粒度，加值即可，无 schema 变更；首版不做，避免「消息条/章节/文件」之外的第四种心智。
- 基数约束不变：一个锚点连一个任务，一个任务可被多个锚点连接；删除任务级联删锚点行（无需残迹化——正文里没有东西可清理）；删除对象级联删其锚点。
- `label` 字段保留（提案卡片与列表展示用），但不再承担残迹化职责。

DDL 变化（v8 → v12 迁移时一并调整）：无新增列；`target_type` 注释语义更新为 `'message' | 'chapter' | 'file'`。

## 3. 展示与交互

锚点从「正文里的 chip」变为「对象详情里的关联区 + 列表上的轻标记」：

- **对象详情页**（消息详情 sheet / 章节页 / 文件详情）：新增「关联任务」区，chip 列表（任务标题 + 状态色），点击跳任务详情；行尾「+」添加关联（选已有任务或新建）。
- **任务详情 sheet**「来源锚点」区不变：图标区分 message/chapter/file，点击反向跳转到对象详情。
- **列表行轻标记**：消息行、章节行、文件行的副标题区显示一个小链环角标（有锚点时），不做 chip 内联，避免列表噪音。
- **双向跳转**沿用 `task_navigation.dart` 的 `showTaskDetailSheet` / `openAnchorTarget`，只是落点从「高亮正文 chip」改为「打开对象详情并滚动到关联区」。
- 人工入口（功能对等原则不变）：对象详情页「关联任务」区、列表多选态「关联任务」批量操作（多选 N 条消息 → 建 N 个对象级锚点提案/直接操作，人工路径直接生效）。

废弃交互：正文选段「添加任务锚点」、笔记编辑器 marker 高亮、plain → markdown 锚点转换确认弹窗（不再需要）。

## 4. AI 工具变更

| 工具 | 变化 |
|---|---|
| `anchor.create` | 参数从 `{targetType, targetId, anchorText, taskRef}` 简化为 `{targetType, targetId, taskId}`。**去掉 anchorText**——不再定位正文片段，不存在「定位失败」这一类 `failed` |
| `anchor.remove` | 不变（按 anchorId 删行） |
| `note.replace_section` | **废弃**。它依赖「锚点/标题界定区段」，且原地覆写正文与 SSA 冲突。AI 写笔记收敛为 `note.create` / `note.append`（章节末尾追加）。需要「改旧内容」的意图由 AI 拆为「append 修订段 + （人工）编辑」 |
| 其余 | 不变 |

提案卡片 diff 展示从「正文片段 + 插入位置」改为「对象摘要（消息标题/章节名/文件名）→ 任务标题」，更短更易审。

## 5. 废弃清单（实现层）

> 2026-11-08：本节已全部落地（批次 A）。`stripAnchorMarkers`/`anchorMarkerPattern` 仅保留给旧版撤销 payload 的兼容读取；删除任务撤销快照的 bodies 恒为空（旧快照兼容回写前剥离 marker）。

随 v12 一并移除/改写：

- `TaskAnchorInlineSyntax`、`MarkdownElementBuilder` 锚点 chip 分支、`AnchorHighlightController`、`AnchoredMarkdownBody` 中的 marker 渲染（组件本身保留给 markdown 正文渲染，去掉锚点职责）；
- `stripAnchorMarkers` 及三处调用点审计（`content_hash` 恢复为对原文直接计算）；`computeContentHash` 相关防御性剥离测试删除；
- `AnchorService.residualizeForTask`（残迹化）、消息正文受限写入通道与 `edited_at` 锚点留痕；
- 存档格式：正文不再含 marker，`anchors.json` 照常导出；导入的「marker 一致性校验」步骤删除；
- 测试替换：`anchor_syntax_test` / `content_hash_marker_test` 删除；`anchor_service_test` 改写为对象级 CRUD + 级联删除 + OR-Set 并发语义（见 `docs/crdt.md` §4.3）。

## 6. v12 迁移（行内 marker → 对象级锚点）

> 2026-11-08：v11 已被批次 D 的 `conversations.pinned` 占用，本节迁移顺延至 v12，与 `crdt.md` §7 同窗口。
> 2026-11-08：已落地（`migrateToV12` / `normalizeAnchorsToObjectLevel`），迁移测试 `db_v12_migration_test.dart` 全绿 ✅。

1. 扫描 `messages` / `notes` 正文，剥离全部 `⟦task:<id>⟧` marker（纯文本替换，正文恢复原貌）；
2. 每条被剥离的 marker 转为对象级锚点行：所在消息 → `target_type='message', target_id=messages.id`；所在笔记 → 其所属章节 `target_type='chapter', target_id=chapters.id`（同一对象多个 marker 去重为一条，保留最早 `created_at`）；
3. 受影响消息的 `content_hash` 按原文明文重算更新；
4. 迁移测试：`db_v12_migration_test.dart`——marker 剥离幂等、锚点转换去重、哈希与重投去重一致、无 marker 数据原样通过。

## 7. 与 CRDT 的关系

对象级锚点是典型的**集合**语义，天然适配 OR-Set（`docs/crdt.md` §4.3）：并发添加（人和助理同时关联同一对象到不同任务）全部保留；「移除」只移除已观察到的添加，并发「添加 + 移除」按 add-wins 保留。行内 marker 方案下这类并发要处理正文文本冲突，对象级方案下冲突域缩到一张关联表，这也是简化的深层收益。
