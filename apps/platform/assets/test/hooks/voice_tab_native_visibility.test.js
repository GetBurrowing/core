import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"

/**
 * The on-device Voice island tells the server when the page is visible
 * (task 01a21e8d stage 3), so the server stops treating a backgrounded app
 * as a listener and its pushes go out again:
 *
 *   - `voice_native_visible {visible}` on every visibility change, never the
 *     same value twice in a row; `pagehide` sends false;
 *   - `voice_native_ready` carries `visible`;
 *   - the voice plugin's `appStateChanged {active}` sends the same, when the
 *     plugin has it, and is removed on destroy; no other plugin is touched.
 *
 * The setup is a minimal copy of voice_tab_native.test.js's fakes (not an
 * import, so the two files stay independent).
 */

vi.mock("livekit-client", async (importOriginal) => {
  const actual = await importOriginal()
  class Room {
    on() {
      return this
    }
    connect() {
      return Promise.resolve()
    }
    disconnect() {
      return Promise.resolve()
    }
  }
  return { ...actual, Room }
})

import VoiceTab from "../../js/hooks/voice_tab.js"
import VoiceTabNative from "../../js/hooks/voice_tab_native_runtime.js"
import { __resetForTests as resetClientState } from "../../js/client_state.js"

const TURN_TEXT = "what is left on the list"

function fakeDocument() {
  const target = new EventTarget()
  return Object.assign(target, {
    visibilityState: "visible",
    getElementById: () => null,
    createElement: () => ({ setAttribute() {}, appendChild() {}, children: [] }),
    head: { appendChild() {} },
  })
}

function fakePlugin() {
  const listeners = {}
  return {
    listeners,
    capabilities: vi.fn(() =>
      Promise.resolve({ onDeviceSpeech: true, reason: null, locale: "en-US", testBuild: false, micPermission: "granted" }),
    ),
    prepare: vi.fn(() => Promise.reject(new Error("no assets"))),
    start: vi.fn(() => Promise.resolve({ started: true, route: null })),
    stop: vi.fn(() => Promise.resolve({ text: TURN_TEXT })),
    cancel: vi.fn(() => Promise.resolve()),
    speak: vi.fn(() => Promise.resolve({ spoken: true })),
    voices: vi.fn(() => Promise.resolve({ voices: [], default: null })),
    stopSpeaking: vi.fn(() => Promise.resolve()),
    addListener: vi.fn((event, fn) => {
      listeners[event] = fn
      return Promise.resolve({ remove: vi.fn() })
    }),
  }
}

let windowListeners

function install({ plugin, meetings } = {}) {
  windowListeners = {}
  const Plugins = { BurrowVoice: plugin }
  if (meetings) Plugins.BurrowMeetings = meetings
  vi.stubGlobal("window", {
    __burrowVoiceNative: VoiceTabNative,
    Capacitor: { isNativePlatform: () => true, Plugins },
    addEventListener: (t, fn) => (windowListeners[t] = fn),
    removeEventListener: (t) => delete windowListeners[t],
  })
}

async function mount() {
  const mic = {
    id: "mic",
    disabled: false,
    setPointerCapture() {},
    releasePointerCapture() {},
    closest() {
      return this
    },
    getBoundingClientRect: () => ({ left: 0, right: 10, top: 0, bottom: 10 }),
  }
  const pushed = []
  const el = {
    dataset: { userId: "u1", partnerId: "a1" },
    addEventListener() {},
    removeEventListener() {},
    querySelector: (sel) => (sel === "#mic" ? mic : null),
    querySelectorAll: () => [],
  }
  vi.stubGlobal("navigator", { mediaDevices: { getUserMedia: vi.fn() } })
  const hook = Object.create(VoiceTab)
  hook.el = el
  hook.pushEvent = (event, payload, cb) => {
    pushed.push([event, payload])
    if (event === "voice_native_turn" && cb) cb({ ok: true, message_id: "m1" })
  }
  hook.handleEvent = () => {}
  hook.mounted()
  await hook._probe
  await settle()
  return {
    hook,
    pushed,
    sent: (name) => pushed.filter(([e]) => e === name).map(([, p]) => p),
  }
}

const settle = async () => {
  for (let i = 0; i < 5; i++) await new Promise((r) => setTimeout(r, 0))
}

const setVisibility = (state) => {
  document.visibilityState = state
  document.dispatchEvent(new Event("visibilitychange"))
}

beforeEach(() => {
  resetClientState()
  vi.stubGlobal("performance", { now: () => 0 })
  vi.stubGlobal("document", fakeDocument())
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("voice_native_visible", () => {
  it("hidden pushes visible:false once, visible pushes visible:true", async () => {
    install({ plugin: fakePlugin() })
    const t = await mount()
    expect(t.sent("voice_native_visible")).toEqual([])

    setVisibility("hidden")
    expect(t.sent("voice_native_visible")).toEqual([{ visible: false }])

    setVisibility("visible")
    expect(t.sent("voice_native_visible")).toEqual([{ visible: false }, { visible: true }])
  })

  it("pagehide pushes visible:false", async () => {
    install({ plugin: fakePlugin() })
    const t = await mount()
    windowListeners.pagehide()
    expect(t.sent("voice_native_visible")).toEqual([{ visible: false }])
  })

  it("repeated identical states push once", async () => {
    install({ plugin: fakePlugin() })
    const t = await mount()

    setVisibility("visible")
    setVisibility("hidden")
    setVisibility("hidden")
    windowListeners.pagehide()
    setVisibility("visible")
    setVisibility("visible")

    expect(t.sent("voice_native_visible")).toEqual([{ visible: false }, { visible: true }])
  })
})

describe("voice_native_ready carries visible", () => {
  it("absent (visible) when the page is visible, so older servers see today's payload", async () => {
    install({ plugin: fakePlugin() })
    const t = await mount()
    expect(t.sent("voice_native_ready")).toHaveLength(1)
    expect("visible" in t.sent("voice_native_ready")[0]).toBe(false)
  })

  it("false on a reconnect while hidden, and the next visible is pushed", async () => {
    install({ plugin: fakePlugin() })
    const t = await mount()

    setVisibility("hidden")
    t.hook.reconnected()
    expect(t.sent("voice_native_ready").map((p) => p.visible)).toEqual([undefined, false])

    setVisibility("visible")
    expect(t.sent("voice_native_visible")).toEqual([{ visible: false }, { visible: true }])
  })
})

describe("appStateChanged on the voice plugin", () => {
  it("active:false pushes false, active:true pushes true, deduped", async () => {
    const plugin = fakePlugin()
    install({ plugin })
    const t = await mount()

    expect(plugin.addListener).toHaveBeenCalledWith("appStateChanged", expect.any(Function))
    plugin.listeners.appStateChanged({ active: false, background: true })
    plugin.listeners.appStateChanged({ active: false })
    plugin.listeners.appStateChanged({ active: true })
    plugin.listeners.appStateChanged({})
    plugin.listeners.appStateChanged(undefined)

    expect(t.sent("voice_native_visible")).toEqual([{ visible: false }, { visible: true }])
  })

  it("is removed on destroy", async () => {
    const plugin = fakePlugin()
    const handle = { remove: vi.fn() }
    const add = plugin.addListener
    plugin.addListener = vi.fn((event, fn) => (event === "appStateChanged" ? (add(event, fn), Promise.resolve(handle)) : add(event, fn)))
    install({ plugin })
    const t = await mount()
    t.hook.destroyed()
    await settle()
    expect(handle.remove).toHaveBeenCalledTimes(1)
  })

  it("a plugin whose addListener throws for it does not throw", async () => {
    const plugin = fakePlugin()
    const add = plugin.addListener
    plugin.addListener = vi.fn((event, fn) => {
      if (event === "appStateChanged") throw new Error("no such event")
      return add(event, fn)
    })
    install({ plugin })
    const t = await mount()
    setVisibility("hidden")
    expect(t.sent("voice_native_visible")).toEqual([{ visible: false }])
  })

  it("never touches another plugin", async () => {
    const other = { addListener: vi.fn() }
    install({ plugin: fakePlugin(), meetings: other })
    await mount()
    expect(other.addListener).not.toHaveBeenCalled()
  })
})

describe("no text leaves in these payloads", () => {
  it("visible and ready payloads carry no turn or reply text", async () => {
    const plugin = fakePlugin()
    install({ plugin })
    const t = await mount()

    setVisibility("hidden")
    setVisibility("visible")
    windowListeners.pagehide()
    plugin.listeners.appStateChanged({ active: true })
    t.hook.reconnected()

    const payloads = [...t.sent("voice_native_visible"), ...t.sent("voice_native_ready")]
    expect(payloads.length).toBeGreaterThan(0)
    for (const p of payloads) {
      expect(JSON.stringify(p)).not.toContain(TURN_TEXT)
      expect(Object.keys(p)).not.toContain("text")
    }
    for (const p of t.sent("voice_native_visible")) expect(Object.keys(p)).toEqual(["visible"])
  })
})
