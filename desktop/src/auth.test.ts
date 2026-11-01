import assert from "node:assert/strict";
import { test } from "node:test";

import { isBearerTokenMatch, safeEqual } from "./auth.js";

/// P2-3 回归：Authorization 校验必须常量时间比较，且行为与旧实现一致。
const TOKEN = "AbCdEf1234567890_-xyz";

test("正确的 Bearer token → 通过", () => {
  assert.equal(isBearerTokenMatch(`Bearer ${TOKEN}`, TOKEN), true);
});

test("错误的 token（同长度）→ 拒绝", () => {
  const wrong = "X".repeat(TOKEN.length);
  assert.equal(isBearerTokenMatch(`Bearer ${wrong}`, TOKEN), false);
});

test("错误 token（不同长度）→ 拒绝且不抛异常", () => {
  assert.equal(isBearerTokenMatch("Bearer short", TOKEN), false);
  assert.equal(isBearerTokenMatch(`Bearer ${TOKEN}extra`, TOKEN), false);
});

test("缺少头 / 头格式不对 → 拒绝", () => {
  assert.equal(isBearerTokenMatch(undefined, TOKEN), false);
  assert.equal(isBearerTokenMatch("", TOKEN), false);
  assert.equal(isBearerTokenMatch(TOKEN, TOKEN), false);
  assert.equal(isBearerTokenMatch(`bearer ${TOKEN}`, TOKEN), false);
  assert.equal(isBearerTokenMatch(`Basic ${TOKEN}`, TOKEN), false);
});

test("token 为空时一律拒绝（避免空口令放行）", () => {
  assert.equal(isBearerTokenMatch("Bearer ", ""), false);
  assert.equal(isBearerTokenMatch("anything", ""), false);
});

test("safeEqual：相同/不同/不同长度", () => {
  assert.equal(safeEqual("abc", "abc"), true);
  assert.equal(safeEqual("abc", "abd"), false);
  assert.equal(safeEqual("abc", "abcd"), false);
  assert.equal(safeEqual("", ""), true);
});
