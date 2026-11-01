# LinkModel Desktop（电脑端）

LinkModel 是本地 AI 统一接口（AI 网关，design-v3 §6）：macOS 状态栏托盘应用 + 内嵌 HTTP 服务（`127.0.0.1:8765`）。手机（Flutter）经 `adb reverse` 访问本服务；电脑端只做**模型路由与协议透传**——不解析、不执行模型输出中的工具块，无业务数据、无 dashboard。

## 日常使用：macOS 状态栏应用（无需终端）

安装：

1. `npm run dist` 产出 `release/LinkModel-0.3.0-arm64.dmg`（或拿到 dmg 文件）。
2. 打开 dmg，把 **LinkModel.app** 拖入「应用程序」。
3. 首次启动：应用未签名，需要在「应用程序」里**右键 → 打开**，在弹窗中确认。之后双击/开机自启均可直接运行。

启动后没有任何窗口和 Dock 图标，只在状态栏出现一个气泡图标。启动即自动完成：内嵌 HTTP 服务（`127.0.0.1:8765`）→ 探测 adb → 手机接入自动识别 → 自动 `adb reverse` → 5 秒看护（断线重连、服务掉线重拉、逐模型连通性探测）。

托盘菜单：

| 菜单项 | 说明 |
| --- | --- |
| 服务 | 运行中地址 / 复用已有进程 / 启动失败原因（如端口被占用） |
| 模型 | 可达计数 + 默认模型连通性；不可达时手机端自动改走其他可用模型 |
| 模型列表 | 逐模型状态（● 可达 / ○ 不可达，含 provider 与模型名） |
| 手机 | 已连接设备（型号 + 序列号 + 通道状态）/ 待授权 / 未连接 / 未检测到 adb |
| 最近事件 | 最近 5 条状态事件（时间戳） |
| 配对码 | 复制 / 重置（手机端 401 时会自动重新配对，一般无需手动操作） |
| 重载模型配置 | 重新加载配置文件（等价于 `POST /v1/models/reload`），无需重启应用 |
| 开机自启 | macOS login item 开关 |
| 退出 | 停止内嵌服务并退出 |

状态变化通过系统通知提示：手机已连接/断开、待 USB 授权、模型不可达/恢复、服务启动失败、未检测到 adb。（应用未签名，macOS 可能不弹通知——所有状态以托盘菜单为准。）

### 前置要求：adb

手机经 USB 连接需要 adb（Android Platform Tools）。托盘找不到 adb 时菜单里会出现「复制安装命令」和下载页入口：

```bash
brew install android-platform-tools
```

托盘会依次探测：PATH → `$ANDROID_HOME/platform-tools/adb` → `/opt/homebrew/bin/adb` → `/usr/local/bin/adb` → `~/Library/Android/sdk/platform-tools/adb`。装好 adb 后 5 秒内自动识别，无需重启应用（首次需手机授权 USB 调试）。

### 配置覆盖（模型列表等）

托盘应用配置生效顺序：包内 `config/default.json` → `~/Library/Application Support/LinkModel/config.json`（存在则覆盖合并）。合并语义：标量（host/port/defaultModelId）直接覆盖；`models` 数组**按 id 合并**——同 id 条目字段级浅合并（可只写要改的字段），新 id 追加。改完后托盘菜单点「重载模型配置」即可生效。

数据目录 `~/Library/Application Support/LinkModel/`（pairing.json、config.json），与 CLI 的 `desktop/data/` 相互独立。干净迁移：**不做旧目录迁移**，全新安装后重新配对即可。

## 开发（CLI）

```bash
cd desktop
npm install        # 要求 Node 18+
npm run pair       # 查看/生成配对 token
npm start          # 启动 HTTP 服务（默认 127.0.0.1:8765）
npm run connect    # 开发调试用：拉起/复用服务 + adb reverse + 5 秒看护（日常使用请用托盘应用）
npm run electron   # 开发模式跑托盘应用（tsc + electron .）
npm run dist       # electron-builder 打包 dmg 到 release/
npm run icons      # 重新生成 assets/ 下的托盘/应用图标（程序化绘制，无美术资源）
```

测试与构建：

```bash
npm run build                  # tsc 类型检查 + 编译到 dist/
npx tsx --test src/*.test.ts   # node:test 单元测试（同 CI）
```

实现说明：

- 主进程 `src/electron-main.ts`（编译为 `dist/electron-main.js`，package.json `main` 指向它；Electron 28+ 的 ESM 主进程）。
- HTTP 服务进程内启动（复用 `server.ts`）；若 8765 已被其他 LinkModel 进程占用则直接复用，不重复拉起。
- 模型注册中心 `src/models.ts`（ModelManager）：持有模型列表与 provider 实例，逐模型连通性探测带 30s 缓存，`/v1/models` 与托盘看护共用。
- adb 逻辑在 `src/adb.ts`，CLI（connect.ts）与托盘共用。
- 打包配置在 package.json 的 `build` 字段：`shared/` 经 extraResources 拷入包内（`registry.ts` 有回退路径），不签名（`identity: null`）、asar 关闭、`LSUIElement` 隐藏 Dock 图标。
- 开发环境 Electron 二进制若因 npm install-scripts 拦截未下载，需手动执行 `node node_modules/electron/install.js`。

## HTTP 接口

| 方法 | 路径 | 认证 | 说明 |
| --- | --- | --- | --- |
| GET | `/v1/health` | 免 | 健康检查（含 defaultModelId、模型数） |
| POST | `/v1/pair` | 免 | 自动配对：返回当前 token；`{"reset":true}` 重新签发（需带当前 token，仅 loopback 可达） |
| GET | `/v1/models` | Bearer | 模型列表 + 逐模型连通性探测结果（30s 缓存），供手机助理页拉取展示 |
| POST | `/v1/models/reload` | Bearer | 重载模型配置（default.json ← local.json ← userData/config.json） |
| POST | `/v1/chat` | Bearer | 统一对话接口：SSE 流式透传 token（`token_delta` / `done` / `error` 事件） |

`/v1/chat` 要点（design-v3 §6.3、details §2.4）：

- 请求体按 `shared/schemas/chat-request.schema.json` 校验（ajv）；`modelConfigId` 缺省用配置里的 `defaultModelId`。
- 响应为 SSE（`data: {...}\n\n`），事件格式见 `shared/schemas/chat-response.schema.json`；首版恒为流式。
- desktop **只透传不解析**：工具说明书由手机端组装进消息；模型输出中的 ```` ```tool ```` 工具块原样透传，提案生成与执行都在手机端。
- 顶层 `attachments`（手机端已展开正文、自带 `[#note:标题]` 引用头）拼成一条上下文消息；`tool` 角色消息折叠为带 `[工具执行结果]` 前缀的 user 消息（本地端点对 tool 角色要求 tool_calls 字段）。
- 并发闸按模型 id 分闸（`limit.ts` GatePool）：不同后端并行、同一后端串行，每闸最多排 8 个，超出 429。
- v2 的 `POST /v1/process` 批处理评估管线已随 v3 删除（404）；批处理能力以手机端 `inbox.triage` 工具重生。

## 模型配置

`config/default.json` 为 `models[]` + `defaultModelId` 结构（条目 schema 见 `shared/schemas/model-config.schema.json`）：

```json
{
  "host": "127.0.0.1",
  "port": 8765,
  "models": [
    {"id": "local-gemma", "name": "Gemma 4 26B (本地)", "provider": "openai-compat",
     "baseUrl": "http://127.0.0.1:8080/v1", "model": "gemma-4-26b-a4b-it"}
  ],
  "defaultModelId": "local-gemma"
}
```

- **openai-compat**：本地 llama.cpp 或任何 OpenAI 兼容端点；远程 API 的密钥用 `apiKeyEnv` 指向环境变量（配置里不存密钥）。
- **mock**：内置假模型，无需任何模型服务即可端到端跑通 `/v1/chat` 全链路（联调/测试用）。不进默认配置，需要时在 local.json/userData config.json 里追加。
- **ollama**：暂缓（design-v3 §6.2，无调试设施）。`src/ai/ollama.ts` 代码保留并标记 experimental，不出现在默认配置、schema 枚举与 factory 中。

CLI 本地覆盖用 `config/local.json`（git 忽略），托盘应用覆盖用 userData 的 `config.json`。旧 v2 平铺配置（`provider`/`openai`/`ollama` 字段）不做自动迁移，会被静默忽略。

## 目录

```
config/default.json   默认配置（CLI 可用 config/local.json 覆盖，git 忽略）
data/                 CLI 运行期数据（pairing.json，git 忽略）
assets/               托盘/应用图标（npm run icons 生成）
scripts/make-icons.mjs 图标生成脚本
src/                  index.ts(CLI) connect.ts(开发用连接看护) electron-main.ts(托盘主进程)
                      adb.ts auth.ts config.ts limit.ts models.ts registry.ts server.ts types.ts ai/
```
