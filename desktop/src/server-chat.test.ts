import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import type { AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";

import { PairingManager } from "./auth.js";
import { createServer } from "./server.js";
import { ModelManager, type ModelListEntry } from "./models.js";
import type { Config } from "./config.js";
import type { ChatEvent } from "./types.js";

// v3 路由测试：/v1/models、/v1/models/reload、/v1/chat（mock provider），
// 以及 /v1/process 已删除（404）。
const dataDir = mkdtempSync(path.join(os.tmpdir(), "linkmodel-chat-"));
let server: ReturnType<typeof createServer>;
let base = "";
const pairing = new PairingManager(dataDir);

let config: Config = {
  host: "127.0.0.1",
  port: 0,
  models: [
    { id: "mock-1", name: "Mock", provider: "mock", baseUrl: "", model: "mock-chat" },
    { id: "dead", name: "Dead", provider: "openai-compat", baseUrl: "http://127.0.0.1:9/v1", model: "x" },
  ],
  defaultModelId: "mock-1",
};

const auth = () => ({ Authorization: `Bearer ${pairing.token}` });

before(async () => {
  server = createServer({
    host: "127.0.0.1",
    port: 0,
    pairing,
    models: new ModelManager(() => config, 500),
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const addr = server.address() as AddressInfo;
  base = `http://127.0.0.1:${addr.port}`;
});

after(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
  rmSync(dataDir, { recursive: true, force: true });
});

test("GET /v1/models 无认证 → 401", async () => {
  const res = await fetch(`${base}/v1/models`);
  assert.equal(res.status, 401);
});

test("GET /v1/models 返回列表 + 逐模型连通性", async () => {
  const res = await fetch(`${base}/v1/models`, { headers: auth() });
  assert.equal(res.status, 200);
  const body = (await res.json()) as { defaultModelId: string; models: ModelListEntry[] };
  assert.equal(body.defaultModelId, "mock-1");
  assert.equal(body.models.length, 2);
  const mock = body.models.find((m) => m.id === "mock-1")!;
  assert.equal(mock.reachable, true);
  assert.equal(mock.provider, "mock");
  const dead = body.models.find((m) => m.id === "dead")!;
  assert.equal(dead.reachable, false);
  // 密钥相关字段不外泄之外的配置字段照常返回
  assert.equal(typeof mock.checkedAt, "number");
});

test("POST /v1/models/reload 重载配置", async () => {
  config = { ...config, models: [config.models[0]] };
  const res = await fetch(`${base}/v1/models/reload`, { method: "POST", headers: auth() });
  assert.equal(res.status, 200);
  const body = (await res.json()) as { models: ModelListEntry[] };
  assert.equal(body.models.length, 1);
  // 还原，避免影响后续用例
  config = { ...config, models: [...config.models, { id: "dead", name: "Dead", provider: "openai-compat", baseUrl: "http://127.0.0.1:9/v1", model: "x" }] };
  await fetch(`${base}/v1/models/reload`, { method: "POST", headers: auth() });
});

test("POST /v1/chat 无认证 → 401", async () => {
  const res = await fetch(`${base}/v1/chat`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({}),
  });
  assert.equal(res.status, 401);
});

test("POST /v1/chat 请求体不合 schema → 400", async () => {
  const res = await fetch(`${base}/v1/chat`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...auth() },
    // 缺必填的 conversationId
    body: JSON.stringify({ messages: [{ role: "user", content: "hi" }], stream: true }),
  });
  assert.equal(res.status, 400);
  const body = (await res.json()) as { error: string };
  assert.match(body.error, /invalid chat request/);
});

test("POST /v1/chat 未知 modelConfigId → 400", async () => {
  const res = await fetch(`${base}/v1/chat`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...auth() },
    body: JSON.stringify({
      conversationId: "c1",
      messages: [{ role: "user", content: "hi" }],
      modelConfigId: "nope",
      stream: true,
    }),
  });
  assert.equal(res.status, 400);
  assert.match(((await res.json()) as { error: string }).error, /未知模型配置/);
});

/** 读取 SSE 流，解析全部 data: 事件。 */
async function readSse(res: Response): Promise<ChatEvent[]> {
  const text = await res.text();
  return text
    .split("\n")
    .filter((l) => l.startsWith("data: "))
    .map((l) => JSON.parse(l.slice(6)) as ChatEvent);
}

test("POST /v1/chat（mock）：SSE 逐条 token_delta，done 收尾", async () => {
  const res = await fetch(`${base}/v1/chat`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...auth() },
    body: JSON.stringify({
      conversationId: "c1",
      messages: [
        { role: "user", content: "帮我整理一下今天的通知" },
        { role: "assistant", content: "好的" },
        { role: "tool", content: "已创建任务" },
        { role: "user", content: "继续" },
      ],
      attachments: [{ type: "note", id: "n1", content: "[#note:购物清单]\n牛奶、鸡蛋" }],
      stream: true,
    }),
  });
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type") ?? "", /text\/event-stream/);
  const events = await readSse(res);
  const tokens = events.filter((e) => e.type === "token_delta");
  assert.ok(tokens.length > 1, "mock 应按多段流式输出");
  const full = tokens.map((t) => (t as { delta: string }).delta).join("");
  assert.match(full, /mock 回复/);
  assert.match(full, /继续/, "末条用户消息应被回显");
  assert.deepEqual(events.at(-1), { type: "done" });
  assert.ok(!events.some((e) => e.type === "error"));
});

test("POST /v1/chat（mock）：图片附件 → content parts，回复带图像计数", async () => {
  const res = await fetch(`${base}/v1/chat`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...auth() },
    body: JSON.stringify({
      conversationId: "c-img",
      messages: [{ role: "user", content: "这张图里有什么" }],
      attachments: [
        {
          type: "file",
          id: "f1",
          content: "[#file:照片.png]（image/png）\n[图像已内联：640×480 PNG]",
          mimeType: "image/png",
          dataBase64: "aGVsbG8=", // 内容不解码，仅透传
        },
      ],
      stream: true,
    }),
  });
  assert.equal(res.status, 200);
  const events = await readSse(res);
  const full = events
    .filter((e) => e.type === "token_delta")
    .map((t) => (t as { delta: string }).delta)
    .join("");
  assert.match(full, /含 1 张图片/, "含 dataBase64 的附件应组装为图像块");
  assert.deepEqual(events.at(-1), { type: "done" });
});

test("POST /v1/chat 缺省 modelConfigId 走默认模型", async () => {
  const res = await fetch(`${base}/v1/chat`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...auth() },
    body: JSON.stringify({
      conversationId: "c2",
      messages: [{ role: "user", content: "hi" }],
      stream: true,
    }),
  });
  assert.equal(res.status, 200);
  const events = await readSse(res);
  assert.deepEqual(events.at(-1), { type: "done" });
});

test("POST /v1/chat 路由到不可达模型 → SSE error 事件（HTTP 仍 200）", async () => {
  const res = await fetch(`${base}/v1/chat`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...auth() },
    body: JSON.stringify({
      conversationId: "c3",
      messages: [{ role: "user", content: "hi" }],
      modelConfigId: "dead",
      stream: true,
    }),
  });
  assert.equal(res.status, 200);
  const events = await readSse(res);
  assert.equal(events.at(-1)?.type, "error");
});

test("旧 POST /v1/process 已删除 → 404", async () => {
  const res = await fetch(`${base}/v1/process`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...auth() },
    body: JSON.stringify({ messages: [{ id: "1", title: "t" }] }),
  });
  assert.equal(res.status, 404);
});
