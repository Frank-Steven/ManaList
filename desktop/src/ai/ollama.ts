import type { AIProvider, ChatOptions, ProviderChatMessage } from "./provider.js";
import { contentText } from "./provider.js";

/**
 * EXPERIMENTAL — Ollama provider（design-v3 §6.2：Ollama 暂缓，无调试设施，v3 不投入）。
 * 代码保留供后续启用，但不出现在默认配置与 /v1/models 中（model-config schema 的
 * provider 枚举暂只列 openai-compat / mock），factory 也不会创建它。
 * 调 {baseUrl}/api/chat（非流式，stream=false），启用前需补流式与实测。
 * 多模态消息（content parts）降级为纯文本（图像块丢弃；启用时再补 images 数组）。
 */
export class OllamaProvider implements AIProvider {
  readonly name = "ollama";
  readonly model: string;

  constructor(private readonly opts: { baseUrl: string; model: string }) {
    this.model = opts.model;
  }

  async chat(messages: ProviderChatMessage[], _options?: ChatOptions): Promise<string> {
    const res = await fetch(`${this.opts.baseUrl}/api/chat`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: this.opts.model,
        messages: messages.map((m) => ({
          role: m.role,
          content: contentText(m.content),
        })),
        stream: false,
      }),
    });
    if (!res.ok) throw new Error(`Ollama /api/chat 返回 ${res.status}: ${await res.text()}`);
    const data = (await res.json()) as { message?: { content?: string } };
    const full = data.message?.content ?? "";
    if (full) _options?.onToken?.(full);
    return full;
  }
}
