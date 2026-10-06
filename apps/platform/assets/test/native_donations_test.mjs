// Task 01a111bb stage 2: `phx:native_donate` reaches SuiteNative.donate inside
// the Burrow app, and does nothing in a plain browser.
import test from "node:test";
import assert from "node:assert/strict";
import { installNativeDonations, nativeDonatePlugin } from "../js/native_donations.js";

function fakeWindow(capacitor) {
  const listeners = {};
  return {
    Capacitor: capacitor,
    addEventListener(name, fn) {
      (listeners[name] ||= []).push(fn);
    },
    dispatch(name, detail) {
      (listeners[name] || []).forEach((fn) => fn({ detail }));
    },
  };
}

test("inside the app, the payload is forwarded unchanged to SuiteNative.donate", () => {
  const calls = [];
  const win = fakeWindow({
    isNativePlatform: () => true,
    Plugins: { SuiteNative: { donate: (detail) => calls.push(detail) } },
  });

  installNativeDonations(win);
  const detail = { kind: "meeting_started", meeting_id: "m-1" };
  win.dispatch("phx:native_donate", detail);

  assert.deepEqual(calls, [detail]);
});

test("in a browser (no native platform) nothing is called and nothing throws", () => {
  const calls = [];
  const browser = fakeWindow({
    isNativePlatform: () => false,
    Plugins: { SuiteNative: { donate: (d) => calls.push(d) } },
  });

  installNativeDonations(browser);
  browser.dispatch("phx:native_donate", { kind: "task_created", task_id: "t" });

  assert.deepEqual(calls, []);
  assert.equal(nativeDonatePlugin(fakeWindow(undefined)), null);
});

test("an app build without donate is a no-op, and a rejected promise is swallowed", async () => {
  const old = fakeWindow({ isNativePlatform: () => true, Plugins: { SuiteNative: {} } });
  installNativeDonations(old);
  old.dispatch("phx:native_donate", { kind: "task_created" });

  const rejecting = fakeWindow({
    isNativePlatform: () => true,
    Plugins: { SuiteNative: { donate: () => Promise.reject(new Error("no")) } },
  });
  installNativeDonations(rejecting);
  rejecting.dispatch("phx:native_donate", { kind: "task_created" });
  await new Promise((r) => setTimeout(r, 0));
});
