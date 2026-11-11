import fs from "node:fs";
import path from "node:path";

import { DESKTOP_ROOT } from "./registry.js";

/**
 * 拉起服务的启动方式（B20 回归点）。
 *
 * 旧实现 `spawn("npx", ["tsx", ...])` 在 Windows 上必挂：`npx` 实际是 `npx.cmd`，
 * 不带 `shell: true` 的 spawn 找不到可执行文件 → `ENOENT`，connect 直接崩。
 * 现在统一用 **当前 Node 可执行文件 + 本地已安装的 tsx CLI**（或已构建的 dist），
 * 不依赖任何 `.cmd` / shell，Windows / macOS / Linux 行为一致。
 *
 * 本文件刻意保持**零副作用**（不读配置、不连 adb、不自启看护），
 * 这样单测可以安全 import；connect.ts 只负责调用。
 */
export type ServerLaunch = {
  command: string;
  args: string[];
  source: "tsx-cli" | "built-dist";
};

export type ServerLaunchProbe = {
  root?: string;
  execPath?: string;
  exists?: (p: string) => boolean;
  readFile?: (p: string) => string;
};

export function resolveServerLaunch(probe: ServerLaunchProbe = {}): ServerLaunch {
  const root = probe.root ?? DESKTOP_ROOT;
  const execPath = probe.execPath ?? process.execPath;
  const exists = probe.exists ?? ((p: string) => fs.existsSync(p));
  const readFile = probe.readFile ?? ((p: string) => fs.readFileSync(p, "utf8"));

  // 1) 优先：本地 node_modules/tsx 的 CLI（devDependency，npm install 后一定在）
  const tsxPkg = path.join(root, "node_modules", "tsx", "package.json");
  if (exists(tsxPkg)) {
    try {
      const pkg = JSON.parse(readFile(tsxPkg)) as {
        bin?: string | Record<string, string>;
      };
      const bin = typeof pkg.bin === "string" ? pkg.bin : pkg.bin?.tsx;
      if (bin) {
        const cli = path.join(root, "node_modules", "tsx", bin);
        if (exists(cli)) {
          return { command: execPath, args: [cli, "src/index.ts", "start"], source: "tsx-cli" };
        }
      }
    } catch {
      // 包损坏（JSON 坏了 / 读取失败）→ 继续尝试下一个候选
    }
  }

  // 2) 次选：已构建的 dist（npm run build 之后；打包/生产环境里没有 tsx 也能起）
  const built = path.join(root, "dist", "index.js");
  if (exists(built)) {
    return { command: execPath, args: [built, "start"], source: "built-dist" };
  }

  // 3) 都没有：给出可操作错误（不再是难懂的 ENOENT）
  throw new Error(
    "无法拉起服务：既找不到本地 tsx（node_modules/tsx），也没有 dist/index.js。" +
      "请在 desktop 目录执行 npm install（或 npm run build）后重试。",
  );
}
