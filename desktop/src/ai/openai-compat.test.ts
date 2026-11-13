import assert from "node:assert/strict";
import http from "node:http";
import { test } from "node:test";

import { OpenAICompatProvider } from "./openai-compat.js";

/// F35 回归（2026-11-13）：OpenAI 兼容 provider 的推理参数与推理增量。
///
/// 用本地 http server mock 上游，不起真实网络：
///  a) reasoning=high → 请求体含 reasoning_effort:"high"；
///  b) reasoning 缺省 / off → 请求体不含 reasoning_effort；
///  c) 上游 delta 带 reasoning_content → onReasoning 被调用，且不进返回全文。
interface UpstreamReply {
  reasoning?: string;
  content?: string;
}

interface Upstream {
  baseUrl: string;
  bodies: Array<Record<string, unknown>>;
  close: () => Promise<void>;
}

function startUpstream(reply: (body: Record<string, unknown>) => UpstreamReply) {
  return new Promise<Upstream>((resolve) => {
    const bodies: Array<Record<string, unknown>> = [];
    const server = http.createServer((req, res) => {
      let raw = "";
      req.on("data", (chunk) => {
        raw += chunk;
      });
      req.on("end", () => {
        const body = JSON.parse(raw || "{}") as Record<string, unknown>;
        bodies.push(body);
        const { reasoning, content } = reply(body);
        res.writeHead(200, { "Content-Type": "text/event-stream" });
        if (reasoning) {
          res.write(
            `data: ${JSON.stringify({
              choices: [{ delta: { reasoning_content: reasoning } }],
            })}\n\n`,
          );
        }
        if (content) {
          res.write(
            `data: ${JSON.stringify({
              choices: [{ delta: { content } }],
            })}\n\n`,
          );
        }
        res.write("data: [DONE]\n\n");
        res.end();
      });
    });
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      const port = typeof addr === "object" && addr !== null ? addr.port : 0;
      resolve({
        baseUrl: `http://127.0.0.1:${port}` ,
        bodies,
        close: () =>
          new Promise<void>((done) => {
            server.close(() => done());
          }),
      });
    });
  });
}

const messages = [{ role: "user" as const, content: "你好" }];

test("reasoning=high → 请求体带 reasoning_effort: high", async () => {
  const upstream = await startUpstream(() => ({ content: "正文" }));
  try {
    const provider = new OpenAICompatProvider({
      baseUrl: upstream.baseUrl,
      model: "test-model",
    });
    const full = await provider.chat(messages, { reasoning: "high" });
    assert.equal(full, "正文");
    assert.equal(upstream.bodies.length, 1);
    assert.equal(upstream.bodies[0].reasoning_effort, "high");
    assert.equal(upstream.bodies[0].model, "test-model");
    assert.equal(upstream.bodies[0].stream, true);
  } finally {
    await upstream.close();
  }
});

test("reasoning 缺省 → 请求体不含 reasoning_effort", async () => {
  const upstream = await startUpstream(() => ({ content: "正文" }));
  try {
    const provider = new OpenAICompatProvider({
      baseUrl: upstream.baseUrl,
      model: "test-model",
    });
    await provider.chat(messages);
    assert.equal("reasoning_effort" in upstream.bodies[0], false);
  } finally {
    await upstream.close();
  }
});

test("reasoning=off → 请求体不含 reasoning_effort（显式关闭≠未配置，但都不发）",
  async () => {
    const upstream = await startUpstream(() => ({ content: "正文" }));
    try {
      const provider = new OpenAICompatProvider({
        baseUrl: upstream.baseUrl,
        model: "test-model",
      });
      await provider.chat(messages, { reasoning: "off" });
      assert.equal("reasoning_effort" in upstream.bodies[0], false);
    } finally {
      await upstream.close();
    }
  },
);

test("上游 delta 含 reasoning_content → onReasoning 被调用且不混入正文", async () => {
  const upstream = await startUpstream(() => ({
    reasoning: "先算单价再汇总",
    content: "结论：共 120 元",
  }));
  try {
    const provider = new OpenAICompatProvider({
      baseUrl: upstream.baseUrl,
      model: "test-model",
    });
    const reasonings: string[] = [];
    const tokens: string[] = [];
    const full = await provider.chat(messages, {
      reasoning: "medium",
      onReasoning: (d) => reasonings.push(d),
      onToken: (d) => tokens.push(d),
    });

    assert.deepEqual(reasonings, ["先算单价再汇总"]);
    assert.deepEqual(tokens, ["结论：共 120 元"]);
    assert.equal(full, "结论：共 120 元");
    assert.equal(full.includes("先算单价"), false,
      "推理内容不得混进正文（否则会污染工具块解析）");
  } finally {
    await upstream.close();
  }
});

test("delta.reasoning（非 reasoning_content）同样走 onReasoning", async () => {
  const server = http.createServer((req, res) => {
    req.resume();
    req.on("end", () => {
      res.writeHead(200, { "Content-Type": "text/event-stream" });
      res.write(
        `data: ${JSON.stringify({
          choices: [{ delta: { reasoning: "别名推理" } }],
        })}\n\n`,
      );
      res.write("data: [DONE]\n\n");
      res.end();
    });
  });
  await new Promise<void>((done) => server.listen(0, "127.0.0.1", () => done()));
  const addr = server.address();
  const port = typeof addr === "object" && addr !== null ? addr.port : 0;
  try {
    const provider = new OpenAICompatProvider({
      baseUrl: `http://127.0.0.1:${port}` ,
      model: "m",
    });
    const got: string[] = [];
    const full = await provider.chat(messages, {
      onReasoning: (d) => got.push(d),
    });
    assert.deepEqual(got, ["别名推理"]);
    assert.equal(full, "");
  } finally {
    await new Promise<void>((done) => server.close(() => done()));
  }
});
// ---- F40（2026-11-13）：真实 token usage 透传 ----
//
// 三条覆盖：请求侧带 stream_options.include_usage；usage chunk 规范化后回调 onUsage
// 且不混入正文；上游 4xx 拒绝该参数时去掉重试一次（不许整轮失败）。

/** 起一个可自定义应答的上游（用于 usage / 400 重试用例）。 */
function startCustomUpstream(
  handler: (
    body: Record<string, unknown>,
    res: http.ServerResponse,
    attempt: number,
  ) => void,
) {
  return new Promise<Upstream & { attempts: number }>((resolve) => {
    const bodies: Array<Record<string, unknown>> = [];
    let attempts = 0;
    const server = http.createServer((req, res) => {
      let raw = "";
      req.on("data", (chunk) => {
        raw += chunk;
      });
      req.on("end", () => {
        attempts += 1;
        const body = JSON.parse(raw || "{}") as Record<string, unknown>;
        bodies.push(body);
        handler(body, res, attempts);
      });
    });
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      const port = typeof addr === "object" && addr !== null ? addr.port : 0;
      resolve({
        baseUrl: `http://127.0.0.1:${port}`,
        bodies,
        attempts,
        close: () =>
          new Promise<void>((done) => {
            server.close(() => done());
          }),
      } as Upstream & { attempts: number });
    });
  });
}

test("F40 请求体带 stream_options.include_usage", async () => {
  const upstream = await startUpstream(() => ({ content: "正文" }));
  try {
    const provider = new OpenAICompatProvider({ baseUrl: upstream.baseUrl, model: "m" });
    await provider.chat(messages);
    const body = upstream.bodies[0] as { stream_options?: { include_usage?: boolean } };
    assert.deepEqual(body.stream_options, { include_usage: true });
  } finally {
    await upstream.close();
  }
});

test("F40 usage chunk → onUsage 规范化数字，且 usage 不进正文", async () => {
  const upstream = await startCustomUpstream((_body, res) => {
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: "答" } }] })}\n\n`);
    // usage 作为最后一个 chunk：choices 为空
    res.write(
      `data: ${JSON.stringify({
        choices: [],
        usage: {
          prompt_tokens: 120,
          completion_tokens: 30,
          total_tokens: 150,
          prompt_tokens_details: { cached_tokens: 64 },
        },
      })}\n\n`,
    );
    res.write("data: [DONE]\n\n");
    res.end();
  });
  try {
    const provider = new OpenAICompatProvider({ baseUrl: upstream.baseUrl, model: "m" });
    const usages: Array<Record<string, number>> = [];
    const tokens: string[] = [];
    const full = await provider.chat(messages, {
      onToken: (d) => tokens.push(d),
      onUsage: (u) => usages.push({ ...u }),
    });
    assert.deepEqual(usages, [
      { promptTokens: 120, completionTokens: 30, totalTokens: 150, cachedPromptTokens: 64 },
    ]);
    assert.equal(full, "答", "usage 不得混进正文");
    assert.deepEqual(tokens, ["答"]);
  } finally {
    await upstream.close();
  }
});

test("F40 上游 4xx 拒绝 stream_options → 去掉参数重试一次并成功", async () => {
  const upstream = await startCustomUpstream((body, res, attempt) => {
    const hasStreamOptions = "stream_options" in body;
    if (attempt === 1 && hasStreamOptions) {
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "unsupported parameter: stream_options" }));
      return;
    }
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: "重试成功" } }] })}\n\n`);
    res.write("data: [DONE]\n\n");
    res.end();
  });
  try {
    const provider = new OpenAICompatProvider({ baseUrl: upstream.baseUrl, model: "m" });
    const usages: unknown[] = [];
    const full = await provider.chat(messages, { onUsage: (u) => usages.push(u) });
    assert.equal(full, "重试成功", "去参数后应正常返回正文，不许整轮失败");
    assert.equal(upstream.bodies.length, 2, "只重试一次");
    assert.deepEqual(upstream.bodies[0].stream_options, { include_usage: true });
    assert.equal("stream_options" in upstream.bodies[1], false, "重试请求去掉 stream_options");
    assert.equal(usages.length, 0, "重试后拿不到 usage，不得伪造");
  } finally {
    await upstream.close();
  }
});
