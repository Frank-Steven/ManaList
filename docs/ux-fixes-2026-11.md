# 缺陷修复方案与人体工学改善（2026-11-08）

> 状态：v1.0（2026-11-08）
> 内容：①应用图标缓存导致首屏不显示图标的修复；②华为鸿蒙 4.0 机器上应用名显示为包名的排查与修复；③全 App 人体工学细节改善清单。
> 实施时按本文档位落码；与 `ui-structure.md` 冲突处以本文档为准并回写。

---

## 1. 修复：图标缓存导致页面首次加载不显示图标

### 1.1 根因分析（代码审计结论）

现状链路：`AppIcon`（`mobile/lib/ui/shared/app_icon.dart`）每个实例独立 `initState → AppIconService.iconFor()`（`mobile/lib/services/app_icon_service.dart`），首次加载要串行经过：两次 `path_provider` 平台往返（`getApplicationSupportDirectory` + `getTemporaryDirectory` 回退检查）→ 磁盘读 → 方法通道 `getAppIcon`（Kotlin 侧再开线程查 PackageManager + 位图缩放 + PNG 编码）。三个叠加缺陷：

1. **加载期渲染空白**：`app_icon.dart:68-70` 在未加载完成时返回空 `SizedBox`——首屏所有图标位是纯空白，用户感知即「不显示图标」；
2. **瞬时失败被永久记忆**：`_load` 的 `catch` 把磁盘/通道任何异常（含竞态、线程调度失败）都落为 `_mem[pkg] = null`（`app_icon_service.dart:64-68`），语义是「已确认无图标，不再重复查询」——**一次瞬时失败，本次会话内该图标永不出现**；
3. **无预热**：列表首帧先渲染、图标后异步逐个补齐，滚动中每个新图标都重走整条链。

### 1.2 修复方案

| # | 改动 | 位置 |
|---|---|---|
| 1 | 新增同步快路径 `AppIconService.cached(pkg)`：build 时同步查内存表，命中即当帧渲染，零闪烁 | `app_icon_service.dart` |
| 2 | 未命中时渲染「应用名首字符占位块」（即现有无图标兜底样式），不再用空 `SizedBox`；字节到达后原位替换 | `app_icon.dart` |
| 3 | **区分失败类型**：仅 Kotlin 侧明确返回「包不存在」（`NameNotFoundException` 映射的特定结果）才记忆 null；通道异常/IO 异常不写入 `_mem`，下次 build 自然重试 | `app_icon_service.dart` + `MainActivity.kt` `getAppIcon` 错误回传细分 |
| 4 | 磁盘写失败不影响返回字节（现状写盘异常被外层 catch 吞成 null 返回）；读盘/取通道/写盘三段各自 try | `app_icon_service.dart` `_load` 重构 |
| 5 | **批量预热**：消息页/库页数据加载后，对首屏可见包名集合调一次 `prewarm(packages)`；Kotlin 侧新增 `getAppIcons`（批量，单线程遍历，逐张 PNG）减少 N 次通道往返；磁盘命中直接进内存表 | `app_icon_service.dart`、`MainActivity.kt`、`messages_page.dart` |
| 6 | 平台侧 `appIconPng` 增加自适应图标兜底：`getApplicationIcon` 返回的 AdaptiveIconDrawable 在某些 ROM 上 `intrinsicWidth ≤ 0`，导致 `drawableToBitmap` 产出 1×1 空图——宽高回退为固定 96px 画布再 draw | `MainActivity.kt` `drawableToBitmap` |

验证：`messages_page` 冷启动首帧即见全部组头图标（预热在数据就绪同帧完成）；飞行模式下断通道重试后图标可恢复；新增 `app_icon_service_test`（null 仅在包不存在时记忆、写盘失败仍返回字节、prewarm 合并并发）。

## 2. 修复：鸿蒙 4.0（华为）上应用名显示为包名

报告现象：ManaList 在开发机正常，在华为鸿蒙 4.0（EMUI 底，非纯血 HarmonyOS NEXT）机器上**显示为包名**。按发生面分两个独立问题，分别修复。

### 2.1 库内「来源应用名」显示为包名（高概率主因）

根因：`NotificationCaptureService.kt:188-193` 采集时用 `getApplicationLabel` 解析应用名，**失败即回退为 packageName 并永久固化**进消息行与 `seen_apps.json`；`messages_page.dart:301-306` 展示链 `appName ?? pkg` 无法区分「真名字」和「当初没解析出来的包名」。鸿蒙上 label 解析失败率显著更高（双开应用、工作资料、预置冻结应用、ROM 的 PackageManager 缓存差异），于是消息流里成片显示包名。

修复：

1. **入库不再固化失败值**：`appName == packageName`（解析失败回退）时 `emit` 写空串而非包名；`recordSeenApp` 同理；
2. **显示层懒解析回填**：新增平台方法 `getAppName(packageName)`（Kotlin `getApplicationLabel`，异常返回 null）；Dart 侧 `AppNameService`（内存缓存 + 与图标同款 inflight 合并）：消息行的 appName 为空/等于包名时触发重解析，成功后**回填 DB**（`messages.appName`、`seen_apps.json` 下次 flush 生效）；
3. **批量修复存量**：设置页「来源应用」列表加载时，对所有 `appName` 为空/等于包名的条目调用 `getInstalledApps`（已有，返回正确 label）做一次批量回填；
4. 展示兜底链改为 `解析名 → 重解析 → 包名`，包名永不再作为持久值出现。

### 2.2 启动器桌面图标下名称显示为包名（若报告指此现象）

排查结论与修复：

1. **MainActivity 缺 `android:label`**：`AndroidManifest.xml` 仅 `<application android:label="ManaList">`，`<activity>` 未声明 label。AOSP 规范下启动器应回退到 application label，但 EMUI/鸿蒙桌面部分版本直接读取 launcher activity 的 label，缺失时异常回退为包名。**修复**：`<activity android:label="@string/app_name">`，同时 `<application>` 的 label 也统一改为 `@string/app_name` 引用（单一事实源在 `res/values/strings.xml`，已是 "ManaList"）；
2. **桌面缓存**：鸿蒙桌面有名称/图标缓存，修复包安装后若仍显示旧值，需重启桌面或重装验证——写入发版说明；
3. **验证手段**（问题机）：`adb shell cmd package resolve-activity --brief <pkg>` 与 `dumpsys package <pkg> | grep -A2 launcher` 确认 label 解析结果；验收标准为桌面与「设置→应用管理」均显示 ManaList。

## 3. 人体工学改善清单（全 App）

原则：手机单手竖屏为主场景；拇指热区在屏幕下 2/3；少打断、可撤销优先于确认框。

### 3.1 触控与手势

| # | 改善 | 说明 |
|---|---|---|
| 1 | 命中区审计 | 全部 icon button / chip / 勾选框视觉可小于 48dp，但命中区 ≥48×48dp（`TapTargetSize` / 透明 padding）；重点：提案卡双键、筛选 chip、列表行尾图标 |
| 2 | 手势语言统一 | 右滑 = 积极（归档/通过），左滑 = 消极/管理（垃圾/删除/拒绝），全 App 一致；消息列表与提案卡对齐（`assistant-v4.md` §4.3） |
| 3 | 滑动阈值标定 | 滑动触发距离 ≥ 列表行高 40%，途中可回弹取消；与任务面板短促拖拽判定（`_tapDragMaxMs`）同一思路：慢速小位移永远不算手势 |
| 4 | 触觉分级 | 轻振=选择切换/勾选；中振=审批通过/任务完成；不振=拒绝/取消；破坏性操作确认时一次重振 |

### 3.2 布局与可达性

| # | 改善 | 说明 |
|---|---|---|
| 5 | 主操作下沉 | 高频确认动作一律在拇指热区：待确认区批量条、附件选择确认、提案双键已在底部——审计所有新 sheet，禁止把主确认按钮放顶栏 |
| 6 | 顶部只放「看」，不放「做」 | AppBar actions 限导航/筛选类低频入口；破坏性操作不进 AppBar |
| 7 | 长列表定位 | 消息/文件列表滚动 >3 屏后右下角出现「回顶」小 FAB（滚动到顶后自动消失），与主 FAB 错层 |
| 8 | 键盘协同 | 输入区上贴键盘（adjustResize 已有）；打开键盘时附件条自动收起为单行；发送后键盘不收起（连续对话场景），仅点消息流空白处收起 |

### 3.3 反馈与防错

| # | 改善 | 说明 |
|---|---|---|
| 9 | 确认分级矩阵 | 沿用 `ui-structure.md` §4 裁决并补全：可撤销→SnackBar；不可撤销但影响单对象→dialog；影响多对象（批量删除/清空）→dialog + 输入对象计数确认（「删除 12 项」按钮文字含计数） |
| 10 | 加载骨架 | 库/任务/助理三列表首加骨架屏（行状 shimmer），替代白屏 + 转圈；数据 <300ms 到达时不闪骨架（最小展示时长反打） |
| 11 | 空态即引导 | 沿用 §7 空态标准，补：空态主按钮文案与 FAB 一致（动词短语），并附一句「为什么这里是空的」 |
| 12 | 感知性能 | 列表图片全部 `cacheWidth` 限解码（文件区已做，补消息附件预览）；首屏外图片懒解码；动画分档：微交互 150ms / 卡片 200ms / 页面 250–300ms，超 300ms 的动画全 App 禁止 |
| 13 | 数字与等宽 | 等宽数字（tnum）已全局；补：计数变化（待确认角标、已选 N 项）用 AnimatedSwitcher 位次滚动而非硬跳 |

### 3.4 阅读与密度

| # | 改善 | 说明 |
|---|---|---|
| 14 | 正文行高 | 中文正文 lineHeight ≥1.5；markdown 正文 16sp/1.6；列表副标题 12sp 下限（不再出现 10sp 以下） |
| 15 | 对比度审计 | 副标题/脚注用 `onSurfaceVariant`（现有个别 hardcode 灰值收编）；状态色点同时配图标/文字（色盲友好，颜色不单独立义） |
| 16 | 动态字号 | 系统字体放大 1.3× 内布局不破：提案卡、消息卡、任务行做 TextScaler 弹性测试；超出时截断策略为「标题先省略、时间永不省略」 |

### 3.5 误触与恢复

| # | 改善 | 说明 |
|---|---|---|
| 17 | 连续操作防连击 | 发送/通过/保存按钮在结果返回前禁用 + 按钮内转圈，杜绝双击双提交（网络慢时尤其） |
| 18 | 撤销可达性 | SnackBar 撤销期限 10s（现状）保持；撤销入口同时进 op log 审计视图（`crdt.md` §5），超时后仍可追溯 |
| 19 | 返回不丢 | 编辑器返回即保存（已有）扩展到附件选择/模型选择的选择态（返回 = 确认所选，与「确认」按钮同效），消除「选了半天下滑返回全丢」 |

## 4. 实施批次

| 批次 | 内容 | 验证 |
|---|---|---|
| F1 | 图标缓存修复（§1） | ✅ 2026-11-08 已落地：冷启动首帧图标齐；`app_icon_service_test` 13 项 |
| F2 | 应用名修复（§2.1 库内名称；§2.2 manifest label） | ✅ 2026-11-08 已落地（代码侧）；鸿蒙问题机实机验收待做 |
| F3 | 人体工学 3.1/3.2（触控、手势、可达性） | 命中区 lint 检查 + 手感走查 |
| F4 | 人体工学 3.3–3.5（反馈、密度、防错） | 动态字号测试；动画时长审计 |

F1/F2 为缺陷修复，优先于一切体验批次；F3/F4 可与 `assistant-v4.md` 的实施批次交错落地。
