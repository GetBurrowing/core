import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { RoomEvent } from "livekit-client"
import { watchRoomDevices } from "../../js/hooks/meeting_bar.js"
import { __resetForTests as resetClientState } from "../../js/client_state.js"
import { DEVICE_FALLBACK_EVENT, registerRoom, __resetForTests } from "../../js/lib/media_devices.js"
import { asDeviceInfos } from "../lib/fake_media_devices.js"

/**
 * The in-call top bar on a page with no call client (/calendar, /inbox) is
 * the one handling an unplug (task 01a1f4c5 stage 4). Round 2 of the stage 5
 * review: when nobody picked a device and livekit published the mic with no
 * ActiveDeviceChanged, livekit's own recovery announced only the NEW device
 * and the strap never showed. The bar's bind must seed what the room is on.
 */

// No static getLocalDevices, so the device layer reads navigator.mediaDevices.
vi.mock("livekit-client", async (importOriginal) => {
  const actual = await importOriginal()
  return { ...actual, Room: class {} }
})

const PLUGGED = [
  { kind: "audioinput", deviceId: "default", label: "Default - MacBook Pro Microphone", groupId: "gM" },
  { kind: "audioinput", deviceId: "air-1", label: "AirPods Pro", groupId: "gA" },
  { kind: "audioinput", deviceId: "mbp-1", label: "MacBook Pro Microphone", groupId: "gM" },
]
const UNPLUGGED = [PLUGGED[0], PLUGGED[2]]
const STRAP = {
  kind: "audioinput",
  fromLabel: "AirPods Pro",
  toLabel: "MacBook Pro Microphone",
  surface: "meeting",
}
const settle = () => new Promise((r) => setTimeout(r, 0))

function fakeRoom() {
  const handlers = new Map()
  const active = new Map([["audioinput", "air-1"]])
  const micPub = {
    source: "microphone",
    kind: "audio",
    track: { source: "microphone", mediaStreamTrack: { getSettings: () => ({ deviceId: "air-1" }) } },
  }
  return {
    active,
    micPub,
    switched: [],
    localParticipant: {
      getTrackPublication: (source) => (source === "microphone" ? micPub : undefined),
    },
    getActiveDevice: (kind) => active.get(kind),
    switchActiveDevice(kind, deviceId) {
      this.switched.push([kind, deviceId])
      active.set(kind, deviceId)
      return Promise.resolve(true)
    },
    on(event, cb) {
      handlers.set(event, [...(handlers.get(event) || []), cb])
    },
    off(event, cb) {
      handlers.set(event, (handlers.get(event) || []).filter((f) => f !== cb))
    },
    emit(event, ...args) {
      for (const cb of [...(handlers.get(event) || [])]) cb(...args)
    },
  }
}

let devices
let events
let win
let stop

beforeEach(() => {
  devices = [...PLUGGED]
  resetClientState()
  __resetForTests()
  events = []
  win = new EventTarget()
  win.addEventListener(DEVICE_FALLBACK_EVENT, (e) => events.push(e.detail))
  vi.stubGlobal("window", win)
  vi.stubGlobal("navigator", {
    userAgent: "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    mediaDevices: {
      enumerateDevices: () => Promise.resolve(asDeviceInfos(devices)),
      addEventListener() {},
      removeEventListener() {},
    },
  })
})

afterEach(() => {
  if (stop) stop()
  stop = null
  vi.unstubAllGlobals()
})

// No #meeting-client on the page: the bar is the handler.
const doc = { getElementById: () => null }

async function barOn(room) {
  registerRoom(room, "meeting")
  stop = watchRoomDevices(win, doc)
  win.dispatchEvent(Object.assign(new Event("livekit:room-connected"), { detail: { room } }))
  await settle()
}

describe("the top bar's strap with no pick (stage 5 round 2)", () => {
  it("unmuted: livekit restarts the track before MediaDevicesChanged: one strap", async () => {
    const room = fakeRoom()
    await barOn(room)
    devices = [...UNPLUGGED]
    room.active.set("audioinput", "mbp-1")
    room.emit(RoomEvent.ActiveDeviceChanged, "audioinput", "mbp-1")
    room.emit(RoomEvent.MediaDevicesChanged)
    await settle()

    expect(events).toEqual([STRAP])
    expect(room.switched).toEqual([])
  })

  it("muted: selectDefaultDevices moves it before MediaDevicesChanged: one strap", async () => {
    const room = fakeRoom()
    await barOn(room)
    devices = [...UNPLUGGED]
    room.active.set("audioinput", "default")
    room.emit(RoomEvent.ActiveDeviceChanged, "audioinput", "default")
    room.emit(RoomEvent.MediaDevicesChanged)
    await settle()

    expect(events).toEqual([STRAP])
  })

  it("a mic published after the bar bound is seeded from its track", async () => {
    const room = fakeRoom()
    room.active.set("audioinput", "default")
    const settings = { deviceId: "mbp-1" }
    room.micPub.track.mediaStreamTrack = { getSettings: () => settings }
    await barOn(room)
    // The mic publishes on the AirPods after the bar bound.
    settings.deviceId = "air-1"
    room.emit(RoomEvent.LocalTrackPublished, room.micPub)
    await settle()
    devices = [...UNPLUGGED]
    room.emit(RoomEvent.ActiveDeviceChanged, "audioinput", "default")
    room.emit(RoomEvent.MediaDevicesChanged)
    await settle()

    expect(events).toEqual([STRAP])
  })
})
