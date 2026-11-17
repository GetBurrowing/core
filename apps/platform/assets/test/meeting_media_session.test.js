import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import {
  createMeetingMediaSession,
  cardMetadata,
  callTitle,
  rosterText,
  nativeCallOwnsMedia,
  METADATA_REFRESH_MS,
} from "../js/meeting_media_session.js"
import { createMeetingPresence } from "../js/meeting_presence.js"
import { __resetForTests } from "../js/client_state.js"

// Task 01a1e82a stage 3: the lock-screen card (Media Session) and the
// in-call tab title. vitest runs in node, so the media session, the title
// and the presence host are fakes handed in through `env`.

const PATTERNS = ["/chat", "/chat/:space_slug", "/calendar", "/tasks", "/meetings/:slug"]
const T0 = Date.parse("2026-11-17T10:00:00Z")

function fakeMediaSession({ throwOn = [] } = {}) {
  const handlers = new Map()
  const ms = {
    metadata: null,
    metadataWrites: 0,
    mic: [],
    camera: [],
    setActionHandler(action, fn) {
      if (throwOn.includes(action)) throw new TypeError(`unsupported ${action}`)
      if (fn) handlers.set(action, fn)
      else handlers.delete(action)
    },
    setMicrophoneActive(v) {
      ms.mic.push(v)
    },
    setCameraActive(v) {
      ms.camera.push(v)
    },
    handlers,
  }
  let meta = null
  Object.defineProperty(ms, "metadata", {
    get: () => meta,
    set: (v) => {
      meta = v
      if (v) ms.metadataWrites += 1
    },
  })
  return ms
}

function inCallState(extra = {}) {
  return {
    inCall: true,
    meetingId: "m1",
    name: "Weekly sync",
    returnPath: "/meetings/weekly-sync",
    inCallRoom: false,
    patterns: PATTERNS,
    othersCount: 2,
    canEnd: false,
    names: ["Sam Example", "Lee Example"],
    startedAt: new Date(T0).toISOString(),
    ...extra,
  }
}

// A presence controller and the media session wired the way
// installMeetingPresence wires them, with recording fakes.
function rig({ ms = fakeMediaSession(), native = false, mic = true, bar = null } = {}) {
  let clock = T0
  const intervals = []
  const timers = []
  const page = { title: "Tasks · Burrow" }
  const host = {
    leaves: 0,
    pushes: [],
    pushLeave(done) {
      host.leaves += 1
      done({ left: { name: "Weekly sync", names: ["Sam Example", "Lee Example"], count: 2 } })
    },
    push(event) {
      host.pushes.push(event)
    },
    navigate() {},
  }
  const toasts = []
  let media = null
  const presence = createMeetingPresence({
    storage: { get: () => null, set() {}, remove() {} },
    now: () => clock,
    setTimeout: (fn, ms) => timers.push({ fn, ms }),
    clearTimeout() {},
    setInterval: (fn, ms) => intervals.push({ fn, ms }) - 1,
    clearInterval() {},
    location: { href: "http://app.test/tasks", origin: "http://app.test", pathname: "/tasks" },
    ui: { toast: (spec) => (toasts.push(spec), { dismiss() {} }), bar: () => null },
    barControl: (kind) => (bar ? bar[kind] : null),
    onChange: (s) => media && media.update(s),
  })
  media = createMeetingMediaSession({
    now: () => clock,
    setInterval: (fn, ms) => intervals.push({ fn, ms, media: true }) - 1,
    clearInterval() {},
    mediaSession: () => ms,
    MediaMetadata: (meta) => ({ ...meta }),
    nativeOwnsMedia: () => native,
    getTitle: () => page.title,
    setTitle: (t) => (page.title = t),
    appName: () => "Burrow",
    readMic: () => mic,
    readCamera: () => false,
    toggleMic: () => presence.toggleMedia("mic"),
    toggleCamera: () => presence.toggleMedia("camera"),
    hangup: () => presence.leaveNow(),
  })
  return {
    ms,
    page,
    host,
    toasts,
    presence,
    media,
    advance(ms) {
      clock += ms
      for (const i of intervals.filter((x) => x.media)) i.fn()
    },
    setMic(v) {
      mic = v
    },
  }
}

describe("copy", () => {
  it("lock-screen card: In <name> / <names> · mic on|off / elapsed", () => {
    expect(cardMetadata({ name: "Weekly sync", names: ["Sam", "Lee"], mic: true, elapsed: "12:04" })).toEqual({
      title: "In Weekly sync",
      artist: "Sam and Lee · mic on",
      album: "12:04",
    })
    expect(cardMetadata({ name: "Weekly sync", names: [], mic: false, elapsed: "0:03" }).artist).toBe("mic off")
    expect(rosterText(["A", "B", "C", "D", "E"])).toBe("A, B, C and 2 others")
  })

  it("tab title: connected and reconnecting", () => {
    expect(callTitle({ name: "Weekly sync", elapsed: "12:04", appName: "Burrow" })).toBe("● 12:04 Weekly sync · Burrow")
    expect(callTitle({ name: "Weekly sync", elapsed: "0:07", reconnecting: true, appName: "Burrow" })).toBe(
      "● ↻ 0:07 Weekly sync · Burrow",
    )
  })
})

describe("Media Session", () => {
  beforeEach(() => __resetForTests && __resetForTests())

  it("sets the card on join with the exact copy and registers the three actions", () => {
    const r = rig()
    r.presence.mount(inCallState(), r.host)
    r.advance(12 * 60 * 1000 + 4000)

    expect(r.ms.metadata.title).toBe("In Weekly sync")
    expect(r.ms.metadata.artist).toBe("Sam Example and Lee Example · mic on")
    expect([...r.ms.handlers.keys()].sort()).toEqual(["hangup", "togglecamera", "togglemicrophone"])
    expect(r.ms.mic.at(-1)).toBe(true)
    expect(r.ms.camera.at(-1)).toBe(false)
  })

  it("refreshes the elapsed time at most every 15s, but a mic change at once", () => {
    const r = rig()
    r.presence.mount(inCallState(), r.host)
    const first = r.ms.metadataWrites
    r.advance(1000)
    r.advance(1000)
    expect(r.ms.metadataWrites).toBe(first)
    r.advance(METADATA_REFRESH_MS)
    expect(r.ms.metadataWrites).toBe(first + 1)
    expect(r.ms.metadata.album).toBe("0:17")

    r.setMic(false)
    r.advance(1000)
    expect(r.ms.metadataWrites).toBe(first + 2)
    expect(r.ms.metadata.artist).toBe("Sam Example and Lee Example · mic off")
  })

  it("togglemicrophone clicks the bar's [data-bar-mic]; togglecamera its camera", () => {
    const bar = { mic: { disabled: false, click: vi.fn() }, camera: { disabled: false, click: vi.fn() } }
    const r = rig({ bar })
    r.presence.mount(inCallState(), r.host)

    r.ms.handlers.get("togglemicrophone")()
    r.ms.handlers.get("togglecamera")()
    expect(bar.mic.click).toHaveBeenCalledTimes(1)
    expect(bar.camera.click).toHaveBeenCalledTimes(1)
    expect(r.host.pushes).toEqual([])
  })

  it("a pending (disabled) bar mic is not clicked", () => {
    const bar = { mic: { disabled: true, click: vi.fn() } }
    const r = rig({ bar })
    r.presence.mount(inCallState(), r.host)
    r.ms.handlers.get("togglemicrophone")()
    expect(bar.mic.click).not.toHaveBeenCalled()
  })

  it("without the bar (the call room) Mute pushes the bar's own meeting_toggle_mic", () => {
    const r = rig()
    r.presence.mount(inCallState({ inCallRoom: true }), r.host)
    r.ms.handlers.get("togglemicrophone")()
    r.ms.handlers.get("togglecamera")()
    expect(r.host.pushes).toEqual(["meeting_toggle_mic", "meeting_toggle_camera"])
  })

  it("hangup is the explicit leave: server leave, left toast, card and handlers cleared", () => {
    const r = rig()
    r.presence.mount(inCallState(), r.host)

    r.ms.handlers.get("hangup")()

    expect(r.host.leaves).toBe(1)
    expect(r.toasts.at(-1).title).toBe("You left Weekly sync")
    expect(r.ms.metadata).toBe(null)
    expect(r.ms.handlers.size).toBe(0)
    expect(r.presence.armed()).toBe(false)
  })

  it("clears on a host end and on the server's left", () => {
    const r = rig()
    r.presence.mount(inCallState(), r.host)
    r.presence.onServerEvent({ kind: "ended", host: "Sam", name: "Weekly sync" })
    expect(r.ms.metadata).toBe(null)
    expect(r.ms.handlers.size).toBe(0)

    const r2 = rig()
    r2.presence.mount(inCallState(), r2.host)
    r2.presence.update({ ...inCallState(), inCall: false })
    expect(r2.ms.metadata).toBe(null)
    expect(r2.ms.handlers.size).toBe(0)
  })

  it("a throwing setActionHandler does not stop the other actions or the card", () => {
    const ms = fakeMediaSession({ throwOn: ["togglecamera"] })
    const r = rig({ ms })
    expect(() => r.presence.mount(inCallState(), r.host)).not.toThrow()
    expect(ms.metadata.title).toBe("In Weekly sync")
    expect([...ms.handlers.keys()].sort()).toEqual(["hangup", "togglemicrophone"])
    expect(r.page.title).toBe("● 0:00 Weekly sync · Burrow")
  })

  it("is a no-op without navigator.mediaSession", () => {
    const r = rig({ ms: null })
    expect(() => r.presence.mount(inCallState(), r.host)).not.toThrow()
    expect(r.page.title).toBe("● 0:00 Weekly sync · Burrow")
  })

  it("stays off when the iOS native call owns media", () => {
    const r = rig({ native: true })
    r.presence.mount(inCallState(), r.host)
    r.advance(METADATA_REFRESH_MS)
    expect(r.ms.metadata).toBe(null)
    expect(r.ms.handlers.size).toBe(0)
  })

  it("nativeCallOwnsMedia needs the native platform and the meetings plugin", () => {
    expect(nativeCallOwnsMedia({})).toBe(false)
    expect(nativeCallOwnsMedia({ Capacitor: { isNativePlatform: () => false, Plugins: { BurrowMeetings: {} } } })).toBe(false)
    expect(nativeCallOwnsMedia({ Capacitor: { isNativePlatform: () => true, Plugins: {} } })).toBe(false)
    expect(nativeCallOwnsMedia({ Capacitor: { isNativePlatform: () => true, Plugins: { SuiteMeetings: {} } } })).toBe(true)
  })
})

describe("tab title", () => {
  afterEach(() => vi.useRealTimers())

  it("ticks the elapsed time, shows the reconnect counter, and restores the page title on leave", () => {
    const r = rig()
    r.presence.mount(inCallState(), r.host)
    expect(r.page.title).toBe("● 0:00 Weekly sync · Burrow")

    r.advance(12 * 60 * 1000 + 4000)
    expect(r.page.title).toBe("● 12:04 Weekly sync · Burrow")

    r.presence.onRoomState("reconnecting")
    r.advance(7000)
    expect(r.page.title).toBe("● ↻ 0:07 Weekly sync · Burrow")

    r.presence.onRoomState("reconnected")
    r.advance(1000)
    expect(r.page.title).toBe("● 12:12 Weekly sync · Burrow")

    r.presence.noteBarLeave()
    expect(r.page.title).toBe("Tasks · Burrow")
  })

  it("a live navigation's new page title is what comes back on leave", () => {
    const r = rig()
    r.presence.mount(inCallState(), r.host)
    r.page.title = "Calendar · Burrow" // LiveView's page_title on navigation
    r.media.onTitleChanged()
    expect(r.page.title).toBe("● 0:00 Weekly sync · Burrow")

    r.presence.update({ ...inCallState(), inCall: false })
    expect(r.page.title).toBe("Calendar · Burrow")
  })

  it("leaves the call room's title alone", () => {
    const r = rig()
    r.page.title = "Weekly sync · Burrow"
    r.presence.mount(inCallState({ inCallRoom: true }), r.host)
    r.advance(5000)
    expect(r.page.title).toBe("Weekly sync · Burrow")
  })
})
