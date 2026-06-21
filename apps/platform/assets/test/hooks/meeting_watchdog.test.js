import { describe, it, expect, beforeEach, afterEach } from "vitest"
import MeetingWatchdog from "../../js/hooks/meeting_watchdog.js"

/**
 * Tests for the `MeetingWatchdog` hook (task 019ee06b stage 1).
 *
 * The watchdog is the shell-level slim sibling of `MeetingClient`. It owns
 * ONLY network-survival concerns: idempotent binding of the LiveKit
 * reconnect lifecycle (Reconnecting / Reconnected / ConnectionStateChanged /
 * Disconnected) and the `dataset.roomState` / `livekit:state` breadcrumb.
 *
 * The shape of these fakes mirrors `meeting_client.test.js` so reviewers can
 * pattern-match between the two suites. The hook runs in vitest's default
 * `node` env (no jsdom), so we build a minimal fake document + window.
 */

// ── Fakes ────────────────────────────────────────────────────────────────

// Minimal LiveKit Room stub. `.on(event, cb)` registers, `.off(event, cb)`
// removes a specific ref, `.emit(event, ...)` fires registered handlers.
// Records `disconnect()` calls.
function fakeRoom({ state = "connected", name = "space-room" } = {}) {
  const handlers = new Map()
  return {
    name,
    state,
    disconnectCalls: 0,
    on(event, cb) {
      const list = handlers.get(event) || []
      list.push(cb)
      handlers.set(event, list)
      return this
    },
    off(event, cb) {
      const list = handlers.get(event) || []
      const i = list.indexOf(cb)
      if (i >= 0) list.splice(i, 1)
      return this
    },
    emit(event, ...args) {
      ;(handlers.get(event) || []).forEach((cb) => cb(...args))
    },
    listenerCount(event) {
      return (handlers.get(event) || []).length
    },
    disconnect() {
      this.disconnectCalls += 1
      return Promise.resolve()
    },
  }
}

function fakeHookEl(dataset = {}) {
  return { dataset: { ...dataset } }
}

function buildDocument() {
  const events = []
  const listeners = new Map()
  return {
    _events: events,
    _listeners: listeners,
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
    dispatchEvent(evt) {
      events.push(evt)
      const list = listeners.get(evt.type) || []
      list.forEach((cb) => cb(evt))
      return true
    },
  }
}

function buildWindow({ existingRoom = null } = {}) {
  const listeners = new Map()
  return {
    __livekitWatchdogActive: false,
    __livekit_room: existingRoom,
    __livekitRoom: existingRoom,
    _listeners: listeners,
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
    dispatchEvent() {
      return true
    },
  }
}

function buildHook(el) {
  const hook = Object.create(MeetingWatchdog)
  hook.el = el || fakeHookEl()
  return hook
}

// ─────────────────────────────────────────────────────────────────────────

describe("MeetingWatchdog — singleton + lifecycle", () => {
  let priorWindow
  let priorDocument
  let priorCustomEvent

  beforeEach(() => {
    globalThis.console = globalThis.console || {
      warn() {},
      error() {},
      info() {},
    }
    if (!globalThis.console.info) globalThis.console.info = () => {}

    priorWindow = globalThis.window
    priorDocument = globalThis.document
    priorCustomEvent = globalThis.CustomEvent

    globalThis.document = buildDocument()
    globalThis.window = buildWindow()
    globalThis.CustomEvent =
      globalThis.CustomEvent ||
      class CustomEvent {
        constructor(type, init = {}) {
          this.type = type
          this.detail = init.detail
        }
      }
  })

  afterEach(() => {
    globalThis.window = priorWindow
    globalThis.document = priorDocument
    globalThis.CustomEvent = priorCustomEvent
  })

  it("mounts without error when no Room exists (just-landed-on-/tasks path)", () => {
    const hook = buildHook()
    expect(() => hook.mounted()).not.toThrow()
    expect(globalThis.window.__livekitWatchdogActive).toBe(true)
    // No room → no breadcrumb yet. dataset.roomState left at whatever the
    // server rendered ("unknown" in stage 2's HEEX, undefined here).
    expect(hook.el.dataset.roomState).toBeUndefined()
  })

  it("adopts an existing connected Room on mount (idempotent attribute stamp)", () => {
    const room = fakeRoom({ state: "connected" })
    globalThis.window = buildWindow({ existingRoom: room })

    const hook = buildHook()
    hook.mounted()

    // Breadcrumb stamped from the surviving room state.
    expect(hook.el.dataset.roomState).toBe("connected")
    // Singleton flag set.
    expect(globalThis.window.__livekitWatchdogActive).toBe(true)
    // Per-instance bookkeeping captured the adopted Room so destroyed()
    // can release the listener refs it installed.
    expect(hook._boundRoom).toBe(room)
    expect(hook._roomListeners.length).toBeGreaterThan(0)
    // The room never got disconnected.
    expect(room.disconnectCalls).toBe(0)
  })

  it("attaches the LiveKit reconnect listener set on adopt", () => {
    const room = fakeRoom({ state: "connected" })
    globalThis.window = buildWindow({ existingRoom: room })
    const hook = buildHook()
    hook.mounted()

    // Exactly one listener per relevant RoomEvent.
    expect(room.listenerCount("reconnecting")).toBe(1)
    expect(room.listenerCount("reconnected")).toBe(1)
    expect(room.listenerCount("connectionStateChanged")).toBe(1)
    expect(room.listenerCount("disconnected")).toBe(1)

    // Firing them updates the breadcrumb.
    room.emit("reconnecting")
    expect(hook.el.dataset.roomState).toBe("reconnecting")
    room.emit("reconnected")
    expect(hook.el.dataset.roomState).toBe("reconnected")
    room.emit("disconnected")
    expect(hook.el.dataset.roomState).toBe("disconnected")
  })

  it("singleton guard: a second mount no-ops (no second listener bind, no flag overwrite)", () => {
    const room = fakeRoom({ state: "connected" })
    globalThis.window = buildWindow({ existingRoom: room })

    const hook1 = buildHook()
    hook1.mounted()
    expect(globalThis.window.__livekitWatchdogActive).toBe(true)
    expect(room.listenerCount("reconnected")).toBe(1)

    // A second watchdog mounts (LV repatched the shell element). It must
    // detect the active flag and back off without re-binding.
    const hook2 = buildHook()
    hook2.mounted()

    expect(room.listenerCount("reconnected")).toBe(1)
    // The second instance is marked inactive — it will skip its destroyed()
    // cleanup too.
    expect(hook2._inactive).toBe(true)
  })

  it("per-instance idempotency: adopting the SAME Room twice does not re-bind", () => {
    const room = fakeRoom({ state: "connected" })
    globalThis.window = buildWindow({ existingRoom: room })

    const hook = buildHook()
    hook.mounted()

    // First adopt installed one listener per relevant event.
    expect(room.listenerCount("reconnected")).toBe(1)
    expect(room.listenerCount("reconnecting")).toBe(1)
    const refsAfterFirst = hook._roomListeners.length
    expect(refsAfterFirst).toBeGreaterThan(0)

    // A second _adoptRoom against the same Room (e.g. a stray
    // livekit:room-connected event for the surviving room) must NOT add
    // listeners — counts remain stable and our tracked refs do not grow.
    hook._adoptRoom(room)

    expect(room.listenerCount("reconnected")).toBe(1)
    expect(room.listenerCount("reconnecting")).toBe(1)
    expect(hook._roomListeners.length).toBe(refsAfterFirst)
    // Breadcrumb still re-stamped on the no-op bind path.
    expect(hook.el.dataset.roomState).toBe("connected")
  })

  it("coexists with another hook (MeetingClient) that bound listeners first", () => {
    // Simulate the /chat case: MeetingClient bound its handler before the
    // shell-level watchdog mounts. The watchdog must STILL install its own
    // listener (the v1 __watchdogBound flag dropped — see watchdog rationale).
    const room = fakeRoom({ state: "connected" })
    // External pre-bound listener (e.g. MeetingClient on /chat).
    const externalReconnected = () => {}
    room.on("reconnected", externalReconnected)
    expect(room.listenerCount("reconnected")).toBe(1)

    globalThis.window = buildWindow({ existingRoom: room })
    const hook = buildHook()
    hook.mounted()

    // Watchdog adds its own listener — total grows to 2 (one external,
    // one watchdog-owned). The two hooks stamp DIFFERENT dataset elements
    // and tag `source` on their CustomEvents so downstream consumers can
    // dedupe by origin.
    expect(room.listenerCount("reconnected")).toBe(2)
    expect(hook.el.dataset.roomState).toBe("connected")
  })

  it("destroyed() clears the singleton flag and removes window/document listeners", () => {
    const hook = buildHook()
    hook.mounted()
    expect(globalThis.window.__livekitWatchdogActive).toBe(true)
    expect(globalThis.window._listeners.get("pagehide").length).toBe(1)
    expect(globalThis.window._listeners.get("beforeunload").length).toBe(1)
    expect(
      globalThis.document._listeners.get("livekit:room-connected").length,
    ).toBe(1)

    hook.destroyed()

    expect(globalThis.window.__livekitWatchdogActive).toBe(false)
    expect(globalThis.window._listeners.get("pagehide").length).toBe(0)
    expect(globalThis.window._listeners.get("beforeunload").length).toBe(0)
    expect(
      globalThis.document._listeners.get("livekit:room-connected").length,
    ).toBe(0)
    expect(
      globalThis.document._listeners.get("livekit:room-disconnected").length,
    ).toBe(0)
  })

  it("destroyed() releases the Room listeners it installed (case-3 cleanup)", () => {
    // The Room survives a watchdog destroy/re-mount cycle on window. Without
    // explicit off() walks every shell repatch would leak a fresh listener
    // set onto the same Room — exactly what the case-3 e2e reviewer caught
    // for MeetingClient. The watchdog must clean up symmetrically.
    const room = fakeRoom({ state: "connected" })
    globalThis.window = buildWindow({ existingRoom: room })
    const hook = buildHook()
    hook.mounted()

    expect(room.listenerCount("reconnected")).toBe(1)
    expect(room.listenerCount("reconnecting")).toBe(1)
    expect(room.listenerCount("connectionStateChanged")).toBe(1)
    expect(room.listenerCount("disconnected")).toBe(1)

    hook.destroyed()

    // All watchdog-owned refs detached from the surviving Room.
    expect(room.listenerCount("reconnected")).toBe(0)
    expect(room.listenerCount("reconnecting")).toBe(0)
    expect(room.listenerCount("connectionStateChanged")).toBe(0)
    expect(room.listenerCount("disconnected")).toBe(0)
    expect(hook._boundRoom).toBeNull()
    expect(hook._roomListeners).toEqual([])
  })

  it("destroyed() + re-mount installs ONE listener set on the surviving Room", () => {
    // Simulates: watchdog mounts on /chat (with meeting active) → user
    // navigates to /tasks (shell repatches, watchdog destroys + re-mounts
    // against the SAME surviving Room). Listener count must STAY AT 1, not
    // grow per navigation.
    const room = fakeRoom({ state: "connected" })
    globalThis.window = buildWindow({ existingRoom: room })
    const hook1 = buildHook()
    hook1.mounted()
    expect(room.listenerCount("reconnected")).toBe(1)
    hook1.destroyed()
    expect(room.listenerCount("reconnected")).toBe(0)

    const hook2 = buildHook()
    hook2.mounted()
    expect(room.listenerCount("reconnected")).toBe(1)
    expect(room.listenerCount("reconnecting")).toBe(1)
    expect(room.listenerCount("connectionStateChanged")).toBe(1)
    expect(room.listenerCount("disconnected")).toBe(1)
  })

  it("destroyed() on an inactive (singleton-skipped) instance is a no-op", () => {
    // Pre-set the flag so mount returns early.
    globalThis.window.__livekitWatchdogActive = true
    const hook = buildHook()
    hook.mounted()
    expect(hook._inactive).toBe(true)

    // destroyed() must NOT clear the flag (another instance owns it).
    hook.destroyed()
    expect(globalThis.window.__livekitWatchdogActive).toBe(true)
  })

  it("adopts a new Room that arrives via livekit:room-connected DOM event", () => {
    const hook = buildHook()
    hook.mounted()
    expect(hook.el.dataset.roomState).toBeUndefined()

    // Simulate MeetingClient._join firing the cross-component event after a
    // late join from /chat.
    const room = fakeRoom({ state: "connected" })
    globalThis.window.__livekit_room = room
    globalThis.window.__livekitRoom = room

    const evt = new globalThis.CustomEvent("livekit:room-connected", {
      detail: { room },
    })
    globalThis.document.dispatchEvent(evt)

    expect(hook.el.dataset.roomState).toBe("connected")
    expect(hook._boundRoom).toBe(room)
    expect(room.listenerCount("reconnected")).toBe(1)
  })

  it("livekit:room-disconnected refreshes the breadcrumb and releases listener refs", () => {
    const room = fakeRoom({ state: "connected" })
    globalThis.window = buildWindow({ existingRoom: room })
    const hook = buildHook()
    hook.mounted()
    expect(hook.el.dataset.roomState).toBe("connected")
    expect(hook._boundRoom).toBe(room)

    // MeetingClient._cleanupRoom dispatched this after a server-driven leave.
    globalThis.window.__livekit_room = null
    globalThis.window.__livekitRoom = null
    const evt = new globalThis.CustomEvent("livekit:room-disconnected")
    globalThis.document.dispatchEvent(evt)

    expect(hook.el.dataset.roomState).toBe("disconnected")
    // Refs released so a fresh room (new _join) starts from a clean state.
    expect(hook._boundRoom).toBeNull()
    expect(room.listenerCount("reconnected")).toBe(0)
  })

  it("pagehide disconnects the surviving room (true page exit)", () => {
    const room = fakeRoom({ state: "connected" })
    globalThis.window = buildWindow({ existingRoom: room })
    const hook = buildHook()
    hook.mounted()

    const pageHide = globalThis.window._listeners.get("pagehide")[0]
    pageHide()

    expect(room.disconnectCalls).toBe(1)
  })

  it("Reconnected handler fires _emitState('reconnected') and dispatches livekit:state", () => {
    const room = fakeRoom({ state: "connected" })
    globalThis.window = buildWindow({ existingRoom: room })
    const hook = buildHook()
    hook.mounted()
    globalThis.document._events.length = 0

    room.emit("reconnected")

    expect(hook.el.dataset.roomState).toBe("reconnected")
    const stateEvt = globalThis.document._events.find(
      (e) => e.type === "livekit:state" && e.detail.state === "reconnected",
    )
    expect(stateEvt).toBeTruthy()
    expect(stateEvt.detail.source).toBe("watchdog")
    expect(stateEvt.detail.roomName).toBe("space-room")
  })
})
