# 协同与冲突避免：CRDT 设计

> 状态：v1.0（2026-11-08）
> 定位：本文档取代「不引入真正的 CRDT」的旧决策（原 `assistant.md` §2.1「刻意保持简单」、§10「不引入 CRDT 同步协议」）。原子化与全量审批两条硬约束**不变**；变化的是：并发冲突从「靠人工审批串行化在源头上规避」升级为「数据层用 CRDT 保证收敛，审批层只做人性裁决」。
> 动机：三类并发真实存在且旧方案处理不了——①多个助理对话的回合并行工作（`AssistantTurnHandle` 服务自持后，多对话同时产出提案是常态）；②人手动编辑与助理 pending 提案同时指向同一对象；③提案任意子集、任意顺序的选择性审批。旧方案对②③的答案是「执行前二次校验，失败置 `failed`」——把可自动合并的并发误判为失败，把审批顺序变成正确性变量。

---

## 1. 目标与非目标

目标：

1. **收敛**：任何 actor（人、任一助理对话）以任意顺序做出的写操作，最终落到同一状态，无需全局锁、无需审批串行化。
2. **选择性审批安全**：提案按任意子集、任意顺序通过/拒绝，结果与审批顺序无关。
3. **人优先**：人的操作与助理提案冲突时，确定性规则保证人的修改不被静默覆盖。
4. **可撤销、可审计**：每次写入可逆（撤销队列），全量操作留痕（op log）。

非目标（维持旧决策的边界）：

- 首版仍是**单设备**：不做多副本网络同步、不做桌面端业务逻辑。CRDT 在此是**本地并发控制与审批语义的数学底座**，op log 同时是未来的多设备同步负载预留。
- 不引入第三方 CRDT 库；本文用到的类型（LWW-Register、OR-Set、追加集）各是一段几十行的纯函数 + 一张 op log 表。
- 不做人-人实时协同编辑（无多用户概念）。

## 2. 核心模型：操作（Op）与 Actor

### 2.1 Actor

| actor_id | 含义 |
|---|---|
| `user` | 人的一切手动操作 |
| `assistant:<conversation_id>` | 某对话的助理（提案审批通过后，以该对话身份落 op） |
| `system` | 采集入库、迁移、归档联动等非交互写入 |

确定性决胜序（lamport 相同时）：`user` > `system` > `assistant:*`（同级按 actor_id 字典序、再按 op_id）。**人永远赢同刻冲突**——这是规则，不是启发式。

### 2.2 Op（操作）

一切写入（人工 UI、审批通过的提案、系统联动）统一表达为 op，append 到 `op_log`：

```
op_id        uuid
actor        TEXT               -- 上表
lamport      INTEGER            -- max(本地计数, 已见最大值)+1，单设备内单调
target       TEXT               -- 'tasks:<id>:title' / 'anchors:<task_id>' 等寻址串
kind         TEXT               -- 'lww_set' | 'or_add' | 'or_remove' | 'append' | 'tombstone'
payload      TEXT               -- JSON，新值 / 集合元素 tag / 追加内容
base         TEXT               -- 生成该写入时读到的目标版本（见 §3.2），人工即时操作为当前版本
created_at   INTEGER
```

物化状态（现有各表）= op log 的折叠结果。常规读写仍走现有表（它们是「当前值缓存」）；op log 是事实源，支撑撤销、审计、冲突判定与未来同步。表与 log 不一致时以 log 重放为准（提供诊断工具，不进常规路径）。

## 3. 提案生命周期与合并规则

### 3.1 提案携带 base

提案生成（`proposal_service` 落 pending）时，校验器顺带读取目标对象的**当前版本**记入 `payload.base`：

- 修改类提案（task.update / message.set_priority）：base = 目标字段当前的 `(lamport, actor)`；
- 集合类提案（anchor.create/remove）：base = 当前观察到的锚点 tag 集（增量同步语义，见 §4.3）；
- 创建类提案（task.create / note.create）：无 base（新对象，永不冲突）。

### 3.2 审批时的三态裁决

提案通过时，`proposal_executor` 不再「校验失败即 failed」，而是：

```
读目标当前版本 cur
若 cur == base                      → 直接落 op（无并发）
若 cur ≠ base 且改动域不相交        → 自动 rebase：落 op，结果标注「已基于最新状态生效」
若 cur ≠ base 且改动域相交          → 按 §4 的 CRDT 类型规则确定性合并：
    · 合并结果 = 对方（人）的值      → 提案置 superseded，卡片显示「已被你的修改覆盖：旧值 → 新值」
    · 合并结果 = 提案的值            → 仅当对方也是 assistant 时允许自动生效；对方是 user 时
                                      永不自动覆盖（上面决胜序保证这种情况不会发生——user 必赢）
```

`superseded` 是新增提案状态（原 status 枚举加值），语义 = 「提案没被执行，但不是错误」；卡片提供「基于当前状态重新生成」入口（AI 下轮重提或人手动改）。

### 3.3 选择性审批为何安全

- 每条提案独立携带 base、独立 rebase，**审批顺序不构成正确性变量**：先批 A 再批 B 与反过来，两条 op 的 lamport 先后不同，但 §4 的合并规则对 lamport 顺序是确定的，两种审批顺序收敛到同一终态（字段不相交时显然；相交时后落者按 LWW 赢，而 lamport 由落 op 时刻分配——顺序差异只会体现在「谁赢」上，且这个差异对人是可见的：每张卡片都显示最终生效值）。
- 批量通过 = 逐条走同一裁决管线，无事务包装；部分失败（目标已被删除）置 `failed` 不影响其余——与旧语义兼容，只是「失败」的判定从「base 过期」收窄为「目标不存在/权限拒绝」。

## 4. 各类数据的 CRDT 类型映射

### 4.1 任务字段：LWW-Register（每字段独立）

标题、描述、时间、优先级、完成状态各自是一个 LWW 寄存器：比较键 `(lamport, actor 决胜序, op_id)`。字段级粒度让「人改时间 + 助理改优先级」天然不相交、自动共存——这是最常见的人机并发，旧方案下后者会被判 failed。

### 4.2 任务删除/归档：LWW 墓碑

删除 = 落 `tombstone` op（携带 lamport）。墓碑与并发编辑比较：删除晚（lamport 大）→ 删除生效，并发编辑只存在于 op log（可撤销恢复）；编辑晚 → 编辑生效，删除提案置 superseded 并提示「该任务在你审批期间被修改」。归档同理由状态寄存器承载。删除对象（消息/文件/章节）级联锚点行，op log 保留可整体撤销（沿用 TaskDeletionSnapshot 思路，改由 op 逆操作实现，见 §5）。

### 4.3 锚点集合：OR-Set（Observed-Remove Set，add-wins）

每个锚点 = 集合元素 `(task_id, target_type, target_id)` + 唯一 tag（即 anchor id）。

- `anchor.create` → `or_add(tag)`：并发添加（人和助理同时把同一消息关联到不同任务）**全部保留**；
- `anchor.remove` → `or_remove(生成时观察到的 tag 集)`：只移除已观察到的添加；「移除 X 与并发再添加 X」按 add-wins 保留新 tag；
- 收益：对象级锚点（`anchors-v2.md`）把并发域收敛到这张表，无需处理任何正文文本冲突。

### 4.4 笔记章节正文：SSA + 追加集

SSA（`assistant.md` §7.1）保持不动：**正文本体不可变**。在此之上：

- `note.append` → 追加集元素（`append` op，payload 为追加文本段）；并发追加（人写一段 + 助理审批通过一段）按 lamport 序拼接，互不丢失；
- 「编辑正文」= 产生新本体 id + 引用切换（SSA 原有语义），并发两个新本体按 LWW 决定引用指向谁，落选本体仍在 `attachment_store`/历史本体区可恢复；
- `note.replace_section` 已废弃（`anchors-v2.md` §4），最大的原地写冲突源随之消失。

### 4.5 消息优先级与其余标量

`messages.priority`、文件 `folder`、文件夹重命名等一律 LWW-Register。消息正文恢复只读后退出并发域。

## 5. 撤销与审计

- **撤销 = 逆 op**：LWW → 写回前值的 op；or_add → or_remove；or_remove → or_add（同 tag）；append → 标记段隐藏（灰显删除线而非物理移除，保持追加集单调）。UndoService 由「快照回写」改为「投递逆 op」，撤销本身也进 op log（审计完整）；撤销与并发写同样走合并规则，不再假设「撤销时状态没变」。
- **审计**：op log 即全量变更流水，设置页「最近错误」旁可加「最近变更」只读视图（actor 标注「你 / 助理·对话名 / 系统」），让「助理提案、人做决定」事后可追溯。

## 6. 多助理并行与人机并发的场景验收

| 场景 | 旧行为 | 新行为 |
|---|---|---|
| 对话 A、B 同时对任务 T 提 update（不同字段） | 先批的生效，后批的 failed | 两条都 rebase 生效，字段共存 |
| 对话 A、B 同时改 T 的标题 | 后批的 failed | 后落 op 者赢（LWW），落选卡片显示 superseded 与最终值 |
| 人改了标题，助理提案也改标题，人随后批提案 | 提案生效覆盖人的修改（无感知）或 failed | user 决胜序保证人的值不被助理覆盖；提案 superseded 并明示 |
| 人编辑消息正文，助理提案给该消息加锚点 | 受限写入通道竞争 edited_at | 锚点不写正文，天然无冲突 |
| 审批 12 条 inbox.triage 提案中的任意 5 条 | 依赖「二次校验」逐个赌运气 | 每条独立裁决，顺序无关 |
| 助理提案删除任务 T，人刚把 T 标记完成 | failed 或误删 | LWW 墓碑比较 lamport：完成在后 → 删除提案 superseded 并提示 |

## 7. 实施与迁移（DB v12 增量）

> 2026-11-08：v11 已被批次 D 的 `conversations.pinned` 占用，本节顺延至 v12。
> 2026-11-08：本节已全部落地（批次 A），见下方各项 ✅ 与「落地决策」。

1. ✅ 新增 `op_log` 表（§2.2 结构，`createOpLogTable`）+ `change_proposals.status` 枚举加 `superseded` + payload 加 `base` 字段约定（落库时 `ProposalService.captureBase` 捕获）；
2. ✅ 写路径改造：`proposal_executor` 三态裁决管线（§3.2）；人工写路径（任务编辑、完成勾选、锚点增删、优先级标记）统一带 `actor` 参数经 `recordOp` 落 log + 更新物化表（双写，物化表仍是读路径；未引入独立 OpService，op 落账收敛在 `AppDatabase.recordOp`）；
3. ✅ `UndoService` 换底为逆 op（`ProposalExecutor._applyUndo` 全部以 `OpActor.user` 经 op 路径）；
4. ✅ 迁移：现有物化表状态视为「lamport=0 的初始折叠」，不补历史 op；`anchors-v2.md` §6 的锚点迁移与本表同批进行（`migrateToV12` = 建 op_log + `normalizeAnchorsToObjectLevel`）；
5. ✅ 测试：`crdt_merge_test`（LWW 决胜序与全序性质）、`proposal_rebase_test`（三态裁决全分支）、`undo_inverse_op_test`（撤销与并发交叉）、`db_v12_migration_test`。

### 落地决策（实现时收窄，2026-11-08）

- **superseded 粒度 = 整提案**：只要任一涉及字段的 base 漂移且冲突方是人/系统，整条提案置 superseded（卡片提供「以当前状态重新提交」），不做「部分字段生效、部分字段驳回」的逐字段部分生效——整提案语义更简单，也不会产生半执行状态。
- **note.append 的撤销 = 内容寄存器回写**：撤销笔记追加按 lww_set 逆 op 把正文写回追加前内容，不做 §5 设想的「追加段灰显删除线」UI（首版简化；追加集单调性让渡给可读的撤销体验）。
- **审计视图已落地**：设置页「最近错误」旁新增「最近变更」只读页（`RecentOpsPage`，`recentOps(50)`，actor 标注「你 / 助理·对话名 / 系统」）。

## 8. 不变量重申

- 原子化、全量审批、无静默写入：不变。CRDT 管「生效后怎么收敛」，不管「能不能生效」——后者仍是人的权力。
- 桌面端仍无业务逻辑：op 的生成、合并、执行全在手机端。
- 数据模型绝对稳定原则不变：本次为增量（加表、加枚举值、加 payload 字段），无破坏性变更。
