import assert from "node:assert/strict";
import { test } from "node:test";

import {
  configuredVision,
  isKnownVisionModel,
  normalizeModelId,
  resolveVisionSupport,
  visionAllowsImages,
} from "./model-capabilities.js";
import { ModelManager } from "./models.js";
import { buildProviderMessages } from "./server.js";
import type { Config } from "./config.js";
import type { ChatRequest } from "./types.js";

// B11/B10 回归：视觉能力三态识别 + desktop 自己的图片门禁。
// 真机事实：DeepSeek V4.1 Flash 1017 支持图片输入，但旧配置 vision 缺省 false 被误判，
// 图片被剥成文字；同时 desktop 原先无条件内联图片（B10）。

test("normalizeModelId：小写 + 去空白 + 去 provider 前缀", () => {
  assert.equal(normalizeModelId("  DeepSeek-Flash "), "deepseek-flash");
  assert.equal(normalizeModelId("deepseek/deepseek-v4.1-flash"), "deepseek-v4.1-flash");
  assert.equal(normalizeModelId("openai/1017"), "1017");
  assert.equal(normalizeModelId("deepseek-flash-plus"), "deepseek-flash-plus");
});

test("已知识别：deepseek-flash / deepseek-v4.1-flash / 1017", () => {
  for (const m of ["deepseek-flash", "deepseek-v4.1-flash", "1017"]) {
    assert.equal(isKnownVisionModel(m), true, m);
    assert.equal(resolveVisionSupport(m), "supported", m);
  }
});

test("别名与大小写/前缀命中", () => {
  assert.equal(resolveVisionSupport("DeepSeek-V4.1-Flash-1017"), "supported");
  assert.equal(resolveVisionSupport("deepseek/deepseek-flash"), "supported");
});

test("显式关闭优先：已知模型也不破例", () => {
  assert.equal(resolveVisionSupport("deepseek-flash", false), "disabled");
  assert.equal(visionAllowsImages("disabled"), false);
});

test("显式开启：未知模型也照发", () => {
  assert.equal(resolveVisionSupport("some-local-model", true), "supported");
  assert.equal(visionAllowsImages("supported"), true);
});

test("未知安全默认：unknown 且不放行图片", () => {
  assert.equal(resolveVisionSupport("gpt-4o"), "unknown");
  assert.equal(resolveVisionSupport(""), "unknown");
  assert.equal(visionAllowsImages("unknown"), false);
});

function chatWithImage(): ChatRequest {
  return {
    conversationId: "c1",
    stream: true,
    messages: [{ role: "user", content: "看看这张图" }],
    attachments: [
      {
        type: "file",
        id: "f1",
        content: "[#file:截图]",
        mimeType: "image/png",
        dataBase64: "AAAA",
      },
    ],
  };
}

test("B10 图片门禁：vision=true 内联 image_url 内容块", () => {
  const out = buildProviderMessages(chatWithImage(), true);
  const first = out[0] as { content: unknown };
  assert.ok(Array.isArray(first.content), "vision=true 时应为 content parts");
  const parts = first.content as Array<{ type: string }>;
  assert.equal(parts.filter((p) => p.type === "image_url").length, 1);
});

test("B10 图片门禁：vision=false 只发文本，绝不带 image_url", () => {
  const out = buildProviderMessages(chatWithImage(), false);
  const first = out[0] as { content: unknown };
  assert.equal(typeof first.content, "string", "vision=false 时必须是纯文本");
  assert.equal(JSON.stringify(out).includes("image_url"), false);
});

test("/v1/models 条目带上 visionStatus / visionEffective（已知识别）", async () => {
  const config: Config = {
    host: "127.0.0.1",
    port: 8765,
    models: [
      { id: "ds", name: "DeepSeek", provider: "mock", baseUrl: "", model: "deepseek-v4.1-flash" },
      // 显式关闭（visionExplicit: true）→ 上报 disabled
      { id: "off", name: "Closed", provider: "mock", baseUrl: "", model: "deepseek-flash", vision: false, visionExplicit: true },
      // B12 回归：旧 false（无 visionExplicit）+ 已知视觉模型 → 上报 supported（不再误报关闭）
      { id: "legacy-false", name: "LegacyFalse", provider: "mock", baseUrl: "", model: "deepseek-flash", vision: false },
      // 旧 true（无 visionExplicit）+ 未知模型 → 仍按用户开启上报 supported
      { id: "legacy-true", name: "LegacyTrue", provider: "mock", baseUrl: "", model: "some-unknown-model", vision: true },
      { id: "unknown", name: "X", provider: "mock", baseUrl: "", model: "gpt-4o" },
    ],
    defaultModelId: "ds",
  };
  const list = await new ModelManager(() => config, 500).probeAll();
  const byId = new Map(list.map((e) => [e.id, e]));
  assert.equal(byId.get("ds")?.visionStatus, "supported");
  assert.equal(byId.get("ds")?.visionEffective, true);
  assert.equal(byId.get("off")?.visionStatus, "disabled");
  assert.equal(byId.get("off")?.visionEffective, false);
  // B12：/v1/models 与 /v1/chat 共用 configuredVision 后，旧 false 的已知模型必须恢复 supported
  assert.equal(byId.get("legacy-false")?.visionStatus, "supported");
  assert.equal(byId.get("legacy-false")?.visionEffective, true);
  assert.equal(byId.get("legacy-true")?.visionStatus, "supported");
  assert.equal(byId.get("legacy-true")?.visionEffective, true);
  assert.equal(byId.get("unknown")?.visionStatus, "unknown");
  assert.equal(byId.get("unknown")?.visionEffective, false);
});

// ---- B12：桌面旧配置兼容（vision 三态归一）----

const baseModel = {
  id: "m1",
  name: "M1",
  provider: "mock" as const,
  baseUrl: "",
  model: "deepseek-flash",
};

test("B12 configuredVision：旧 true 保留、旧 false 视为未配置、显式 false 关闭", () => {
  // 缺省 / null → 未配置
  assert.equal(configuredVision(undefined), null);
  assert.equal(configuredVision({ ...baseModel }), null);
  assert.equal(configuredVision({ ...baseModel, vision: null }), null);
  // 旧 true（无 visionExplicit）必须保留为「用户开启」
  assert.equal(configuredVision({ ...baseModel, vision: true }), true);
  // 旧 false（无 visionExplicit）是旧默认值 → 未配置
  assert.equal(configuredVision({ ...baseModel, vision: false }), null);
  // 新配置：显式 false 才是「用户关闭」
  assert.equal(
    configuredVision({ ...baseModel, vision: false, visionExplicit: true }),
    false,
  );
  assert.equal(
    configuredVision({ ...baseModel, vision: true, visionExplicit: true }),
    true,
  );
});

test("B12 归一后接能力表：旧 false 的已知模型 → supported；显式 false → disabled", () => {
  const legacyFalseKnown = resolveVisionSupport(
    "deepseek-flash",
    configuredVision({ ...baseModel, vision: false }),
  );
  assert.equal(legacyFalseKnown, "supported", "旧 false 无 explicit 时已知模型应恢复支持");

  const explicitOff = resolveVisionSupport(
    "deepseek-flash",
    configuredVision({ ...baseModel, vision: false, visionExplicit: true }),
  );
  assert.equal(explicitOff, "disabled", "显式关闭必须严格生效");

  const legacyTrueUnknown = resolveVisionSupport(
    "some-unknown-model",
    configuredVision({ ...baseModel, vision: true }),
  );
  assert.equal(legacyTrueUnknown, "supported", "旧 true 即使模型未知也必须保留支持");
});

test("B12 /v1/models：旧 false 的已知模型上报 supported，显式 false 仍 disabled", async () => {
  const config: Config = {
    host: "127.0.0.1",
    port: 8765,
    models: [
      // 旧默认值写法：vision:false 且无 visionExplicit，模型是已知视觉模型
      { id: "legacy-false", name: "LegacyFalse", provider: "mock", baseUrl: "", model: "deepseek-flash", vision: false },
      // 用户显式关闭
      { id: "explicit-off", name: "ExplicitOff", provider: "mock", baseUrl: "", model: "deepseek-flash", vision: false, visionExplicit: true },
      // 未配置 + 未知模型 → 安全默认
      { id: "unknown", name: "X", provider: "mock", baseUrl: "", model: "gpt-4o" },
    ],
    defaultModelId: "legacy-false",
  };
  const byId = new Map((await new ModelManager(() => config, 500).probeAll()).map((e) => [e.id, e]));
  // B12 回归：上报侧与 /v1/chat 门禁同语义，旧 false 不再被误报成「用户关闭」
  assert.equal(byId.get("legacy-false")?.visionStatus, "supported");
  assert.equal(byId.get("legacy-false")?.visionEffective, true);
  assert.equal(byId.get("explicit-off")?.visionStatus, "disabled");
  assert.equal(byId.get("explicit-off")?.visionEffective, false);
  assert.equal(byId.get("unknown")?.visionStatus, "unknown");
  assert.equal(byId.get("unknown")?.visionEffective, false);
});
