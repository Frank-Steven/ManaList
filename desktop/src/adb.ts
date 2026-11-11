import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);

/**
 * adb 通道维护：connect.ts CLI 与 Electron 托盘共用。
 * 无设备/未授权时静默返回状态，由调用方决定是否提示。
 * 打包 App 从 Finder 启动时 PATH 不含 Homebrew，因此先解析 adb 绝对路径再执行。
 */

export type DeviceState = "ok" | "unauthorized" | "absent";

export interface DeviceInfo {
  serial: string;
  model: string;
}

let resolvedAdb: string | null | undefined;

/** 解析 adb 可执行文件路径：先 PATH，再常见安装位置；找不到缓存 null（下次调用重新探测）。 */
export async function adbPath(): Promise<string | null> {
  if (resolvedAdb !== undefined && resolvedAdb !== null) return resolvedAdb;
  try {
    await run("adb", ["version"]);
    resolvedAdb = "adb";
    return resolvedAdb;
  } catch {
    // PATH 上没有，继续找常见位置
  }
  const candidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"];
  const androidHome = process.env.ANDROID_HOME ?? process.env.ANDROID_SDK_ROOT;
  if (androidHome) candidates.unshift(path.join(androidHome, "platform-tools", "adb"));
  candidates.push(path.join(os.homedir(), "Library", "Android", "sdk", "platform-tools", "adb"));
  for (const c of candidates) {
    if (existsSync(c)) {
      resolvedAdb = c;
      return c;
    }
  }
  resolvedAdb = null;
  return null;
}

async function adb(args: string[]): Promise<string> {
  const bin = await adbPath();
  if (!bin) throw new Error("adb 未安装");
  const { stdout } = await run(bin, args);
  return stdout;
}

/** 一次 `adb devices -l` 的完整扫描结果（O07：状态与设备列表同源）。 */
export interface DeviceScan {
  state: DeviceState;
  devices: DeviceInfo[];
}

/**
 * 纯解析：`adb devices -l` 的原始输出 → （状态 + 已授权设备列表）。
 *
 * B21（2026-11-11）：旧实现硬依赖 `line.includes("\tdevice")`。本机 adb 37.0.1
 * 用**空格**分隔列（`R58M...   device product:...`），于是有设备仍被判 absent、
 * reverse 不执行。现在改为按空白分隔解析：
 * - 设备判定 `\s+device\b`（tab/多空格/CRLF 都适用，且不误伤 `devices`/`offline`）；
 * - serial = 首个空白分隔字段；
 * - 忽略 header（List of devices attached）、daemon 提示（`* daemon ...`）、
 *   adb server 版本提示与 error 行；
 * - state 由**首个可判定行**决定（与旧「先命中先返回」一致）：device → ok，
 *   unauthorized → unauthorized。
 */
export function parseDevicesList(output: string): DeviceScan {
  let state: DeviceState | null = null;
  const devices: DeviceInfo[] = [];
  for (const raw of output.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith("List of devices attached")) continue;
    if (line.startsWith("*")) continue; // daemon 启动/结束提示
    if (line.startsWith("adb server")) continue; // 版本不匹配提示
    if (line.startsWith("error:")) continue;
    const parts = line.split(/\s+/);
    const serial = parts[0];
    if (!serial) continue;
    const isDevice = /\s+device\b/.test(line);
    const isUnauthorized = /\bunauthorized\b/.test(line);
    if (state === null) {
      if (isDevice) state = "ok";
      else if (isUnauthorized) state = "unauthorized";
    }
    if (!isDevice) continue;
    const modelMatch = /\bmodel:(\S+)/.exec(line);
    devices.push({ serial, model: modelMatch?.[1] ?? "未知型号" });
  }
  return { state: state ?? "absent", devices };
}

/**
 * 单次 `adb devices -l` 同时得到连接状态与设备列表（O07，2026-11-03）。
 *
 * 原先看护 tick 每个 5s 周期先 deviceState()（`adb devices`）再 listDevices()
 * （`adb devices -l`）——同一份信息 spawn 两次 adb 进程。`-l` 的输出包含 plain
 * `devices` 的全部内容并附 model 字段，因此一次 `-l` 足够同时算出两者。
 * 解析失败 / 无 adb 时按 absent + 空列表返回（与原 deviceState/listDevices 一致）。
 */
export async function scanDevices(): Promise<DeviceScan> {
  let out: string;
  try {
    out = await adb(["devices", "-l"]);
  } catch {
    return { state: "absent", devices: [] };
  }
  return parseDevicesList(out);
}

/** 已授权设备列表（含型号/序列号）；adb 缺失或无设备时返回空数组。 */
export async function listDevices(): Promise<DeviceInfo[]> {
  return (await scanDevices()).devices;
}

export async function deviceState(): Promise<DeviceState> {
  return (await scanDevices()).state;
}

export async function reverseEstablished(port: number): Promise<boolean> {
  try {
    const out = await adb(["reverse", "--list"]);
    return out.includes(`tcp:${port}`);
  } catch {
    return false;
  }
}

/** 确保 adb reverse tcp:port 存在；已存在直接返回 true，失败返回 false（不抛异常）。 */
export async function ensureReverse(port: number): Promise<boolean> {
  if (await reverseEstablished(port)) return true;
  try {
    await adb(["reverse", `tcp:${port}`, `tcp:${port}`]);
    return await reverseEstablished(port);
  } catch {
    return false;
  }
}
