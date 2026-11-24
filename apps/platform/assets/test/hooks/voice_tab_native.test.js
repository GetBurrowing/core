import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

/**
 * VoiceTab on the device (task 01a20dc5 stage 3). A mocked
 * `window.Capacitor.Plugins.BurrowVoice` stands in for the iOS plugin
 * (clients/ios/ios/App/App/Plugins/BurrowVoicePlugin.swift) and records
 * every call. Assertions are on what reached the server (pushEvent) and the
 * plugin, plus the text the hook draws in #voice-native-pending.
 *
 * Without the plugin (a browser, Android, an older app build), or when it
 * says no for any reason or throws, a press must behave exactly as on main:
 * getUserMedia, then `voice_start`.
 */

const lk = vi.hoisted(() => ({ rooms: [] }))

vi.mock("livekit-client", async (importOriginal) => {
  const actual = await importOriginal()
  class Room {
    constructor() {
      const pub = {
        isMuted: false,
        track: { mediaStreamTrack: { readyState: "live", enabled: true, getSettings: () => ({}) } },
        mute() {
          this.isMuted = true
          return Promise.resolve()
        },
        unmute() {
          this.isMuted = false
          return Promise.resolve()
        },
      }
      this.localParticipant = {
        setMicrophoneEnabled: () => Promise.resolve(),
        getTrackPublication: () => pub,
      }
      lk.rooms.push(this)
    }
    on() {
      return this
    }
    connect() {
      return Promise.resolve()
    }
    disconnect() {
      return Promise.resolve()
    }
    getActiveDevice() {
      return undefined
    }
  }
  return { ...actual, Room }
})

import VoiceTab, {
  NO_WORDS_MS,
  TURN_CAP_MS,
  TURN_WARN_MS,
  VOICE_NATIVE_ISLAND,
} from "../../js/hooks/voice_tab.js"
import { onDeviceVoiceCapability } from "../../js/lib/on_device_voice.js"
import VoiceTabNative from "../../js/hooks/voice_tab_native_runtime.js"
import { DRAG_CANCEL_PX } from "../../js/hooks/voice_tab_shared.js"

const REASONS = ["os_too_old", "unavailable", "locale_unsupported", "speech_permission_denied", "assets_missing"]

// ── a tiny DOM: just what the hook's pending area touches ─────────────────

function matches(node, sel) {
  const m = sel.match(/^\[([\w-]+)(?:=([\w-]+))?\]$/)
  if (!m) return false
  const v = node.getAttribute ? node.getAttribute(m[1]) : null
  return m[2] === undefined ? v !== null : v === m[2]
}

function element(tag) {
  return {
    tag,
    children: [],
    attrs: {},
    className: "",
    _text: "",
    parent: null,
    get textContent() {
      return this._text + this.children.map((c) => c.textContent).join("")
    },
    set textContent(v) {
      this._text = String(v)
      this.children = []
    },
    set innerHTML(_v) {
      throw new Error("innerHTML is never used")
    },
    get parentNode() {
      return this.parent
    },
    appendChild(c) {
      if (c.parent) c.remove()
      c.parent = this
      this.children.push(c)
      return c
    },
    remove() {
      if (this.parent) this.parent.children = this.parent.children.filter((x) => x !== this)
      this.parent = null
    },
    setAttribute(k, v) {
      this.attrs[k] = String(v)
    },
    getAttribute(k) {
      return k in this.attrs ? this.attrs[k] : null
    },
    closest(sel) {
      let n = this
      while (n) {
        if (matches(n, sel)) return n
        n = n.parent
      }
      return null
    },
    querySelector(sel) {
      for (const c of this.children) {
        const f = c.find(sel)
        if (f) return f
      }
      return null
    },
    find(sel) {
      if (matches(this, sel)) return this
      for (const c of this.children) {
        const f = c.find(sel)
        if (f) return f
      }
      return null
    },
  }
}

let documentListeners = {}

function fakeDocument(pending) {
  documentListeners = {}
  const target = new EventTarget()
  const doc = Object.assign(target, {
    visibilityState: "visible",
    getElementById: (id) => (id === "voice-native-pending" ? pending : null),
    createElement: (tag) => element(tag),
    head: {
      appended: [],
      appendChild(node) {
        this.appended.push(node)
      },
    },
  })
  const add = target.addEventListener.bind(target)
  const remove = target.removeEventListener.bind(target)
  doc.addEventListener = (type, fn, opts) => {
    documentListeners[type] = fn
    add(type, fn, opts)
  }
  doc.removeEventListener = (type, fn, opts) => {
    if (documentListeners[type] === fn) delete documentListeners[type]
    remove(type, fn, opts)
  }
  return doc
}

// ── the plugin ────────────────────────────────────────────────────────────

function fakePlugin({ caps, start, stopText = "what is left on the list", prepare } = {}) {
  const listeners = {}
  const plugin = {
    listeners,
    capabilities: vi.fn(() =>
      typeof caps === "function"
        ? caps()
        : Promise.resolve(
            caps || { onDeviceSpeech: true, reason: null, locale: "en-US", testBuild: true, micPermission: "granted" },
          ),
    ),
    prepare: vi.fn(prepare || (() => Promise.reject(new Error("no assets")))),
    start: vi.fn(start || (() => Promise.resolve({ started: true, route: null }))),
    stop: vi.fn(() => Promise.resolve({ text: stopText })),
    cancel: vi.fn(() => Promise.resolve()),
    speak: vi.fn(() => Promise.resolve({ spoken: true })),
    stopSpeaking: vi.fn(() => Promise.resolve()),
    openSettings: vi.fn(() => Promise.resolve({ opened: true })),
    addListener: vi.fn((event, fn) => {
      listeners[event] = fn
      return Promise.resolve({ remove: vi.fn() })
    }),
    emit(event, data) {
      if (listeners[event]) listeners[event](data)
    },
  }
  return plugin
}

// ── the hook ──────────────────────────────────────────────────────────────

let clock = 0
let pending
let windowListeners

// `island: false` leaves the voice_native island unloaded, so the hook has to
// fetch it; by default it is already on the page, as after its script ran.
function install({ plugin, native = true, meetings, island = true } = {}) {
  windowListeners = {}
  const Plugins = {}
  if (plugin) Plugins.BurrowVoice = plugin
  if (meetings) Plugins.BurrowMeetings = meetings
  const win = {
    __burrowVoiceNative: island ? VoiceTabNative : undefined,
    Capacitor: { isNativePlatform: () => native, Plugins },
    addEventListener: (t, fn) => (windowListeners[t] = fn),
    removeEventListener: (t) => delete windowListeners[t],
  }
  vi.stubGlobal("window", win)
  return win
}

async function mount({ turnReply = { ok: true, message_id: "m1" }, noTurnReply = false } = {}) {
  const mic = {
    id: "mic",
    disabled: false,
    setPointerCapture() {},
    releasePointerCapture() {},
    closest() {
      return this
    },
    getBoundingClientRect: () => ({ left: 100, right: 196, top: 500, bottom: 596 }),
  }
  const listeners = {}
  const pushed = []
  const handlers = {}
  const el = {
    dataset: { userId: "u1", partnerId: "a1" },
    addEventListener: (type, fn) => (listeners[type] = fn),
    removeEventListener: (type) => delete listeners[type],
    querySelector: (sel) => (sel === "#mic" ? mic : null),
    querySelectorAll: () => [],
  }
  const gum = vi.fn(() => Promise.resolve({ getTracks: () => [{ stop() {} }] }))
  vi.stubGlobal("navigator", { mediaDevices: { getUserMedia: gum } })

  const hook = Object.create(VoiceTab)
  hook.el = el
  hook.pushEvent = (event, payload, cb) => {
    pushed.push([event, payload])
    if (event === "voice_start" && cb) cb({ ok: true, token: "tok", url: "ws://lk.test", room: "dm" })
    if (event === "voice_native_turn" && cb && !noTurnReply) cb(typeof turnReply === "function" ? turnReply() : turnReply)
  }
  hook.handleEvent = (event, fn) => (handlers[event] = fn)
  hook.mounted()
  await hook._probe

  const fire = (type, event) => listeners[type] && listeners[type](event)
  return {
    hook,
    mic,
    gum,
    handlers,
    pushed,
    events: () => pushed.map(([e]) => e),
    sent: (name) => pushed.filter(([e]) => e === name).map(([, p]) => p),
    down: (at = clock, at2 = {}) => {
      clock = at
      fire("pointerdown", { target: mic, button: 0, pointerId: 1, clientX: 148, clientY: 548, preventDefault() {}, ...at2 })
    },
    up: (at) => {
      clock = at
      fire("pointerup", { target: mic, pointerId: 1 })
    },
    move: (x, y) => fire("pointermove", { target: mic, pointerId: 1, clientX: x, clientY: y }),
    click: (target) => documentListeners.click && documentListeners.click({ target }),
  }
}

const settle = async () => {
  for (let i = 0; i < 5; i++) await new Promise((r) => setTimeout(r, 0))
}

beforeEach(() => {
  clock = 0
  lk.rooms = []
  pending = element("div")
  vi.stubGlobal("performance", { now: () => clock })
  vi.stubGlobal("document", fakeDocument(pending))
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

const turnNode = () => pending.find("[data-native-turn]")

// ── the fallback: exactly today's path ────────────────────────────────────

describe("without the on-device path a press is today's LiveKit press", () => {
  const expectToday = async (t, plugin) => {
    t.down(0)
    await settle()
    expect(t.gum).toHaveBeenCalledTimes(1)
    expect(t.events()).toContain("voice_start")
    expect(t.events()).not.toContain("voice_native_ready")
    expect(lk.rooms.length).toBe(1)
    if (plugin) expect(plugin.start).not.toHaveBeenCalled()
  }

  it("in a browser (no window.Capacitor)", async () => {
    vi.stubGlobal("window", {})
    await expectToday(await mount())
  })

  it("on Android or the web inside Capacitor (not native)", async () => {
    const plugin = fakePlugin()
    install({ plugin, native: false })
    await expectToday(await mount(), plugin)
  })

  it("in an older app build without the plugin", async () => {
    install({})
    await expectToday(await mount())
  })

  it("when capabilities() throws", async () => {
    const plugin = fakePlugin({ caps: () => Promise.reject(new Error("UNIMPLEMENTED")) })
    install({ plugin })
    await expectToday(await mount(), plugin)
  })

  for (const reason of REASONS) {
    it(`when the phone says no: ${reason}`, async () => {
      const plugin = fakePlugin({ caps: { onDeviceSpeech: false, reason, testBuild: true, micPermission: "granted" } })
      install({ plugin })
      await expectToday(await mount(), plugin)
    })
  }

  it("onDeviceVoiceCapability resolves available:false on a throw, a hang and no plugin", async () => {
    expect((await onDeviceVoiceCapability({})).available).toBe(false)
    const throwing = { Capacitor: { isNativePlatform: () => { throw new Error("x") }, Plugins: {} } }
    expect((await onDeviceVoiceCapability(throwing)).available).toBe(false)
    const hanging = {
      Capacitor: { isNativePlatform: () => true, Plugins: { BurrowVoice: { capabilities: () => new Promise(() => {}) } } },
    }
    expect(await onDeviceVoiceCapability(hanging, 5)).toMatchObject({ available: false, reason: "error" })
    const yes = { Capacitor: { isNativePlatform: () => true, Plugins: { BurrowVoice: fakePlugin() } } }
    expect(await onDeviceVoiceCapability(yes)).toMatchObject({ available: true, reason: null, testBuild: true })
  })

  it("assets_missing prepares, then adopts the device path", async () => {
    const plugin = fakePlugin({
      caps: { onDeviceSpeech: false, reason: "assets_missing", micPermission: "granted" },
      prepare: () => Promise.resolve({ onDeviceSpeech: true, reason: null, testBuild: false, micPermission: "granted" }),
    })
    install({ plugin })
    const t = await mount()
    await settle()
    expect(plugin.prepare).toHaveBeenCalledTimes(1)
    expect(t.sent("voice_native_ready")).toEqual([
      { available: true, reason: null, locale: null, test_build: false, route: null },
    ])
  })
})

// ── the on-device press ──────────────────────────────────────────────────

describe("on the device", () => {
  it("pushes voice_native_ready once, and a press calls start(), never getUserMedia or LiveKit", async () => {
    const plugin = fakePlugin()
    install({ plugin })
    const t = await mount()
    expect(t.sent("voice_native_ready")).toEqual([
      { available: true, reason: null, locale: "en-US", test_build: true, route: null },
    ])

    t.down(0)
    await settle()
    expect(plugin.start).toHaveBeenCalledTimes(1)
    expect(t.gum).not.toHaveBeenCalled()
    expect(t.events()).not.toContain("voice_start")
    expect(t.events()).not.toContain("voice_press")
    expect(lk.rooms.length).toBe(0)
    expect(t.sent("voice_native_mic")).toEqual([{ state: "held" }])
  })

  it("partials land in #voice-native-pending as text; a hold release sends one turn", async () => {
    const plugin = fakePlugin({ stopText: "what is left on the launch checklist" })
    install({ plugin })
    const t = await mount()
    t.down(0)
    await settle()
    plugin.emit("partial", { text: "what is <b>left" })
    expect(turnNode().find("[data-native-text]").textContent).toBe("what is <b>left")
    expect(turnNode().className).toContain("text-secondary")

    t.up(600)
    await settle()
    expect(plugin.stop).toHaveBeenCalledTimes(1)
    const turns = t.sent("voice_native_turn")
    expect(turns.length).toBe(1)
    expect(turns[0].text).toBe("what is left on the launch checklist")
    expect(typeof turns[0].client_turn_id).toBe("string")
    expect(turns[0].client_turn_id.length).toBeGreaterThan(8)
    // ok: the server's confirmed turn replaces the pending words.
    expect(turnNode()).toBe(null)
    expect(t.sent("voice_native_mic").map((p) => p.state)).toEqual(["held", "idle"])
  })

  it("a short tap toggles; the next tap sends", async () => {
    const plugin = fakePlugin()
    install({ plugin })
    const t = await mount()
    t.down(0)
    await settle()
    t.up(100)
    expect(t.sent("voice_native_mic").map((p) => p.state)).toEqual(["held", "toggled"])
    expect(plugin.stop).not.toHaveBeenCalled()
    t.down(3000)
    t.up(3050)
    await settle()
    expect(t.sent("voice_native_turn").length).toBe(1)
  })

  it("a failed reply shows Not sent; Retry resends the SAME client_turn_id", async () => {
    const plugin = fakePlugin()
    install({ plugin })
    let ok = false
    const t = await mount({ turnReply: () => (ok ? { ok: true, message_id: "m1" } : { ok: false }) })
    t.down(0)
    await settle()
    t.up(600)
    await settle()
    const node = turnNode()
    expect(node.textContent).toContain("Not sent")
    const retry = node.find("[data-native-retry]")
    expect(retry.textContent).toBe("Retry")
    expect(node.find("[data-native-text]").textContent).toBe("what is left on the list")

    ok = true
    t.click(retry)
    await settle()
    const turns = t.sent("voice_native_turn")
    expect(turns.length).toBe(2)
    expect(turns[1].client_turn_id).toBe(turns[0].client_turn_id)
    expect(turns[1].text).toBe(turns[0].text)
    expect(turnNode()).toBe(null)
  })

  it("Retry on a turn drawn by an earlier hook instance (a reconnect) resends its id and text", async () => {
    const plugin = fakePlugin()
    install({ plugin })
    const first = await mount({ turnReply: { ok: false } })
    first.down(0)
    await settle()
    first.up(600)
    await settle()
    const [sent] = first.sent("voice_native_turn")
    const retry = turnNode().find("[data-native-retry]")
    first.hook.destroyed()

    const second = await mount()
    second.click(retry)
    await settle()
    expect(second.sent("voice_native_turn")).toEqual([
      expect.objectContaining({ client_turn_id: sent.client_turn_id, text: sent.text }),
    ])
  })

  it("a reconnect re-announces the device path and puts Not sent turns back", async () => {
    const plugin = fakePlugin()
    install({ plugin })
    const t = await mount({ turnReply: { ok: false } })
    plugin.emit("route", { label: "Bluetooth" })
    t.down(0)
    await settle()
    t.up(600)
    await settle()
    const node = turnNode()
    // The fresh server render drops the pending area, then draws it again.
    pending.children = []
    node.parent = null
    t.hook.reconnected()
    expect(t.sent("voice_native_ready").length).toBe(2)
    expect(t.sent("voice_native_ready")[1].route).toBe("Bluetooth")
    await new Promise((r) => setTimeout(r, 150))
    expect(turnNode()).toBe(node)
    expect(node.textContent).toContain("Not sent")
  })

  it("no reply in MIC_TIMEOUT_MS (socket down) is Not sent", async () => {
    vi.useFakeTimers()
    const plugin = fakePlugin()
    install({ plugin })
    const t = await (async () => {
      const p = mount({ noTurnReply: true })
      await vi.advanceTimersByTimeAsync(0)
      return p
    })()
    t.down(0)
    await vi.advanceTimersByTimeAsync(0)
    t.up(600)
    await vi.advanceTimersByTimeAsync(0)
    expect(turnNode().textContent).toContain("Sending")
    await vi.advanceTimersByTimeAsync(10_000)
    expect(turnNode().textContent).toContain("Not sent")
  })

  it("an empty final shows No words heard for ~2s and sends nothing", async () => {
    vi.useFakeTimers()
    const plugin = fakePlugin({ stopText: "  " })
    install({ plugin })
    const p = mount()
    await vi.advanceTimersByTimeAsync(0)
    const t = await p
    t.down(0)
    await vi.advanceTimersByTimeAsync(0)
    t.up(600)
    await vi.advanceTimersByTimeAsync(0)
    expect(t.sent("voice_native_turn")).toEqual([])
    expect(pending.find("[data-native-note]").textContent).toBe("No words heard")
    expect(turnNode()).toBe(null)
    await vi.advanceTimersByTimeAsync(NO_WORDS_MS)
    expect(pending.find("[data-native-note]")).toBe(null)
  })

  it("caps a turn: 10 seconds left at 50s, sent as if released at 60s", async () => {
    vi.useFakeTimers()
    const plugin = fakePlugin()
    install({ plugin })
    const p = mount()
    await vi.advanceTimersByTimeAsync(0)
    const t = await p
    t.down(0)
    await vi.advanceTimersByTimeAsync(0)
    t.up(100) // toggled on
    expect(TURN_WARN_MS).toBe(50000)
    expect(TURN_CAP_MS).toBe(60000)
    await vi.advanceTimersByTimeAsync(50_000)
    expect(turnNode().textContent).toContain("10 seconds left")
    expect(t.sent("voice_native_turn")).toEqual([])
    await vi.advanceTimersByTimeAsync(10_000)
    expect(plugin.stop).toHaveBeenCalledTimes(1)
    expect(t.sent("voice_native_turn").length).toBe(1)
  })

  it("sliding off the mic, or a vertical drag from it, cancels and sends nothing", async () => {
    const plugin = fakePlugin()
    install({ plugin })
    const t = await mount()
    t.down(0)
    await settle()
    t.move(150, 540) // still on the mic, a small move
    expect(plugin.cancel).not.toHaveBeenCalled()
    t.move(300, 548) // off the mic
    expect(plugin.cancel).toHaveBeenCalledTimes(1)
    expect(turnNode()).toBe(null)
    t.up(900)
    await settle()
    expect(plugin.stop).not.toHaveBeenCalled()
    expect(t.sent("voice_native_turn")).toEqual([])

    t.down(2000)
    await settle()
    t.move(148, 548 - DRAG_CANCEL_PX - 1) // a vertical drag inside the bounds
    expect(plugin.cancel).toHaveBeenCalledTimes(2)
  })

  it("start refusals: mic_in_use and mic_permission_denied", async () => {
    const reasons = ["mic_in_use", "mic_permission_denied"]
    const plugin = fakePlugin({ start: () => Promise.resolve({ started: false, reason: reasons.shift() }) })
    install({ plugin })
    const t = await mount()
    t.down(0)
    await settle()
    t.up(600)
    expect(t.sent("voice_native_mic")).toEqual([{ state: "in_use" }])
    t.down(1000)
    await settle()
    t.up(1600)
    expect(t.sent("voice_native_permission")).toEqual([{ mic: "denied" }])
    expect(t.gum).not.toHaveBeenCalled()
  })

  it("a refusal remembered by iOS shows the permission card at once; Open Settings opens Settings", async () => {
    const plugin = fakePlugin({
      caps: { onDeviceSpeech: true, reason: null, testBuild: false, micPermission: "denied" },
    })
    install({ plugin })
    const t = await mount()
    expect(t.sent("voice_native_permission")).toEqual([{ mic: "denied" }])
    const button = element("button")
    button.setAttribute("data-native-action", "open-settings")
    t.click(button)
    expect(plugin.openSettings).toHaveBeenCalledTimes(1)
  })

  it("voice_native_speak speaks; a new press calls start (which stops speech natively)", async () => {
    const plugin = fakePlugin()
    install({ plugin })
    const t = await mount()
    t.handlers.voice_native_speak({ id: "r1", text: "Three items: the deck" })
    expect(plugin.speak).toHaveBeenCalledWith({ id: "r1", text: "Three items: the deck" })
    plugin.emit("speech", { id: "r1", state: "started" })
    expect(t.sent("voice_native_speaking")).toEqual([{ id: "r1", state: "started", reason: null }])
    t.down(0)
    await settle()
    expect(plugin.start).toHaveBeenCalledTimes(1)
    plugin.emit("speech", { id: "r1", state: "stopped", reason: "mic_opened" })
    expect(t.sent("voice_native_speaking")[1]).toEqual({ id: "r1", state: "stopped", reason: "mic_opened" })
  })

  it("voice_native_stop cancels the turn and stops speaking", async () => {
    const plugin = fakePlugin()
    install({ plugin })
    const t = await mount()
    t.down(0)
    await settle()
    t.handlers.voice_native_stop({})
    expect(plugin.cancel).toHaveBeenCalledTimes(1)
    expect(plugin.stopSpeaking).toHaveBeenCalledWith({ reason: "stopped" })
    expect(turnNode()).toBe(null)
  })

  it("a system end (call, Siri, background) discards the half-formed turn", async () => {
    const plugin = fakePlugin()
    install({ plugin })
    const t = await mount()
    t.down(0)
    await settle()
    plugin.emit("partial", { text: "half a" })
    plugin.emit("ended", { reason: "interrupted" })
    expect(turnNode()).toBe(null)
    expect(t.hook.inTurn()).toBe(false)
    t.up(900)
    await settle()
    expect(t.sent("voice_native_turn")).toEqual([])
  })

  it("route events reach the server as voice_native_route", async () => {
    const plugin = fakePlugin()
    install({ plugin })
    const t = await mount()
    plugin.emit("route", { label: "Bluetooth" })
    expect(t.sent("voice_native_route")).toEqual([{ label: "Bluetooth" }])
  })
})

// ── mic release (the core #289 rule) ───────────────────────────────────────

describe("the voice_native island loads only inside the app", () => {
  it("a browser, Android and an older app build never fetch it", async () => {
    const setups = [
      () => vi.stubGlobal("window", {}),
      () => install({ plugin: fakePlugin(), native: false, island: false }),
      () => install({ island: false }),
    ]
    for (const setup of setups) {
      vi.stubGlobal("document", fakeDocument(pending))
      setup()
      await mount()
      expect(document.head.appended).toEqual([])
    }
  })

  it("an island that fails to load leaves today's path", async () => {
    const plugin = fakePlugin()
    install({ plugin, island: false })
    const mounting = mount()
    await settle()
    expect(document.head.appended.length).toBe(1)
    document.head.appended[0].onerror(new Error("offline"))
    const t = await mounting
    expect(t.events()).not.toContain("voice_native_ready")
    t.down(0)
    await settle()
    expect(t.gum).toHaveBeenCalledTimes(1)
    expect(plugin.start).not.toHaveBeenCalled()
  })

  it("inside the app it fetches the island, then takes the device path", async () => {
    const plugin = fakePlugin()
    const win = install({ plugin, island: false })
    const mounting = mount()
    await settle()
    const [script] = document.head.appended
    expect(script.src).toBe(VOICE_NATIVE_ISLAND)
    expect(script.src).toBe("/assets/js/voice_native_island.js")
    win.__burrowVoiceNative = VoiceTabNative
    script.onload()
    const t = await mounting
    expect(t.events()).toContain("voice_native_ready")
    t.down(0)
    await settle()
    expect(plugin.start).toHaveBeenCalledTimes(1)
    expect(t.gum).not.toHaveBeenCalled()
  })
})

describe("leaving releases the mic", () => {
  it("destroyed() mid-start: the late start() is cancelled at once; speech stops; meetings untouched", async () => {
    let resolveStart
    const plugin = fakePlugin({ start: () => new Promise((r) => (resolveStart = r)) })
    const meetings = new Proxy({}, { get: (_t, k) => vi.fn(() => { throw new Error(`meetings.${String(k)} called`) }) })
    const meetingsCalls = vi.fn()
    install({ plugin, meetings: new Proxy({}, { get: (_t, k) => { meetingsCalls(k); return meetings[k] } }) })
    const t = await mount()
    t.down(0)
    await settle()
    t.hook.destroyed()
    expect(plugin.stopSpeaking).toHaveBeenCalled()
    const cancelsBefore = plugin.cancel.mock.calls.length
    resolveStart({ started: true })
    await settle()
    expect(plugin.cancel.mock.calls.length).toBe(cancelsBefore + 1)
    expect(t.sent("voice_native_mic")).not.toContainEqual({ state: "held" })
    expect(meetingsCalls).not.toHaveBeenCalled()
  })

  it("the page going hidden cancels the turn and stops speaking", async () => {
    const plugin = fakePlugin()
    install({ plugin })
    const t = await mount()
    t.down(0)
    await settle()
    document.visibilityState = "hidden"
    document.dispatchEvent(new Event("visibilitychange"))
    expect(plugin.cancel).toHaveBeenCalled()
    expect(plugin.stopSpeaking).toHaveBeenCalled()
    expect(t.hook.inTurn()).toBe(false)
    t.up(900)
    await settle()
    expect(t.sent("voice_native_turn")).toEqual([])
  })

  it("pagehide does the same", async () => {
    const plugin = fakePlugin()
    install({ plugin })
    const t = await mount()
    t.down(0)
    await settle()
    windowListeners.pagehide()
    expect(plugin.cancel).toHaveBeenCalled()
    expect(plugin.stopSpeaking).toHaveBeenCalled()
  })

  it("voice_disconnect (through _disconnect) cancels and stops speaking", async () => {
    const plugin = fakePlugin()
    install({ plugin })
    const t = await mount()
    t.down(0)
    await settle()
    t.hook._disconnect()
    expect(plugin.cancel).toHaveBeenCalled()
    expect(plugin.stopSpeaking).toHaveBeenCalled()
  })
})

describe("source hygiene", () => {
  // Every file of the hook: the app.js half, the island half and what they share.
  const src = ["voice_tab.js", "voice_tab_native_runtime.js", "voice_tab_shared.js", "../lib/on_device_voice.js"]
    .map((f) => fs.readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), "../../js/hooks", f), "utf8"))
    .join("\n")

  it("reads every file of the hook", () => {
    expect(src).toContain("_nativeBegin")
    expect(src).toContain("onDeviceVoiceCapability")
  })

  it("never uses innerHTML and never logs", () => {
    expect(src).not.toMatch(/\.innerHTML\s*=|insertAdjacentHTML/)
    expect(src).not.toMatch(/console\.(log|info|debug|warn|error)/)
  })

  it("never reaches the meetings plugin", () => {
    expect(src).not.toMatch(/BurrowMeetings|SuiteMeetings/)
  })
})
