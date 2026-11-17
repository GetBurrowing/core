import { describe, it, expect, beforeEach, afterEach } from "vitest"
import MeetingBar, { watchLocalMedia } from "../../js/hooks/meeting_bar.js"

// Task 01a1e82a remediation, finding 1. On a fresh join the bar read
// "Mic off" / "Cam off" while both tracks were live: `livekit:room-connected`
// fires before the join publishes its tracks, and nothing re-read the room
// after that. The bar now re-syncs on every local publish / unpublish /
// mute / unmute, so it follows the same live state the room controls,
// the joined toast and the lock-screen card read.

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
    count: (type) => (listeners.get(type) || []).length,
  }
}

function fakeRoom({ mic = false, camera = false } = {}) {
  const handlers = new Map()
  const lp = { identity: "user:me", isMicrophoneEnabled: mic, isCameraEnabled: camera }
  return {
    state: "connected",
    localParticipant: lp,
    on(e, fn) {
      handlers.set(e, [...(handlers.get(e) || []), fn])
    },
    off(e, fn) {
      handlers.set(e, (handlers.get(e) || []).filter((f) => f !== fn))
    },
    emit(e, ...args) {
      for (const fn of [...(handlers.get(e) || [])]) fn(...args)
    },
    listenerTotal: () => [...handlers.values()].reduce((n, l) => n + l.length, 0),
  }
}

function mountBar() {
  const pushes = []
  const hook = Object.create(MeetingBar)
  hook.el = { dataset: {}, querySelectorAll: () => [], querySelector: () => null }
  hook.pushEventTo = (_el, event, payload) => pushes.push([event, payload])
  hook.pushEvent = () => {}
  hook.handleEvent = () => {}
  hook.mounted()
  return { hook, pushes }
}

const states = (pushes) =>
  pushes.filter(([e]) => e === "meeting_bar_state").map(([, p]) => [p.mic, p.camera])

let win
beforeEach(() => {
  win = fakeWindow()
  globalThis.window = win
  globalThis.CustomEvent = class {
    constructor(type, init = {}) {
      this.type = type
      this.detail = init.detail
    }
  }
})
afterEach(() => {
  delete globalThis.window
})

describe("MeetingBar mic / camera state on join", () => {
  it("re-syncs when the tracks publish after room-connected", () => {
    const { pushes } = mountBar()
    const room = fakeRoom({ mic: false, camera: false })
    win.__livekit_room = room
    win.dispatchEvent(new CustomEvent("livekit:room-connected", { detail: { room } }))
    // What the room says at connect: nothing published yet.
    expect(states(pushes).at(-1)).toEqual([false, false])

    room.localParticipant.isMicrophoneEnabled = true
    room.emit("localTrackPublished", { kind: "audio" }, room.localParticipant)
    expect(states(pushes).at(-1)).toEqual([true, false])

    room.localParticipant.isCameraEnabled = true
    room.emit("localTrackPublished", { kind: "video" }, room.localParticipant)
    expect(states(pushes).at(-1)).toEqual([true, true])

    room.localParticipant.isMicrophoneEnabled = false
    room.emit("trackMuted", { kind: "audio" }, room.localParticipant)
    expect(states(pushes).at(-1)).toEqual([false, true])
  })

  it("ignores remote mutes and drops identical pushes", () => {
    const { pushes } = mountBar()
    const room = fakeRoom({ mic: true })
    win.__livekit_room = room
    win.dispatchEvent(new CustomEvent("livekit:room-connected", { detail: { room } }))
    const before = states(pushes).length
    room.emit("trackMuted", { kind: "audio" }, { identity: "user:other" })
    room.emit("localTrackPublished", { kind: "audio" }, room.localParticipant)
    expect(states(pushes).length).toBe(before)
  })

  it("takes its room listeners off on destroy", () => {
    const { hook } = mountBar()
    const room = fakeRoom()
    win.__livekit_room = room
    win.dispatchEvent(new CustomEvent("livekit:room-connected", { detail: { room } }))
    expect(room.listenerTotal()).toBeGreaterThan(0)
    hook.destroyed()
    expect(room.listenerTotal()).toBe(0)
  })
})

describe("watchLocalMedia", () => {
  it("binds a room already connected at install, and moves to the next room", () => {
    const first = fakeRoom()
    win.__livekit_room = first
    const seen = []
    const stop = watchLocalMedia(win, (room) => seen.push(room))
    first.emit("trackUnmuted", {}, first.localParticipant)
    expect(seen).toEqual([first])

    const second = fakeRoom()
    win.dispatchEvent(new CustomEvent("livekit:room-connected", { detail: { room: second } }))
    expect(first.listenerTotal()).toBe(0)
    second.emit("localTrackUnpublished", {}, second.localParticipant)
    expect(seen).toEqual([first, second, second])

    stop()
    expect(second.listenerTotal()).toBe(0)
    expect(win.count("livekit:room-connected")).toBe(0)
  })
})
