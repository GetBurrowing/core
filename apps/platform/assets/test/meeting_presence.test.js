import { describe, it, expect, beforeEach, vi } from "vitest"
import {
  createMeetingPresence,
  classifyClick,
  routeMatches,
  destinationLabel,
  readState,
  joinNames,
  leftToast,
  RECONNECT_LOST_MS,
  REJOIN_INTENT_MS,
  DIALOG_Z_CLASS,
  createDomUi,
  guardDialog,
} from "../js/meeting_presence.js"
import { readFileSync, readdirSync, statSync } from "node:fs"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import { __resetForTests } from "../js/client_state.js"

// Task 01a1e82a stage 2. vitest runs in node (no jsdom), so the controller
// is driven through its `env`: fake anchors, a fake bar element, a recording
// toast/dialog renderer and an in-memory storage.

const PATTERNS = ["/chat", "/chat/:space_slug", "/calendar", "/inbox", "/meetings/:slug", "/org_memory/*file_key"]
const ORIGIN = "http://app.test"

function fakeLocation(pathname = "/chat/general") {
  return { href: `${ORIGIN}${pathname}`, origin: ORIGIN, pathname, search: "" }
}

function anchor(attrs = {}) {
  const a = {
    getAttribute: (k) => (k in attrs ? attrs[k] : null),
    hasAttribute: (k) => k in attrs,
    closest: (sel) => (sel === "a[href]" && "href" in attrs ? a : null),
  }
  return a
}

function click(attrs, extra = {}) {
  const target = anchor(attrs)
  return {
    target,
    button: 0,
    defaultPrevented: false,
    prevented: 0,
    stopped: 0,
    preventDefault() {
      this.defaultPrevented = true
      this.prevented += 1
    },
    stopImmediatePropagation() {
      this.stopped += 1
    },
    ...extra,
  }
}

function fakeBar() {
  const attrs = { "data-state": "connected" }
  const counter = { textContent: "0:00" }
  return {
    attrs,
    counter,
    setAttribute: (k, v) => (attrs[k] = String(v)),
    removeAttribute: (k) => delete attrs[k],
    getAttribute: (k) => (k in attrs ? attrs[k] : null),
    querySelector: (sel) => (sel === "[data-conn-timer]" ? counter : null),
  }
}

function memoryStorage() {
  const m = new Map()
  return {
    m,
    get: (ns, k, d = null) => (m.has(`${ns}:${k}`) ? m.get(`${ns}:${k}`) : d),
    set: (ns, k, v) => m.set(`${ns}:${k}`, v),
    remove: (ns, k) => m.delete(`${ns}:${k}`),
  }
}

function throwingStorage() {
  const boom = () => {
    throw new Error("SecurityError")
  }
  return { get: boom, set: boom, remove: boom }
}

const CALL = {
  inCall: true,
  meetingId: "m-1",
  name: "Weekly sync",
  returnPath: "/meetings/weekly-sync",
  inCallRoom: false,
  patterns: PATTERNS,
  othersCount: 2,
  canEnd: false,
}

function setup({ phone = false, storage = memoryStorage(), choice = "cancel", path, owner = null, roomState = null } = {}) {
  const toasts = []
  const dialogs = []
  const bar = fakeBar()
  const calls = { open: [], assign: [], disconnect: 0, navigate: [], pushLeave: 0, pushEnd: 0 }
  let replyWith = { left: { kind: "left", name: "Weekly sync", names: ["Dalton", "Brosnan"], count: 2, return_path: "/meetings/weekly-sync" } }
  const location = fakeLocation(path)
  const presence = createMeetingPresence({
    storage,
    location,
    isPhone: () => phone,
    ui: {
      toast: (spec, onAction) => {
        const handle = { spec, onAction, dismissed: false, dismiss() { this.dismissed = true } }
        toasts.push(handle)
        return handle
      },
      choose: (spec) => {
        dialogs.push(spec)
        return choice
      },
      bar: () => bar,
    },
    openWindow: (href) => calls.open.push(href),
    assign: (href) => calls.assign.push(href),
    disconnectRoom: () => (calls.disconnect += 1),
    connectionOwner: () => owner,
    roomState: () => roomState,
  })
  const host = {
    pushes: [],
    push: (event) => host.pushes.push(event),
    pushLeave: (done) => {
      calls.pushLeave += 1
      done(replyWith)
    },
    pushEnd: () => (calls.pushEnd += 1),
    navigate: (p) => calls.navigate.push(p),
  }
  return { presence, toasts, dialogs, bar, calls, host, storage, setReply: (r) => (replyWith = r) }
}

const titles = (toasts) => toasts.map((t) => t.spec.title)

beforeEach(() => {
  __resetForTests()
})

describe("routeMatches", () => {
  it("matches static, :param and *glob segments exactly", () => {
    expect(routeMatches("/chat", PATTERNS)).toBe(true)
    expect(routeMatches("/chat/general", PATTERNS)).toBe(true)
    expect(routeMatches("/chat/general/extra", PATTERNS)).toBe(false)
    expect(routeMatches("/org_memory/a/b/c", PATTERNS)).toBe(true)
    expect(routeMatches("/admin", PATTERNS)).toBe(false)
    expect(routeMatches("/canvases/1", PATTERNS)).toBe(false)
  })
})

describe("classifyClick (the full-load guard's decision)", () => {
  const ctx = { location: fakeLocation(), patterns: PATTERNS }

  it("intercepts a plain same-origin link", () => {
    expect(classifyClick(click({ href: "/admin" }), ctx)).toMatchObject({ pathname: "/admin" })
  })

  it("intercepts a redirect link that leaves the authenticated live_session", () => {
    const hit = classifyClick(click({ href: "/canvases/abc", "data-phx-link": "redirect" }), ctx)
    expect(hit).toMatchObject({ pathname: "/canvases/abc" })
  })

  it("ignores live links: patch, and redirects inside the live_session", () => {
    expect(classifyClick(click({ href: "/chat/x", "data-phx-link": "patch" }), ctx)).toBeNull()
    expect(classifyClick(click({ href: "/calendar", "data-phx-link": "redirect" }), ctx)).toBeNull()
    expect(classifyClick(click({ href: "/inbox", "data-in-app-link": "path" }), ctx)).toBeNull()
  })

  it("ignores target=_blank, modifier clicks, downloads, anchors and other origins", () => {
    expect(classifyClick(click({ href: "/admin", target: "_blank" }), ctx)).toBeNull()
    for (const mod of ["metaKey", "ctrlKey", "shiftKey", "altKey"]) {
      expect(classifyClick(click({ href: "/admin" }, { [mod]: true }), ctx)).toBeNull()
    }
    expect(classifyClick(click({ href: "/admin" }, { button: 1 }), ctx)).toBeNull()
    expect(classifyClick(click({ href: "/files/blob/1", download: "" }), ctx)).toBeNull()
    expect(classifyClick(click({ href: "#top" }), ctx)).toBeNull()
    expect(classifyClick(click({ href: "https://elsewhere.test/x" }), ctx)).toBeNull()
  })

  it("names the destination from the first path segment", () => {
    expect(destinationLabel("/admin/users")).toBe("Admin")
    expect(destinationLabel("/canvases/1")).toBe("Canvases")
    expect(destinationLabel("/")).toBe("This page")
  })
})

describe("the guard dialog", () => {
  it("shows the exact desktop copy and does nothing on Cancel (call kept)", async () => {
    const { presence, dialogs, calls, host } = setup({ choice: "cancel" })
    presence.mount(CALL, host)
    const ev = click({ href: "/admin" })
    const choice = await presence.onClick(ev)
    expect(choice).toBe("cancel")
    expect(ev.prevented).toBe(1)
    expect(ev.stopped).toBe(1)
    expect(dialogs[0]).toMatchObject({
      title: "Admin opens outside the app",
      body: "Going there reloads the page, which would end your place in Weekly sync. Open it in a new tab to stay in the call.",
    })
    expect(dialogs[0].buttons.map((b) => [b.label, b.tone])).toEqual([
      ["Cancel", "neutral"],
      ["Leave call and go", "error"],
      ["Open in new tab", "primary"],
    ])
    expect(calls).toMatchObject({ open: [], assign: [], disconnect: 0, pushLeave: 0 })
    expect(presence.armed()).toBe(true)
  })

  it("Open in new tab opens the link in a new window and keeps the call", async () => {
    const { presence, calls, host } = setup({ choice: "newtab" })
    presence.mount(CALL, host)
    await presence.onClick(click({ href: "/admin" }))
    expect(calls.open).toEqual([`${ORIGIN}/admin`])
    expect(calls.assign).toEqual([])
    expect(calls.disconnect).toBe(0)
    expect(presence.armed()).toBe(true)
  })

  it("Leave call and go leaves through the server, then navigates; the stashed toast renders on the next load", async () => {
    const storage = memoryStorage()
    const first = setup({ choice: "leave", storage })
    first.presence.mount(CALL, first.host)
    await first.presence.onClick(click({ href: "/admin" }))
    expect(first.calls.pushLeave).toBe(1)
    expect(first.calls.disconnect).toBe(1)
    expect(first.calls.assign).toEqual([`${ORIGIN}/admin`])
    expect(first.toasts).toEqual([])
    expect(first.presence.armed()).toBe(false)

    // The destination page load: a fresh controller over the same storage.
    const next = setup({ storage })
    next.presence.showStashed()
    expect(titles(next.toasts)).toEqual(["You left Weekly sync"])
    expect(next.toasts[0].spec.body).toBe("Dalton and Brosnan are still in the room.")
    expect(next.toasts[0].spec.action).toEqual({ label: "Rejoin", value: "rejoin" })
    // One-shot.
    const again = setup({ storage })
    again.presence.showStashed()
    expect(again.toasts).toEqual([])
  })

  it("uses the phone sheet copy below sm, with Open in Safari in the iOS app", async () => {
    const { presence, dialogs, host } = setup({ phone: true })
    presence.mount(CALL, host)
    await presence.onClick(click({ href: "/admin" }))
    expect(dialogs[0]).toMatchObject({
      variant: "sheet",
      title: "This page opens outside the app",
      body: "Opening it would end your call.",
    })
    expect(dialogs[0].buttons.map((b) => b.label)).toEqual(["Open in new tab", "Leave call and open", "Cancel"])

    const native = createMeetingPresence({
      location: fakeLocation(),
      isPhone: () => true,
      isNativeApp: () => true,
      ui: { choose: (spec) => (dialogs.push(spec), "cancel") },
    })
    native.mount(CALL, null)
    await native.onClick(click({ href: "/admin" }))
    expect(dialogs[1].buttons[0].label).toBe("Open in Safari")
  })

  it("is not armed outside a call, and never fires for live links", async () => {
    const { presence, dialogs, host } = setup()
    presence.mount({ ...CALL, inCall: false }, host)
    expect(await presence.onClick(click({ href: "/admin" }))).toBeNull()
    presence.update(CALL)
    expect(await presence.onClick(click({ href: "/calendar", "data-phx-link": "redirect" }))).toBeNull()
    expect(dialogs).toEqual([])
  })
})

describe("beforeunload", () => {
  const unload = () => ({ prevented: 0, returnValue: undefined, preventDefault() { this.prevented += 1 } })

  it("is armed only while in a call", () => {
    const { presence, host } = setup()
    presence.mount({ ...CALL, inCall: false }, host)
    const idle = unload()
    presence.onBeforeUnload(idle)
    expect(idle.prevented).toBe(0)

    presence.update(CALL)
    const live = unload()
    presence.onBeforeUnload(live)
    expect(live.prevented).toBe(1)
    expect(live.returnValue).toBe("")
  })

  it("is disarmed after the bar's Leave and after Leave call and go", async () => {
    const a = setup()
    a.presence.mount(CALL, a.host)
    a.presence.noteBarLeave()
    const e1 = unload()
    a.presence.onBeforeUnload(e1)
    expect(e1.prevented).toBe(0)

    const b = setup({ choice: "leave" })
    b.presence.mount(CALL, b.host)
    await b.presence.onClick(click({ href: "/admin" }))
    const e2 = unload()
    b.presence.onBeforeUnload(e2)
    expect(e2.prevented).toBe(0)

    // A new call re-arms it.
    b.presence.update({ ...CALL, inCall: false })
    b.presence.update({ ...CALL, meetingId: "m-2" })
    const e3 = unload()
    b.presence.onBeforeUnload(e3)
    expect(e3.prevented).toBe(1)
  })
})

describe("toasts", () => {
  it("\"You're still in\" fires once per meeting id across navigations", () => {
    const { presence, toasts, host, calls } = setup()
    presence.mount(CALL, host) // the page load: no toast
    expect(toasts).toEqual([])
    presence.mount(CALL, host) // first live navigation that keeps the call
    presence.mount(CALL, host) // second
    expect(titles(toasts)).toEqual(["You're still in Weekly sync"])
    expect(toasts[0].spec.body).toBe("Switching tabs never leaves the call. Use Leave to go.")
    expect(toasts[0].spec.action.label).toBe("Back to call")
    toasts[0].onAction("back", toasts[0].spec)
    expect(calls.navigate).toEqual(["/meetings/weekly-sync"])

    // A different meeting gets its own one.
    presence.mount({ ...CALL, meetingId: "m-2" }, host)
    presence.mount({ ...CALL, meetingId: "m-2" }, host)
    expect(titles(toasts)).toEqual(["You're still in Weekly sync", "You're still in Weekly sync"])
  })

  it("leaving the call room counts as a kept navigation; the call room itself never toasts", () => {
    const { presence, toasts, host } = setup({ phone: true })
    presence.mount({ ...CALL, inCallRoom: true }, host)
    presence.mount({ ...CALL, inCallRoom: true }, host)
    expect(toasts).toEqual([])
    presence.mount(CALL, host)
    expect(toasts.map((t) => [t.spec.title, t.spec.body])).toEqual([["Still in Weekly sync", "Tap the green bar to go back."]])
  })

  it("renders joined / left / ended copy from the server events", () => {
    const { presence, toasts, host, calls } = setup()
    presence.mount(CALL, host)
    presence.onServerEvent({ kind: "joined", name: "Weekly sync", mic: true, camera: false })
    presence.onServerEvent({
      kind: "left",
      name: "Weekly sync",
      names: ["Dalton", "Brosnan", "Scribe"],
      count: 3,
      return_path: "/meetings/weekly-sync",
    })
    presence.onServerEvent({ kind: "left", name: "Weekly sync", names: [], count: 0 })
    presence.onServerEvent({ kind: "ended", name: "Weekly sync", host: "Brosnan" })
    expect(toasts.map((t) => [t.spec.title, t.spec.body])).toEqual([
      ["You joined Weekly sync", "Mic on · camera off. The call stays on while you switch tabs."],
      ["You left Weekly sync", "Dalton, Brosnan and Scribe are still in the room."],
      ["Call ended", undefined],
      ["Brosnan ended Weekly sync", undefined],
    ])
    expect(toasts[1].spec.duration).toBe(10000)
    toasts[1].onAction("rejoin", toasts[1].spec)
    expect(calls.navigate).toEqual(["/meetings/weekly-sync"])
    // Ended drops the LiveKit room.
    expect(calls.disconnect).toBe(1)
  })

  it("uses the phone copy below sm", () => {
    const { presence, toasts, host } = setup({ phone: true })
    presence.mount(CALL, host)
    presence.onServerEvent({ kind: "joined", name: "Weekly sync" })
    presence.onServerEvent({ kind: "left", name: "Weekly sync", names: ["A", "B"], count: 2 })
    expect(toasts.map((t) => [t.spec.title, t.spec.body])).toEqual([
      ["You joined Weekly sync", "The call stays on across tabs."],
      ["You left Weekly sync", "2 people are still in the room."],
    ])
  })

  it("joins long name lists with a count", () => {
    expect(joinNames(["A"], 1)).toBe("A")
    expect(joinNames(["A", "B", "C", "D", "E"], 5)).toBe("A, B, C and 2 others")
    expect(leftToast({ name: "X", names: ["Dalton"], count: 1 }, false).body).toBe("Dalton is still in the room.")
  })
})

describe("reconnecting bar", () => {
  it("goes amber with a counting clock, then Connection lost after 30s, and back on recovery", () => {
    vi.useFakeTimers()
    try {
      const { presence, toasts, bar, host } = setup()
      presence.mount(CALL, host)
      presence.onRoomState("reconnecting")
      expect(bar.attrs["data-state"]).toBe("reconnecting")
      expect(bar.attrs["data-lost"]).toBeUndefined()
      expect(toasts.map((t) => [t.spec.title, t.spec.body])).toEqual([
        ["Connection dropped. Reconnecting…", "You haven't left. Others see you as reconnecting."],
      ])
      vi.advanceTimersByTime(7000)
      expect(bar.counter.textContent).toBe("0:07")
      // A second "reconnecting" (the watchdog's copy of the event) restarts nothing.
      presence.onRoomState("reconnecting")
      expect(toasts.length).toBe(1)

      vi.advanceTimersByTime(RECONNECT_LOST_MS - 7000)
      expect(bar.attrs["data-lost"]).toBe("true")
      expect(toasts[0].dismissed).toBe(true)
      expect(titles(toasts)).toEqual(["Connection dropped. Reconnecting…", "Connection lost"])

      presence.onRoomState("reconnected")
      expect(bar.attrs["data-state"]).toBe("connected")
      expect(bar.attrs["data-lost"]).toBeUndefined()
      expect(toasts[1].dismissed).toBe(true)
    } finally {
      vi.useRealTimers()
    }
  })

  it("uses the phone reconnecting copy, and re-applies the state to a freshly mounted bar", () => {
    vi.useFakeTimers()
    try {
      const { presence, toasts, bar, host } = setup({ phone: true })
      presence.mount(CALL, host)
      presence.onRoomState("reconnecting")
      expect([toasts[0].spec.title, toasts[0].spec.body]).toEqual(["Reconnecting…", "You haven't left the call."])
      bar.attrs["data-state"] = "connected" // a server render of a new bar
      presence.mount(CALL, host)
      expect(bar.attrs["data-state"]).toBe("reconnecting")
    } finally {
      vi.useRealTimers()
    }
  })

  it("Rejoin and Leave reach the call client's lost-state paths", () => {
    const owner = { _connLost: true, rejoined: 0, left: 0, _manualRejoin() { this.rejoined += 1 }, _leaveAfterLoss() { this.left += 1 } }
    const { presence, host, calls } = setup({ owner })
    presence.mount(CALL, host)
    presence.onRoomState("lost")
    presence.rejoin()
    expect(owner.rejoined).toBe(1)
    presence.noteBarLeave()
    expect(owner.left).toBe(1)

    // No call client on this page: Rejoin goes back to the call.
    const other = setup()
    other.presence.mount(CALL, other.host)
    other.presence.rejoin()
    expect(other.calls.navigate).toEqual(["/meetings/weekly-sync"])
    expect(calls.navigate).toEqual([])
  })
})

describe("the phone Leave sheet", () => {
  it("shows the exact copy; End for everyone only for the host", async () => {
    const { presence, dialogs, host } = setup({ phone: true })
    presence.mount(CALL, host)
    await presence.openLeaveSheet()
    expect(dialogs[0]).toMatchObject({ title: "Leave Weekly sync?", body: "2 others are still in the room." })
    expect(dialogs[0].buttons.map((b) => b.label)).toEqual(["Leave call", "Stay in call"])
    presence.update({ ...CALL, canEnd: true })
    await presence.openLeaveSheet()
    expect(dialogs[1].buttons.map((b) => b.label)).toEqual(["Leave call", "End for everyone", "Stay in call"])
  })

  it("Leave call leaves through the server and shows the left toast", async () => {
    const { presence, toasts, host, calls } = setup({ phone: true, choice: "leave" })
    presence.mount(CALL, host)
    await presence.openLeaveSheet()
    expect(calls.pushLeave).toBe(1)
    expect(calls.disconnect).toBe(1)
    expect(titles(toasts)).toEqual(["You left Weekly sync"])
  })
})

describe("storage that throws", () => {
  it("breaks neither the still-in toast, the stash, nor the guard", async () => {
    const { presence, toasts, calls, host } = setup({ storage: throwingStorage(), choice: "leave" })
    presence.mount(CALL, host)
    presence.mount(CALL, host)
    presence.mount(CALL, host)
    expect(titles(toasts)).toEqual(["You're still in Weekly sync"])
    await presence.onClick(click({ href: "/admin" }))
    expect(calls.assign).toEqual([`${ORIGIN}/admin`])
    // The stash fell back to this controller's memory.
    presence.showStashed()
    expect(titles(toasts)).toEqual(["You're still in Weekly sync", "You left Weekly sync"])
  })
})

describe("readState", () => {
  it("reads #meeting-presence's dataset", () => {
    expect(
      readState({
        callActive: "true",
        meetingId: "m-1",
        meetingName: "Weekly sync",
        returnPath: "/meetings/weekly-sync",
        callRoom: "false",
        othersCount: "2",
        canEnd: "true",
        authRoutes: JSON.stringify(PATTERNS),
        otherNames: JSON.stringify(["Sam Example"]),
        startedAt: "2026-11-17T10:00:00Z",
        path: "/calendar",
      }),
    ).toEqual({ ...CALL, canEnd: true, names: ["Sam Example"], startedAt: "2026-11-17T10:00:00Z", path: "/calendar" })
    expect(readState({ authRoutes: "not json" }).patterns).toEqual([])
    expect(readState({ otherNames: "not json" }).names).toEqual([])
  })
})

// ── Task 01a1e82a remediation (the failed behavioural gate) ─────────────

describe("remediation finding 2: signal reconnects and offline are reconnecting", () => {
  it("signalReconnecting turns the bar amber with the counter and toast, and connected turns it green", () => {
    vi.useFakeTimers()
    try {
      const { presence, toasts, bar, host } = setup()
      presence.mount(CALL, host)
      presence.onRoomState("signalReconnecting")
      expect(bar.attrs["data-state"]).toBe("reconnecting")
      expect(titles(toasts)).toEqual(["Connection dropped. Reconnecting…"])
      vi.advanceTimersByTime(3000)
      expect(bar.counter.textContent).toBe("0:03")
      // ConnectionStateChanged -> connected is the recovery signal for a
      // signal-only reconnect (there is no SignalReconnected event).
      presence.onRoomState("connected")
      expect(bar.attrs["data-state"]).toBe("connected")
      expect(toasts[0].dismissed).toBe(true)
      expect(titles(toasts)).not.toContain("You left Weekly sync")
    } finally {
      vi.useRealTimers()
    }
  })

  it("the 30s Connection lost clock starts at the FIRST reconnecting of any kind", () => {
    vi.useFakeTimers()
    try {
      const { presence, toasts, bar, host } = setup()
      presence.mount(CALL, host)
      presence.onRoomState("signalReconnecting")
      vi.advanceTimersByTime(20000)
      // LiveKit escalates to a full reconnect: the clock does not restart.
      presence.onRoomState("reconnecting")
      expect(toasts.length).toBe(1)
      vi.advanceTimersByTime(RECONNECT_LOST_MS - 20000)
      expect(bar.attrs["data-lost"]).toBe("true")
      expect(titles(toasts)).toEqual(["Connection dropped. Reconnecting…", "Connection lost"])
      presence.onRoomState("reconnected")
      expect(bar.attrs["data-state"]).toBe("connected")
    } finally {
      vi.useRealTimers()
    }
  })

  it("the browser going offline is reconnecting at once; back online with a connected room is green", () => {
    vi.useFakeTimers()
    try {
      const s = setup({ roomState: "connected" })
      s.presence.mount(CALL, s.host)
      s.presence.onNetwork(false)
      expect(s.bar.attrs["data-state"]).toBe("reconnecting")
      vi.advanceTimersByTime(5000)
      s.presence.onNetwork(true)
      expect(s.bar.attrs["data-state"]).toBe("connected")

      // Back online while LiveKit is still recovering: stay amber until it says so.
      const t = setup({ roomState: "signalReconnecting" })
      t.presence.mount(CALL, t.host)
      t.presence.onNetwork(false)
      t.presence.onNetwork(true)
      expect(t.bar.attrs["data-state"]).toBe("reconnecting")
      t.presence.onRoomState("connected")
      expect(t.bar.attrs["data-state"]).toBe("connected")

      // Offline outside a call does nothing.
      const u = setup()
      u.presence.onNetwork(false)
      expect(u.bar.attrs["data-state"]).toBe("connected")
    } finally {
      vi.useRealTimers()
    }
  })

  it("a disconnect the call client is retrying stays reconnecting; a plain disconnect resets", () => {
    vi.useFakeTimers()
    try {
      const owner = { _connLost: true }
      const s = setup({ owner })
      s.presence.mount(CALL, s.host)
      s.presence.onRoomState("disconnected")
      expect(s.bar.attrs["data-state"]).toBe("reconnecting")

      const t = setup()
      t.presence.mount(CALL, t.host)
      t.presence.onRoomState("signalReconnecting")
      t.presence.onRoomState("disconnected")
      expect(t.bar.attrs["data-state"]).toBe("connected")
    } finally {
      vi.useRealTimers()
    }
  })
})

describe("remediation finding 7: Rejoin joins", () => {
  const LEFT = { ...CALL, inCall: false, meetingId: null, path: "/calendar" }

  it("the left toast's Rejoin goes to the call room and runs its explicit Join once", () => {
    const { presence, toasts, host, calls } = setup({ path: "/calendar" })
    presence.mount(LEFT, host)
    presence.onServerEvent({ kind: "left", name: "Weekly sync", names: ["Sam"], count: 1, return_path: "/meetings/weekly-sync" })
    const left = toasts.find((t) => t.spec.kind === "left")
    left.onAction("rejoin", left.spec)
    expect(calls.navigate).toEqual(["/meetings/weekly-sync"])
    expect(host.pushes).toEqual([])

    // The call room's LiveView mounts (a new hook, same controller).
    presence.mount({ ...LEFT, path: "/meetings/weekly-sync" }, host)
    expect(host.pushes).toEqual(["join_meeting"])

    // One-shot: a later visit to the call room does not join.
    presence.mount({ ...LEFT, path: "/meetings/weekly-sync" }, host)
    expect(host.pushes).toEqual(["join_meeting"])
  })

  it("Rejoin while already on the call room joins in place", () => {
    const { presence, host, calls } = setup()
    presence.mount({ ...LEFT, path: "/meetings/weekly-sync" }, host)
    presence.rejoinAt("/meetings/weekly-sync")
    expect(host.pushes).toEqual(["join_meeting"])
    expect(calls.navigate).toEqual([])
  })

  it("a stale intent, or one for another page, never joins", () => {
    vi.useFakeTimers()
    try {
      const { presence, host } = setup()
      presence.mount(LEFT, host)
      presence.rejoinAt("/meetings/weekly-sync")
      presence.mount({ ...LEFT, path: "/inbox" }, host)
      expect(host.pushes).toEqual([])
      vi.advanceTimersByTime(REJOIN_INTENT_MS + 1)
      vi.setSystemTime(Date.now() + REJOIN_INTENT_MS + 1)
      presence.mount({ ...LEFT, path: "/meetings/weekly-sync" }, host)
      expect(host.pushes).toEqual([])
    } finally {
      vi.useRealTimers()
    }
  })

  it("the lost bar's Rejoin with no call client goes back to the call; a still-held call restores without a second join", () => {
    const { presence, host, calls } = setup()
    presence.mount({ ...CALL, path: "/calendar" }, host)
    presence.onRoomState("lost")
    presence.rejoin()
    expect(calls.navigate).toEqual(["/meetings/weekly-sync"])
    presence.mount({ ...CALL, inCallRoom: true, path: "/meetings/weekly-sync" }, host)
    expect(host.pushes).toEqual([])
  })
})

describe("remediation finding 4: the phone overlay minimizes", () => {
  it("minimizing the in-chat call is a kept call: \"Still in\" fires once", () => {
    const { presence, toasts, host } = setup({ phone: true })
    presence.mount(CALL, host)
    presence.noteMinimized()
    presence.noteMinimized()
    expect(toasts.map((t) => [t.spec.title, t.spec.body])).toEqual([["Still in Weekly sync", "Tap the green bar to go back."]])
    // A navigation after it does not repeat it.
    presence.mount(CALL, host)
    expect(toasts.length).toBe(1)
  })
})

describe("remediation finding 8: the desktop End for everyone", () => {
  it("disarms the unload prompt like the bar's Leave", () => {
    const { presence, host } = setup()
    presence.mount({ ...CALL, canEnd: true }, host)
    expect(presence.armed()).toBe(true)
    presence.noteBarEnd()
    expect(presence.armed()).toBe(false)
  })
})

// ── Finding 5: the guard dialog renders above every sheet ───────────────

function fakeEl(tag) {
  const listeners = {}
  return {
    tag,
    className: "",
    textContent: "",
    id: "",
    type: "",
    dataset: {},
    attrs: {},
    children: [],
    setAttribute(k, v) {
      this.attrs[k] = v
    },
    appendChild(c) {
      this.children.push(c)
      c.parent = this
      return c
    },
    addEventListener(t, fn) {
      ;(listeners[t] ||= []).push(fn)
    },
    click() {
      for (const fn of listeners.click || []) fn({ target: this })
    },
    remove() {
      if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this)
    },
    focus() {},
  }
}

function walk(node, out = []) {
  out.push(node)
  for (const c of node.children || []) walk(c, out)
  return out
}

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, "..", "..")

function files(dir, exts, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) files(p, exts, out)
    else if (exts.some((e) => name.endsWith(e))) out.push(p)
  }
  return out
}

describe("remediation finding 5: the guard dialog sits above every sheet", () => {
  it("uses a z-index above every other z-index in the app (sheets are 100)", () => {
    const own = Number(DIALOG_Z_CLASS.match(/^z-\[(\d+)\]$/)[1])
    const others = []
    const sources = [
      ...files(join(ROOT, "lib"), [".ex", ".heex"]),
      ...files(join(ROOT, "assets", "js"), [".js"]),
      join(ROOT, "assets", "css", "app.css"),
    ]
    for (const f of sources) {
      const text = readFileSync(f, "utf8")
      for (const m of text.matchAll(/z-\[(\d+)\]/g)) others.push([Number(m[1]), f])
      for (const m of text.matchAll(/z-index:\s*(\d+)/g)) others.push([Number(m[1]), f])
    }
    const above = others.filter(([z, f]) => z >= own && !f.endsWith("meeting_presence.js"))
    expect(others.length).toBeGreaterThan(10) // the scan saw the app
    expect(others.some(([z]) => z === 100)).toBe(true) // ...including the sheets
    expect(above).toEqual([])
  })

  it("the dialog overlay carries it, and Cancel resolves the choice", async () => {
    const body = fakeEl("body")
    const doc = {
      body,
      createElement: (t) => fakeEl(t),
      getElementById: (id) => walk(body).find((n) => n.id === id) || null,
      addEventListener() {},
      removeEventListener() {},
    }
    const ui = createDomUi(doc, { setTimeout, clearTimeout }, { isPhone: () => false })
    const choice = ui.choose(guardDialog({ destination: "Admin", name: "Weekly sync" }))
    const overlay = doc.getElementById("meeting-presence-dialog")
    expect(overlay.className.split(" ")).toContain(DIALOG_Z_CLASS)
    walk(overlay).find((n) => n.dataset.choice === "cancel").click()
    await expect(choice).resolves.toBe("cancel")
    expect(doc.getElementById("meeting-presence-dialog")).toBe(null)
  })
})
