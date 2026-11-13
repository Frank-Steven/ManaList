// 与 shared/schemas/*.schema.json 对齐的 TS 类型。字段名以 schema 为唯一事实源。



// ---- raw-message.schema.json ----




// ---- structured-item.schema.json ----



// ---- category-registry.schema.json ----


/** 分类的默认优先级（v1 沿用，注册表与 AI 输出仍用 P0-P3 表示分类倾向）。 */
export type Priority = "P0" | "P1" | "P2" | "P3";

export interface CategoryDef {
  key: string;
  displayName: string;
  description: string;
  baseKind: "specialized" | "generic";
  defaultPriority: Priority;
  priorityHints?: string;
  timeHints?: string;
  payloadSchema: Record<string, unknown>;
}

export interface CategoryRegistry {
  version: string;
  categories: CategoryDef[];
  definitions?: Record<string, unknown>;
}

// ---- sync-request / sync-response ----


// ---- task-anchor.schema.json（design-v3 §1.1）----

/** 任务锚点：连接一个任务与库中消息/笔记/文件；正文行内 marker 为 ⟦task:<id>⟧。 */
export interface TaskAnchor {
  id: string;
  taskId: string;
  targetType: "message" | "note" | "file";
  targetId: string;
  label?: string | null;
  createdBy: "user" | "ai";
  /** Unix 毫秒时间戳 */
  createdAt: number;
}

// ---- chat-request.schema.json（design-v3 §2、§6.3）----

export interface ChatMessageRef {
  type: "note" | "message" | "file";
  id: string;
}

export interface ChatRequestMessage {
  role: "user" | "assistant" | "tool";
  content: string;
  /** 该消息引用的库实体（仅引用）；正文在顶层 attachments 中展开 */
  attachments?: ChatMessageRef[];
}

/** 附件正文展开块：带 [#note:标题] 类引用头，供 AI 引用定位。 */
export interface ChatAttachment {
  type: "note" | "message" | "file";
  id: string;
  content: string;
  /** 文件附件的 MIME 类型（图片附件必有，如 image/png） */
  mimeType?: string;
  /** 图片附件的内联图像数据（base64，PNG）；仅 vision 模型附带 */
  dataBase64?: string;
}

export interface ChatRequest {
  conversationId: string;
  messages: ChatRequestMessage[];
  attachments?: ChatAttachment[];
  /** 对话绑定的模型配置 id，缺省用 defaultModelId */
  modelConfigId?: string;
  stream: boolean;
  /** 推理强度（F35）：缺省/off 不发参数；low/medium/high → reasoning_effort */
  reasoning?: "off" | "low" | "medium" | "high";
}

// ---- chat-response.schema.json（design-v3 §2、§5.4）----

/**
 * /v1/chat 流式事件。desktop 只透传 token 流、不解析不执行工具；
 * proposal 事件的 proposalId 由客户端（手机端解析层）生成。
 */
export type ChatEvent =
  | { type: "token_delta"; delta: string }
  | { type: "reasoning_delta"; delta: string }
  | {
      type: "proposal";
      proposalId: string;
      /** 原子工具名，如 task.create（清单见 design-v3 §5.2） */
      tool: string;
      args: Record<string, unknown>;
    }
  | {
      /**
       * F40：上游真实 token 用量，紧跟 done 之前发出。
       * **不返回 usage 时该事件根本不出现**（旧客户端不受影响）。
       */
      type: "usage";
      promptTokens: number;
      completionTokens: number;
      totalTokens: number;
      /** 命中缓存的 prompt token；上游不给则缺省 */
      cachedPromptTokens?: number;
    }
  | { type: "done" }
  | { type: "error"; error: string };

// ---- model-config.schema.json（design-v3 §6.2）----

/** 模型配置；Ollama 暂缓，provider 暂只列 openai-compat / mock。 */
export interface ModelConfig {
  id: string;
  name: string;
  provider: "openai-compat" | "mock";
  baseUrl: string;
  model: string;
  /** API key 所在环境变量名，不直接存密钥 */
  apiKeyEnv?: string;
  /**
   * 图像输入（多模态）三态（B11，语义见 model-capabilities.ts）：
   * true = 支持；false = 用户显式关闭；null/缺省 = 未配置（按模型能力表推断）。
   *
   * 兼容旧配置：旧实现可能对「从未配置」的项写下 false（且无 visionExplicit 标记），
   * 这种值无法区分用户意图，读取方应按「未配置」处理。
   */
  vision?: boolean | null;
  /** 用户显式选择过视觉能力时为 true；此后 vision:false 才代表「用户关闭」。 */
  visionExplicit?: boolean;
}
