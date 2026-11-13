import type {
  AIProvider,
  ChatOptions,
  ProviderChatMessage,
  ProviderUsage,
} from "./provider.js";

/** stream_options 被上游拒绝时的重试说明（只有一次重试，不影响整轮对话）。 */
const kRetryNote =
  "[openai-compat] 上游不接受 stream_options.include_usage，已去掉该参数重试一次（本轮无 usage）";

interface RawUsage {
  prompt_tokens?: unknown;
  completion_tokens?: unknown;
  total_tokens?: unknown;
  prompt_tokens_details?: { cached_tokens?: unknown } | null;
}

/** 规范化上游 usage：字段缺失时按 0/推算补齐；一个数字都没有则返回 undefined。 */
export function normalizeUsage(raw: RawUsage | null | undefined): ProviderUsage | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const num = (v: unknown): number | undefined =>
    typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : undefined;
  const prompt = num(raw.prompt_tokens);
  const completion = num(raw.completion_tokens);
  const total = num(raw.total_tokens);
  if (prompt === undefined && completion === undefined && total === undefined) return undefined;
  const cached = num(raw.prompt_tokens_details?.cached_tokens);
  const pt = prompt ?? Math.max(0, (total ?? 0) - (completion ?? 0));
  const ct = completion ?? Math.max(0, (total ?? 0) - pt);
  return {
    promptTokens: pt,
    completionTokens: ct,
    totalTokens: total ?? pt + ct,
    ...(cached === undefined ? {} : { cachedPromptTokens: cached }),
  };
}

/**
 * OpenAI 兼容 provider：POST {baseUrl}/chat/completions（stream=true），
 * SSE 逐行解析 choices[0].delta.content 回调 onToken，返回累积全文。
 * 适用本地 llama.cpp 与任何 OpenAI 兼容端点；desktop 只透传对话，不做工具解析。
 *
 * F40：请求带 stream_options.include_usage，usage 作为**最后一个 chunk**（choices 为空）
 * 返回；解析后回调 onUsage，供 /v1/chat 透传真实 token 用量（不混进正文）。
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
    const url = `${this.opts.baseUrl.replace(/\/$/, "")}/chat/completions`;

    const requestBody = (withUsage: boolean): string =>
      JSON.stringify({
        model: this.opts.model,
        stream: true,
        ...(options?.reasoning && options.reasoning !== "off"
          ? { reasoning_effort: options.reasoning }
          : {}),
        // F40：让上游在流末尾追加一个 usage chunk（OpenAI 兼容规范）
        ...(withUsage ? { stream_options: { include_usage: true } } : {}),
        messages,
      });
    const post = (body: string) =>
      fetch(url, { method: "POST", headers, signal: AbortSignal.timeout(180_000), body });

    let res = await post(requestBody(true));
    // 兼容性：部分兼容实现不认 stream_options，会直接 4xx。去掉参数重试一次，
    // 不许整轮失败（重试后拿不到 usage，圆环回退到估算即可）。
    if (!res.ok && res.status >= 400 && res.status < 500) {
      const detail = await res.text().catch(() => "");
      console.warn(`${kRetryNote}：首次 ${res.status} ${detail.slice(0, 200)}`);
      res = await post(requestBody(false));
    }
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
              choices?: Array<{
                delta?: { content?: string; reasoning_content?: string; reasoning?: string };
              }>;
              usage?: RawUsage | null;
            };
            // F40：usage 是最后一个 chunk（choices: []），只回调、绝不当作正文 token。
            const usage = normalizeUsage(json.usage);
            if (usage) options?.onUsage?.(usage);
            const d = json.choices?.[0]?.delta;
            // F35：推理内容单独回调，不混进正文（否则会污染工具块解析）。
            const reasoning = d?.reasoning_content ?? d?.reasoning;
            if (typeof reasoning === "string" && reasoning.length > 0) {
              options?.onReasoning?.(reasoning);
            }
            const delta = d?.content;
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
