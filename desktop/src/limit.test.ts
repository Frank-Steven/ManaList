import assert from "node:assert/strict";
import { test } from "node:test";

import { GateBusyError, GatePool, SerialGate } from "./limit.js";

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

test("串行：并发峰值始终为 1", async () => {
  const gate = new SerialGate(1, 8);
  let active = 0;
  let peak = 0;
  const task = async () => {
    active++;
    peak = Math.max(peak, active);
    await sleep(10);
    active--;
  };
  await Promise.all([gate.run(task), gate.run(task), gate.run(task)]);
  assert.equal(peak, 1);
  assert.equal(gate.activeCount, 0);
});

test("maxConcurrent=2 时允许两个并行", async () => {
  const gate = new SerialGate(2, 8);
  let active = 0;
  let peak = 0;
  const task = async () => {
    active++;
    peak = Math.max(peak, active);
    await sleep(15);
    active--;
  };
  await Promise.all([gate.run(task), gate.run(task), gate.run(task), gate.run(task)]);
  assert.equal(peak, 2);
});

test("队列满 → GateBusyError（而不是无界排队）", async () => {
  const gate = new SerialGate(1, 1);
  const slow = () => sleep(50);
  const p1 = gate.run(slow);
  const p2 = gate.run(slow);
  await assert.rejects(
    () => gate.run(slow),
    (e: unknown) => e instanceof GateBusyError && e.code === "GATE_BUSY",
  );
  await Promise.all([p1, p2]);
  assert.equal(gate.activeCount, 0);
});

test("任务抛错也会释放槽位", async () => {
  const gate = new SerialGate(1, 1);
  await assert.rejects(() =>
    gate.run(async () => {
      throw new Error("boom");
    }),
  );
  assert.equal(await gate.run(async () => 42), 42);
});

test("acquireSlot 重复调用释放函数只释放一次", async () => {
  const gate = new SerialGate(1, 1);
  const release = await gate.acquireSlot();
  assert.equal(gate.activeCount, 1);
  release();
  release();
  assert.equal(gate.activeCount, 0);
});

test("GatePool：不同 key 并行，同一 key 串行", async () => {
  const pool = new GatePool(1, 8);
  let activeA = 0;
  let peakA = 0;
  let overlap = 0; // a 与 b 同时运行的采样计数
  const taskA = async () => {
    activeA++;
    peakA = Math.max(peakA, activeA);
    await sleep(20);
    activeA--;
  };
  const taskB = async () => {
    if (activeA > 0) overlap++;
    await sleep(20);
  };
  await Promise.all([
    pool.gateFor("a").run(taskA),
    pool.gateFor("a").run(taskA),
    pool.gateFor("b").run(taskB),
  ]);
  assert.equal(peakA, 1, "同一 key 必须串行");
  assert.ok(overlap > 0, "不同 key 应并行");
});

test("GatePool：同一 key 的排队上限独立生效", async () => {
  const pool = new GatePool(1, 1);
  const slow = () => sleep(50);
  const p1 = pool.gateFor("a").run(slow);
  const p2 = pool.gateFor("a").run(slow);
  await assert.rejects(() => pool.gateFor("a").run(slow), GateBusyError);
  // key b 的闸不受 a 排队满影响
  assert.equal(await pool.gateFor("b").run(async () => 7), 7);
  await Promise.all([p1, p2]);
});

test("GatePool：同一 key 返回同一个闸实例", () => {
  const pool = new GatePool();
  assert.equal(pool.gateFor("x"), pool.gateFor("x"));
  assert.notEqual(pool.gateFor("x"), pool.gateFor("y"));
});
