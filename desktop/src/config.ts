import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { DESKTOP_ROOT } from "./registry.js";
import type { ModelConfig } from "./types.js";

export interface Config {
  host: string;
  port: number;
  models: ModelConfig[];
  defaultModelId: string;
}

/**
 * 加载 config/default.json，并用 config/local.json（git 忽略）做浅合并覆盖。
 *  extraOverridePaths 为可选的追加覆盖文件（如托盘应用的 userData/config.json），按顺序最后应用。
 *
 * 合并语义（v3，design-v3 §6.2）：
 *  - 标量（host/port/defaultModelId）：后者直接覆盖；
 *  - models 数组：**按 id 合并**——覆盖文件中与默认同 id 的条目做字段级浅合并
 *   （可只写要改的字段，如 {"id":"local-gemma","baseUrl":"..."}），新 id 的条目追加到列表末尾；
 *  - 旧 v2 平铺配置（provider/openai/ollama 字段）不做自动迁移（干净迁移策略），会被静默忽略。
 */
export function loadConfig(extraOverridePaths: string[] = []): Config {
  const cfg = JSON.parse(
    readFileSync(path.join(DESKTOP_ROOT, "config/default.json"), "utf8"),
  ) as Config;
  const localPath = path.join(DESKTOP_ROOT, "config/local.json");
  for (const overridePath of [localPath, ...extraOverridePaths]) {
    if (!existsSync(overridePath)) continue;
    const override = JSON.parse(readFileSync(overridePath, "utf8")) as Record<string, unknown>;
    for (const [k, v] of Object.entries(override)) {
      // 旧 v2 平铺配置键不做迁移，静默忽略
      if (k === "provider" || k === "ollama" || k === "openai") continue;
      if (k === "models" && Array.isArray(v)) {
        mergeModels(cfg, v as Array<Record<string, unknown>>);
      } else {
        (cfg as unknown as Record<string, unknown>)[k] = v;
      }
    }
  }
  return cfg;
}

function mergeModels(cfg: Config, overrides: Array<Record<string, unknown>>): void {
  for (const entry of overrides) {
    if (!entry || typeof entry.id !== "string") continue;
    const existing = cfg.models.find((m) => m.id === entry.id);
    if (existing) {
      Object.assign(existing, entry);
    } else {
      cfg.models.push(entry as unknown as ModelConfig);
    }
  }
}
