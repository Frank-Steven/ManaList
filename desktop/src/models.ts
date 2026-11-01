import { createProviderForModel } from "./ai/factory.js";
import type { AIProvider } from "./ai/provider.js";
import type { Config } from "./config.js";
import type { ModelConfig } from "./types.js";

export interface ModelProbeResult {
  ok: boolean;
  checkedAt: number;
}

/** GET /v1/models 响应中的单条目。 */
export interface ModelListEntry extends ModelConfig {
  reachable: boolean | null; // null = 尚未探测
  checkedAt: number | null;
}

const PROBE_TTL_MS = 30_000;

/**
 * 模型注册中心（design-v3 §6.2）：持有当前生效的模型列表与对应 provider 实例，
 * 提供逐模型连通性探测（带 30s 缓存）与配置重载（POST /v1/models/reload）。
 *
 * 构造时传入 loadConfig 闭包而非路径，便于测试注入内存配置。
 */
export class ModelManager {
  private config: Config;
  private providers = new Map<string, AIProvider>();
  private probeCache = new Map<string, ModelProbeResult>();

  constructor(
    private readonly loadConfigFn: () => Config,
    private readonly probeTimeoutMs = 3000,
  ) {
    this.config = loadConfigFn();
    this.rebuildProviders();
  }

  get models(): ModelConfig[] {
    return this.config.models;
  }

  /** defaultModelId 无效时回退到第一个模型（配置容错，不炸服务）。 */
  get defaultModelId(): string {
    const { defaultModelId, models } = this.config;
    return models.some((m) => m.id === defaultModelId) ? defaultModelId : (models[0]?.id ?? "");
  }

  providerFor(id: string): AIProvider | undefined {
    return this.providers.get(id);
  }

  modelFor(id: string): ModelConfig | undefined {
    return this.config.models.find((m) => m.id === id);
  }

  /** 重载配置（重跑 loadConfig 闭包），重建 provider 并清空探测缓存。 */
  reload(): void {
    this.config = this.loadConfigFn();
    this.rebuildProviders();
    this.probeCache.clear();
  }

  private rebuildProviders(): void {
    this.providers.clear();
    for (const m of this.config.models) {
      try {
        this.providers.set(m.id, createProviderForModel(m));
      } catch (err) {
        console.error(`[models] 创建 provider 失败（${m.id}）：${String(err)}`);
      }
    }
  }

  /**
   * 单模型连通性探测（带 TTL 缓存；force 绕过缓存）。
   * mock 恒可达；openai-compat 依次试 {origin}/health、{baseUrl}/models、{origin}/api/tags。
   */
  async probe(id: string, force = false): Promise<ModelProbeResult> {
    if (!force) {
      const cached = this.probeCache.get(id);
      if (cached && Date.now() - cached.checkedAt < PROBE_TTL_MS) return cached;
    }
    const model = this.modelFor(id);
    const ok = model ? await this.doProbe(model) : false;
    const result: ModelProbeResult = { ok, checkedAt: Date.now() };
    this.probeCache.set(id, result);
    return result;
  }

  /** 逐模型探测全部（供 /v1/models 与托盘 5s 看护复用同一缓存）。 */
  async probeAll(): Promise<ModelListEntry[]> {
    const out: ModelListEntry[] = [];
    for (const m of this.config.models) {
      const p = await this.probe(m.id);
      out.push({ ...m, reachable: p.ok, checkedAt: p.checkedAt });
    }
    return out;
  }

  private async doProbe(model: ModelConfig): Promise<boolean> {
    if (model.provider === "mock") return true;
    let origin: string;
    try {
      origin = new URL(model.baseUrl).origin;
    } catch {
      return false;
    }
    const candidates = [
      `${origin}/health`,
      `${model.baseUrl.replace(/\/$/, "")}/models`,
      `${origin}/api/tags`,
    ];
    for (const url of candidates) {
      try {
        const res = await fetch(url, { signal: AbortSignal.timeout(this.probeTimeoutMs) });
        if (res.ok) return true;
      } catch {
        // 试下一个
      }
    }
    return false;
  }
}
