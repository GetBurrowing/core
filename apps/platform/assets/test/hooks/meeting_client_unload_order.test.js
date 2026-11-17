import { describe, it, expect, beforeAll, vi } from "vitest"
import MeetingClient from "../../js/hooks/meeting_client.js"
import { installMeetingPresence } from "../../js/meeting_presence.js"

// Task 01a1e82a stage 3 (audit rider on stage 2). meeting_presence.js
// registers its beforeunload listener at import, before any hook mounts, and
// cancels the event while in a call so the browser asks first. MeetingClient
// registers its own page-exit listener later and skips teardown on a
// beforeunload already cancelled. This pins that ORDER with the real
// listeners on one window: presence first, MeetingClient second, a shared
// event object, so "Stay" on the native prompt keeps the room.
//
// The same installed presence also carries the stage 3 lock-screen wiring,
// so the real navigator.mediaSession handlers are checked here too.

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
    addEventListener() {},
  }
}

function buildWindow() {
  const listeners = new Map()
  const handlers = new Map()
  const win = {
    __livekit_room: null,
    __livekitRoom: null,
    location: {
      href: "http://app.test/tasks",
      origin: "http://app.test",
      pathname: "/tasks",
      assign() {},
    },
    navigator: {
      mediaSession: {
        metadata: null,
        setActionHandler(action, fn) {
          if (fn) handlers.set(action, fn)
          else handlers.delete(action)
        },
      },
    },
    MediaMetadata: function (meta) {
      Object.assign(this, meta)
    },
    addEventListener(type, cb) {
      const list = listeners.get(type) || []
      list.push(cb)
      listeners.set(type, list)
    },
    removeEventListener(type, cb) {
      const list = listeners.get(type) || []
      const i = list.indexOf(cb)
      if (i >= 0) list.splice(i, 1)
    },
    dispatchEvent: () => true,
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    open() {},
    // Fire in registration order with ONE event object, as a browser does.
    fire(type) {
      const event = {
        type,
        defaultPrevented: false,
        returnValue: undefined,
        preventDefault() {
          this.defaultPrevented = true
        },
      }
      for (const cb of [...(listeners.get(type) || [])]) cb(event)
      return event
    },
    _listeners: listeners,
    _handlers: handlers,
  }
  return win
}

function buildDocument() {
  const titleEl = { dataset: { default: "Burrow" } }
  return {
    readyState: "complete",
    title: "Tasks · Burrow",
    visibilityState: "visible",
    createElement: () => fakeNode(),
    querySelector: (sel) => (sel === "title" ? titleEl : null),
    querySelectorAll: () => [],
    getElementById: () => null,
    addEventListener() {},
    removeEventListener() {},
    dispatchEvent: () => true,
    body: fakeNode(),
  }
}

const CALL = {
  inCall: true,
  meetingId: "m1",
  name: "Weekly sync",
  returnPath: "/meetings/weekly-sync",
  inCallRoom: false,
  patterns: ["/tasks", "/chat/:space_slug", "/meetings/:slug"],
  othersCount: 1,
  canEnd: false,
  names: ["Sam Example"],
  startedAt: "2026-11-17T10:00:00Z",
}

describe("beforeunload order: meeting_presence before MeetingClient", () => {
  let win
  let doc
  let presence
  let client
  const host = { leaves: 0, pushLeave: (done) => (host.leaves++, done(null)), push() {}, navigate() {} }

  beforeAll(() => {
    win = buildWindow()
    doc = buildDocument()
    globalThis.window = win
    globalThis.document = doc
    globalThis.requestAnimationFrame = (cb) => cb()

    presence = installMeetingPresence(win, doc)
    presence.mount(CALL, host)

    client = Object.create(MeetingClient)
    client._tiles = new Map()
    client._boundRoom = null
    client._roomListeners = []
    client.el = { dataset: { micEnabled: "true", cameraEnabled: "false" } }
    client.pushEvent = () => {}
    client.handleEvent = () => {}
    client.mounted()
    client._leave = vi.fn()
    client._companionCameraOff = vi.fn()
  })

  it("registers presence's listener first", () => {
    const list = win._listeners.get("beforeunload")
    expect(list.length).toBe(2)
    expect(list[1]).toBe(client._onPageHide)
  })

  it("a beforeunload presence cancels keeps the room (no _leave)", () => {
    const event = win.fire("beforeunload")
    expect(event.defaultPrevented).toBe(true)
    expect(client._leave).not.toHaveBeenCalled()
    expect(client._leaving).toBe(false)
  })

  it("the lock screen's hangup is the explicit leave, and then a beforeunload tears down", () => {
    expect(win.navigator.mediaSession.metadata.title).toBe("In Weekly sync")
    expect(doc.title).toMatch(/^● \d+:\d{2}(:\d{2})? Weekly sync · Burrow$/)

    win._handlers.get("hangup")()

    expect(host.leaves).toBe(1)
    expect(win.navigator.mediaSession.metadata).toBe(null)
    expect(win._handlers.size).toBe(0)
    expect(doc.title).toBe("Tasks · Burrow")

    // Disarmed after the explicit leave: nothing cancels it, so it is a
    // real exit for MeetingClient.
    const event = win.fire("beforeunload")
    expect(event.defaultPrevented).toBe(false)
    expect(client._leave).toHaveBeenCalledTimes(1)
  })
})
