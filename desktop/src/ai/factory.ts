import type { ModelConfig } from "../types.js";
import type { AIProvider } from "./provider.js";
import { MockProvider } from "./mock.js";
import { OpenAICompatProvider } from "./openai-compat.js";

/**
 * 按模型配置条目创建 provider（design-v3 §6.2）；CLI（index.ts）与 Electron 主进程共用。
 * Ollama 暂缓：ollama.ts 代码保留（experimental），但此处不创建、不进默认配置。
 */
export function createProviderForModel(model: ModelConfig): AIProvider {
  switch (model.provider) {
    case "openai-compat":
      return new OpenAICompatProvider({
        baseUrl: model.baseUrl,
        model: model.model,
        apiKey: model.apiKeyEnv ? process.env[model.apiKeyEnv] : undefined,
      });
    case "mock":
      return new MockProvider();
    default:
      throw new Error(`未知 provider 类型: ${(model as ModelConfig).provider}`);
  }
}
