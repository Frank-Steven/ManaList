import assert from "node:assert/strict";
import { test } from "node:test";

import { parseDevicesList } from "./adb.js";

/// B21 回归（2026-11-11）：adb 37.0.1 的 `adb devices -l` 用**空格**分隔列，
/// 旧实现硬依赖 `line.includes("\tdevice")` → 有设备仍判 absent、reverse 不执行。
/// 本文件只测纯解析函数，不执行真实 adb。

const HEADER = "List of devices attached";

test("空格分隔（adb 37.0.1 真实形态，7 个空格）→ ok + 解析出 serial/model", () => {
  const out = [
    HEADER,
    "7NQBB24509006610       device product:STG-AL00 model:STG_AL00 device:STG transport_id:1",
    "",
  ].join("\n");
  const scan = parseDevicesList(out);
  assert.equal(scan.state, "ok");
  assert.equal(scan.devices.length, 1);
  assert.equal(scan.devices[0].serial, "7NQBB24509006610");
  assert.equal(scan.devices[0].model, "STG_AL00");
});

test("Tab 分隔（旧版 adb）→ 仍然 ok", () => {
  const out = [HEADER, "emulator-5554\tdevice product:sdk model:Pixel_X device:generic transport_id:2", ""].join("\n");
  const scan = parseDevicesList(out);
  assert.equal(scan.state, "ok");
  assert.equal(scan.devices[0].serial, "emulator-5554");
  assert.equal(scan.devices[0].model, "Pixel_X");
});

test("CRLF 行尾 + 尾部空行 → ok", () => {
  const out = HEADER + "\r\n" + "7NQBB24509006610   device model:STG_AL00 transport_id:1\r\n\r\n";
  const scan = parseDevicesList(out);
  assert.equal(scan.state, "ok");
  assert.equal(scan.devices[0].model, "STG_AL00");
});

test("仅 unauthorized → state=unauthorized，且不计入设备列表", () => {
  const out = [HEADER, "7NQBB24509006610       unauthorized usb:1-1 transport_id:3", ""].join("\n");
  const scan = parseDevicesList(out);
  assert.equal(scan.state, "unauthorized");
  assert.deepEqual(scan.devices, []);
});

test("无设备（只有 header）→ absent + 空列表", () => {
  const scan = parseDevicesList(HEADER + "\n");
  assert.equal(scan.state, "absent");
  assert.deepEqual(scan.devices, []);
});

test("空输出 → absent", () => {
  const scan = parseDevicesList("");
  assert.equal(scan.state, "absent");
  assert.deepEqual(scan.devices, []);
});

test("daemon 启动/版本提示行不影响判定（真实启动场景）", () => {
  const out = [
    "* daemon not running; starting now at tcp:5037",
    "* daemon started successfully",
    HEADER,
    "7NQBB24509006610       device model:STG_AL00 transport_id:1",
    "",
  ].join("\n");
  const scan = parseDevicesList(out);
  assert.equal(scan.state, "ok");
  assert.equal(scan.devices.length, 1);
});

test("adb server 版本不匹配提示行被忽略", () => {
  const out = [
    "adb server version (41) doesn't match this client (40); killing...",
    "* daemon started successfully",
    HEADER,
    "7NQBB24509006610       device model:STG_AL00",
  ].join("\n");
  const scan = parseDevicesList(out);
  assert.equal(scan.state, "ok");
});

test("offline / no permissions 不算 ok（旧行为保持）", () => {
  const out = [HEADER, "7NQBB24509006610       offline", "abc123   no permissions (user in plugdev group)"].join("\n");
  const scan = parseDevicesList(out);
  assert.equal(scan.state, "absent");
  assert.deepEqual(scan.devices, []);
});

test("多设备：首个可判定行为 ok，列表含全部 device，缺 model 给未知型号", () => {
  const out = [
    HEADER,
    "devA       device transport_id:1",
    "devB       unauthorized usb:1-2",
    "devC       device model:M3 transport_id:3",
  ].join("\n");
  const scan = parseDevicesList(out);
  assert.equal(scan.state, "ok");
  assert.deepEqual(scan.devices.map((d) => d.serial), ["devA", "devC"]);
  assert.equal(scan.devices[0].model, "未知型号");
  assert.equal(scan.devices[1].model, "M3");
});

test("先 unauthorized 后 device：state 取首个可判定行（unauthorized）", () => {
  const out = [
    HEADER,
    "devB       unauthorized usb:1-2",
    "devC       device model:M3",
  ].join("\n");
  const scan = parseDevicesList(out);
  assert.equal(scan.state, "unauthorized");
  assert.deepEqual(scan.devices.map((d) => d.serial), ["devC"]);
});

test("多个空格/混合空白分隔都能取到 serial", () => {
  const out = [HEADER, "   devX    device   model:M1   transport_id:9  ", ""].join("\n");
  const scan = parseDevicesList(out);
  assert.equal(scan.state, "ok");
  assert.equal(scan.devices[0].serial, "devX");
});
