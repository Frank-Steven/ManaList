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