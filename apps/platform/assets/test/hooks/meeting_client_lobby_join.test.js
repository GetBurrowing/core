import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import MeetingClient from "../../js/hooks/meeting_client.js"

/**
 * FE-17 stage 4 (task 01a07410) — the lobby's mic/camera choice must be
 * the state the LiveKit participant ENTERS the room with.
 *
 * `_join` used to call `setMicrophoneEnabled(true)` unconditionally after
 * `room.connect`, so joining muted was impossible: whatever the user chose
 * before Join, the connect path switched the mic on. The join payload now
 * carries `mic_enabled` / `camera_enabled` (the server's assigns at push
 * time) and `_join` passes THOSE to LiveKit.
 *
 * The load-bearing assertion is the muted join: `setMicCalls` must equal
 * `[false]`. Restoring the hardcoded `true` makes it `[true]`, which is
 * the mutation the stage names. The both-on case would survive that
 * mutation and is here to pin the default, not to catch the defect.
 */

const livekitFake = vi.hoisted(() => ({ created: [] }))

vi.mock("livekit-client", async (importOriginal) => {
  const actual = await importOriginal()
  class Room {
    constructor(opts) {
      this.opts = opts
      this.name = "space-lobby"
      this.state = "disconnected"
      this.connectCalls = 0
      this.disconnectCalls = 0
      this._handlers = new Map()
      this.remoteParticipants = new Map()
      this.localParticipant = {
        identity: "guest:fresh",
        name: "Fresh",
        isLocal: true,
        isCameraEnabled: false,
        isMicrophoneEnabled: false,
        trackPublications: new Map(),
        setCameraCalls: [],
        setMicCalls: [],
        setCameraEnabled(v) {
          this.setCameraCalls.push(v)
          this.isCameraEnabled = v
          return Promise.resolve()
        },
        setMicrophoneEnabled(v) {
          this.setMicCalls.push(v)
          this.isMicrophoneEnabled = v
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
    listenerCount(event) {
      return (this._handlers.get(event) || []).length
    }
    connect() {
      this.connectCalls += 1
      this.state = "connected"
      return Promise.resolve()
    }
    disconnect() {
      this.disconnectCalls += 1
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
    querySelector() {
      return null
    },
    querySelectorAll() {
      return []
    },
    setAttribute() {},
  }
}

function buildDocument() {
  return {
    createElement: () => fakeNode(),
    querySelector: () => null,
    querySelectorAll: () => [],
    getElementById: () => null,
    addEventListener() {},
    removeEventListener() {},
    dispatchEvent: () => true,
    body: fakeNode(),
  }
}

function buildHook(dataset = {}) {
  const hook = Object.create(MeetingClient)
  hook._tiles = new Map()
  hook._localVideoEl = null
  hook._localVideoTrack = null
  hook._boundRoom = null
  hook._roomListeners = []
  hook.el = { dataset: { ...dataset } }
  hook.pushEvent = () => {}
  return hook
}

const PAYLOAD = { token: "tok", url: "wss://livekit.test", room_name: "space-lobby" }

describe("MeetingClient._join honours the lobby's mic/camera choice", () => {
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
    globalThis.document = buildDocument()
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

  // THE assertion this stage exists for. A lobby that muted the mic must
  // produce a participant whose FIRST mic call is `false`, never `true`.
  it("enters the room MUTED when the payload says mic_enabled: false", async () => {
    const hook = buildHook({ micEnabled: "false", cameraEnabled: "true" })

    await hook._join({ ...PAYLOAD, mic_enabled: false, camera_enabled: true })

    const lp = livekitFake.created[0].localParticipant
    expect(lp.setMicCalls).toEqual([false])
    expect(lp.isMicrophoneEnabled).toBe(false)
    expect(lp.setCameraCalls).toEqual([true])
  })

  it("enters the room with the camera OFF when the payload says camera_enabled: false", async () => {
    const hook = buildHook({ micEnabled: "true", cameraEnabled: "false" })

    await hook._join({ ...PAYLOAD, mic_enabled: true, camera_enabled: false })

    const lp = livekitFake.created[0].localParticipant
    expect(lp.setCameraCalls).toEqual([false])
    expect(lp.isCameraEnabled).toBe(false)
    expect(lp.setMicCalls).toEqual([true])
  })

  it("joining with both on leaves both on", async () => {
    const hook = buildHook({ micEnabled: "true", cameraEnabled: "true" })

    await hook._join({ ...PAYLOAD, mic_enabled: true, camera_enabled: true })

    const lp = livekitFake.created[0].localParticipant
    expect(lp.setMicCalls).toEqual([true])
    expect(lp.setCameraCalls).toEqual([true])
  })

  // The payload is the source of truth; the dataset is a fallback for a
  // push that predates the lobby. When BOTH are present and disagree the
  // payload wins, because it is what the server said at the moment of Join.
  it("prefers the payload over the dataset when they disagree", async () => {
    const hook = buildHook({ micEnabled: "true", cameraEnabled: "true" })

    await hook._join({ ...PAYLOAD, mic_enabled: false, camera_enabled: false })

    const lp = livekitFake.created[0].localParticipant
    expect(lp.setMicCalls).toEqual([false])
    expect(lp.setCameraCalls).toEqual([false])
  })

  it("falls back to the #meeting-client dataset when the payload omits the pair", async () => {
    const hook = buildHook({ micEnabled: "false", cameraEnabled: "false" })

    await hook._join(PAYLOAD)

    const lp = livekitFake.created[0].localParticipant
    expect(lp.setMicCalls).toEqual([false])
    expect(lp.setCameraCalls).toEqual([false])
  })

  it("defaults to live when neither payload nor dataset says anything (pre-lobby behaviour)", async () => {
    const hook = buildHook({})

    await hook._join(PAYLOAD)

    const lp = livekitFake.created[0].localParticipant
    expect(lp.setMicCalls).toEqual([true])
    expect(lp.setCameraCalls).toEqual([true])
  })
})
