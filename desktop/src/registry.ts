import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
// src/ 与编译产物 dist/ 的上一级都是 desktop/
export const DESKTOP_ROOT = path.resolve(here, "..");

function resolveSharedDir(): string {
  const fromRepo = path.resolve(DESKTOP_ROOT, "..", "shared");
  if (existsSync(fromRepo)) return fromRepo;
  // Electron 打包后：shared/ 由 electron-builder extraResources 放到 resources/shared
  const resourcesPath = (process as unknown as { resourcesPath?: string }).resourcesPath;
  if (resourcesPath) return path.join(resourcesPath, "shared");
  return fromRepo;
}

export const SHARED_DIR = resolveSharedDir();

export function readSharedJson(rel: string): unknown {
  return JSON.parse(readFileSync(path.join(SHARED_DIR, rel), "utf8"));
}
