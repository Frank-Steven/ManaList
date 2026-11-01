import { spawn, type ChildProcess } from "node:child_process";
import path from "node:path";
import { loadConfig } from "./config.js";
import { DESKTOP_ROOT } from "./registry.js";
import { loadOrCreatePairing } from "./auth.js";
import { deviceState, ensureReverse } from "./adb.js";

/**
 * 一键连接看护：起服务（如未运行）→ 检测手机授权 → 建立 adb reverse →
 * 校验链路 → 常驻看护（USB 重插自动重建通道、服务掉线自动拉起）。
 * Ctrl+C 退出；若服务是本脚本拉起的会一并停止。
 */

const cfg = loadConfig();
const DATA_DIR = path.join(DESKTOP_ROOT, "data");
const PORT = cfg.port;

let serverChild: ChildProcess | null = null;

function log(msg: string): void {
  console.log(`[${new Date().toLocaleTimeString("zh-CN", { hour12: false })}] ${msg}`);
}

async function serverUp(): Promise<boolean> {
  try {
    const res = await fetch(`http://127.0.0.1:${PORT}/v1/health`, {
      signal: AbortSignal.timeout(3000),
    });
    return res.ok;
  } catch {
    return false;
  }
}

async function ensureServer(): Promise<void> {
  if (await serverUp()) return;
  if (!serverChild) {
    log("服务未运行，正在拉起…");
    serverChild = spawn("npx", ["tsx", "src/index.ts", "start"], {
      cwd: DESKTOP_ROOT,
      stdio: ["ignore", "pipe", "pipe"],
    });
    serverChild.stdout?.on("data", (d: Buffer) => process.stdout.write(`  [server] ${d}`));
    serverChild.stderr?.on("data", (d: Buffer) => process.stderr.write(`  [server] ${d}`));
    serverChild.on("exit", () => {
      serverChild = null;
    });
  }
  // 等待服务就绪（模型/注册表加载可能耗时）
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 1000));
    if (await serverUp()) return;
  }
  throw new Error("服务拉起超时");
}

let lastState = "";

async function tick(): Promise<void> {
  await ensureServer();

  const dev = await deviceState();
  if (dev === "absent") {
    if (lastState !== "absent") log("未检测到手机。请用 USB 连接并开启 USB 调试。");
    lastState = "absent";
    return;
  }
  if (dev === "unauthorized") {
    if (lastState !== "unauthorized")
      log("手机已连接但未授权——请在手机弹窗中允许 USB 调试。");
    lastState = "unauthorized";
    return;
  }

  if (!(await ensureReverse(PORT))) {
    if (lastState !== "reverse-fail") log(`adb reverse 建立失败，重试中…`);
    lastState = "reverse-fail";
    return;
  }

  if (lastState !== "ok") {
    const { pairing } = loadOrCreatePairing(DATA_DIR);
    log("连接就绪：手机 → adb reverse → 电脑服务");
    log(`  服务: http://127.0.0.1:${PORT}（默认模型 ${cfg.defaultModelId}）`);
    log(`  配对 token: ${pairing.token}`);
  }
  lastState = "ok";
}

async function main(): Promise<void> {
  log(`LinkModel 连接看护启动（端口 ${PORT}，Ctrl+C 退出）`);
  const timer = setInterval(() => {
    tick().catch((e) => log(`看护异常：${String(e)}`));
  }, 5000);
  await tick().catch((e) => log(`看护异常：${String(e)}`));

  process.on("SIGINT", () => {
    clearInterval(timer);
    if (serverChild) {
      log("停止由本脚本拉起的服务…");
      serverChild.kill();
    }
    process.exit(0);
  });
}

await main();
