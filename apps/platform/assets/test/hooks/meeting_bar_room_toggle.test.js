import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { RoomEvent } from "livekit-client"
import MeetingBar from "../../js/hooks/meeting_bar.js"

// Task 01a1e82a remediation round 2, finding 2. On a shell page (/calendar,
// /inbox) the bar's Mic / Cam pushed `meeting_toggle_*` to the shell, which
// flipped its own assign and pushed `toggle-mic` to a MeetingClient that is
// only mounted on the chat. The room was never touched: the chip said "Mic
// off" while the microphone kept publishing. The bar now toggles the real
// room itself and the chip follows the room's own track events.

function fakeWindow() {
  const listeners = new Map()
  return {
    __livekit_room: null,
    __livekitRoom: null,
    addEventListener(type, cb) {
      listeners.set(type, [...(listeners.get(type) || []), cb])
    },
    removeEventListener(type, cb) {
      listeners.set(type, (listeners.get(type) || []).filter((f) => f !== cb))
    },
    dispatchEvent(event) {
      for (const cb of [...(listeners.get(event.type) || [])]) cb(event)
      return true
    },
  }
}

// A room whose local participant behaves like livekit-client's: the enable
// calls resolve after the track mutes / unmutes, and the room emits the
// TrackMuted / TrackUnmuted event for the local participant.
function fakeRoom({ mic = true, camera = true } = {}) {
  const handlers = new Map()
  const room = {
    state: "connected",
    on(e, fn) {
      handlers.set(e, [...(handlers.get(e) || []), fn])
    },
    off(e, fn) {
      handlers.set(e, (handlers.get(e) || []).filter((f) => f !== fn))
    },
    emit(e, ...args) {
      for (const fn of [...(handlers.get(e) || [])]) fn(...args)
    },
  }
  const lp = {
    identity: "user:me",
    isMicrophoneEnabled: mic,
    isCameraEnabled: camera,
    setMicrophoneEnabled: vi.fn(async (on) => {
      lp.isMicrophoneEnabled = on
      room.emit(on ? RoomEvent.TrackUnmuted : RoomEvent.TrackMuted, { source: "microphone" }, lp)
    }),
    setCameraEnabled: vi.fn(async (on) => {
      lp.isCameraEnabled = on
      room.emit(on ? RoomEvent.TrackUnmuted : RoomEvent.TrackMuted, { source: "camera" }, lp)
    }),
  }
  room.localParticipant = lp
  return room
}

function fakeButton() {
  const listeners = []
  return {
    disabled: false,
    addEventListener: (type, fn) => type === "click" && listeners.push(fn),
    removeEventListener: (type, fn) => {
      const i = listeners.indexOf(fn)
      if (i >= 0) listeners.splice(i, 1)
    },
    click: () => listeners.slice().forEach((fn) => fn({ preventDefault() {} })),
  }
}

function mountBar() {
  const mic = fakeButton()
  const cam = fakeButton()
  const pushes = []
  const serverPushes = []
  const hook = Object.create(MeetingBar)
  hook.el = {
    dataset: {},
    querySelector: () => null,
    querySelectorAll: (sel) => (sel === "[data-bar-mic]" ? [mic] : sel === "[data-bar-camera]" ? [cam] : []),
  }
  hook.pushEventTo = (_el, event, payload) => pushes.push([event, payload])
  hook.pushEvent = (event, payload) => serverPushes.push([event, payload])
  hook.handleEvent = () => {}
  hook.mounted()
  return { hook, mic, cam, pushes, serverPushes }
}

const chip = (pushes) => {
  const states = pushes.filter(([e]) => e === "meeting_bar_state")
  const last = states[states.length - 1]
  return last ? { mic: last[1].mic, camera: last[1].camera } : null
}

const flush = async () => {
  for (let i = 0; i < 10; i++) await Promise.resolve()
}

let win, doc
beforeEach(() => {
  win = fakeWindow()
  // A shell page: no MeetingClient element (that lives on the chat only).
  doc = { getElementById: () => null }
  globalThis.window = win
  globalThis.document = doc
  globalThis.CustomEvent = class {
    constructor(type, init = {}) {
      this.type = type
      this.detail = init.detail
    }
  }
})
afterEach(() => {
  delete globalThis.window
  delete globalThis.document
})

describe("the bar's Mic / Cam on a shell page act on the real room", () => {
  it("Mic calls setMicrophoneEnabled(false) and the chip follows the track-muted event", async () => {
    const room = fakeRoom({ mic: true, camera: true })
    win.__livekit_room = room
    const { mic, pushes, serverPushes } = mountBar()
    expect(chip(pushes)).toEqual({ mic: true, camera: true })

    mic.click()
    await flush()

    expect(room.localParticipant.setMicrophoneEnabled).toHaveBeenCalledWith(false)
    expect(room.localParticipant.isMicrophoneEnabled).toBe(false)
    expect(chip(pushes)).toEqual({ mic: false, camera: true })
    // No optimistic server toggle: the shell only hears the confirmed state.
    expect(serverPushes.map(([e]) => e)).not.toContain("meeting_toggle_mic")
    expect(serverPushes).toContainEqual(["meeting_media_confirmed", { mic: false, camera: true }])

    mic.click()
    await flush()
    expect(room.localParticipant.setMicrophoneEnabled).toHaveBeenLastCalledWith(true)
    expect(chip(pushes)).toEqual({ mic: true, camera: true })
  })

  it("Cam calls setCameraEnabled(false) and the chip follows the track-muted event", async () => {
    const room = fakeRoom({ mic: true, camera: true })
    win.__livekit_room = room
    const { cam, pushes, serverPushes } = mountBar()

    cam.click()
    await flush()

    expect(room.localParticipant.setCameraEnabled).toHaveBeenCalledWith(false)
    expect(chip(pushes)).toEqual({ mic: true, camera: false })
    expect(serverPushes.map(([e]) => e)).not.toContain("meeting_toggle_camera")
    expect(serverPushes).toContainEqual(["meeting_media_confirmed", { mic: true, camera: false }])
  })

  it("a failed toggle leaves the chip on the room's real state", async () => {
    const room = fakeRoom({ mic: true, camera: false })
    room.localParticipant.setMicrophoneEnabled = vi.fn(async () => {
      throw new Error("NotAllowedError")
    })
    win.__livekit_room = room
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {})
    const { mic, pushes } = mountBar()

    mic.click()
    await flush()

    expect(chip(pushes)).toEqual({ mic: true, camera: false })
    warn.mockRestore()
  })

  it("inside the iOS app the native call owns media: the bar hands off to the server", async () => {
    const room = fakeRoom({ mic: true, camera: false })
    win.__livekit_room = room
    win.Capacitor = {
      isNativePlatform: () => true,
      Plugins: { BurrowMeetings: {} },
    }
    const { mic, serverPushes } = mountBar()

    mic.click()
    await flush()

    expect(room.localParticipant.setMicrophoneEnabled).not.toHaveBeenCalled()
    expect(serverPushes).toContainEqual(["meeting_toggle_mic", {}])
  })

  it("on the chat (MeetingClient mounted) the bar keeps the MeetingHooks path", async () => {
    const room = fakeRoom({ mic: true, camera: false })
    win.__livekit_room = room
    doc.getElementById = (id) => (id === "meeting-client" ? {} : null)
    const { mic, serverPushes } = mountBar()

    mic.click()
    await flush()

    expect(room.localParticipant.setMicrophoneEnabled).not.toHaveBeenCalled()
    expect(serverPushes).toContainEqual(["meeting_toggle_mic", {}])
  })
})
