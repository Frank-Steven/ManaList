import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";

import { loadConfig } from "./config.js";

// v3 配置加载：default.json ← local.json ← 追加覆盖文件；models 按 id 合并（design-v3 §6.2）。
// 注意：仓库里存在 config/local.json（local-gemma 覆盖），断言只关心相对变化，不假设其不存在。

const tmp = mkdtempSync(path.join(os.tmpdir(), "linkmodel-config-"));

function writeOverride(name: string, obj: unknown): string {
  const p = path.join(tmp, name);
  writeFileSync(p, JSON.stringify(obj));
  return p;
}

test("默认配置：models 非空且 defaultModelId 指向其中一项", () => {
  const cfg = loadConfig();
  assert.ok(Array.isArray(cfg.models));
  assert.ok(cfg.models.length >= 1);
  assert.ok(cfg.models.some((m) => m.id === cfg.defaultModelId));
  assert.equal(typeof cfg.host, "string");
  assert.equal(typeof cfg.port, "number");
});

test("标量覆盖：port/defaultModelId 直接替换", () => {
  const cfg = loadConfig([writeOverride("scalar.json", { port: 9999, defaultModelId: "local-gemma" })]);
  assert.equal(cfg.port, 9999);
  assert.equal(cfg.defaultModelId, "local-gemma");
});

test("models 按 id 合并：同 id 字段级浅合并，新 id 追加", () => {
  const base = loadConfig();
  const cfg = loadConfig([
    writeOverride("models.json", {
      models: [
        { id: "local-gemma", model: "gemma-custom" }, // 只改一个字段
        { id: "mock-x", name: "Mock X", provider: "mock", baseUrl: "", model: "mock-chat" },
      ],
    }),
  ]);
  assert.equal(cfg.models.length, base.models.length + 1, "新 id 追加，同 id 不新增");
  const gemma = cfg.models.find((m) => m.id === "local-gemma")!;
  assert.equal(gemma.model, "gemma-custom");
  assert.equal(gemma.provider, "openai-compat", "未覆盖的字段保留默认值");
  assert.ok(cfg.models.some((m) => m.id === "mock-x"));
});

test("多个覆盖文件按顺序应用", () => {
  const cfg = loadConfig([
    writeOverride("a.json", { port: 9001 }),
    writeOverride("b.json", { port: 9002 }),
  ]);
  assert.equal(cfg.port, 9002);
});

test("旧 v2 平铺配置键静默忽略（干净迁移策略，不自动改写）", () => {
  const cfg = loadConfig([
    writeOverride("legacy.json", {
      provider: "ollama",
      ollama: { baseUrl: "http://127.0.0.1:11434", model: "qwen2.5:7b" },
      openai: { baseUrl: "http://x", model: "y", apiKeyEnv: "Z" },
    }),
  ]) as unknown as Record<string, unknown>;
  assert.equal("provider" in cfg, false);
  assert.equal("ollama" in cfg, false);
  assert.equal("openai" in cfg, false);
});

test("loadConfig 不污染默认值（每次重新读文件）", () => {
  loadConfig([writeOverride("pollute.json", { port: 1 })]);
  assert.equal(loadConfig().port, 8765);
});

test("清理临时目录", () => {
  rmSync(tmp, { recursive: true, force: true });
});
