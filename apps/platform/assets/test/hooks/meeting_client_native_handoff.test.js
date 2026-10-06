import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import MeetingClient from "../../js/hooks/meeting_client.js"

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
})
