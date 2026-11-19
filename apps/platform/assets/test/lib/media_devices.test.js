import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { ClientState, __resetForTests as resetClientState } from "../../js/client_state.js"
import {
  truncateMiddle,
  NAMESPACE,
  DEVICE_FALLBACK_EVENT,
  ACTIVE_DEVICE_EVENT,
  activeRoom,
  fallbackFor,
  getPreference,
  handleDevicesChanged,
  listDevices,
  preferredDeviceId,
  registerRoom,
  resolvePreferred,
  roomDefaults,
  selectDevice,
  supportsOutputSelection,
  unregisterRoom,
  __resetForTests,
} from "../../js/lib/media_devices.js"

/**
 * The shared media-device layer (task 01a1f4c5 stage 1).
 *
 * vitest runs in node: localStorage, navigator.mediaDevices, window and the
 * audio element are faked here. `livekit-client` is the REAL module, so
 * `supportsOutputSelection` exercises livekit's own `setSinkId` probe.
 */

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
    clear: () => store.clear(),
    _store: store,
  }
}

const AIRPODS = { kind: "audioinput", deviceId: "air-1", label: "AirPods Pro", groupId: "g1" }
const BLACKHOLE = { kind: "audioinput", deviceId: "bh-1", label: "BlackHole 2ch", groupId: "g2" }
const DEFAULT_MIC = {
  kind: "audioinput",
  deviceId: "default",
  label: "Default - MacBook Pro Microphone",
  groupId: "g3",
}
const MACBOOK = { kind: "audioinput", deviceId: "mbp-1", label: "MacBook Pro Microphone", groupId: "g3" }

let devices
let storage
let events

function stubBrowser() {
  storage = fakeStorage()
  vi.stubGlobal("localStorage", storage)
  vi.stubGlobal("navigator", {
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    mediaDevices: {
      enumerateDevices: () => Promise.resolve(devices.map((d) => ({ ...d }))),
      addEventListener() {},
      removeEventListener() {},
    },
  })
  events = []
  const win = new EventTarget()
  for (const name of [ACTIVE_DEVICE_EVENT, DEVICE_FALLBACK_EVENT, "meeting:devices-changed"]) {
    win.addEventListener(name, (e) => events.push([name, e.detail]))
  }
  vi.stubGlobal("window", win)
}

beforeEach(() => {
  devices = [DEFAULT_MIC, MACBOOK, AIRPODS, BLACKHOLE]
  resetClientState()
  __resetForTests()
  stubBrowser()
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("listDevices", () => {
  it("tags virtual and default rows and drops unlabeled ones", async () => {
    devices = [...devices, { kind: "audioinput", deviceId: "", label: "" }]
    const list = await listDevices("audioinput")
    expect(list.map((d) => d.deviceId)).toEqual(["default", "mbp-1", "air-1", "bh-1"])
    expect(list.find((d) => d.deviceId === "bh-1").virtual).toBe(true)
    expect(list.find((d) => d.deviceId === "air-1").virtual).toBe(false)
    expect(list.find((d) => d.deviceId === "default").default).toBe(true)
    expect(list.find((d) => d.deviceId === "mbp-1").default).toBe(false)
  })
})

describe("resolvePreferred", () => {
  it("matches the stored deviceId exactly", async () => {
    ClientState.set(NAMESPACE, "audioinput", { deviceId: "air-1", label: "AirPods Pro" })
    const list = await listDevices("audioinput")
    expect(resolvePreferred("audioinput", list)).toEqual({
      device: expect.objectContaining({ deviceId: "air-1" }),
      substituted: false,
    })
  })

  it("matches by label after the deviceId rotated", async () => {
    ClientState.set(NAMESPACE, "audioinput", { deviceId: "air-OLD", label: "AirPods Pro" })
    devices = [DEFAULT_MIC, MACBOOK, { ...AIRPODS, deviceId: "air-NEW" }]
    const list = await listDevices("audioinput")
    const { device, substituted } = resolvePreferred("audioinput", list)
    expect(device.deviceId).toBe("air-NEW")
    expect(substituted).toBe(false)
  })

  it("substitutes the default entry when the stored device is gone, and says so", async () => {
    ClientState.set(NAMESPACE, "audioinput", { deviceId: "air-1", label: "AirPods Pro" })
    devices = [MACBOOK, DEFAULT_MIC, BLACKHOLE]
    const list = await listDevices("audioinput")
    const { device, substituted } = resolvePreferred("audioinput", list)
    expect(device.deviceId).toBe("default")
    expect(substituted).toBe(true)
  })

  it("falls to the first device when there is no default entry", async () => {
    ClientState.set(NAMESPACE, "audioinput", { deviceId: "air-1", label: "AirPods Pro" })
    devices = [BLACKHOLE, MACBOOK]
    const list = await listDevices("audioinput")
    expect(resolvePreferred("audioinput", list).device.deviceId).toBe("bh-1")
  })

  it("is never 'substituted' when nothing was stored", async () => {
    const list = await listDevices("audioinput")
    const { device, substituted } = resolvePreferred("audioinput", list)
    expect(device.deviceId).toBe("default")
    expect(substituted).toBe(false)
  })
})

describe("fallbackFor", () => {
  it("prefers the default entry", async () => {
    const list = await listDevices("audioinput")
    expect(fallbackFor("audioinput", "air-1", list).deviceId).toBe("default")
  })

  it("never returns the lost device, even when the lost one IS the default", async () => {
    const list = await listDevices("audioinput")
    expect(fallbackFor("audioinput", "default", list).deviceId).toBe("mbp-1")
    for (const lost of ["default", "mbp-1", "air-1", "bh-1"]) {
      expect(fallbackFor("audioinput", lost, list).deviceId).not.toBe(lost)
    }
  })

  it("is null when the lost device was the only one", async () => {
    devices = [AIRPODS]
    const list = await listDevices("audioinput")
    expect(fallbackFor("audioinput", "air-1", list)).toBeNull()
  })
})

describe("supportsOutputSelection (livekit's setSinkId probe)", () => {
  class FakeMediaElement {}

  beforeEach(() => {
    FakeMediaElement.prototype.setSinkId = function () {
      return Promise.resolve()
    }
    vi.stubGlobal("HTMLMediaElement", FakeMediaElement)
    vi.stubGlobal("document", { createElement: () => new FakeMediaElement() })
  })

  it("is true where audio elements have setSinkId", () => {
    expect(supportsOutputSelection()).toBe(true)
  })

  it("is false once HTMLMediaElement.prototype.setSinkId is deleted", () => {
    delete HTMLMediaElement.prototype.setSinkId
    expect(supportsOutputSelection()).toBe(false)
  })

  it("is false, not a throw, with no document at all", () => {
    vi.stubGlobal("document", undefined)
    expect(supportsOutputSelection()).toBe(false)
  })
})

describe("the preference store", () => {
  it("lives under the ClientState meeting_devices namespace", async () => {
    await selectDevice("audioinput", "air-1", { room: null })
    expect(NAMESPACE).toBe("meeting_devices")
    expect(JSON.parse(storage.getItem("suite:meeting_devices:audioinput"))).toEqual({
      deviceId: "air-1",
      label: "AirPods Pro",
    })
    expect(getPreference("audioinput")).toEqual({ deviceId: "air-1", label: "AirPods Pro" })
  })

  it("roomDefaults carries only kinds with a stored preference", async () => {
    await selectDevice("audioinput", "air-1", { room: null })
    expect(roomDefaults()).toEqual({ audioCaptureDefaults: { deviceId: "air-1" } })
    expect(preferredDeviceId("videoinput")).toBeNull()
  })
})

describe("selectDevice", () => {
  function fakeRoom({ fail = false } = {}) {
    const active = new Map([["audioinput", "mbp-1"]])
    return {
      switched: [],
      getActiveDevice: (kind) => active.get(kind),
      switchActiveDevice(kind, id, exact) {
        this.switched.push([kind, id, exact])
        if (fail) return Promise.reject(new Error("NotReadableError"))
        active.set(kind, id)
        return Promise.resolve(true)
      },
    }
  }

  it("switches the registered room (exact) and persists", async () => {
    const room = registerRoom(fakeRoom(), "meeting")
    const result = await selectDevice("audioinput", "air-1")
    expect(result).toEqual({ ok: true })
    expect(room.switched).toEqual([["audioinput", "air-1", true]])
    expect(getPreference("audioinput").deviceId).toBe("air-1")
  })

  it("a failed switch does not persist, and re-reports the device actually in use", async () => {
    registerRoom(fakeRoom({ fail: true }), "meeting")
    const result = await selectDevice("audioinput", "air-1")
    expect(result.ok).toBe(false)
    expect(result.deviceId).toBe("mbp-1")
    expect(getPreference("audioinput")).toBeNull()
    expect(events.filter(([n]) => n === ACTIVE_DEVICE_EVENT).at(-1)[1]).toEqual({
      kind: "audioinput",
      deviceId: "mbp-1",
      label: "MacBook Pro Microphone",
    })
  })

  it("drives the room of the surface that registered last; unregister hands back", () => {
    const meeting = registerRoom(fakeRoom(), "meeting")
    const voice = registerRoom(fakeRoom(), "voice")
    expect(activeRoom()).toBe(voice)
    expect(activeRoom("meeting")).toBe(meeting)
    unregisterRoom(voice)
    expect(activeRoom()).toBe(meeting)
  })
})

describe("handleDevicesChanged", () => {
  it("moves a kind whose active device vanished and emits the fallback", async () => {
    await listDevices("audioinput") // learn AirPods' label while present
    const active = new Map([["audioinput", "air-1"]])
    const room = {
      switched: [],
      getActiveDevice: (k) => active.get(k),
      switchActiveDevice(kind, id) {
        this.switched.push([kind, id])
        active.set(kind, id)
        return Promise.resolve(true)
      },
    }
    devices = [DEFAULT_MIC, MACBOOK, BLACKHOLE]
    await handleDevicesChanged(room, { kinds: ["audioinput"] })
    expect(room.switched).toEqual([["audioinput", "default"]])
    expect(events.find(([n]) => n === DEVICE_FALLBACK_EVENT)[1]).toEqual({
      kind: "audioinput",
      fromLabel: "AirPods Pro",
      toLabel: "Default - MacBook Pro Microphone",
    })
  })

  it("leaves a kind alone while its active device is still listed", async () => {
    const room = {
      switched: [],
      getActiveDevice: () => "air-1",
      switchActiveDevice(kind, id) {
        this.switched.push([kind, id])
        return Promise.resolve(true)
      },
    }
    await handleDevicesChanged(room, { kinds: ["audioinput"] })
    expect(room.switched).toEqual([])
    expect(events.some(([n]) => n === DEVICE_FALLBACK_EVENT)).toBe(false)
  })
})

describe("truncateMiddle (stage 2)", () => {
  it("keeps short names whole", () => {
    expect(truncateMiddle("AirPods Pro", 26)).toBe("AirPods Pro")
    expect(truncateMiddle("AirPods Pro", 11)).toBe("AirPods Pro")
  })

  it("cuts the middle, keeps the distinguishing tail, and fits maxChars", () => {
    const out = truncateMiddle("Logitech BRIO 2 Ultra HD Pro Webcam", 22)
    expect(out.length).toBeLessThanOrEqual(22)
    expect(out.startsWith("Logitech")).toBe(true)
    expect(out.endsWith("Pro Webcam")).toBe(true)
    expect(out).toContain("\u2026")
    expect(truncateMiddle("Microphone Array (Realtek USB)", 20).endsWith("USB)")).toBe(true)
  })

  it("two names that differ only at the end stay distinguishable", () => {
    const a = truncateMiddle("Logitech BRIO Webcam Unit 2", 16)
    const b = truncateMiddle("Logitech BRIO Webcam Unit 4", 16)
    expect(a).not.toBe(b)
  })

  it("tolerates nil and nonsense limits", () => {
    expect(truncateMiddle(null, 10)).toBe("")
    expect(truncateMiddle("abc", 0)).toBe("abc")
    expect(truncateMiddle("abcdef", 1)).toBe("\u2026")
  })
})
