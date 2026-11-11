import assert from "node:assert/strict";
import path from "node:path";
import { test } from "node:test";

import { resolveServerLaunch } from "./launch.js";

/// B20 回归（2026-11-11）：connect 服务未运行时拉起子进程不再依赖裸 npx。
/// 旧实现 spawn("npx", ...) 在 Windows 上是 npx.cmd → ENOENT，connect 直接崩。
/// 新实现必须：① 用当前 Node 可执行文件；② 优先本地 tsx CLI；③ 缺失时可回退 dist；
/// ④ 都没有时抛可操作错误；⑤ command 永远不是 npx / *.cmd。

const EXEC = "/tmp/fake-node";
const ROOT = "/proj/desktop";
const TSX_PKG = path.join(ROOT, "node_modules", "tsx", "package.json");
const TSX_CLI = path.join(ROOT, "node_modules", "tsx", "dist", "cli.mjs");
const BUILT = path.join(ROOT, "dist", "index.js");

type Files = Record<string, string>;

function probe(files: Files, execPath: string = EXEC) {
  return {
    root: ROOT,
    execPath,
    exists: (p: string): boolean => Object.prototype.hasOwnProperty.call(files, p),
    readFile: (p: string): string => files[p] ?? "",
  };
}

test("优先走 process.execPath + 本地 tsx CLI", () => {
  const launch = resolveServerLaunch(
    probe({
      [TSX_PKG]: JSON.stringify({ bin: { tsx: "dist/cli.mjs" } }),
      [TSX_CLI]: "// cli",
    }),
  );
  assert.equal(launch.command, EXEC);
  assert.equal(launch.source, "tsx-cli");
  assert.deepEqual(launch.args, [TSX_CLI, "src/index.ts", "start"]);
});

test("tsx 的 bin 是字符串时同样可用", () => {
  const launch = resolveServerLaunch(
    probe({
      [TSX_PKG]: JSON.stringify({ bin: "dist/cli.mjs" }),
      [TSX_CLI]: "// cli",
    }),
  );
  assert.equal(launch.source, "tsx-cli");
  assert.deepEqual(launch.args, [TSX_CLI, "src/index.ts", "start"]);
});

test("tsx 缺失但有 dist/index.js → 回退已构建产物（仍用 execPath）", () => {
  const launch = resolveServerLaunch(probe({ [BUILT]: "// built" }));
  assert.equal(launch.source, "built-dist");
  assert.equal(launch.command, EXEC);
  assert.deepEqual(launch.args, [BUILT, "start"]);
});

test("tsx 的 package.json 损坏 → 不抛、继续回退 dist", () => {
  const launch = resolveServerLaunch(
    probe({ [TSX_PKG]: "{ not json", [BUILT]: "// built" }),
  );
  assert.equal(launch.source, "built-dist");
});

test("既没有 tsx 也没有 dist → 抛出可操作错误（不是 ENOENT）", () => {
  assert.throws(
    () => resolveServerLaunch(probe({})),
    (err: unknown) => {
      const msg = (err as Error).message;
      assert.match(msg, /npm install/);
      assert.match(msg, /dist\/index\.js/);
      return true;
    },
  );
});

test("任何情况下都不再返回 npx / npx.cmd（跨平台回归）", () => {
  const cases = [
    probe({
      [TSX_PKG]: JSON.stringify({ bin: { tsx: "dist/cli.mjs" } }),
      [TSX_CLI]: "//",
    }),
    probe({ [BUILT]: "//" }),
  ];
  for (const p of cases) {
    const launch = resolveServerLaunch(p);
    assert.notEqual(launch.command, "npx");
    assert.ok(!launch.command.endsWith(".cmd"));
    assert.ok(!launch.args.some((a) => a === "npx"));
  }
});

test("execPath 透传（模拟 Windows 的 node.exe）", () => {
  const winNode = "C:\\Program Files\\nodejs\\node.exe";
  const launch = resolveServerLaunch(
    probe(
      {
        [TSX_PKG]: JSON.stringify({ bin: { tsx: "dist/cli.mjs" } }),
        [TSX_CLI]: "//",
      },
      winNode,
    ),
  );
  assert.equal(launch.command, winNode);
});
