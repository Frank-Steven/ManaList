import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { randomBytes, timingSafeEqual } from "node:crypto";
import type { IncomingMessage } from "node:http";

export interface Pairing {
  token: string;
  createdAt: number;
}

/** 首次启动生成随机 token 写入 data/pairing.json；已存在则直接加载。 */
export function loadOrCreatePairing(dataDir: string): { pairing: Pairing; created: boolean } {
  mkdirSync(dataDir, { recursive: true });
  const file = path.join(dataDir, "pairing.json");
  if (existsSync(file)) {
    try {
      const parsed = JSON.parse(readFileSync(file, "utf8")) as Pairing;
      if (parsed && typeof parsed.token === "string" && parsed.token.length > 0) {
        return { pairing: parsed, created: false };
      }
    } catch {
      // 文件损坏则重新生成
    }
  }
  const pairing: Pairing = { token: randomBytes(24).toString("base64url"), createdAt: Date.now() };
  writeFileSync(file, JSON.stringify(pairing, null, 2), { mode: 0o600 });
  return { pairing, created: true };
}

/**
 * 常量时间比较两段字符串（P2-3）。长度不同直接返回 false —— 长度本身不是秘密，
 * 但可以避免 timingSafeEqual 抛错。
 */
export function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}

/**
 * 校验 Authorization 头的值是否为 `Bearer <token>`（常量时间比较，防计时攻击）。
 * 抽成纯函数是为了可单测：不必伪造 IncomingMessage。
 */
export function isBearerTokenMatch(headerValue: string | undefined, token: string): boolean {
  if (!headerValue || token.length === 0) return false;
  return safeEqual(headerValue, `Bearer ${token}`);
}

/** 校验 Authorization: Bearer <token>。 */
export function isAuthorized(req: IncomingMessage, token: string): boolean {
  return isBearerTokenMatch(req.headers.authorization, token);
}

/** 配对 token 的运行期持有者：支持 /v1/pair 的 reset 重新签发并落盘。 */
export class PairingManager {
  private current: Pairing;
  readonly created: boolean;

  constructor(private readonly dataDir: string) {
    const { pairing, created } = loadOrCreatePairing(dataDir);
    this.current = pairing;
    this.created = created;
  }

  get token(): string {
    return this.current.token;
  }

  /** 重新签发 token 并落盘（0600）。 */
  reset(): Pairing {
    this.current = { token: randomBytes(24).toString("base64url"), createdAt: Date.now() };
    writeFileSync(path.join(this.dataDir, "pairing.json"), JSON.stringify(this.current, null, 2), {
      mode: 0o600,
    });
    return this.current;
  }
}
