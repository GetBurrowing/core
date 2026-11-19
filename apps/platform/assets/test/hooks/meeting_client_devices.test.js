import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { RoomEvent } from "livekit-client"
import MeetingClient from "../../js/hooks/meeting_client.js"
import { ClientState, __resetForTests as resetClientState } from "../../js/client_state.js"
import {
  NAMESPACE,
  DEVICE_FALLBACK_EVENT,
  ACTIVE_DEVICE_EVENT,
  activeRoom,
  getPreference,
  selectDevice,
  __resetForTests,
} from "../../js/lib/media_devices.js"

/**
 * MeetingClient on the shared media-device layer (task 01a1f4c5 stage 1).
 *
 * The load-bearing case is the MUTED unplug: livekit's own recovery
 * (`handleTrackEnded`) restarts only an unmuted track, and only onto
 * 'default', so a person who was muted when their microphone went away stays
 * bound to a dead device and nobody tells them. MediaDevicesChanged must move
 * them anyway and emit `meeting:device-fallback`.
 *
 * Room stub mirrors meeting_client_lobby_join.test.js, plus the device API
 * (`getActiveDevice`, `switchActiveDevice`) and an emitter so the test can
 * fire RoomEvents the way livekit does.
 */

const livekitFake = vi.hoisted(() => ({ created: [], switchFails: false }))

vi.mock("livekit-client", async (importOriginal) => {
  const actual = await importOriginal()
  class Room {
    constructor(opts) {
      this.opts = opts
      this.name = "space-devices"
      this.state = "disconnected"
      this._handlers = new Map()
      this.remoteParticipants = new Map()
      this.active = new Map([
        ["audioinput", "air-1"],
        ["videoinput", "cam-1"],
      ])
      this.switched = []
      const micPub = { source: "microphone", kind: "audio", isMuted: false, track: { isMuted: false } }
      this.micPub = micPub
      this.localParticipant = {
        identity: "user:me",
        name: "Me",
        isLocal: true,
        isCameraEnabled: false,
        isMicrophoneEnabled: false,
        trackPublications: new Map([["TR_mic", micPub]]),
        audioTrackPublications: new Map([["TR_mic", micPub]]),
        setCameraEnabled(v) {
          this.isCameraEnabled = v
          return Promise.resolve()
        },
        setMicrophoneEnabled(v) {
          this.isMicrophoneEnabled = v
          micPub.isMuted = !v
          micPub.track.isMuted = !v
          return Promise.resolve()
        },
      }
      livekitFake.created.push(this)
    }
    getActiveDevice(kind) {
      return this.active.get(kind)
    }
    switchActiveDevice(kind, deviceId, exact) {
      this.switched.push([kind, deviceId, exact])
      if (livekitFake.switchFails) return Promise.reject(new Error("NotReadableError"))
      this.active.set(kind, deviceId)
      return Promise.resolve(true)
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
      for (const cb of [...(this._handlers.get(event) || [])]) cb(...args)
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

function fakeStorage() {
  const store = new Map()
  return {
    get length() {
      return store.size
    },
    key: (i) => Array.from(store.keys())[i] ?? null,
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
  }
}

const MICS = [
  { kind: "audioinput", deviceId: "default", label: "Default - MacBook Pro Microphone" },
  { kind: "audioinput", deviceId: "mbp-1", label: "MacBook Pro Microphone" },
  { kind: "audioinput", deviceId: "air-1", label: "AirPods Pro" },
]
const CAMS = [{ kind: "videoinput", deviceId: "cam-1", label: "FaceTime HD Camera" }]
const OUTS = [{ kind: "audiooutput", deviceId: "out-1", label: "AirPods Pro" }]

const PAYLOAD = { token: "tok", url: "wss://livekit.test", room_name: "space-devices" }
const settle = () => new Promise((r) => setTimeout(r, 0))

let devices
let events

beforeEach(() => {
  livekitFake.created.length = 0
  livekitFake.switchFails = false
  devices = [...MICS, ...CAMS, ...OUTS]
  resetClientState()
  __resetForTests()

  events = []
  const win = new EventTarget()
  Object.assign(win, {
    __livekit_room: null,
    __livekitRoom: null,
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
  })
  for (const name of [DEVICE_FALLBACK_EVENT, ACTIVE_DEVICE_EVENT]) {
    win.addEventListener(name, (e) => events.push([name, e.detail]))
  }
  vi.stubGlobal("window", win)
  vi.stubGlobal("document", {
    createElement: () => fakeNode(),
    querySelector: () => null,
    querySelectorAll: () => [],
    getElementById: () => null,
    addEventListener() {},
    removeEventListener() {},
    dispatchEvent: () => true,
    body: fakeNode(),
  })
  vi.stubGlobal("requestAnimationFrame", (cb) => cb())
  vi.stubGlobal("localStorage", fakeStorage())
  vi.stubGlobal("navigator", {
    userAgent: "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    mediaDevices: {
      enumerateDevices: () => Promise.resolve(devices.map((d) => ({ ...d }))),
      addEventListener() {},
      removeEventListener() {},
    },
  })
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("_newRoom starts on the remembered devices", () => {
  it("passes the stored deviceIds, NON-exact, as capture and output defaults", () => {
    // An audio element with setSinkId: output selection is supported.
    vi.stubGlobal("document", { createElement: () => ({ setSinkId() {} }) })
    ClientState.set(NAMESPACE, "audioinput", { deviceId: "air-1", label: "AirPods Pro" })
    ClientState.set(NAMESPACE, "videoinput", { deviceId: "cam-1", label: "FaceTime HD Camera" })
    ClientState.set(NAMESPACE, "audiooutput", { deviceId: "out-1", label: "AirPods Pro" })

    const room = buildHook()._newRoom()

    expect(room.opts.audioCaptureDefaults).toEqual({ deviceId: "air-1" })
    expect(room.opts.videoCaptureDefaults).toEqual({ deviceId: "cam-1" })
    expect(room.opts.audioOutput).toEqual({ deviceId: "out-1" })
    expect(room.opts.disconnectOnPageLeave).toBe(false)
  })

  it("leaves audioOutput out where the browser cannot choose an output", () => {
    vi.stubGlobal("document", { createElement: () => ({}) })
    ClientState.set(NAMESPACE, "audiooutput", { deviceId: "out-1", label: "AirPods Pro" })
    expect(buildHook()._newRoom().opts.audioOutput).toBeUndefined()
  })

  it("with nothing stored the Room is exactly what it was", () => {
    const room = buildHook()._newRoom()
    expect(room.opts).toEqual({
      adaptiveStream: true,
      dynacast: true,
      publishDefaults: { simulcast: true },
      disconnectOnPageLeave: false,
    })
  })

  it("_join matches a rotated deviceId by label before building the Room", async () => {
    ClientState.set(NAMESPACE, "audioinput", { deviceId: "air-OLD", label: "AirPods Pro" })
    await buildHook()._join(PAYLOAD)
    expect(livekitFake.created[0].opts.audioCaptureDefaults).toEqual({ deviceId: "air-1" })
  })
})

describe("the room registry", () => {
  it("_join registers the room and _leave unregisters it", async () => {
    const hook = buildHook()
    await hook._join(PAYLOAD)
    const room = livekitFake.created[0]
    expect(activeRoom()).toBe(room)
    await hook._leave()
    expect(activeRoom()).toBeNull()
  })

  it("_adoptRoom re-registers a surviving room on remount", async () => {
    const first = buildHook()
    await first._join(PAYLOAD)
    const room = livekitFake.created[0]
    first._cleanupRoom() // what a teardown would leave
    room.state = "connected"
    expect(activeRoom()).toBeNull()

    buildHook()._adoptRoom(room)
    expect(activeRoom()).toBe(room)
  })

  it("the native hand-off registers no room", async () => {
    window.Capacitor = {
      Plugins: {
        SuiteMeetings: {
          join: () => Promise.resolve({ status: "starting" }),
          addListener: () => Promise.resolve({ remove() {} }),
        },
      },
    }
    await buildHook()._join({ ...PAYLOAD, meeting_id: "m1" })
    expect(livekitFake.created.length).toBe(0)
    expect(activeRoom()).toBeNull()
  })
})

describe("MediaDevicesChanged: the active microphone disappears", () => {
  async function joinedOnAirPods({ micEnabled }) {
    const hook = buildHook()
    await hook._join({ ...PAYLOAD, mic_enabled: micEnabled, camera_enabled: false })
    const room = livekitFake.created[0]
    // Learn the labels while the AirPods are still plugged in.
    room.emit(RoomEvent.MediaDevicesChanged)
    await settle()
    events.length = 0
    room.switched.length = 0
    return room
  }

  it("unmuted: switches to the fallback and emits meeting:device-fallback", async () => {
    const room = await joinedOnAirPods({ micEnabled: true })
    expect(room.micPub.isMuted).toBe(false)

    devices = devices.filter((d) => d.deviceId !== "air-1")
    room.emit(RoomEvent.MediaDevicesChanged)
    await settle()

    expect(room.switched).toContainEqual(["audioinput", "default", undefined])
    expect(events.find(([n]) => n === DEVICE_FALLBACK_EVENT)?.[1]).toEqual({
      kind: "audioinput",
      fromLabel: "AirPods Pro",
      toLabel: "Default - MacBook Pro Microphone",
      surface: "meeting",
    })
  })

  // The case livekit misses.
  it("MUTED at unplug: still switches and still emits meeting:device-fallback", async () => {
    const room = await joinedOnAirPods({ micEnabled: false })
    expect(room.micPub.isMuted).toBe(true)

    devices = devices.filter((d) => d.deviceId !== "air-1")
    room.emit(RoomEvent.MediaDevicesChanged)
    await settle()

    expect(room.switched).toContainEqual(["audioinput", "default", undefined])
    expect(room.getActiveDevice("audioinput")).toBe("default")
    expect(events.find(([n]) => n === DEVICE_FALLBACK_EVENT)?.[1]).toEqual({
      kind: "audioinput",
      fromLabel: "AirPods Pro",
      toLabel: "Default - MacBook Pro Microphone",
      surface: "meeting",
    })
  })

  it("a device list change that keeps the active mic switches nothing", async () => {
    const room = await joinedOnAirPods({ micEnabled: true })
    devices = [...devices, { kind: "audioinput", deviceId: "usb-1", label: "USB Mic" }]
    room.emit(RoomEvent.MediaDevicesChanged)
    await settle()
    expect(room.switched).toEqual([])
    expect(events.some(([n]) => n === DEVICE_FALLBACK_EVENT)).toBe(false)
  })
})

describe("ActiveDeviceChanged", () => {
  it("becomes meeting:active-device", async () => {
    await buildHook()._join(PAYLOAD)
    const room = livekitFake.created[0]
    await selectDevice("audioinput", "mbp-1", { room: null }) // learn labels
    events.length = 0
    room.emit(RoomEvent.ActiveDeviceChanged, "audioinput", "air-1")
    expect(events).toEqual([
      [ACTIVE_DEVICE_EVENT, { kind: "audioinput", deviceId: "air-1", label: "AirPods Pro" }],
    ])
  })
})

describe("selectDevice through the registered meeting room", () => {
  it("a failed switch does not persist the choice", async () => {
    await buildHook()._join(PAYLOAD)
    livekitFake.switchFails = true
    const result = await selectDevice("audioinput", "mbp-1")
    expect(result.ok).toBe(false)
    expect(result.deviceId).toBe("air-1")
    expect(livekitFake.created[0].switched).toEqual([["audioinput", "mbp-1", true]])
    expect(getPreference("audioinput")).toBeNull()
  })

  it("a working switch persists it", async () => {
    await buildHook()._join(PAYLOAD)
    expect((await selectDevice("audioinput", "mbp-1")).ok).toBe(true)
    expect(getPreference("audioinput")).toEqual({
      deviceId: "mbp-1",
      label: "MacBook Pro Microphone",
    })
  })
})
