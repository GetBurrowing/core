import { describe, it, expect, vi, afterEach } from "vitest"
import PushSubscribe, { nativePushPlugin } from "../../js/hooks/push_subscribe.js"

/**
 * The `PushSubscribe` hook (task 01a10882 stage 3).
 *
 * Inside the Suite iOS app the page runs in a Capacitor web view, so the hook
 * must hand push to the app's `SuiteNative` plugin and never touch
 * `pushManager`. The honesty rule from task 019ffe52 carries over: "granted"
 * reaches the server ONLY when the native device registration POST
 * succeeded. The browser branch must be unchanged.
 *
 * vitest runs in plain node here (no DOM), so `window`, `document`,
 * `Notification` and `navigator` are stubbed per test.
 */

function mountHook() {
  const events = []
  const handlers = {}
  const hook = Object.assign(Object.create(PushSubscribe), {
    pushEvent: (name, payload) => events.push([name, payload]),
    handleEvent: (name, fn) => {
      handlers[name] = fn
    }
  })
  hook.mounted()
  return { hook, events, handlers }
}

const flush = () => new Promise(resolve => setTimeout(resolve, 0))

function stubNative(plugin) {
  vi.stubGlobal("window", {
    Capacitor: { isNativePlatform: () => true, Plugins: { SuiteNative: plugin } }
  })
  // No VAPID meta: the native branch must not depend on it.
  vi.stubGlobal("document", { querySelector: () => null })
}

function stubBrowser({ permission, pushManager }) {
  vi.stubGlobal("window", {})
  vi.stubGlobal("document", {
    querySelector: () => ({ getAttribute: () => "BPublicKey" })
  })
  vi.stubGlobal("Notification", { permission, requestPermission: vi.fn() })
  vi.stubGlobal("navigator", {
    serviceWorker: { ready: Promise.resolve({ pushManager }) }
  })
  window.Notification = globalThis.Notification
}

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("nativePushPlugin", () => {
  it("is null in a browser without Capacitor", () => {
    expect(nativePushPlugin({})).toBe(null)
  })

  it("is null when Capacitor reports a web platform", () => {
    const win = { Capacitor: { isNativePlatform: () => false, Plugins: { SuiteNative: {} } } }
    expect(nativePushPlugin(win)).toBe(null)
  })

  it("returns SuiteNative on the native platform", () => {
    const plugin = { enablePush() {} }
    const win = { Capacitor: { isNativePlatform: () => true, Plugins: { SuiteNative: plugin } } }
    expect(nativePushPlugin(win)).toBe(plugin)
  })
})

describe("native branch", () => {
  // The banner's dismissal is per USER, so a person who dismissed it on a
  // desktop never sees it in the app. Waiting for its click would mean iOS
  // never prompts on a new device and push can never be enabled there.
  it("asks iOS on mount when it has not been asked yet, without a click", async () => {
    const enablePush = vi.fn(async () => ({ registered: true }))
    stubNative({ pushState: async () => ({ state: "prompt" }), enablePush })
    const { events } = mountHook()
    await flush()
    await flush()
    expect(enablePush).toHaveBeenCalledTimes(1)
    expect(events).toEqual([["push_permission_state", { state: "granted" }]])
  })

  it("does not ask iOS on mount when the person already declined", async () => {
    const enablePush = vi.fn(async () => ({ registered: true }))
    stubNative({ pushState: async () => ({ state: "denied" }), enablePush })
    const { events } = mountHook()
    await flush()
    await flush()
    expect(enablePush).not.toHaveBeenCalled()
    expect(events).toEqual([["push_permission_state", { state: "denied" }]])
  })

  it("reports prompt and waits for the click when pushState fails", async () => {
    const enablePush = vi.fn(async () => ({ registered: true }))
    stubNative({ pushState: async () => { throw new Error("bridge down") }, enablePush })
    const { events, handlers } = mountHook()
    await flush()
    expect(enablePush).not.toHaveBeenCalled()
    expect(events).toEqual([["push_permission_state", { state: "prompt" }]])
    handlers.request_push_permission()
    await flush()
    expect(enablePush).toHaveBeenCalledTimes(1)
    expect(events.at(-1)).toEqual(["push_permission_state", { state: "granted" }])
  })

  it("does NOT report granted when the registration POST failed", async () => {
    const enablePush = vi.fn(async () => {
      const err = new Error("POST /api/app/devices returned 500")
      err.code = "registration_failed"
      throw err
    })
    stubNative({ pushState: async () => ({ state: "prompt" }), enablePush })
    const { events } = mountHook()
    await flush()
    await flush()
    expect(events.some(([, p]) => p?.state === "granted")).toBe(false)
    expect(events.at(-1)).toEqual([
      "push_subscribe_failed",
      { name: "registration_failed", message: "POST /api/app/devices returned 500" }
    ])
  })

  it("does NOT report granted when enablePush resolves without registering", async () => {
    stubNative({
      pushState: async () => ({ state: "prompt" }),
      enablePush: async () => ({ registered: false, state: "granted", error: "no session" })
    })
    const { events } = mountHook()
    await flush()
    await flush()
    expect(events.some(([, p]) => p?.state === "granted")).toBe(false)
    expect(events.at(-1)[0]).toBe("push_subscribe_failed")
  })

  it("reports denied when the person declines the iOS prompt", async () => {
    stubNative({
      pushState: async () => ({ state: "prompt" }),
      enablePush: async () => ({ registered: false, state: "denied" })
    })
    const { events } = mountHook()
    await flush()
    await flush()
    expect(events.at(-1)).toEqual(["push_permission_state", { state: "denied" }])
  })

  it("re-registers silently on mount when already allowed", async () => {
    const enablePush = vi.fn(async () => ({ registered: true }))
    stubNative({ pushState: async () => ({ state: "granted" }), enablePush })
    const { events } = mountHook()
    await flush()
    await flush()
    expect(enablePush).toHaveBeenCalledTimes(1)
    expect(events).toEqual([["push_permission_state", { state: "granted" }]])
  })

  it("never touches pushManager or Notification", async () => {
    const pushManager = { getSubscription: vi.fn(), subscribe: vi.fn() }
    vi.stubGlobal("navigator", { serviceWorker: { ready: Promise.resolve({ pushManager }) } })
    const requestPermission = vi.fn()
    vi.stubGlobal("Notification", { permission: "granted", requestPermission })
    stubNative({ pushState: async () => ({ state: "granted" }), enablePush: async () => ({ registered: true }) })
    const { handlers } = mountHook()
    await flush()
    handlers.request_push_permission()
    await flush()
    expect(pushManager.getSubscription).not.toHaveBeenCalled()
    expect(pushManager.subscribe).not.toHaveBeenCalled()
    expect(requestPermission).not.toHaveBeenCalled()
  })
})

describe("browser branch (unchanged)", () => {
  it("reports unsupported without a VAPID key", () => {
    vi.stubGlobal("window", {})
    vi.stubGlobal("document", { querySelector: () => null })
    const { events } = mountHook()
    expect(events).toEqual([["push_unsupported", {}]])
  })

  it("reports denied from Notification.permission", () => {
    stubBrowser({ permission: "denied", pushManager: {} })
    const { events } = mountHook()
    expect(events).toEqual([["push_permission_state", { state: "denied" }]])
  })

  it("reports prompt for the default permission", () => {
    stubBrowser({ permission: "default", pushManager: {} })
    const { events } = mountHook()
    expect(events).toEqual([["push_permission_state", { state: "prompt" }]])
  })

  it("subscribes through pushManager when already granted", async () => {
    const sub = {
      toJSON: () => ({ endpoint: "https://push.example/e", keys: { p256dh: "p", auth: "a" } })
    }
    const pushManager = { getSubscription: vi.fn(async () => sub), subscribe: vi.fn() }
    stubBrowser({ permission: "granted", pushManager })
    const { events } = mountHook()
    await flush()
    await flush()
    expect(pushManager.getSubscription).toHaveBeenCalled()
    expect(events).toContainEqual(["push_permission_state", { state: "granted" }])
    expect(events).toContainEqual([
      "push_subscribed",
      { endpoint: "https://push.example/e", keys: { p256dh: "p", auth: "a" } }
    ])
  })
})
