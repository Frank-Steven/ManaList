# ManaList

手机通知采集 + AI 助理的个人信息管理应用（原 MsgRepo，v3 起改名 ManaList）。

核心理念（设计 v3）：**库 / 任务 / 助理三主 Tab —— 消息只是库的数据源，AI 助理通过「原子工具提案 + 人工审批」操作应用。**

- **手机端**（Flutter/Android）持有全部数据与全部 UI：库（笔记 markdown / 消息 / 文件区）、任务（列表/日/月/年四视图 + 子任务 + 本地提醒）、助理（对话 + 待确认区审批 + inbox.triage 批量评估提案生成器）、任务锚点（笔记/消息/文件 ↔ 任务的双向链接）、存档导出/导入（zip 全量备份）。
- **电脑端 LinkModel**（Electron 状态栏应用）：本地 AI 统一接口（AI 网关）——模型列表与配置（`GET /v1/models`）、统一对话接口（`POST /v1/chat`，SSE 透传）、维护 adb 通道。无业务数据、无 dashboard、不解析不执行 AI 工具调用。
- **AI 路由**：手机检测到电脑端在线（health 探测）→ 用电脑端模型（USB adb 通道，自动配对零配置）；否则用助理对话绑定的远程 OpenAI 兼容 API。
- **数据不出本机**：USB 物理通道即信任；AI 推理在本地或用户自选的远程 API。

## 目录结构

```
mobile/    手机端 ManaList（Flutter，Android；包名 msgrepo_mobile，标识符沿用未改）
desktop/   电脑端 LinkModel（Electron 状态栏应用 + 本地 AI 网关，TypeScript）
shared/    两端共享的 JSON Schema 契约（锚点/对话/模型配置）
docs/      设计文档（现行设计见 docs/design-v3.md + docs/design-v3-details.md）
```

## 构建运行

手机端（需要 Flutter SDK 与 Android 工具链）：

```bash
cd mobile
flutter pub get
flutter test                  # 单元/widget 测试
flutter build apk --debug     # 出 debug 包
flutter run                   # 真机/模拟器运行
```

实机覆盖安装用 `adb install -r`（禁用 `flutter install`，它会先卸载导致数据丢失）。

电脑端（需要 Node.js）：

```bash
cd desktop
npm install
npm run connect    # adb reverse 通道看护（自动重连）
npm run electron   # 状态栏托盘应用（开发期）
npm run dist       # 打包 macOS dmg（electron-builder）
```

## 文档

| 文档 | 内容 |
|---|---|
| [docs/design-v3.md](docs/design-v3.md) | **现行设计**（v3：库/任务/助理、锚点、工具协议、待确认区、存档） |
| [docs/design-v3-details.md](docs/design-v3-details.md) | v3 机制定稿（marker 语法、工具协议细化、inbox.triage、存档格式） |
| [docs/refactor-v3.md](docs/refactor-v3.md) | v2 → v3 重构操作记录（分阶段 commit） |
| docs/design-v2.md / docs/refactor-v2.md | v2 历史文档（已 superseded，保留作参考） |
| docs/architecture.md / data-model.md / protocol.md / ai-pipeline.md / extensibility.md | v1 历史文档，保留作参考 |
