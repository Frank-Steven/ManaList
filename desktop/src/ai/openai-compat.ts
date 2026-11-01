import type { AIProvider, ChatOptions, ProviderChatMessage } from "./provider.js";

/**
 * OpenAI 兼容 provider：POST {baseUrl}/chat/completions（stream=true），
 * SSE 逐行解析 choices[0].delta.content 回调 onToken，返回累积全文。
 * 适用本地 llama.cpp 与任何 OpenAI 兼容端点；desktop 只透传对话，不做工具解析。
 */
export class OpenAICompatProvider implements AIProvider {
  readonly name = "openai-compat";
  readonly model: string;

  constructor(private readonly opts: { baseUrl: string; model: string; apiKey?: string }) {
    this.model = opts.model;
  }

  async chat(messages: ProviderChatMessage[], options?: ChatOptions): Promise<string> {
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    if (this.opts.apiKey) headers.Authorization = `Bearer ${this.opts.apiKey}`;

    const res = await fetch(`${this.opts.baseUrl.replace(/\/$/, "")}/chat/completions`, {
      method: "POST",
      headers,
      signal: AbortSignal.timeout(180_000),
      body: JSON.stringify({
        model: this.opts.model,
        stream: true,
        messages,
      }),
    });
    if (!res.ok || !res.body) {
      throw new Error(`OpenAI 兼容接口返回 ${res.status}: ${await res.text()}`);
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    let full = "";
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });
        let nl = buf.indexOf("\n");
        while (nl >= 0) {
          const line = buf.slice(0, nl).trim();
          buf = buf.slice(nl + 1);
          nl = buf.indexOf("\n");
          if (!line.startsWith("data:")) continue;
          const data = line.slice(5).trim();
          if (data === "[DONE]") continue;
          try {
            const json = JSON.parse(data) as {
              choices?: Array<{ delta?: { content?: string } }>;
            };
            const delta = json.choices?.[0]?.delta?.content;
            if (typeof delta === "string" && delta.length > 0) {
              full += delta;
              options?.onToken?.(delta);
            }
          } catch {
            // 忽略不完整的 JSON 行/保活注释
          }
        }
      }
    } finally {
      reader.releaseLock();
    }
    return full;
  }
}
