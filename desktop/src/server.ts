import http from "node:http";
import os from "node:os";
import { Ajv2020 } from "ajv/dist/2020.js";
import { isAuthorized, type PairingManager } from "./auth.js";
import { GateBusyError, GatePool } from "./limit.js";
import { readSharedJson } from "./registry.js";
import type { ModelManager } from "./models.js";
import type { ProviderChatMessage } from "./ai/provider.js";
import {
  configuredVision,
  resolveVisionSupport,
  visionAllowsImages,
} from "./model-capabilities.js";
import type { ChatEvent, ChatRequest } from "./types.js";

export interface ServerOptions {
  host: string;
  port: number;
  pairing: PairingManager;
  models: ModelManager;
}

const MAX_BODY = 20 * 1024 * 1024;

function readBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function sendJson(res: http.ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(body));
}

/**
 * 把 /v1/chat 请求体组装为 provider 消息序列（design-v3 §6.3、details §2.4）：
 * desktop 只透传不解析——工具说明书由手机端组装进消息；这里仅做两件事：
 *  1. 顶层 attachments（手机端已展开正文、自带 [#note:标题] 引用头）拼成一条上下文消息——
 *     图片附件（带 dataBase64）按 OpenAI content parts 内联（image_url，data URL）；
 *  2. OpenAI 端点对 tool 角色要求 tool_calls 字段，本地小模型链路用不上——折叠为带前缀的 user 消息。
 *
 * B10：desktop 必须**自己**按模型能力门禁图片（[vision]），不能只依赖手机端剥离——
 * 手机端版本可能滞后、或请求来自其它客户端。
 */
export function buildProviderMessages(
  body: ChatRequest,
  vision: boolean,
): ProviderChatMessage[] {
  const out: ProviderChatMessage[] = [];
  if (body.attachments && body.attachments.length > 0) {
    const blocks = body.attachments.map((a) => a.content).join("\n\n");
    const images = body.attachments.filter(
      (a) => vision && typeof a.dataBase64 === "string" && a.dataBase64.length > 0,
    );
    const intro = `以下是与本次对话相关的库内容（供引用定位）：\n\n${blocks}`;
    if (images.length === 0) {
      out.push({ role: "user", content: intro });
    } else {
      // 多模态消息：文本上下文 + 逐张图片的 image_url 块
      out.push({
        role: "user",
        content: [
          { type: "text", text: intro },
          ...images.map((a) => ({
            type: "image_url" as const,
            image_url: {
              url: `data:${a.mimeType ?? "image/png"};base64,${a.dataBase64}`,
            },
          })),
        ],
      });
    }
  }
  for (const m of body.messages) {
    if (m.role === "tool") {
      out.push({ role: "user", content: `[工具执行结果]\n${m.content}` });
    } else {
      out.push({ role: m.role, content: m.content });
    }
  }
  return out;
}

export function createServer(opts: ServerOptions): http.Server {
  // 请求体验证：shared/schemas/chat-request.schema.json（唯一事实源）
  const ajv = new Ajv2020({ allErrors: true, strict: false, validateFormats: false });
  const validateChat = ajv.compile(readSharedJson("schemas/chat-request.schema.json") as object);
  // 并发闸（v3）：按模型 id 分闸——不同后端并行、同一后端串行，每闸最多排 8 个，再多 429
  const gates = new GatePool(1, 8);

  return http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
      const pathname = url.pathname;

      // 免认证
      if (req.method === "GET" && pathname === "/v1/health") {
        return sendJson(res, 200, {
          status: "ok",
          defaultModelId: opts.models.defaultModelId,
          modelCount: opts.models.models.length,
          time: Date.now(),
        });
      }
      // 自动配对（设计 §11）：免认证——server 只监听 loopback，USB 物理通道即信任。
      // 无 body 返回当前 token；{"reset":true} 重新签发。手机端 401 时自动调一次。
      if (req.method === "POST" && pathname === "/v1/pair") {
        const raw = await readBody(req);
        let body: unknown = {};
        if (raw.trim()) {
          try {
            body = JSON.parse(raw);
          } catch {
            return sendJson(res, 400, { error: "invalid JSON body" });
          }
        }
        if ((body as { reset?: unknown }).reset === true) {
          // P2-2：重置 token 必须证明持有当前 token。此前任何人都能在 loopback 上把
          // 手机踢下线（或诱导手机重新配对到本机攻击者进程）。首次配对不走 reset，
          // 因此「USB 即信任、不输入 token」的零配置体验不受影响。
          if (!isAuthorized(req, opts.pairing.token)) {
            return sendJson(res, 403, { error: "reset requires current token" });
          }
          opts.pairing.reset();
        }
        return sendJson(res, 200, {
          token: opts.pairing.token,
          deviceName: os.hostname(),
        });
      }

      // 模型列表（design-v3 §6.2）：逐模型连通性探测结果（带缓存），供手机助理页拉取展示
      if (req.method === "GET" && pathname === "/v1/models") {
        if (!isAuthorized(req, opts.pairing.token))
          return sendJson(res, 401, { error: "unauthorized" });
        const models = await opts.models.probeAll();
        return sendJson(res, 200, { defaultModelId: opts.models.defaultModelId, models });
      }

      // 重载模型配置（default.json ← local.json ← userData/config.json 重新合并）
      if (req.method === "POST" && pathname === "/v1/models/reload") {
        if (!isAuthorized(req, opts.pairing.token))
          return sendJson(res, 401, { error: "unauthorized" });
        opts.models.reload();
        const models = await opts.models.probeAll();
        console.log(`[models] 配置已重载：${models.length} 个模型，默认 ${opts.models.defaultModelId}`);
        return sendJson(res, 200, { defaultModelId: opts.models.defaultModelId, models });
      }

      // v3 统一对话接口（design-v3 §6.3）：SSE 透传 token 流，不解析、不执行工具块
      if (req.method === "POST" && pathname === "/v1/chat") {
        if (!isAuthorized(req, opts.pairing.token))
          return sendJson(res, 401, { error: "unauthorized" });
        let parsed: unknown;
        try {
          parsed = JSON.parse(await readBody(req));
        } catch {
          return sendJson(res, 400, { error: "invalid JSON body" });
        }
        if (!validateChat(parsed)) {
          return sendJson(res, 400, {
            error: "invalid chat request",
            details: ajv.errorsText(validateChat.errors),
          });
        }
        const body = parsed as ChatRequest;
        const modelId = body.modelConfigId ?? opts.models.defaultModelId;
        const provider = opts.models.providerFor(modelId);
        if (!provider) {
          return sendJson(res, 400, { error: `未知模型配置: ${modelId}` });
        }

        // 同一模型后端串行（本地推理进程扛不住并发），不同后端并行
        let releaseSlot: (() => void) | null = null;
        try {
          releaseSlot = await gates.acquireSlot(modelId);
        } catch (e) {
          if (e instanceof GateBusyError) {
            res.setHeader("Retry-After", "5");
            return sendJson(res, 429, { error: "busy", retryAfter: 5 });
          }
          throw e;
        }
        res.on("close", () => releaseSlot?.());

        const startedAt = Date.now();
        console.log(`[chat] 对话 ${body.conversationId} → 模型 ${modelId}（${body.messages.length} 条消息）`);
        res.writeHead(200, {
          "Content-Type": "text/event-stream; charset=utf-8",
          "Cache-Control": "no-cache",
          "X-Accel-Buffering": "no",
        });
        // 立即冲刷响应头：首 token 可能耗时数秒，客户端对建立连接有超时限制
        res.flushHeaders();
        const send = (event: ChatEvent) => {
          try {
            res.write(`data: ${JSON.stringify(event)}\n\n`);
          } catch {
            // 客户端已断开：忽略写入错误
          }
        };
        // B10/B11：desktop 侧独立解析该模型的能力（模型名 + 配置的 vision 三态），
        // 未确认/关闭时丢弃图片，避免把 image parts 发给不支持的端点。
        const modelConfig = opts.models.modelFor(modelId);
        // B12：不能直接用 modelConfig.vision —— 旧配置的 false 是「默认值」而不是用户意图。
        const visionSupport = resolveVisionSupport(
          modelConfig?.model ?? "",
          configuredVision(modelConfig),
        );
        try {
          await provider.chat(buildProviderMessages(body, visionAllowsImages(visionSupport)), {
            onToken: (delta) => send({ type: "token_delta", delta }),
          });
          send({ type: "done" });
          console.log(`[chat] 完成：${modelId}，耗时 ${((Date.now() - startedAt) / 1000).toFixed(1)}s`);
        } catch (err) {
          send({ type: "error", error: String(err) });
          console.log(`[chat] 失败：${modelId}：${String(err)}`);
        }
        res.end();
        return;
      }

      sendJson(res, 404, { error: "not found" });
    } catch (err) {
      sendJson(res, 500, { error: String(err) });
    }
  });
}
