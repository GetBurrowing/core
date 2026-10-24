import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { RoomEvent, Track } from "livekit-client"
import MeetingClient, {
  COMPANION_CAMERA_TIMEOUT_MS,
  NATIVE_MUTE_TIMEOUT_MS,
  isCompanionRoom,
} from "../../js/hooks/meeting_client.js"

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
        setCameraCalls: [],
        setMicCalls: [],
        setCameraEnabled(on) {
          this.setCameraCalls.push(on)
          return livekitFake.setCameraImpl ? livekitFake.setCameraImpl(on) : Promise.resolve()
        },
        setMicrophoneEnabled(on) {
          this.setMicCalls.push(on)
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
    off(event, cb) {
      const list = this._handlers.get(event) || []
      const i = list.indexOf(cb)
      if (i >= 0) list.splice(i, 1)
      return this
    }
    emit(event, ...args) {
      for (const cb of (this._handlers.get(event) || []).slice()) cb(...args)
    }
    connect(...args) {
      this.connectArgs = args
      this.state = "connected"
      // Task 01a13ca2 stage 3: who is already in the room at connect.
      if (livekitFake.onConnect) livekitFake.onConnect(this)
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

  // Task 01a13ca2 stage 3 adds the fourth, `appStateChanged`.
  it("destroy releases all four native listeners and a pending speaker push", async () => {
    const plugin = stage2Plugin()
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()
    await hook._join({ ...PAYLOAD, meeting_id: "m1" })
    expect(Object.keys(plugin.listeners).sort()).toEqual([
      "activeSpeakers",
      "appStateChanged",
      "callEnded",
      "mediaChanged",
    ])

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

/**
 * Task 01a13ca2 stage 3 — the video-only COMPANION Room.
 *
 * A build whose `capabilities().camera` is true gets `join-companion` from
 * the server after `native_call_attached`; the page then opens a second
 * LiveKit connection as `video:user:<uuid>` for the camera and for VIEWING
 * video. The native call keeps the audio, so this Room must never touch a
 * microphone or an audio track. The hook is driven through `mounted()` and
 * the handlers it registers, so what is asserted is the wired path.
 */
const COMPANION = { token: "ctok", url: "wss://livekit.test", room_name: "space-native" }

function cameraPlugin({ camera = true, setVideoActive = true } = {}) {
  const plugin = stage2Plugin()
  plugin.capabilities = () => Promise.resolve({ mic: true, camera, activeSpeakers: true })
  plugin.videoActive = []
  if (setVideoActive) {
    plugin.setVideoActive = (args) => {
      plugin.videoActive.push(args)
      return Promise.resolve()
    }
  }
  return plugin
}

function remotePub(kind, source, sid) {
  const track = {
    kind,
    source,
    sid,
    attachCalls: 0,
    attach() {
      this.attachCalls += 1
      return fakeNode()
    },
    detach: () => [],
  }
  return {
    kind,
    source,
    trackSid: sid,
    isSubscribed: false,
    subscribeCalls: [],
    track: null,
    _track: track,
    setSubscribed(on) {
      this.subscribeCalls.push(on)
      this.isSubscribed = on
    },
  }
}

function remoteParticipant(identity, pubs) {
  return {
    identity,
    name: identity,
    isLocal: false,
    trackPublications: new Map(pubs.map((p) => [p.trackSid, p])),
  }
}

// The local camera publication LiveKit holds once `setCameraEnabled(true)`
// has published (muted = the v2 camera-off shape).
function localCameraPub({ muted = false } = {}) {
  const listeners = {}
  const mediaStreamTrack = {
    readyState: "live",
    addEventListener(event, cb) {
      listeners[event] = cb
    },
    fire(event) {
      listeners[event] && listeners[event]()
    },
  }
  return {
    kind: Track.Kind.Video,
    source: Track.Source.Camera,
    trackSid: "local-cam",
    isMuted: muted,
    track: {
      kind: Track.Kind.Video,
      source: Track.Source.Camera,
      isMuted: muted,
      mediaStreamTrack,
      attach: () => fakeNode(),
      detach: () => [],
    },
  }
}

describe("MeetingClient companion Room (task 01a13ca2 stage 3)", () => {
  let priorWindow
  let priorDocument
  let docListeners
  let winListeners
  let priorRaf

  beforeEach(() => {
    priorWindow = globalThis.window
    priorDocument = globalThis.document
    docListeners = {}
    winListeners = {}
    globalThis.window = {
      __livekit_room: null,
      __livekitRoom: null,
      addEventListener(event, cb) {
        winListeners[event] = cb
      },
      removeEventListener() {},
      dispatchEvent: () => true,
      matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    }
    globalThis.document = {
      visibilityState: "visible",
      createElement: () => fakeNode(),
      querySelector: () => null,
      querySelectorAll: () => [],
      getElementById: () => null,
      addEventListener(event, cb) {
        docListeners[event] = cb
      },
      removeEventListener(event) {
        delete docListeners[event]
      },
      dispatchEvent: () => true,
      body: fakeNode(),
    }
    livekitFake.created.length = 0
    livekitFake.onConnect = null
    livekitFake.setCameraImpl = null
    priorRaf = globalThis.requestAnimationFrame
    globalThis.requestAnimationFrame = (cb) => cb()
  })

  afterEach(() => {
    vi.useRealTimers()
    livekitFake.onConnect = null
    livekitFake.setCameraImpl = null
    globalThis.window = priorWindow
    globalThis.document = priorDocument
    globalThis.requestAnimationFrame = priorRaf
  })

  // A mounted hook whose server handlers we can call, in the iOS app.
  async function mountInApp(plugin) {
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = buildHook()
    const handlers = {}
    hook.handleEvent = (name, cb) => {
      handlers[name] = cb
    }
    hook.mounted()
    hook.pushed = []
    await handlers["join-meeting"]({ ...PAYLOAD, meeting_id: "m1" })
    return { hook, handlers }
  }

  const companionPushes = (hook) => events(hook, "companion_media_state")

  // (a) ───────────────────────────────────────────────────────────────────
  it("(a) capabilities camera:false: no Room is constructed, even if join-companion arrives", async () => {
    const plugin = cameraPlugin({ camera: false })
    const { hook, handlers } = await mountInApp(plugin)

    expect(events(hook, "native_call_attached")[0].capabilities.camera).toBe(false)
    await handlers["join-companion"](COMPANION)
    await flush()

    expect(livekitFake.created.length).toBe(0)
    expect(window.__livekit_room).toBe(null)
    expect(companionPushes(hook)).toEqual([])
  })

  it("(a) a legacy build with no capabilities() gets no Room either", async () => {
    const plugin = fakePlugin()
    plugin.state = () => Promise.resolve({ meetingId: "m1", phase: "connected" })
    const { handlers } = await mountInApp(plugin)

    await handlers["join-companion"](COMPANION)
    expect(livekitFake.created.length).toBe(0)
  })

  it("(a) positive control: camera:true plus join-companion DOES build the Room", async () => {
    const { handlers } = await mountInApp(cameraPlugin())
    expect(livekitFake.created.length).toBe(0)

    await handlers["join-companion"](COMPANION)
    expect(livekitFake.created.length).toBe(1)
  })

  // (b) ───────────────────────────────────────────────────────────────────
  it("(b) one Room, autoSubscribe:false, VIDEO subscribed and audio never; no mic, no <audio>", async () => {
    const audio = remotePub(Track.Kind.Audio, Track.Source.Microphone, "w-mic")
    const cam = remotePub(Track.Kind.Video, Track.Source.Camera, "w-cam")
    const w = remoteParticipant("user:W", [audio, cam])
    livekitFake.onConnect = (room) => room.remoteParticipants.set(w.identity, w)

    const { hook, handlers } = await mountInApp(cameraPlugin())
    await handlers["join-companion"](COMPANION)

    expect(livekitFake.created.length).toBe(1)
    const room = livekitFake.created[0]
    expect(room.connectArgs).toEqual(["wss://livekit.test", "ctok", { autoSubscribe: false }])
    expect(isCompanionRoom(room)).toBe(true)
    expect(window.__livekit_room).toBe(room)
    expect(hook._room).toBe(room)

    // Already in the room at connect.
    expect(cam.subscribeCalls).toEqual([true])
    expect(audio.subscribeCalls).toEqual([])

    // Published after we joined: a screen share, a camera and an audio track.
    const share = remotePub(Track.Kind.Video, Track.Source.ScreenShare, "b-share")
    const bCam = remotePub(Track.Kind.Video, Track.Source.Camera, "b-cam")
    const bMic = remotePub(Track.Kind.Audio, Track.Source.Microphone, "b-mic")
    const shareAudio = remotePub(Track.Kind.Audio, Track.Source.ScreenShareAudio, "b-share-audio")
    const b = remoteParticipant("user:B", [])
    for (const pub of [share, bCam, bMic, shareAudio]) room.emit(RoomEvent.TrackPublished, pub, b)

    expect(share.subscribeCalls).toEqual([true])
    expect(bCam.subscribeCalls).toEqual([true])
    expect(bMic.subscribeCalls).toEqual([])
    expect(shareAudio.subscribeCalls).toEqual([])

    // Reconnects and a LiveView reconnect re-run the reconcilers: still no mic.
    room.emit(RoomEvent.Reconnected)
    hook.reconnected()
    expect(room.localParticipant.setMicCalls).toEqual([])
    // ...and no camera turned on by itself.
    expect(room.localParticipant.setCameraCalls).toEqual([])
    for (const pub of [audio, bMic, shareAudio]) expect(pub._track.attachCalls).toBe(0)
    expect(hook._audioEls.size).toBe(0)
  })

  // (c) ───────────────────────────────────────────────────────────────────
  it("(c) toggle-camera {want:true} pushes companion_media_state only AFTER the publication event", async () => {
    const { hook, handlers } = await mountInApp(cameraPlugin())
    await handlers["join-companion"](COMPANION)
    const room = livekitFake.created[0]
    // The join reports the starting state: off.
    expect(companionPushes(hook)).toEqual([{ camera: false }])
    hook.pushed.length = 0

    await handlers["toggle-camera"]({ want: true })
    expect(room.localParticipant.setCameraCalls).toEqual([true])
    // The click resolved; nothing confirmed it yet.
    expect(companionPushes(hook)).toEqual([])

    const pub = localCameraPub()
    room.localParticipant.trackPublications.set(pub.trackSid, pub)
    room.emit(RoomEvent.LocalTrackPublished, pub, room.localParticipant)

    expect(companionPushes(hook)).toEqual([{ camera: true }])

    // Off: livekit-client v2 MUTES the camera publication.
    hook.pushed.length = 0
    await handlers["toggle-camera"]({ want: false })
    expect(companionPushes(hook)).toEqual([])
    pub.isMuted = true
    pub.track.isMuted = true
    room.emit(RoomEvent.TrackMuted, pub, room.localParticipant)
    expect(companionPushes(hook)).toEqual([{ camera: false }])
  })

  it("(c) a rejected setCameraEnabled pushes the real state with failed: camera", async () => {
    const { hook, handlers } = await mountInApp(cameraPlugin())
    await handlers["join-companion"](COMPANION)
    hook.pushed.length = 0
    livekitFake.setCameraImpl = () => Promise.reject(new Error("NotAllowedError"))

    await handlers["toggle-camera"]({ want: true })

    expect(companionPushes(hook)).toEqual([{ camera: false, failed: "camera" }])
  })

  it("(c) no publication event within the timeout: reads the publication back, failed when it disagrees", async () => {
    const { hook, handlers } = await mountInApp(cameraPlugin())
    await handlers["join-companion"](COMPANION)
    hook.pushed.length = 0

    vi.useFakeTimers()
    await handlers["toggle-camera"]({ want: true })
    await vi.advanceTimersByTimeAsync(COMPANION_CAMERA_TIMEOUT_MS - 1)
    expect(companionPushes(hook)).toEqual([])
    await vi.advanceTimersByTimeAsync(1)
    expect(COMPANION_CAMERA_TIMEOUT_MS).toBe(3000)
    expect(companionPushes(hook)).toEqual([{ camera: false, failed: "camera" }])
  })

  it("(c) a browser toggle-camera (no want) keeps the Room path and pushes nothing", async () => {
    window.Capacitor = { Plugins: {} }
    const hook = buildHook()
    const calls = []
    hook._room = {
      localParticipant: {
        isCameraEnabled: true,
        setCameraEnabled(on) {
          calls.push(on)
          return Promise.resolve()
        },
      },
    }

    await hook._toggleCamera({})
    await hook._toggleCamera(undefined)

    expect(calls).toEqual([false, false])
    expect(hook.pushed).toEqual([])
  })

  // (d) ───────────────────────────────────────────────────────────────────
  async function cameraOn() {
    const plugin = cameraPlugin()
    const { hook, handlers } = await mountInApp(plugin)
    await handlers["join-companion"](COMPANION)
    const room = livekitFake.created[0]
    await handlers["toggle-camera"]({ want: true })
    const pub = localCameraPub()
    room.localParticipant.trackPublications.set(pub.trackSid, pub)
    room.emit(RoomEvent.LocalTrackPublished, pub, room.localParticipant)
    room.localParticipant.setCameraCalls.length = 0
    hook.pushed.length = 0
    return { hook, handlers, plugin, room, pub }
  }

  it("(d) visibilitychange to hidden turns the companion camera OFF; visible again does not turn it on", async () => {
    const { room } = await cameraOn()

    document.visibilityState = "hidden"
    docListeners.visibilitychange()
    await flush()
    expect(room.localParticipant.setCameraCalls).toEqual([false])

    document.visibilityState = "visible"
    docListeners.visibilitychange()
    // The reconnect path is where a camera could come back without a tap.
    room.emit(RoomEvent.Reconnected)
    await flush()
    expect(room.localParticipant.setCameraCalls).toEqual([false])
  })

  it("(d) appStateChanged {active:false} turns it OFF; {active:true} does not turn it on", async () => {
    const { plugin, room } = await cameraOn()

    plugin.listeners.appStateChanged({ active: false })
    await flush()
    expect(room.localParticipant.setCameraCalls).toEqual([false])

    plugin.listeners.appStateChanged({ active: true })
    await flush()
    expect(room.localParticipant.setCameraCalls).toEqual([false])
  })

  it("(d) pagehide, and the local track's ended / mute, turn it OFF", async () => {
    const { room, pub } = await cameraOn()

    pub.track.mediaStreamTrack.fire("ended")
    await flush()
    pub.track.mediaStreamTrack.fire("mute")
    await flush()
    expect(room.localParticipant.setCameraCalls).toEqual([false, false])

    winListeners.pagehide()
    await flush()
    expect(room.localParticipant.setCameraCalls).toEqual([false, false, false])
  })

  it("(d) the OFF is confirmed through the publication like any other change", async () => {
    const { hook, room, pub } = await cameraOn()

    document.visibilityState = "hidden"
    docListeners.visibilitychange()
    await flush()
    expect(companionPushes(hook)).toEqual([])
    pub.isMuted = true
    pub.track.isMuted = true
    room.emit(RoomEvent.TrackMuted, pub, room.localParticipant)
    expect(companionPushes(hook)).toEqual([{ camera: false }])
  })

  it("(d) without a companion Room, hidden is a no-op (the browser path)", async () => {
    window.Capacitor = { Plugins: {} }
    const hook = buildHook()
    hook.handleEvent = () => {}
    hook.mounted()
    hook._room = { localParticipant: { setCameraEnabled: vi.fn(() => Promise.resolve()) } }

    document.visibilityState = "hidden"
    docListeners.visibilitychange()
    await flush()
    expect(hook._room.localParticipant.setCameraEnabled).not.toHaveBeenCalled()
  })

  // (e) ───────────────────────────────────────────────────────────────────
  it("(e) setVideoActive gets the CONFIRMED camera, after the publication", async () => {
    const { plugin, room, pub, hook } = await cameraOn()
    // cameraOn's publication confirmed `true` (plus the join's `false`).
    expect(plugin.videoActive).toEqual([{ camera: false }, { camera: true }])

    pub.isMuted = true
    pub.track.isMuted = true
    room.emit(RoomEvent.TrackMuted, pub, room.localParticipant)
    expect(plugin.videoActive.at(-1)).toEqual({ camera: false })
    expect(companionPushes(hook)).toEqual([{ camera: false }])
  })

  it("(e) a build without setVideoActive does not throw, and still pushes the state", async () => {
    const plugin = cameraPlugin({ setVideoActive: false })
    const { hook, handlers } = await mountInApp(plugin)
    await handlers["join-companion"](COMPANION)
    const room = livekitFake.created[0]
    await handlers["toggle-camera"]({ want: true })

    const pub = localCameraPub()
    room.localParticipant.trackPublications.set(pub.trackSid, pub)
    expect(() => room.emit(RoomEvent.LocalTrackPublished, pub, room.localParticipant)).not.toThrow()
    expect(companionPushes(hook).at(-1)).toEqual({ camera: true })
  })

  it("(e) a setVideoActive that rejects is swallowed", async () => {
    const plugin = cameraPlugin()
    plugin.setVideoActive = () => Promise.reject(new Error("UNIMPLEMENTED"))
    const { hook, handlers } = await mountInApp(plugin)
    await handlers["join-companion"](COMPANION)
    await flush()
    expect(companionPushes(hook)).toEqual([{ camera: false }])
  })

  // Leave paths ────────────────────────────────────────────────────────────
  it("leave-meeting, callEnded and _leaveNative each disconnect the companion Room", async () => {
    for (const how of ["leave", "callEnded", "leaveNative"]) {
      livekitFake.created.length = 0
      const plugin = cameraPlugin()
      const { hook, handlers } = await mountInApp(plugin)
      await handlers["join-companion"](COMPANION)
      const room = livekitFake.created[0]
      expect(room.state).toBe("connected")

      if (how === "leave") handlers["leave-meeting"]()
      if (how === "callEnded") plugin.listeners.callEnded({ meetingId: "m1" })
      if (how === "leaveNative") hook._leaveNative()
      await flush()

      expect([how, room.state]).toEqual([how, "disconnected"])
      expect(hook._companionRoom).toBe(null)
    }
  })

  it("the companion dropping is not the person leaving: no meeting_left, camera reported off", async () => {
    const { hook, handlers } = await mountInApp(cameraPlugin())
    await handlers["join-companion"](COMPANION)
    const room = livekitFake.created[0]
    hook.pushed.length = 0

    room.emit(RoomEvent.Disconnected)

    expect(events(hook, "meeting_left")).toEqual([])
    expect(companionPushes(hook)).toEqual([{ camera: false }])
    expect(window.__livekit_room).toBe(null)
  })

  it("a second join-companion for the same connected room re-reports instead of reconnecting", async () => {
    const { hook, handlers } = await mountInApp(cameraPlugin())
    await handlers["join-companion"](COMPANION)
    hook.pushed.length = 0
    livekitFake.created[0].name = "space-native"

    await handlers["join-companion"](COMPANION)

    expect(livekitFake.created.length).toBe(1)
    expect(companionPushes(hook)).toEqual([{ camera: false }])
  })
})
