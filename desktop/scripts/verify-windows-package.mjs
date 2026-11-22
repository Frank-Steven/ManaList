#!/usr/bin/env node
/// B38（2026-11-21）：Windows 正规打包产物校验器。
///
/// 只读校验：不复制依赖、不启动 HTTP 服务、不修改产物。
/// 版本事实源：desktop/package-lock.json 的 packages["node_modules/ajv"].version ——
/// 不在这里维护任何依赖白名单，产物里必须能真正解析到 Ajv。
///
/// 用法：
///   node scripts/verify-windows-package.mjs [appDir]
///   appDir 默认 release/win-unpacked/resources/app；也接受安装后的 resources/app。

import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url)); // desktop/scripts
export const DESKTOP_ROOT = path.resolve(here, ".."); // desktop/
export const DEFAULT_APP_DIR = path.join(
  DESKTOP_ROOT,
  "release",
  "win-unpacked",
  "resources",
  "app",
);

const AJV_PACKAGE = "ajv";
const AJV_ENTRY = "ajv/dist/2020.js";
const AJV_LOCK_KEY = "node_modules/ajv";

function readJson(filePath) {
  return JSON.parse(readFileSync(filePath, "utf8"));
}

function makeIssue(code, message, details = {}) {
  return {
    code,
    message,
    expected: details.expected ?? null,
    actual: details.actual ?? null,
    fix: details.fix ?? null,
  };
}

/// 期望版本来自锁文件本身（npm ci 不该改它），避免第二份版本事实源。
export function expectedAjvVersion(desktopRoot = DESKTOP_ROOT) {
  const lockPath = path.join(desktopRoot, "package-lock.json");
  if (!existsSync(lockPath)) {
    return { lockPath, version: null, problem: `缺少锁文件 ${lockPath}，无法确定 Ajv 期望版本` };
  }
  const lock = readJson(lockPath);
  const version =
    lock?.packages?.[AJV_LOCK_KEY]?.version ?? lock?.dependencies?.[AJV_PACKAGE]?.version ?? null;
  if (typeof version !== "string" || version.length === 0) {
    return {
      lockPath,
      version: null,
      problem: `${lockPath} 里找不到 ${AJV_LOCK_KEY}.version，无法确定 Ajv 期望版本`,
    };
  }
  return { lockPath, version, problem: null };
}

/// 从解析出的模块文件向上找 ajv 的 package.json，拿到包根与版本（允许 node_modules 内合法嵌套）。
function findAjvPackageRoot(moduleFile) {
  let dir = path.dirname(moduleFile);
  for (let depth = 0; depth < 8; depth += 1) {
    const manifest = path.join(dir, "package.json");
    if (existsSync(manifest)) {
      try {
        const meta = readJson(manifest);
        if (meta?.name === AJV_PACKAGE && typeof meta.version === "string") {
          return { rootDir: dir, version: meta.version };
        }
      } catch {
        // 包清单损坏就当没找到，继续向上
      }
    }
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
  return null;
}

function isInsideAppNodeModules(appRoot, moduleFile) {
  const rel = path.relative(appRoot, moduleFile);
  if (rel === "" || rel.startsWith("..") || path.isAbsolute(rel)) return false;
  return rel.split(path.sep)[0] === "node_modules";
}

export async function verifyPackagedApp(appDir = DEFAULT_APP_DIR, options = {}) {
  const desktopRoot = options.desktopRoot ?? DESKTOP_ROOT;
  const appRoot = path.resolve(appDir);
  const issues = [];
  const report = {
    ok: false,
    appDir: appRoot,
    serverEntry: null,
    ajvFile: null,
    ajvPackageRoot: null,
    ajvVersion: null,
    expectedAjvVersion: null,
    lockPath: null,
    createServer: false,
    issues,
  };

  const expectation = expectedAjvVersion(desktopRoot);
  report.lockPath = expectation.lockPath;
  report.expectedAjvVersion = expectation.version;
  if (expectation.problem) {
    issues.push(
      makeIssue("lock-unusable", expectation.problem, {
        expected: `${expectation.lockPath} 含 ${AJV_LOCK_KEY}.version`,
        actual: "未找到版本",
        fix: "确认没有改过 package-lock.json（npm ci 不应改锁文件），再重跑 npm run dist:win",
      }),
    );
  }

  if (!existsSync(appRoot)) {
    issues.push(
      makeIssue("missing-app-dir", `打包产物目录不存在：${appRoot}`, {
        expected: "electron-builder 正常产出的 resources/app",
        actual: "目录不存在",
        fix: "先运行 npm run dist:win；禁止手工组装 resources/app、禁止 --prepackaged",
      }),
    );
    return report;
  }

  const serverEntry = path.join(appRoot, "dist", "server.js");
  report.serverEntry = serverEntry;
  const hasEntry = existsSync(serverEntry);
  if (!hasEntry) {
    issues.push(
      makeIssue("missing-server-entry", `打包产物缺少入口：${serverEntry}`, {
        expected: "resources/app/dist/server.js（npm run build 的 dist 被 build.files 收集）",
        actual: "文件不存在",
        fix: "确认 build.files 仍含 dist/**/*，然后重跑 npm run dist:win",
      }),
    );
  }

  if (hasEntry) {
    // 一、以打包后的入口为基准解析 Ajv —— 证明生产依赖真的被收集进来
    let ajvFile = null;
    try {
      ajvFile = createRequire(serverEntry).resolve(AJV_ENTRY);
    } catch (error) {
      const code = error?.code ?? "UNKNOWN";
      const physical = path.join(appRoot, "node_modules", AJV_PACKAGE, "dist", "2020.js");
      // ajv 的 exports 映射可能只给 ESM 条件；文件物理存在时先按物理路径继续，最终仍由下面的动态 import 定论。
      if (code === "ERR_PACKAGE_PATH_NOT_EXPORTED" && existsSync(physical)) {
        ajvFile = physical;
      } else {
        issues.push(
          makeIssue("ajv-unresolved", `无法从 ${serverEntry} 解析 ${AJV_ENTRY}（${code}）：${error?.message ?? error}`, {
            expected: `${appRoot}${path.sep}node_modules${path.sep}${AJV_PACKAGE}${path.sep}dist${path.sep}2020.js（node_modules 内允许合法嵌套）`,
            actual: "解析失败",
            fix: "生产依赖未被收集：确认 ajv 在 package.json 的 dependencies，且 scripts 里没有手工复制 node_modules",
          }),
        );
      }
    }

    if (ajvFile) {
      report.ajvFile = ajvFile;
      if (!isInsideAppNodeModules(appRoot, ajvFile)) {
        issues.push(
          makeIssue("ajv-outside-app", `Ajv 解析到了 app 目录的 node_modules 之外：${ajvFile}`, {
            expected: `${appRoot}${path.sep}node_modules${path.sep}…${path.sep}${AJV_PACKAGE}${path.sep}dist${path.sep}2020.js`,
            actual: `相对 app 的路径：${path.relative(appRoot, ajvFile)}`,
            fix: "生产依赖必须由 electron-builder 收集到 resources/app/node_modules，不能靠仓库里的 node_modules 兜底",
          }),
        );
      } else {
        const pkgRoot = findAjvPackageRoot(ajvFile);
        if (!pkgRoot) {
          issues.push(
            makeIssue("ajv-metadata-missing", `找不到 ${AJV_PACKAGE} 的 package.json（从 ${ajvFile} 向上）`, {
              expected: `${AJV_PACKAGE}/package.json 可读且含 name/version`,
              actual: "未找到",
              fix: "产物内的 ajv 包不完整，重跑 npm run dist:win",
            }),
          );
        } else {
          report.ajvPackageRoot = pkgRoot.rootDir;
          report.ajvVersion = pkgRoot.version;
          if (expectation.version && pkgRoot.version !== expectation.version) {
            issues.push(
              makeIssue("ajv-version-mismatch", `产物内的 Ajv 版本与锁文件不一致`, {
                expected: expectation.version,
                actual: pkgRoot.version,
                fix: `以 ${expectation.lockPath} 为准；重新 npm ci 后重跑 npm run dist:win`,
              }),
            );
          }
        }
      }
    }

    // 二、真实导入打包后的入口：只检查导出，不启动任何 HTTP 服务
    try {
      const mod = await import(pathToFileURL(serverEntry).href);
      if (typeof mod.createServer === "function") {
        report.createServer = true;
      } else {
        issues.push(
          makeIssue("createServer-missing", `${serverEntry} 没有导出 createServer 函数`, {
            expected: "module.createServer 是函数（src/server.ts:97）",
            actual: `typeof createServer = ${typeof mod.createServer}`,
            fix: "确认 dist 是最新 build 产物、appDir 指向 resources/app 而不是 src/",
          }),
        );
      }
    } catch (error) {
      issues.push(
        makeIssue("import-failed", `导入打包后的 ${serverEntry} 失败：${error?.message ?? error}`, {
          expected: "依赖齐全、可被 Node 直接 import",
          actual: `${error?.name ?? "Error"}: ${error?.message ?? error}`,
          fix: "先看是否 Ajv 或其它运行期依赖缺失；本校验器不会启动 HTTP 服务",
        }),
      );
    }
  }

  report.ok = issues.length === 0;
  return report;
}

export function formatReport(report) {
  const lines = [];
  if (report.ok) {
    lines.push("PASS verify-windows-package");
    lines.push(`  appDir: ${report.appDir}`);
    lines.push(`  serverEntry: ${report.serverEntry}`);
    lines.push(`  ajvPath: ${report.ajvFile}`);
    lines.push(`  ajvVersion: ${report.ajvVersion}（package-lock 期望 ${report.expectedAjvVersion}）`);
    lines.push(`  createServer: ${report.createServer}`);
    return lines.join("\n");
  }
  lines.push(`FAIL verify-windows-package（${report.issues.length} 项）`);
  lines.push(`  appDir: ${report.appDir}`);
  for (const item of report.issues) {
    lines.push(`  - [${item.code}] ${item.message}`);
    if (item.expected) lines.push(`      期望: ${item.expected}`);
    if (item.actual) lines.push(`      实际: ${item.actual}`);
    if (item.fix) lines.push(`      处理: ${item.fix}`);
  }
  return lines.join("\n");
}

const invokedDirectly = process.argv[1]
  ? pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url
  : false;

if (invokedDirectly) {
  const argv = process.argv.slice(2);
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(
      [
        "用法: node scripts/verify-windows-package.mjs [appDir]",
        `  appDir 默认: ${DEFAULT_APP_DIR}`,
        "  appDir 也可以指向安装后的 <安装目录>\\resources\\app",
        "退出码: 0 = 通过，1 = 校验失败",
      ].join("\n"),
    );
    process.exitCode = 0;
  } else {
    const target = argv.find((arg) => !arg.startsWith("-"));
    const report = await verifyPackagedApp(target ?? DEFAULT_APP_DIR);
    console.log(formatReport(report));
    process.exitCode = report.ok ? 0 : 1;
  }
}
