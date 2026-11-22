import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

/// B38 回归（2026-11-21）：Windows 必须走 electron-builder 正常打包，不得退回手工组装。
/// ① Ajv 必须在 dependencies —— 放 devDependencies 时 electron-builder 不会收进 resources/app，
///    安装包启动就会在 dist/server.js 的 ajv/dist/2020.js 上崩；
/// ② Windows 目标必须是 electron-builder 的 nsis/x64，且任何脚本都不得出现 --prepackaged
///    （手工组装那套不能作为常规路径留在脚本里）；
/// ③ verify:win-package 只能指向唯一的 verifier，避免第二套校验实现并存。

const desktopRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const scriptsDir = path.join(desktopRoot, "scripts");
const VERIFIER = "scripts/verify-windows-package.mjs";

interface BuildTarget {
  target?: string;
  arch?: string[];
}

interface BuildConfig {
  asar?: boolean;
  files?: string[];
  nsis?: { include?: string };
  extraResources?: Array<{ from?: string; to?: string }>;
  win?: { target?: Array<string | BuildTarget> | string; icon?: string };
}

interface PackageJson {
  scripts?: Record<string, string>;
  dependencies?: Record<string, string>;
  devDependencies?: Record<string, string>;
  build?: BuildConfig;
}

const pkg = JSON.parse(readFileSync(path.join(desktopRoot, "package.json"), "utf8")) as PackageJson;
const scripts: Record<string, string> = pkg.scripts ?? {};
const build: BuildConfig = pkg.build ?? {};

interface NormalizedTarget {
  target: string;
  arch: string[];
}

function normalizeTargets(raw: Array<string | BuildTarget> | string | undefined): NormalizedTarget[] {
  if (!raw) return [];
  const list = Array.isArray(raw) ? raw : [raw];
  return list.map((item) =>
    typeof item === "string" ? { target: item, arch: [] } : { target: item.target ?? "", arch: item.arch ?? [] },
  );
}

test("B38: Ajv 是运行期依赖，Electron 生产依赖由 electron-builder 收集", () => {
  assert.ok(pkg.dependencies, "package.json 必须有 dependencies");
  assert.ok("ajv" in pkg.dependencies, "dependencies 必须包含 ajv（src/server.ts:3 运行时 import）");
  assert.equal(pkg.devDependencies?.ajv, undefined, "ajv 不能只放在 devDependencies：打包时会被裁掉");
  // 复用检查：files 不得塞整棵 node_modules（那等于自建第二套依赖收集逻辑）
  const files = build.files ?? [];
  assert.ok(!files.some((pattern) => pattern.includes("node_modules")), "build.files 不得包含 node_modules：生产依赖交给 electron-builder 收集，实际: " + JSON.stringify(files));
});

test("B38: Windows 目标是 electron-builder nsis/x64，脚本禁止 --prepackaged", () => {
  assert.ok(build.win, "package.json build.win 必须存在");
  const targets = normalizeTargets(build.win?.target);
  const nsis = targets.find((item) => item.target === "nsis");
  assert.ok(nsis, "build.win.target 必须包含 nsis，实际: " + JSON.stringify(build.win?.target));
  assert.ok(nsis.arch.length === 0 || nsis.arch.includes("x64"), "nsis 必须显式 x64（或交给宿主默认架构），实际: " + JSON.stringify(nsis.arch));
  assert.equal(build.win?.icon, "assets/icon.ico", "build.win.icon 必须沿用现有预制图标");
  assert.ok(existsSync(path.join(desktopRoot, "assets", "icon.ico")), "assets/icon.ico 必须存在（构建用它绕开 icons-bundle 下载）");
  assert.equal(build.asar, false, "asar:false 必须保持（extraResources 与 dist 布局依赖它）");

  for (const [name, command] of Object.entries(scripts)) {
    assert.ok(!command.includes("--prepackaged"), "scripts." + name + " 不得使用 --prepackaged：" + command);
  }
  const distWin = scripts["dist:win"] ?? "";
  assert.ok(distWin.includes("electron-builder"), "scripts.dist:win 必须调用 electron-builder，实际: " + JSON.stringify(distWin));
  assert.ok(distWin.includes("--win"), "scripts.dist:win 必须带 --win，实际: " + JSON.stringify(distWin));
});

test("B38: verify:win-package 指向唯一 verifier", () => {
  assert.equal(scripts["verify:win-package"], "node " + VERIFIER, "verify:win-package 必须调用 " + VERIFIER);
  const verifierPath = path.join(desktopRoot, VERIFIER);
  assert.ok(existsSync(verifierPath), VERIFIER + " 必须存在");

  // 唯一性：所有脚本里只有这一个入口提到 verifier 文件
  const refs = Object.entries(scripts).filter(([, command]) => command.includes("verify-windows-package"));
  assert.deepEqual(refs.map(([name]) => name), ["verify:win-package"], "只有 verify:win-package 可以引用 verifier，实际: " + JSON.stringify(refs));

  // 第二套校验实现：scripts/ 下不得出现第二个 *verify*.mjs
  const candidates = readdirSync(scriptsDir).filter((file) => /verify/i.test(file) && file.endsWith(".mjs"));
  assert.deepEqual(candidates, ["verify-windows-package.mjs"], "scripts/ 下只能有唯一的 verifier，实际: " + JSON.stringify(candidates));

  // verifier 自身只读：不起子进程、不复制依赖、不带 no-sandbox
  const source = readFileSync(verifierPath, "utf8");
  assert.ok(!/child_process|spawn\(/.test(source), "verifier 不得起子进程（不构建、不打包）");
  assert.ok(!source.includes("no-sandbox"), "verifier 不得出现 no-sandbox");
  assert.ok(!source.includes("cp -r") && !source.includes("Copy-Item"), "verifier 只校验，不得复制依赖");
});

/// B39 安装器进程检查（2026-11-21，task-10）：只做"强制选择上游精确名分支"，
/// 不复制、不重定义上游的 FIND_PROCESS / KILL_PROCESS / _CHECK_APP_RUNNING。
/// 前置两行声明（getProcessInfo.nsh + Var pid）镜像上游 allowOnlyOneInstallerInstance.nsh:5-8：
/// electron-builder 把自定义 include 放在脚本最前，上游那段 !ifmacrondef 因此被跳过，
/// 而 _CHECK_APP_RUNNING:106 需要 ${GetProcessInfo} 与 $pid —— 故在此补齐，且各自只能出现一次。
const NSIS_INCLUDE = "nsis/installer.nsh";
/// 旧路径 desktop/build/installer.nsh 已废弃：根 .gitignore:11 的 `build/` 会忽略它，文件进不了仓库。
const LEGACY_NSIS_INCLUDE = "build/installer.nsh";

/// 注释行（NSIS 的 # 与 ;）不算有效逻辑，断言只针对指令。
function nsisCodeLines(source: string): string {
  return source
    .split(/\r?\n/)
    .filter((line) => !/^\s*[#;]/.test(line))
    .join("\n");
}

test("B39: customCheckAppRunning 只委托上游分支选择，且只定义一次", () => {
  assert.equal(build.nsis?.include, NSIS_INCLUDE, "build.nsis.include 必须指向 " + NSIS_INCLUDE);
  const includePath = path.join(desktopRoot, NSIS_INCLUDE);
  assert.ok(existsSync(includePath), NSIS_INCLUDE + " 必须存在");
  assert.ok(
    !existsSync(path.join(desktopRoot, LEGACY_NSIS_INCLUDE)),
    LEGACY_NSIS_INCLUDE + " 不得残留（该路径被根 .gitignore 的 build/ 忽略，会让 CI 缺文件）",
  );
  const source = readFileSync(includePath, "utf8");
  const code = nsisCodeLines(source);

  const defs = code.match(/!macro\s+customCheckAppRunning\b/g) ?? [];
  assert.equal(defs.length, 1, "customCheckAppRunning 只能定义一次，实际: " + defs.length);
  const bodyStart = code.indexOf("!macro customCheckAppRunning");
  const bodyEnd = code.indexOf("!macroend", bodyStart);
  assert.ok(bodyStart >= 0 && bodyEnd > bodyStart, "customCheckAppRunning 宏体必须完整");
  const body = code.slice(bodyStart, bodyEnd);

  // 唯一允许的四步：复用可用性检测 → 固定提示 → 强制精确分支 → 复用上游检查流程
  assert.ok(body.includes("!insertmacro IS_POWERSHELL_AVAILABLE"), "宏体必须复用上游 IS_POWERSHELL_AVAILABLE");
  assert.ok(
    body.includes('DetailPrint "Process check: using exact executable-name fallback"'),
    "宏体必须保留固定 DetailPrint 文案",
  );
  assert.ok(
    body.includes("StrCpy $IsPowerShellAvailable 1"),
    "宏体必须写 IsPowerShellAvailable=1（上游语义 1 = 不可用 → 精确名分支）",
  );
  assert.ok(body.includes("!insertmacro _CHECK_APP_RUNNING"), "宏体必须复用上游 _CHECK_APP_RUNNING");

  // 前置依赖：镜像上游 allowOnlyOneInstallerInstance.nsh:5-8，且必须排在宏定义之前
  const includeRefs = code.match(/!include\s+"getProcessInfo\.nsh"/g) ?? [];
  assert.equal(includeRefs.length, 1, "getProcessInfo.nsh 必须且只能 include 一次，实际: " + includeRefs.length);
  const varPidDecls = code.match(/^\s*Var\s+pid\s*$/gm) ?? [];
  assert.equal(varPidDecls.length, 1, "Var pid 只能声明一次，实际: " + varPidDecls.length);

  const includeIndex = code.search(/!include\s+"getProcessInfo\.nsh"/);
  const varPidIndex = code.search(/^\s*Var\s+pid\s*$/m);
  assert.ok(includeIndex >= 0 && includeIndex < bodyStart, "getProcessInfo.nsh include 必须位于 customCheckAppRunning 宏定义之前");
  assert.ok(varPidIndex >= 0 && varPidIndex < bodyStart, "Var pid 必须位于 customCheckAppRunning 宏定义之前");
});

test("B39: include 不自建进程管理、不跳检查、不动安装模式", () => {
  const code = nsisCodeLines(readFileSync(path.join(desktopRoot, NSIS_INCLUDE), "utf8"));

  // 不复刻上游分支里的进程枚举/结束实现
  assert.ok(!/Get-CimInstance|Stop-Process|Win32_Process/i.test(code), "不得自建 CIM/PowerShell 进程枚举");
  assert.ok(!/\btasklist\b|\btaskkill\b/i.test(code), "不得自建 tasklist/taskkill 调用");
  // 不重定义上游宏（重定义即第二套逻辑）
  assert.ok(
    !/!macro\s+(FIND_PROCESS|KILL_PROCESS|_CHECK_APP_RUNNING)\b/.test(code),
    "不得重定义上游 FIND_PROCESS / KILL_PROCESS / _CHECK_APP_RUNNING",
  );
  // 不跳过检查
  assert.ok(!/\bAbort\b|\bQuit\b/.test(code), "不得提前 Abort/Quit 跳过进程检查");
  // 不夹带 TEMP/ACL/no-sandbox/安装模式改动
  assert.ok(!/no-sandbox/i.test(code), "不得出现 no-sandbox");
  assert.ok(!/icacls|takeown|\$TEMP|%TEMP%/i.test(code), "不得改动 TEMP/ACL");
  assert.ok(
    !/oneClick|INSTALL_MODE_PER_ALL_USERS|RequestExecutionLevel/i.test(code),
    "不得改动安装模式（oneClick / 全用户模式 / 执行级别）",
  );
});
