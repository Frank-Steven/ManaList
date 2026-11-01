import assert from "node:assert/strict";
import { test } from "node:test";

import { ModelManager } from "./models.js";
import type { Config } from "./config.js";

const baseConfig: Config = {
  host: "127.0.0.1",
  port: 8765,
  models: [
    { id: "mock-1", name: "Mock", provider: "mock", baseUrl: "", model: "mock-chat" },
    // 127.0.0.1:9 是 discard 端口，连接即被拒（不会像超时那样拖慢测试）
    { id: "dead", name: "Dead", provider: "openai-compat", baseUrl: "http://127.0.0.1:9/v1", model: "x" },
  ],
  defaultModelId: "mock-1",
};

test("providerFor / modelFor 按 id 路由", () => {
  const m = new ModelManager(() => baseConfig);
  assert.equal(m.providerFor("mock-1")?.name, "mock");
  assert.equal(m.providerFor("dead")?.name, "openai-compat");
  assert.equal(m.providerFor("nope"), undefined);
  assert.equal(m.modelFor("dead")?.model, "x");
});

test("defaultModelId 无效时回退到第一个模型", () => {
  const m = new ModelManager(() => ({ ...baseConfig, defaultModelId: "gone" }));
  assert.equal(m.defaultModelId, "mock-1");
});

test("探测：mock 恒可达，被拒端口不可达", async () => {
  const m = new ModelManager(() => baseConfig, 500);
  assert.equal((await m.probe("mock-1")).ok, true);
  assert.equal((await m.probe("dead")).ok, false);
  assert.equal((await m.probe("nope")).ok, false);
});

test("探测结果带缓存：TTL 内不重复探测（checkedAt 不变）", async () => {
  const m = new ModelManager(() => baseConfig, 500);
  const first = await m.probe("dead");
  const second = await m.probe("dead");
  assert.equal(second.checkedAt, first.checkedAt);
  const forced = await m.probe("dead", true);
  assert.ok(forced.checkedAt >= first.checkedAt);
});

test("probeAll 返回全部模型条目", async () => {
  const m = new ModelManager(() => baseConfig, 500);
  const list = await m.probeAll();
  assert.equal(list.length, 2);
  assert.equal(list.find((e) => e.id === "mock-1")?.reachable, true);
  assert.equal(list.find((e) => e.id === "dead")?.reachable, false);
});

test("reload 重跑 loadConfig 闭包并清空探测缓存", async () => {
  let cfg = baseConfig;
  const m = new ModelManager(() => cfg, 500);
  await m.probe("dead");
  cfg = {
    ...baseConfig,
    models: [baseConfig.models[0]],
    defaultModelId: "mock-1",
  };
  m.reload();
  assert.equal(m.models.length, 1);
  assert.equal(m.providerFor("dead"), undefined);
  // 缓存已清空：未知 id 探测不命中旧缓存
  assert.equal((await m.probe("dead")).ok, false);
});
