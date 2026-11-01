/** OpenAI 多模态内容块（content parts）：文本或内联图像（data URL）。 */
export type ProviderContentPart =
  | { type: "text"; text: string }
  | { type: "image_url"; image_url: { url: string } };

/** 传给 provider 的对话消息（已按 OpenAI 角色规整，tool 角色已折叠为 user）。
 *  content 为字符串（纯文本消息）或 content parts（含图像的多模态消息）。 */
export interface ProviderChatMessage {
  role: "system" | "user" | "assistant";
  content: string | ProviderContentPart[];
}

/** 提取消息纯文本（mock/ollama 等非多模态 provider 用，图像块计数返回）。 */
export function contentText(content: string | ProviderContentPart[]): string {
  if (typeof content === "string") return content;
  return content
    .filter((p): p is { type: "text"; text: string } => p.type === "text")
    .map((p) => p.text)
    .join("\n");
}

/** 消息中的图像块数。 */
export function contentImageCount(content: string | ProviderContentPart[]): number {
  if (typeof content === "string") return 0;
  return content.filter((p) => p.type === "image_url").length;
}

/** v3 统一对话选项（design-v3 §6.3）。 */
export interface ChatOptions {
  /** 每生成一段 delta 回调一次，供 /v1/chat 透传 token_delta 事件 */
  onToken?: (delta: string) => void;
}

/**
 * AI 适配器接口（v3）：只做一件事——流式对话补全。
 * desktop 是 AI 网关：不解析、不执行模型输出中的工具块（design-v3-details §2.4），
 * 提案生成与执行都在手机端。
 */
export interface AIProvider {
  readonly name: string;
  readonly model?: string;
  /** 流式对话：onToken 逐段回调，返回累积全文。 */
  chat(messages: ProviderChatMessage[], options?: ChatOptions): Promise<string>;
}
