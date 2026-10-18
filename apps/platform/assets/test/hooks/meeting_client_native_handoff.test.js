import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import MeetingClient, { NATIVE_MUTE_TIMEOUT_MS } from "../../js/hooks/meeting_client.js"

/**
 * Task 01a10db7 stage 3 — inside the Burrow iOS app the `SuiteMeetings`
 * Capacitor plugin owns the call. `_join` must hand the meeting to it and
 * must NOT construct a JS `Room`: both would join as the same `user:<id>`
 * identity and kick each other out, and the person would hear the call twice.
 *
 * Every case pins both sides: the plugin present WITH a meeting id goes
 * native and builds no Room; without the plugin, or without a meeting id,
 * the web Room path is unchanged.
 */

const livekitFake = vi.hoisted(() => ({ created: [] }))

vi.mock("livekit-client", async (importOriginal) => {
  const actual = await importOriginal()
  class Room {
    constructor(opts) {
      this.opts = opts
      this.name = "space-native"
      this.state = "disconnected"
      this._handlers = new Map()
      this.remoteParticipants = new Map()
      this.localParticipant = {
        identity: "user:u1",
        name: "U1",
        isLocal: true,
        isCameraEnabled: false,
        isMicrophoneEnabled: false,
        trackPublications: new Map(),
        setCameraEnabled() {
          return Promise.resolve()
        },
        setMicrophoneEnabled() {
          return Promise.resolve()
        },
      }
      livekitFake.created.push(this)
    }
    on(event, cb) {
      const list = this._handlers.get(event) || []
      list.push(cb)
      this._handlers.set(event, list)
      return this
    }
    off() {
      return this
    }
    connect() {
      this.state = "connected"
      return Promise.resolve()
    }
    disconnect() {
      this.state = "disconnected"
      return Promise.resolve()
    }
  }
  return { ...actual, Room }
})

function fakeNode() {
  return {
    dataset: {},
    style: {},
    className: "",
    children: [],
    classList: { add() {}, remove() {}, contains: () => false },
    appendChild(child) {
      this.children.push(child)
      return child
    },
    remove() {},
    querySelector: () => null,
    querySelectorAll: () => [],
    setAttribute() {},
  }
}

function buildHook() {
  const hook = Object.create(MeetingClient)
  hook._tiles = new Map()
  hook._localVideoEl = null
  hook._localVideoTrack = null
  hook._boundRoom = null
  hook._roomListeners = []
  hook.el = { dataset: { micEnabled: "true", cameraEnabled: "false" } }
  hook.pushed = []
  hook.pushEvent = (event, payload) => hook.pushed.push([event, payload])
  return hook
}

function fakePlugin() {
  const plugin = {
    joins: [],
    leaves: 0,
    listeners: {},
    join(args) {
      this.joins.push(args)
      return Promise.resolve({ status: "starting" })
    },
    leave() {
      this.leaves += 1
      return Promise.resolve()
    },
    addListener(event, cb) {
      this.listeners[event] = cb
      return Promise.resolve({ remove: () => delete this.listeners[event] })
    },
  }
  return plugin
}

const PAYLOAD = {
  token: "tok",
  url: "wss://livekit.test",
  room_name: "space-native",
  mic_enabled: true,
  camera_enabled: false,
}

describe("MeetingClient native hand-off (SuiteMeetings)", () => {
  let priorWindow
  let priorDocument
  let priorRaf

  beforeEach(() => {
    priorWindow = globalThis.window
    priorDocument = globalThis.document
    priorRaf = globalThis.requestAnimationFrame
    globalThis.window = {
      __livekit_room: null,
      __livekitRoom: null,
      addEventListener() {},
      removeEventListener() {},
      dispatchEvent: () => true,
      matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    }
    globalThis.document = {
      createElement: () => fakeNode(),
      querySelector: () => null,
      querySelectorAll: () => [],
      getElementById: () => null,
      addEventListener() {},
      removeEventListener() {},
      dispatchEvent: () => true,
      body: fakeNode(),
    }
    globalThis.requestAnimationFrame = (cb) => cb()
    globalThis.CustomEvent = class CustomEvent {
      constructor(type, init) {
        this.type = type
        this.detail = init && init.detail
      }
    }
    livekitFake.created.length = 0
  })

  afterEach(() => {
    globalThis.window = priorWindow
    globalThis.document = priorDocument
    globalThis.requestAnimationFrame = priorRaf
  })

  it("with the plugin and a meeting_id: joins natively and builds NO Room", async () => {
    const plugin = fakePlugin()
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()

    await hook._join({ ...PAYLOAD, meeting_id: "m1" })

    expect(plugin.joins).toEqual([{ meetingId: "m1" }])
    expect(livekitFake.created.length).toBe(0)
  })

  it("the native call ending pushes meeting_left, once, for that meeting only", async () => {
    const plugin = fakePlugin()
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()
    await hook._join({ ...PAYLOAD, meeting_id: "m1" })

    // Stage 3 adds the `native_call_attached` push after the join; this
    // case is about `meeting_left` only.
    hook.pushed.length = 0
    plugin.listeners.callEnded({ meetingId: "other" })
    expect(hook.pushed).toEqual([])

    plugin.listeners.callEnded({ meetingId: "m1" })
    plugin.listeners.callEnded({ meetingId: "m1" })
    expect(hook.pushed).toEqual([["meeting_left", {}]])
  })

  it("a server leave-meeting ends the native call", async () => {
    const plugin = fakePlugin()
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()
    await hook._join({ ...PAYLOAD, meeting_id: "m1" })

    hook._leaveNative()
    hook._leaveNative()
    expect(plugin.leaves).toBe(1)
  })

  it("with the plugin but NO meeting_id (a quick-meet without a meeting row): the web Room path", async () => {
    const plugin = fakePlugin()
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()

    await hook._join({ ...PAYLOAD, meeting_id: null })

    expect(plugin.joins).toEqual([])
    expect(livekitFake.created.length).toBe(1)
  })

  it("without the plugin (a browser): the web Room path, unchanged", async () => {
    window.Capacitor = { Plugins: {} }
    const hook = buildHook()

    await hook._join({ ...PAYLOAD, meeting_id: "m1" })

    expect(livekitFake.created.length).toBe(1)
  })

  // Task 01a14ba9 stage 4: newer app builds register `BurrowMeetings`, older
  // ones `SuiteMeetings`. The page reads either, Burrow first.
  it("Burrow-only (BurrowMeetings): joins natively and builds NO Room", async () => {
    const plugin = fakePlugin()
    window.Capacitor = { Plugins: { BurrowMeetings: plugin } }
    const hook = buildHook()

    await hook._join({ ...PAYLOAD, meeting_id: "m1" })

    expect(plugin.joins).toEqual([{ meetingId: "m1" }])
    expect(livekitFake.created.length).toBe(0)
  })

  it("Suite-only (SuiteMeetings, an older app build): still joins natively", async () => {
    const plugin = fakePlugin()
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()

    expect(hook._nativeMeetings()).toBe(plugin)
    await hook._join({ ...PAYLOAD, meeting_id: "m1" })

    expect(plugin.joins).toEqual([{ meetingId: "m1" }])
    expect(livekitFake.created.length).toBe(0)
  })

  it("both present: BurrowMeetings wins and SuiteMeetings is never called", async () => {
    const burrow = fakePlugin()
    const suite = fakePlugin()
    window.Capacitor = { Plugins: { BurrowMeetings: burrow, SuiteMeetings: suite } }
    const hook = buildHook()

    expect(hook._nativeMeetings()).toBe(burrow)
    await hook._join({ ...PAYLOAD, meeting_id: "m1" })

    expect(burrow.joins).toEqual([{ meetingId: "m1" }])
    expect(suite.joins).toEqual([])
  })
})

/**
 * Task 01a13c62 stage 3 — the page's mic button drives the NATIVE call and
 * shows only what the call CONFIRMED. The fake mirrors stage 2's plugin
 * (commit 93bc31bc8): `capabilities()` -> `{mic, camera, activeSpeakers}`,
 * `setMuted({muted})` -> `{mic}` after the read-back (rejecting with
 * MIC_FAILED), `state()` -> `{meetingId, phase, mic, camera, speaking}`, and
 * `mediaChanged` / `activeSpeakers` listeners.
 */
function stage2Plugin({ mic = true } = {}) {
  const plugin = fakePlugin()
  plugin.media = { mic, camera: false }
  plugin.setMutedCalls = []
  plugin.setMutedImpl = ({ muted }) => {
    plugin.media.mic = !muted
    return Promise.resolve({ mic: plugin.media.mic })
  }
  plugin.capabilities = () => Promise.resolve({ mic: true, camera: false, activeSpeakers: true })
  plugin.state = () =>
    Promise.resolve({
      meetingId: "m1",
      phase: "connected",
      mic: plugin.media.mic,
      camera: plugin.media.camera,
      speaking: [],
    })
  plugin.setMuted = (args) => {
    plugin.setMutedCalls.push(args)
    return plugin.setMutedImpl(args)
  }
  return plugin
}

const flush = () => new Promise((resolve) => setImmediate(resolve))
const events = (hook, name) => hook.pushed.filter(([event]) => event === name).map(([, p]) => p)

describe("MeetingClient native media (stage 3)", () => {
  let priorWindow

  beforeEach(() => {
    priorWindow = globalThis.window
    globalThis.window = {
      __livekit_room: null,
      __livekitRoom: null,
      addEventListener() {},
      removeEventListener() {},
      dispatchEvent: () => true,
      matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    }
    livekitFake.created.length = 0
  })

  afterEach(() => {
    vi.useRealTimers()
    globalThis.window = priorWindow
  })

  it("after the native join, pushes native_call_attached with capabilities and the confirmed mic/camera", async () => {
    const plugin = stage2Plugin({ mic: false })
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()

    await hook._join({ ...PAYLOAD, meeting_id: "m1" })

    expect(events(hook, "native_call_attached")).toEqual([
      { capabilities: { mic: true, camera: false, activeSpeakers: true }, mic: false, camera: false },
    ])
    expect(livekitFake.created.length).toBe(0)
  })

  it("a legacy plugin without capabilities(): all-false capabilities, and no crash", async () => {
    const plugin = fakePlugin()
    plugin.state = () => Promise.resolve({ meetingId: "m1", phase: "connected" })
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()

    await hook._join({ ...PAYLOAD, meeting_id: "m1" })

    expect(events(hook, "native_call_attached")).toEqual([
      { capabilities: { mic: false, camera: false, activeSpeakers: false }, mic: null, camera: null },
    ])
  })

  it("a legacy plugin whose capabilities() REJECTS (Capacitor's unknown-method error) is treated the same", async () => {
    const plugin = fakePlugin()
    plugin.capabilities = () => Promise.reject(new Error("not implemented"))
    plugin.state = () => Promise.reject(new Error("not implemented"))
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()

    await hook._join({ ...PAYLOAD, meeting_id: "m1" })

    expect(events(hook, "native_call_attached")).toEqual([
      { capabilities: { mic: false, camera: false, activeSpeakers: false }, mic: null, camera: null },
    ])
  })

  it("the confirmed round trip: toggle-mic {want:false} calls setMuted({muted:true}) and pushes the CONFIRMED state", async () => {
    const plugin = stage2Plugin({ mic: true })
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()
    await hook._join({ ...PAYLOAD, meeting_id: "m1" })
    hook.pushed.length = 0

    await hook._toggleMic({ want: false })

    expect(plugin.setMutedCalls).toEqual([{ muted: true }])
    expect(hook.pushed).toEqual([["native_media_state", { mic: false, camera: false }]])
  })

  it("the confirmed value wins over the requested one (the call refused to unmute)", async () => {
    const plugin = stage2Plugin({ mic: false })
    plugin.setMutedImpl = () => Promise.resolve({ mic: false })
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()
    await hook._join({ ...PAYLOAD, meeting_id: "m1" })
    hook.pushed.length = 0

    await hook._toggleMic({ want: true })

    expect(hook.pushed).toEqual([["native_media_state", { mic: false, camera: false }]])
  })

  it("a reject (MIC_FAILED) reads state() back and pushes failed: mic", async () => {
    const plugin = stage2Plugin({ mic: true })
    plugin.setMutedImpl = () => Promise.reject(Object.assign(new Error("Couldn't change the mic"), { code: "MIC_FAILED" }))
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()
    await hook._join({ ...PAYLOAD, meeting_id: "m1" })
    hook.pushed.length = 0

    await hook._toggleMic({ want: false })

    expect(hook.pushed).toEqual([["native_media_state", { mic: true, camera: false, failed: "mic" }]])
  })

  it("no confirmation within 3 s: pushes the read-back state with failed: mic, and not before", async () => {
    const plugin = stage2Plugin({ mic: true })
    plugin.setMutedImpl = () => new Promise(() => {})
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()
    await hook._join({ ...PAYLOAD, meeting_id: "m1" })
    hook.pushed.length = 0

    vi.useFakeTimers()
    const done = hook._toggleMic({ want: false })
    await vi.advanceTimersByTimeAsync(NATIVE_MUTE_TIMEOUT_MS - 1)
    expect(hook.pushed).toEqual([])

    await vi.advanceTimersByTimeAsync(1)
    await done
    expect(NATIVE_MUTE_TIMEOUT_MS).toBe(3000)
    expect(hook.pushed).toEqual([["native_media_state", { mic: true, camera: false, failed: "mic" }]])
  })

  it("a confirmation landing after the 3 s give-up (plugin waits 5 s) arrives as mediaChanged with no failed key", async () => {
    const plugin = stage2Plugin({ mic: true })
    let confirm
    plugin.setMutedImpl = () => new Promise((resolve) => (confirm = resolve))
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()
    await hook._join({ ...PAYLOAD, meeting_id: "m1" })
    hook.pushed.length = 0

    vi.useFakeTimers()
    const done = hook._toggleMic({ want: false })
    await vi.advanceTimersByTimeAsync(NATIVE_MUTE_TIMEOUT_MS)
    await done

    // 4 s: the native call confirms; stage 2 emits mediaChanged for it.
    plugin.media.mic = false
    confirm({ mic: false })
    plugin.listeners.mediaChanged({ mic: false, camera: false })

    expect(hook.pushed).toEqual([
      ["native_media_state", { mic: true, camera: false, failed: "mic" }],
      ["native_media_state", { mic: false, camera: false }],
    ])
  })

  it("mediaChanged with no click (Control Centre, the native screen) pushes native_media_state", async () => {
    const plugin = stage2Plugin({ mic: true })
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()
    await hook._join({ ...PAYLOAD, meeting_id: "m1" })
    hook.pushed.length = 0

    plugin.listeners.mediaChanged({ mic: false, camera: false })

    expect(hook.pushed).toEqual([["native_media_state", { mic: false, camera: false }]])
    expect(plugin.setMutedCalls).toEqual([])
  })

  it("activeSpeakers is debounced 250 ms trailing and deduplicated by identity set", async () => {
    const plugin = stage2Plugin()
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()
    await hook._join({ ...PAYLOAD, meeting_id: "m1" })
    hook.pushed.length = 0

    vi.useFakeTimers()
    for (let i = 0; i < 10; i++) {
      plugin.listeners.activeSpeakers({ identities: [`user:${i}`, "user:me"] })
      vi.advanceTimersByTime(10)
    }
    expect(events(hook, "active_speakers")).toEqual([])
    vi.advanceTimersByTime(250)
    expect(events(hook, "active_speakers")).toEqual([{ identities: ["user:9", "user:me"] }])

    // Same set, different order: dropped.
    plugin.listeners.activeSpeakers({ identities: ["user:me", "user:9"] })
    vi.advanceTimersByTime(250)
    expect(events(hook, "active_speakers")).toHaveLength(1)

    plugin.listeners.activeSpeakers({ identities: [] })
    vi.advanceTimersByTime(250)
    expect(events(hook, "active_speakers")).toEqual([
      { identities: ["user:9", "user:me"] },
      { identities: [] },
    ])
  })

  it("destroy releases all three native listeners and a pending speaker push", async () => {
    const plugin = stage2Plugin()
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()
    await hook._join({ ...PAYLOAD, meeting_id: "m1" })
    expect(Object.keys(plugin.listeners).sort()).toEqual(["activeSpeakers", "callEnded", "mediaChanged"])

    vi.useFakeTimers()
    plugin.listeners.activeSpeakers({ identities: ["user:a"] })
    hook._releaseNativeListener()
    await vi.advanceTimersByTimeAsync(300)

    expect(plugin.listeners).toEqual({})
    expect(events(hook, "active_speakers")).toEqual([])
  })

  it("no plugin at all: toggle-mic takes the browser Room path, untouched by want", async () => {
    window.Capacitor = { Plugins: {} }
    const hook = buildHook()
    const calls = []
    hook._room = {
      localParticipant: {
        isMicrophoneEnabled: true,
        setMicrophoneEnabled(on) {
          calls.push(on)
          return Promise.resolve()
        },
      },
    }

    await hook._toggleMic({})
    await hook._toggleMic(undefined)

    expect(calls).toEqual([false, false])
    expect(hook.pushed).toEqual([])
  })
})
