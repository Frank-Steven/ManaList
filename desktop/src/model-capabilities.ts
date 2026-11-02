// 模型视觉能力（多模态图像输入）判定（B11）。
//
// 与 mobile/lib/services/model_capabilities.dart **逐条同语义**（两端各自实现，避免跨语言
// 运行期依赖；shared/schemas/model-config.schema.json 的 vision 段落是事实源）：
// - 只有 bool 时无法区分「用户关闭」与「历史上从未配置」，已知支持视觉的模型会被误判为
//   不支持（B11 真机现象：DeepSeek V4.1 Flash 1017 的图片被剥成文字）；
// - 未知模型也不能冒充支持，因此保留 unknown：语义上等同「不发送图片」，但可以如实上报。

import type { ModelConfig } from "./types.js";

export type VisionSupport = "supported" | "disabled" | "unknown";

/** 已知支持图像输入的模型/别名（保守列举，不猜测其它模型）。 */
export const knownVisionModels: ReadonlySet<string> = new Set([
  "deepseek-flash",
  "deepseek-v4.1-flash",
  "deepseek-v4.1-flash-1017",
  "1017",
]);

/** 归一化模型标识：小写、去首尾空白、去掉 provider 前缀（deepseek/deepseek-flash）。 */
export function normalizeModelId(raw: string): string {
  let s = (raw ?? "").trim().toLowerCase();
  const slash = s.lastIndexOf("/");
  if (slash >= 0 && slash < s.length - 1) s = s.substring(slash + 1);
  return s.trim();
}

export function isKnownVisionModel(model: string): boolean {
  return knownVisionModels.has(normalizeModelId(model));
}

/**
 * 解析视觉能力三态。configured：true/false 为用户意图；null/undefined = 未配置。
 * 1. configured === false → disabled（用户关闭优先，已知模型也不破例）
 * 2. configured === true  → supported
 * 3. 未配置 → 已知模型 supported，否则 unknown
 */
export function resolveVisionSupport(
  model: string,
  configured?: boolean | null,
): VisionSupport {
  if (configured === false) return "disabled";
  if (configured === true) return "supported";
  return isKnownVisionModel(model) ? "supported" : "unknown";
}

/** 是否允许把图片内联进请求（只有 supported 才允许）。 */
export function visionAllowsImages(support: VisionSupport): boolean {
  return support === "supported";
}

/**
 * B12：把桌面配置里的 vision 归一到「用户意图」，再交给 [resolveVisionSupport] 判定。
 *
 * 桌面配置沿用了旧语义——旧版本会把默认值直接写成 false，因此：
 * - vision === true              → 用户开启。**旧配置常常没有 visionExplicit，也必须保留**；
 * - vision === false 且显式标记   → 用户关闭（严格生效）；
 * - vision === false 且无标记     → 旧默认值，按「未配置」处理，交给已知模型能力表；
 * - null / 缺省                 → 未配置。
 *
 * server.ts（/v1/chat 图片门禁）与 models.ts（/v1/models 上报）共用本函数，
 * 避免两处语义漂移（B12 的根因就是只改了 chat 侧）。
 */
export function configuredVision(model: ModelConfig | undefined): boolean | null {
  if (!model) return null;
  if (model.vision === true) return true;
  if (model.vision === false) {
    return model.visionExplicit === true ? false : null;
  }
  return null;
}
