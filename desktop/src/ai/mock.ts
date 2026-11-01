import type { AIProvider, ChatOptions, ProviderChatMessage } from "./provider.js";
import { contentImageCount, contentText } from "./provider.js";

/**
 * mock provider（design-v3 §6.2）：内置假模型，不依赖任何真实模型服务，
 * 供无模型环境端到端跑通 /v1/chat 全链路（SSE 流式事件、手机端联调、单元测试）。
 * 回复为固定模板 + 对末条用户消息的简短回显，按小段多次回调 onToken 模拟逐 token 流式。
 * 多模态消息（content parts）只回显文本，附图像块计数。
 */
export class MockProvider implements AIProvider {
  readonly name = "mock";

  readonly model = "mock-chat";

  async chat(messages: ProviderChatMessage[], options?: ChatOptions): Promise<string> {
    const lastUser = [...messages].reverse().find((m) => m.role === "user");
    const imageCount = messages.reduce((n, m) => n + contentImageCount(m.content), 0);
    const echo = lastUser ? contentText(lastUser.content).replace(/\s+/g, " ").slice(0, 40) : "";
    const reply = `【mock 回复】已收到你的消息${echo ? `（"${echo}"）` : ""}` +
      `${imageCount > 0 ? `（含 ${imageCount} 张图片）` : ""}。` +
      `我是内置假模型，用于在没有真实模型服务时验证链路。`;
    let full = "";
    // 每 4 字一段回调，保证客户端能观察到多个 token_delta 事件
    for (let i = 0; i < reply.length; i += 4) {
      const delta = reply.slice(i, i + 4);
      full += delta;
      options?.onToken?.(delta);
    }
    return full;
  }
}
