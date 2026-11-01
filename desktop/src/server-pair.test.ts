import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import type { AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";

import { PairingManager } from "./auth.js";
import { createServer } from "./server.js";
import { ModelManager } from "./models.js";
import type { Config } from "./config.js";

// P2-2 回归：/v1/pair 首次配对免认证，但 reset 必须带当前 token。
const dataDir = mkdtempSync(path.join(os.tmpdir(), "msgrepo-pair-"));
let server: ReturnType<typeof createServer>;
let base = "";
const pairing = new PairingManager(dataDir);

const testConfig: Config = {
  host: "127.0.0.1",
  port: 0,
  models: [
    { id: "mock-1", name: "Mock", provider: "mock", baseUrl: "http://127.0.0.1:9", model: "mock-chat" },
  ],
  defaultModelId: "mock-1",
};

before(async () => {
  server = createServer({
    host: "127.0.0.1",
    port: 0,
    pairing,
    models: new ModelManager(() => testConfig),
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const addr = server.address() as AddressInfo;
  base = `http://127.0.0.1:${addr.port}`;
});

after(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
  rmSync(dataDir, { recursive: true, force: true });
});

const pair = (body: unknown, token?: string) =>
  fetch(`${base}/v1/pair`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  });

test("首次配对：无认证也能拿到 token（USB 即信任）", async () => {
  const res = await pair({});
  assert.equal(res.status, 200);
  const body = (await res.json()) as { token: string };
  assert.equal(body.token, pairing.token);
  assert.ok(body.token.length > 10);
});

test("reset 无 token → 403，且 token 不变", async () => {
  const before = pairing.token;
  const res = await pair({ reset: true });
  assert.equal(res.status, 403);
  const body = (await res.json()) as { error?: string };
  assert.match(body.error ?? "", /current token/);
  assert.equal(pairing.token, before, "未认证的 reset 不得改 token");
});

test("reset 带错误 token → 403", async () => {
  const before = pairing.token;
  const res = await pair({ reset: true }, "not-the-token");
  assert.equal(res.status, 403);
  assert.equal(pairing.token, before);
});

test("reset 带正确 token → 200 并换发新 token", async () => {
  const before = pairing.token;
  const res = await pair({ reset: true }, before);
  assert.equal(res.status, 200);
  const body = (await res.json()) as { token: string };
  assert.notEqual(body.token, before, "应换发新 token");
  assert.equal(body.token, pairing.token);
});
