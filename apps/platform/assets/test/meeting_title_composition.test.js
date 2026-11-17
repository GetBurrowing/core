import { describe, it, expect, beforeEach, afterEach } from "vitest"
import AppBadge from "../js/hooks/app_badge.js"
import { installMeetingMediaSession } from "../js/meeting_media_session.js"

// Task 01a1e82a remediation round 2, finding 1. With an unread Inbox item
// the tab froze: AppBadge prefixed "(1) ", the in-call title writer saw a
// title that was not its own and rewrote it without the prefix, AppBadge
// put the prefix back, and the two observers alternated forever. The
// meeting writer now composes with the badge ("(1) ● 0:05 Weekly sync ·
// Burrow"), both writers write only when the string differs, and each
// discards the mutation records its own write caused.
//
// vitest runs in node, so this is a fake document whose `title` setter
// queues MutationObserver callbacks as microtasks, the way a browser does,
// and fires on EVERY write (a browser replaces the text node even when the
// value is unchanged).

const T0 = Date.parse("2026-11-17T10:00:00Z")

function fakeDom(initialTitle) {
  const observers = new Set()
  let title = initialTitle
  const doc = {
    writes: [],
    titleEl: { dataset: { default: "Burrow" } },
    head: {},
    querySelector: (sel) => (sel === "title" ? doc.titleEl : null),
    getElementById: () => null,
  }
  Object.defineProperty(doc, "title", {
    get: () => title,
    set: (v) => {
      title = String(v)
      doc.writes.push(title)
      for (const o of observers) o._enqueue({ type: "childList" })
    },
  })

  class FakeMutationObserver {
    constructor(cb) {
      this.cb = cb
      this.records = []
      this.scheduled = false
    }
    observe() {
      observers.add(this)
    }
    disconnect() {
      observers.delete(this)
      this.records = []
    }
    takeRecords() {
      const r = this.records
      this.records = []
      return r
    }
    _enqueue(record) {
      this.records.push(record)
      if (this.scheduled) return
      this.scheduled = true
      queueMicrotask(() => {
        this.scheduled = false
        const r = this.takeRecords()
        if (r.length > 0) this.cb(r, this)
      })
    }
  }

  return { doc, FakeMutationObserver, observerCount: () => observers.size }
}

// Drain microtasks a bounded number of times: a loop shows up as writes
// that keep growing, never as a hang.
async function settle(rounds = 200) {
  for (let i = 0; i < rounds; i++) await Promise.resolve()
}

let dom, now, badge, media, win

function mountBadge() {
  const hook = Object.create(AppBadge)
  hook._handlers = {}
  hook.handleEvent = (name, fn) => {
    hook._handlers[name] = fn
  }
  hook.mounted()
  return hook
}

function inCall(extra = {}) {
  return {
    inCall: true,
    explicitLeave: false,
    name: "Weekly sync",
    startedAt: new Date(T0).toISOString(),
    inCallRoom: false,
    names: ["Bob"],
    ...extra,
  }
}

beforeEach(() => {
  dom = fakeDom("Calendar · Burrow")
  now = T0 + 5000
  globalThis.document = dom.doc
  globalThis.MutationObserver = dom.FakeMutationObserver
  win = {
    MutationObserver: dom.FakeMutationObserver,
    navigator: {},
    __livekit_room: null,
  }
  badge = mountBadge()
  badge._handlers.app_badge({ count: 1, label: "1" })
  media = installMeetingMediaSession(win, dom.doc, {
    toggleMic() {},
    toggleCamera() {},
    hangup() {},
  })
})

afterEach(() => {
  if (media) media.stop()
  badge.destroyed()
  delete globalThis.document
  delete globalThis.MutationObserver
})

describe("AppBadge and the in-call title share document.title", () => {
  it("the badge alone prefixes the page title", async () => {
    await settle()
    expect(dom.doc.title).toBe("(1) Calendar · Burrow")
  })

  it("joining a call composes the badge with the call title and settles", async () => {
    await settle()
    dom.doc.writes.length = 0
    media.update(inCall())
    await settle()
    expect(dom.doc.writes.length).toBeLessThan(5)
    expect(dom.doc.title).toBe("(1) ● 0:05 Weekly sync · Burrow")

    // Nothing is still bouncing: more microtasks add no writes.
    const settled = dom.doc.writes.length
    await settle()
    expect(dom.doc.writes.length).toBe(settled)
  })

  it("the clock tick keeps the prefix and writes once per tick", async () => {
    media.update(inCall())
    await settle()
    dom.doc.writes.length = 0
    now = T0 + 6000
    // The controller's 1s tick re-renders from the stored snapshot.
    media.update(inCall())
    await settle()
    expect(dom.doc.title).toBe("(1) ● 0:06 Weekly sync · Burrow")
    expect(dom.doc.writes.length).toBeLessThan(3)
  })

  it("a badge change while in a call recomposes without a loop", async () => {
    media.update(inCall())
    await settle()
    dom.doc.writes.length = 0
    badge._handlers.app_badge({ count: 3, label: "3" })
    await settle()
    expect(dom.doc.title).toBe("(3) ● 0:05 Weekly sync · Burrow")
    expect(dom.doc.writes.length).toBeLessThan(5)

    dom.doc.writes.length = 0
    badge._handlers.app_badge({ count: 0, label: null })
    await settle()
    expect(dom.doc.title).toBe("● 0:05 Weekly sync · Burrow")
    expect(dom.doc.writes.length).toBeLessThan(5)
  })

  it("a LiveView page_title write in a call keeps both badge and call title", async () => {
    media.update(inCall())
    await settle()
    dom.doc.writes.length = 0
    dom.doc.title = "Inbox · Burrow" // <.live_title> on a live navigation
    await settle()
    expect(dom.doc.title).toBe("(1) ● 0:05 Weekly sync · Burrow")
    expect(dom.doc.writes.length).toBeLessThan(6)

    // Leaving restores the page the person is now on, still badged.
    dom.doc.writes.length = 0
    media.update({ inCall: false })
    await settle()
    expect(dom.doc.title).toBe("(1) Inbox · Burrow")
    expect(dom.doc.writes.length).toBeLessThan(4)
  })

  it("leaving the call restores the badged page title", async () => {
    media.update(inCall())
    await settle()
    dom.doc.writes.length = 0
    media.update({ inCall: false })
    await settle()
    expect(dom.doc.title).toBe("(1) Calendar · Burrow")
    expect(dom.doc.writes.length).toBeLessThan(4)
    const settled = dom.doc.writes.length
    await settle()
    expect(dom.doc.writes.length).toBe(settled)
  })

  it("the reconnecting title composes with the badge too", async () => {
    media.update(inCall({ conn: { state: "reconnecting", since: T0 + 2000 } }))
    await settle()
    expect(dom.doc.title).toBe("(1) ● ↻ 0:03 Weekly sync · Burrow")
  })
})

// `now` drives the controller's clock through Date.now.
const realNow = Date.now
beforeEach(() => {
  Date.now = () => now
})
afterEach(() => {
  Date.now = realNow
})
