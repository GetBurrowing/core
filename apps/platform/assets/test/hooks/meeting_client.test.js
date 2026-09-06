import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import MeetingClient from "../../js/hooks/meeting_client.js"

// Task 01a06925 stage 2: `_join` constructs `new Room(...)` from
// livekit-client when it has no room to adopt. Swap ONLY the Room class for
// a recording fake (RoomEvent / Track stay real) so the reconnect tests can
// assert that a fresh connection was made, and with which token.
const livekitFake = vi.hoisted(() => ({ created: [], connectedName: null }))

vi.mock("livekit-client", async (importOriginal) => {
  const actual = await importOriginal()
  class Room {
    constructor(opts) {
      this.opts = opts
      this.name = ""
      this.state = "disconnected"
      this.connectArgs = null
      this.connectCalls = 0
      this.disconnectCalls = 0
      this._handlers = new Map()
      this.remoteParticipants = new Map()
      this.localParticipant = {
        identity: "user:fresh",
        name: "Fresh",
        isLocal: true,
        isCameraEnabled: false,
        isMicrophoneEnabled: false,
        trackPublications: new Map(),
        setCameraCalls: [],
        setMicCalls: [],
        setCameraEnabled(v) {
          this.setCameraCalls.push(v)
          this.isCameraEnabled = v
          return Promise.resolve()
        },
        setMicrophoneEnabled(v) {
          this.setMicCalls.push(v)
          this.isMicrophoneEnabled = v
          return Promise.resolve()
        },
      }
      livekitFake.created.push(this)
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
    listenerCount(event) {
      return (this._handlers.get(event) || []).length
    }
    connect(url, token) {
      this.connectCalls += 1
      this.connectArgs = [url, token]
      this.state = "connected"
      // LiveKit reports the granted room's name after connect; the test
      // declares which room the token it hands over was minted for.
      this.name = livekitFake.connectedName
      return Promise.resolve()
    }
    disconnect() {
      this.disconnectCalls += 1
      this.state = "disconnected"
      return Promise.resolve()
    }
  }
  return { ...actual, Room }
})

/**
 * Tests for the `MeetingClient` hook's v2 local self-view reparenting
 * (task 019e42f6 v2 — "Switching Active Tab In Meeting Drops Video").
 *
 * v1 kept the local camera alive across mode switches but left it in a
 * fixed free-floating PiP, which broke the gallery layout (Rowan rejected
 * the placement). v2 keeps ONE persistent local <video> with the camera
 * track attached EXACTLY ONCE, and on each stage-mode change MOVES it
 * (appendChild) into the dock for the active mode — never detaching the
 * track during a reparent.
 *
 * The hook runs in the default vitest `node` env (no jsdom), so we build a
 * minimal fake `document` exposing the parking slot + the two per-mode
 * docks, plus `createElement` / `querySelector` / `requestAnimationFrame`.
 * The fake track records `detach` calls — the load-bearing assertion is
 * that detach is NEVER called while merely reparenting.
 */

// ── Fakes ────────────────────────────────────────────────────────────────

function fakeNode(attrs = {}) {
  const node = {
    dataset: { ...attrs },
    style: {},
    className: "",
    children: [],
    parentElement: null,
    appendChild(child) {
      if (child.parentElement) {
        const prev = child.parentElement
        const i = prev.children.indexOf(child)
        if (i >= 0) prev.children.splice(i, 1)
      }
      child.parentElement = this
      this.children.push(child)
      return child
    },
    remove() {
      if (this.parentElement) {
        const i = this.parentElement.children.indexOf(this)
        if (i >= 0) this.parentElement.children.splice(i, 1)
        this.parentElement = null
      }
    },
  }
  return node
}

// A LiveKit-style video track recording attach/detach element args.
function fakeTrack(source = "camera") {
  return {
    kind: "video",
    source,
    attachCalls: [],
    detachCalls: [],
    attach(el) {
      this.attachCalls.push(el === undefined ? null : el)
    },
    detach(el) {
      this.detachCalls.push(el === undefined ? null : el)
      return el ? [el] : []
    },
  }
}

// Build a fake document with a parking slot and (optionally) docks.
function buildDocument({ galleryDock = true, stripDock = true, stageMode = "gallery" } = {}) {
  const parking = fakeNode({ role: "local-self-view" })
  const gallery = galleryDock
    ? fakeNode({ localVideoDock: "", dockMode: "gallery" })
    : null
  const strip = stripDock
    ? fakeNode({ localVideoDock: "", dockMode: "strip" })
    : null
  const centerStage = fakeNode({ pane: "center-stage", stageMode })

  return {
    _parking: parking,
    _gallery: gallery,
    _strip: strip,
    _centerStage: centerStage,
    createElement(_tag) {
      return fakeNode()
    },
    querySelector(sel) {
      if (sel === '[data-role="local-self-view"]') return parking
      if (sel === '[data-pane="center-stage"]') return centerStage
      if (sel === '[data-local-video-dock][data-dock-mode="gallery"]') return gallery
      if (sel === '[data-local-video-dock][data-dock-mode="strip"]') return strip
      return null
    },
  }
}

function buildHook() {
  const hook = Object.create(MeetingClient)
  hook._localVideoEl = null
  hook._localVideoTrack = null
  // Phoenix always gives a MOUNTED hook a `pushEvent`; the join paths now
  // report remote media state through it (task 01a0740c stage 2), so a
  // fixture without one asserts against a hook shape that cannot exist.
  // Records rather than throwing — the pushes themselves are asserted in
  // `meeting_client_media_states.test.js`.
  hook.pushedEvents = []
  hook.pushEvent = (event, payload) => hook.pushedEvents.push([event, payload])
  return hook
}

describe("MeetingClient — local self-view reparenting (v2)", () => {
  let rafQueue

  beforeEach(() => {
    globalThis.console = globalThis.console || { warn() {}, error() {} }
    rafQueue = []
    globalThis.requestAnimationFrame = (cb) => rafQueue.push(cb)
  })

  afterEach(() => {
    delete globalThis.document
    delete globalThis.requestAnimationFrame
  })

  function flushRaf() {
    const q = rafQueue
    rafQueue = []
    q.forEach((cb) => cb())
  }

  it("attaches the camera track ONCE into a single persistent element and docks it (gallery)", () => {
    globalThis.document = buildDocument({ stageMode: "gallery" })
    const hook = buildHook()
    const track = fakeTrack()

    hook._attachLocalVideo(track)

    // Exactly one element minted + the track attached to it once.
    expect(hook._localVideoEl).not.toBeNull()
    expect(track.attachCalls).toEqual([hook._localVideoEl])
    expect(hook._localVideoEl.style.transform).toBe("scaleX(-1)")
    // Docked into the gallery dock for gallery mode.
    expect(hook._localVideoEl.parentElement).toBe(globalThis.document._gallery)
  })

  it("_dockLocalVideo('strip') moves the element to the strip dock without detaching", () => {
    globalThis.document = buildDocument({ stageMode: "gallery" })
    const hook = buildHook()
    const track = fakeTrack()
    hook._attachLocalVideo(track)
    expect(hook._localVideoEl.parentElement).toBe(globalThis.document._gallery)

    hook._dockLocalVideo("canvas") // non-gallery → strip dock

    expect(hook._localVideoEl.parentElement).toBe(globalThis.document._strip)
    // The element left the gallery dock.
    expect(globalThis.document._gallery.children).not.toContain(hook._localVideoEl)
    // The track was NEVER detached during the reparent.
    expect(track.detachCalls).toEqual([])
  })

  it("gallery → strip → gallery leaves exactly one element and NEVER detaches the track", () => {
    globalThis.document = buildDocument({ stageMode: "gallery" })
    const hook = buildHook()
    const track = fakeTrack()
    hook._attachLocalVideo(track)
    const el = hook._localVideoEl

    hook._dockLocalVideo("screen") // strip
    hook._dockLocalVideo("whiteboard") // strip
    hook._dockLocalVideo("gallery") // back to gallery

    // Same single element throughout.
    expect(hook._localVideoEl).toBe(el)
    expect(el.parentElement).toBe(globalThis.document._gallery)
    // Track attached once, detached zero times across all reparents.
    expect(track.attachCalls).toEqual([el])
    expect(track.detachCalls).toEqual([])
    // No duplicate left in the strip dock.
    expect(globalThis.document._strip.children).not.toContain(el)
  })

  it("retries on the next frame when the target dock isn't in the DOM yet", () => {
    // Start with NO gallery dock (LV patch hasn't landed the cell yet).
    globalThis.document = buildDocument({ galleryDock: false, stageMode: "gallery" })
    const hook = buildHook()
    const track = fakeTrack()
    hook._attachLocalVideo(track)

    // No gallery dock → the element parks rather than orphan-floats.
    expect(hook._localVideoEl.parentElement).toBe(globalThis.document._parking)

    // The dock appears, then the queued retry runs.
    globalThis.document._gallery = fakeNode({ localVideoDock: "", dockMode: "gallery" })
    const realQuery = globalThis.document.querySelector.bind(globalThis.document)
    globalThis.document.querySelector = (sel) =>
      sel === '[data-local-video-dock][data-dock-mode="gallery"]'
        ? globalThis.document._gallery
        : realQuery(sel)

    flushRaf()
    expect(hook._localVideoEl.parentElement).toBe(globalThis.document._gallery)
  })

  it("toggle off (suspend) then on (re-attach) reuses the SAME element and re-docks", () => {
    globalThis.document = buildDocument({ stageMode: "canvas" })
    const hook = buildHook()
    const track1 = fakeTrack()
    hook._attachLocalVideo(track1)
    const el = hook._localVideoEl
    expect(el.parentElement).toBe(globalThis.document._strip)

    // Camera OFF: detach the track from our element, park it, keep element.
    hook._suspendLocalVideo()
    expect(track1.detachCalls).toEqual([el])
    expect(hook._localVideoTrack).toBeNull()
    expect(hook._localVideoEl).toBe(el)
    expect(el.parentElement).toBe(globalThis.document._parking)

    // Camera ON with a brand-new track: same element, re-attached, re-docked.
    const track2 = fakeTrack()
    hook._attachLocalVideo(track2)
    expect(hook._localVideoEl).toBe(el)
    expect(track2.attachCalls).toEqual([el])
    expect(el.parentElement).toBe(globalThis.document._strip)
  })

  it("teardown detaches the track and removes the element", () => {
    globalThis.document = buildDocument({ stageMode: "gallery" })
    const hook = buildHook()
    const track = fakeTrack()
    hook._attachLocalVideo(track)
    const el = hook._localVideoEl

    hook._teardownLocalVideo()

    expect(track.detachCalls).toEqual([el])
    expect(hook._localVideoEl).toBeNull()
    expect(hook._localVideoTrack).toBeNull()
    expect(el.parentElement).toBeNull()
  })

  // ── updated() re-dock after an LV patch (flash-close-kills-video) ────────
  // On `/meetings` the gallery dock lives inside the server `:for` over
  // participants with no `phx-update="ignore"`, so any LV re-render (closing
  // the "Meeting started" flash, a presence update, a control toggle) lets
  // morphdom replace the dock node and orphan the JS-injected <video>. The
  // `updated()` lifecycle re-docks the persistent element into the
  // (possibly fresh) dock — moving only the element, never re-attaching the
  // live track.
  it("updated() re-docks the orphaned local <video> after an LV patch (gallery)", () => {
    globalThis.document = buildDocument({ stageMode: "gallery" })
    const hook = buildHook()
    const track = fakeTrack()
    hook._attachLocalVideo(track)
    const el = hook._localVideoEl
    expect(el.parentElement).toBe(globalThis.document._gallery)

    // Simulate an LV patch (morphdom) that replaced the gallery dock node:
    // the JS-injected <video> is orphaned (no parent) and a brand-new dock
    // node is now what querySelector resolves to.
    el.remove()
    expect(el.parentElement).toBeNull()
    const freshGallery = fakeNode({ localVideoDock: "", dockMode: "gallery" })
    globalThis.document._gallery = freshGallery
    const realQuery = globalThis.document.querySelector.bind(globalThis.document)
    globalThis.document.querySelector = (sel) =>
      sel === '[data-local-video-dock][data-dock-mode="gallery"]'
        ? freshGallery
        : realQuery(sel)

    hook.updated()

    // Re-parented into the NEW dock; the live track was never re-attached
    // or detached during the re-dock.
    expect(hook._localVideoEl).toBe(el)
    expect(el.parentElement).toBe(freshGallery)
    expect(track.attachCalls).toEqual([el])
    expect(track.detachCalls).toEqual([])
  })

  it("updated() re-docks into the strip dock when the stage is non-gallery", () => {
    globalThis.document = buildDocument({ stageMode: "canvas" })
    const hook = buildHook()
    const track = fakeTrack()
    hook._attachLocalVideo(track)
    const el = hook._localVideoEl
    expect(el.parentElement).toBe(globalThis.document._strip)

    el.remove()
    const freshStrip = fakeNode({ localVideoDock: "", dockMode: "strip" })
    globalThis.document._strip = freshStrip
    const realQuery = globalThis.document.querySelector.bind(globalThis.document)
    globalThis.document.querySelector = (sel) =>
      sel === '[data-local-video-dock][data-dock-mode="strip"]'
        ? freshStrip
        : realQuery(sel)

    hook.updated()

    expect(el.parentElement).toBe(freshStrip)
    expect(track.detachCalls).toEqual([])
  })

  it("updated() is a no-op when there is no local video", () => {
    globalThis.document = buildDocument({ stageMode: "gallery" })
    const hook = buildHook()
    expect(hook._localVideoEl).toBeNull()

    // Must not throw and must not mint an element.
    expect(() => hook.updated()).not.toThrow()
    expect(hook._localVideoEl).toBeNull()
  })
})

/**
 * Tests for the reconnect-survival lifecycle (task 019e4b3e stages 1-4 —
 * "Meeting Module Participant List not reflective").
 *
 * Per ORG_MEMORY "render_hook bypasses JS hooks — verify the JS layer
 * separately": Rowan's bug lived ENTIRELY in the JS hook lifecycle (a
 * transient LiveView socket drop re-mounting the hook, whose destroyed()
 * disconnected the LiveKit room and killed the media session). An LV
 * render_hook test alone would have missed it, so this asserts the JS
 * behavior directly with a stubbed LiveKit Room.
 *
 * Asserted table:
 *   1. destroyed() does NOT call room.disconnect() when a connected
 *      window.__livekit_room exists (reconnect-survival).
 *   2. mounted() with an existing connected window.__livekit_room adopts it
 *      (no new room.connect), re-binds events, rebuilds tiles.
 *   3. _join adopts instead of disconnect-reconnect when already connected.
 *   4. Reconnected with el.dataset.cameraEnabled='true' and
 *      isCameraEnabled=false calls setCameraEnabled(true) (stage 3).
 *   5. Each transition sets el.dataset.roomState and dispatches
 *      livekit:state (stage 4).
 */

// A LiveKit Track.Source.ScreenShare-aware fake video publication.
function fakePublication(track) {
  return { track, kind: "video" }
}

// Minimal fake LiveKit local participant. Records setCameraEnabled /
// setMicrophoneEnabled calls and flips the *Enabled flags so reconcile is
// observable.
function fakeLocalParticipant({ camera = false, mic = false } = {}) {
  return {
    identity: "user:11111111-1111-1111-1111-111111111111",
    name: "Ada Lovelace",
    isLocal: true,
    isCameraEnabled: camera,
    isMicrophoneEnabled: mic,
    trackPublications: new Map(),
    setCameraCalls: [],
    setMicCalls: [],
    setCameraEnabled(v) {
      this.setCameraCalls.push(v)
      this.isCameraEnabled = v
      return Promise.resolve()
    },
    setMicrophoneEnabled(v) {
      this.setMicCalls.push(v)
      this.isMicrophoneEnabled = v
      return Promise.resolve()
    },
  }
}

// Minimal fake LiveKit Room: .on registers handlers, .off removes a ref,
// .emit fires them, .disconnect/.connect are spies. state defaults to
// "connected".
function fakeRoom({ state = "connected", camera = false, mic = false } = {}) {
  const handlers = new Map()
  return {
    name: "space-room",
    state,
    localParticipant: fakeLocalParticipant({ camera, mic }),
    remoteParticipants: new Map(),
    disconnectCalls: 0,
    connectCalls: 0,
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
    connect() {
      this.connectCalls += 1
      return Promise.resolve()
    },
  }
}

// Fake `#meeting-client` hook element with a mutable dataset.
function fakeHookEl(dataset = {}) {
  return { dataset: { ...dataset } }
}

// Build a document that also records dispatched CustomEvents so the
// livekit:state assertions can inspect them. _grid()/_screenShareSlot()
// return null (no grids in the reconnect-survival fixture) so the tile
// path no-ops, matching the live DEAD-tile-path note in the hook.
function buildSignalDocument() {
  const events = []
  return {
    _events: events,
    createElement() {
      return fakeNode()
    },
    querySelector() {
      return null
    },
    querySelectorAll() {
      return []
    },
    getElementById() {
      return null
    },
    addEventListener() {},
    removeEventListener() {},
    dispatchEvent(evt) {
      events.push(evt)
      return true
    },
  }
}

// Record console.warn calls for the duration of one _join (task 01a06925
// stage 2: the mismatch and missing-room_name paths must SAY what they did).
function captureWarns() {
  const calls = []
  const prev = globalThis.console.warn
  globalThis.console.warn = (...args) => {
    calls.push(args)
  }
  return {
    calls,
    restore() {
      globalThis.console.warn = prev
    },
  }
}

function buildReconnectHook(el) {
  const hook = Object.create(MeetingClient)
  hook._tiles = new Map()
  hook._localVideoEl = null
  hook._localVideoTrack = null
  // Per-instance listener bookkeeping (task 019ee06b stage 2 v2 — case-3
  // cleanup). `mounted()` would init these too; tests that bypass mounted
  // need them on the seed.
  hook._boundRoom = null
  hook._roomListeners = []
  hook.el = el
  // pushEvent is called by the Disconnected handler; stub it.
  hook.pushEvent = () => {}
  return hook
}

describe("MeetingClient — reconnect survival + signal (stages 1-4)", () => {
  let priorWindow

  beforeEach(() => {
    globalThis.console = globalThis.console || { warn() {}, error() {}, info() {} }
    if (!globalThis.console.info) globalThis.console.info = () => {}
    globalThis.document = buildSignalDocument()
    priorWindow = globalThis.window
    globalThis.window = {
      __livekit_room: null,
      __livekitRoom: null,
      addEventListener() {},
      removeEventListener() {},
      dispatchEvent() {
        return true
      },
      matchMedia() {
        return { matches: true, addEventListener() {}, removeEventListener() {} }
      },
    }
    // CustomEvent isn't in node's global scope by default.
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
    delete globalThis.document
    delete globalThis.CustomEvent
    globalThis.window = priorWindow
  })

  // 1. destroyed() must NOT disconnect a surviving connected room.
  it("destroyed() does NOT call room.disconnect() (reconnect-survival)", () => {
    const room = fakeRoom({ state: "connected" })
    globalThis.window.__livekit_room = room
    const hook = buildReconnectHook(fakeHookEl())
    hook._room = room
    hook._viewportQuery = { removeEventListener() {} }
    hook._onPageHide = () => {}

    hook.destroyed()

    expect(room.disconnectCalls).toBe(0)
  })

  // 2. mounted()/_adoptRoom adopts an existing connected room without
  //    reconnecting and re-binds events.
  it("_adoptRoom adopts a connected room without a new connect", () => {
    const room = fakeRoom({ state: "connected" })
    const el = fakeHookEl()
    const hook = buildReconnectHook(el)

    hook._adoptRoom(room)

    expect(hook._room).toBe(room)
    expect(room.connectCalls).toBe(0)
    expect(globalThis.window.__livekit_room).toBe(room)
    // Re-binding wired handlers — emitting a known event must not throw.
    expect(() => room.emit("disconnected")).not.toThrow()
  })

  // 2b. Per-instance listener cleanup (task 019ee06b stage 2 v2 — case-3
  //     reviewer fix). The window-pinned Room outlives a MeetingClient
  //     destroy/re-mount cycle (LV navigation /chat → /meetings → back), so
  //     each remount of this hook MUST detach the listeners the previous
  //     instance installed. Without it, listenerCount('reconnected') grew
  //     1 → 2 → 3 across navigation and duplicate `livekit:state` events
  //     fired per real Reconnected. Replaces the v1 `__watchdogBound`
  //     band-aid which was asymmetric (set but never checked) and produced
  //     both the case-1 and case-3 e2e failures.
  it("destroyed() detaches the RoomEvent listeners installed in _bindRoomEvents", () => {
    const room = fakeRoom({ state: "connected" })
    const el = fakeHookEl()
    const hook = buildReconnectHook(el)
    hook._viewportQuery = { removeEventListener() {} }
    hook._onPageHide = () => {}

    hook._adoptRoom(room)
    expect(room.listenerCount("reconnected")).toBe(1)
    expect(room.listenerCount("reconnecting")).toBe(1)
    expect(room.listenerCount("disconnected")).toBe(1)
    expect(room.listenerCount("participantConnected")).toBe(1)
    expect(hook._boundRoom).toBe(room)

    hook.destroyed()

    // Every listener we installed has been removed from the surviving Room.
    expect(room.listenerCount("reconnected")).toBe(0)
    expect(room.listenerCount("reconnecting")).toBe(0)
    expect(room.listenerCount("disconnected")).toBe(0)
    expect(room.listenerCount("participantConnected")).toBe(0)
    expect(hook._boundRoom).toBeNull()
    expect(hook._roomListeners).toEqual([])
    // The Room itself was NOT disconnected (reconnect-survival contract).
    expect(room.disconnectCalls).toBe(0)
  })

  it("destroyed() + re-mount adopt installs exactly ONE listener set on the surviving Room", () => {
    // Mirrors the case-3 scenario: navigate /chat → /tasks → /chat. The Room
    // survives via window.__livekit_room; each MeetingClient destroy/mount
    // cycle must keep the listener count stable at 1, not accumulate.
    const room = fakeRoom({ state: "connected" })
    const el1 = fakeHookEl()
    const hook1 = buildReconnectHook(el1)
    hook1._viewportQuery = { removeEventListener() {} }
    hook1._onPageHide = () => {}
    hook1._adoptRoom(room)
    expect(room.listenerCount("reconnected")).toBe(1)
    hook1.destroyed()
    expect(room.listenerCount("reconnected")).toBe(0)

    const el2 = fakeHookEl()
    const hook2 = buildReconnectHook(el2)
    hook2._adoptRoom(room)
    expect(room.listenerCount("reconnected")).toBe(1)
    expect(room.listenerCount("reconnecting")).toBe(1)
    expect(room.listenerCount("disconnected")).toBe(1)
  })

  it("_bindRoomEvents on the SAME Room twice does not double-bind (per-instance idempotency)", () => {
    const room = fakeRoom({ state: "connected" })
    const el = fakeHookEl()
    const hook = buildReconnectHook(el)

    hook._adoptRoom(room)
    expect(room.listenerCount("reconnected")).toBe(1)

    // A redundant explicit call (e.g. defensive re-bind path) must NOT add
    // a second handler.
    hook._bindRoomEvents(room)
    expect(room.listenerCount("reconnected")).toBe(1)
    expect(room.listenerCount("participantConnected")).toBe(1)
  })

  // 3. _join adopts instead of disconnect-reconnect when already connected
  //    — provided it is the SAME room (task 01a06925 stage 2, J2). The
  //    pinned Room carries a name and the push carries the room the token
  //    grants; equal names keep 019e4b3e's no-thrash adopt.
  it("_join adopts the existing connected room instead of reconnecting when the names match", async () => {
    const room = fakeRoom({ state: "connected" })
    room.name = "space-B"
    globalThis.window.__livekit_room = room
    const hook = buildReconnectHook(fakeHookEl())
    livekitFake.created.length = 0

    await hook._join({ token: "tok", url: "wss://livekit.test", room_name: "space-B" })

    // No disconnect-then-reconnect thrash; the live room is adopted.
    expect(room.disconnectCalls).toBe(0)
    expect(room.connectCalls).toBe(0)
    expect(livekitFake.created).toHaveLength(0)
    expect(hook._room).toBe(room)
  })

  // 3-J1 (task 01a06925 stage 2). The defect: a tab that joined space-A
  //      (quickmeet, or an earlier meeting) live-navigates to a meeting
  //      backed by space-B. mounted() adopted the still-connected space-A
  //      Room; the server then pushes join-meeting for space-B. The hook
  //      must NOT keep space-A: warn naming both, disconnect the stale
  //      room, drop the pinned refs, and connect the granted room with the
  //      new token. Releasing our listeners first is load-bearing — the
  //      Disconnected handler pushes "meeting_left", which would remove the
  //      human from the meeting they are joining.
  it("_join disconnects a connected room whose name differs from room_name and connects the granted one", async () => {
    const stale = fakeRoom({ state: "connected" })
    stale.name = "space-A"
    globalThis.window.__livekit_room = stale
    globalThis.window.__livekitRoom = stale
    const hook = buildReconnectHook(fakeHookEl())
    const pushed = []
    hook.pushEvent = (event) => pushed.push(event)
    // What mounted() does on the new page: adopt the surviving room.
    hook._adoptRoom(stale)
    expect(stale.listenerCount("disconnected")).toBe(1)

    livekitFake.created.length = 0
    livekitFake.connectedName = "space-B"
    const warns = captureWarns()
    try {
      await hook._join({ token: "tok-B", url: "wss://livekit.test", room_name: "space-B" })
    } finally {
      warns.restore()
    }

    // The stale room was disconnected exactly once, and our listeners were
    // off it before that happened.
    expect(stale.disconnectCalls).toBe(1)
    expect(stale.listenerCount("disconnected")).toBe(0)
    stale.emit("disconnected")
    expect(pushed).not.toContain("meeting_left")

    // A fresh Room was connected with the NEW token and is now the pinned one.
    expect(livekitFake.created).toHaveLength(1)
    const fresh = livekitFake.created[0]
    expect(fresh.connectArgs).toEqual(["wss://livekit.test", "tok-B"])
    expect(hook._room).toBe(fresh)
    expect(globalThis.window.__livekit_room).toBe(fresh)
    expect(globalThis.window.__livekitRoom).toBe(fresh)
    expect(globalThis.window.__livekit_room.name).not.toBe("space-A")
    expect(globalThis.window.__livekit_room.name).toBe("space-B")
    expect(fresh.listenerCount("disconnected")).toBe(1)

    // One warn, naming BOTH rooms — the client noticed, it did not land
    // in the right room by luck.
    const mismatchWarns = warns.calls.filter((args) => {
      const text = JSON.stringify(args)
      return text.includes("space-A") && text.includes("space-B")
    })
    expect(mismatchWarns).toHaveLength(1)
  })

  // 3-J3. A push with no room_name (the server always sends one; this is
  //      an older or foreign payload) degrades to the pre-stage-2 adopt,
  //      and says so once.
  it("_join without room_name adopts the connected room and warns once", async () => {
    const room = fakeRoom({ state: "connected" })
    room.name = "space-A"
    globalThis.window.__livekit_room = room
    const hook = buildReconnectHook(fakeHookEl())
    livekitFake.created.length = 0

    const warns = captureWarns()
    try {
      await hook._join({ token: "tok", url: "wss://livekit.test" })
    } finally {
      warns.restore()
    }

    expect(room.disconnectCalls).toBe(0)
    expect(room.connectCalls).toBe(0)
    expect(livekitFake.created).toHaveLength(0)
    expect(hook._room).toBe(room)
    const missingWarns = warns.calls.filter((args) =>
      String(args[0]).includes("no room_name"),
    )
    expect(missingWarns).toHaveLength(1)
  })

  // 3-J4. A pinned room that is already DISCONNECTED (whatever its name) is
  //      not adopted and not disconnected again: plain fresh connect.
  it("_join with a disconnected pinned room of another name connects fresh without calling disconnect", async () => {
    const dead = fakeRoom({ state: "disconnected" })
    dead.name = "space-A"
    globalThis.window.__livekit_room = dead
    const hook = buildReconnectHook(fakeHookEl())
    livekitFake.created.length = 0
    livekitFake.connectedName = "space-B"

    await hook._join({ token: "tok-B", url: "wss://livekit.test", room_name: "space-B" })

    expect(dead.disconnectCalls).toBe(0)
    expect(livekitFake.created).toHaveLength(1)
    expect(livekitFake.created[0].connectArgs).toEqual(["wss://livekit.test", "tok-B"])
    expect(globalThis.window.__livekit_room).toBe(livekitFake.created[0])
    expect(hook._room).toBe(livekitFake.created[0])
  })

  // 3b. adopt-on-remount (v4 stage 4): when mounted() adopts a surviving
  //     connected room after an LV reconnect, it MUST re-emit
  //     _emitState('connected') (sets dataset.roomState so the rail/
  //     observability recover) AND re-run _reconcileLocalMedia (re-engage
  //     the camera from committed intent). This closes the v3 case-3 gap
  //     where the room survived but dataset.roomState was never re-set.
  it("_adoptRoom re-emits 'connected' and re-engages the camera from intent", () => {
    const room = fakeRoom({ state: "connected", camera: false, mic: false })
    const el = fakeHookEl({ cameraEnabled: "true", micEnabled: "true" })
    const hook = buildReconnectHook(el)

    hook._adoptRoom(room)

    // dataset.roomState restored to 'connected'.
    expect(el.dataset.roomState).toBe("connected")
    expect(
      globalThis.document._events.some(
        (e) => e.type === "livekit:state" && e.detail.state === "connected",
      ),
    ).toBe(true)
    // Camera re-engaged from committed intent (was dropped during the blip).
    expect(room.localParticipant.setCameraCalls).toEqual([true])
    expect(room.localParticipant.setMicCalls).toEqual([true])
  })

  // 3c. v4 case-3 fix: on a PURE LV repatch the hook re-mounts against the
  //     SAME surviving room object, and morphdom has already WIPED the
  //     JS-owned `data-room-state` from the server-rendered element. Adopting
  //     the same room must still re-stamp `dataset.roomState='connected'`
  //     (the early-return path must not skip the re-emit), or the reviewer's
  //     breadcrumb stays absent across the reconnect.
  it("_adoptRoom re-stamps roomState even when adopting the SAME room (morphdom wiped it)", () => {
    const room = fakeRoom({ state: "connected" })
    const el = fakeHookEl()
    const hook = buildReconnectHook(el)
    hook._room = room

    // Simulate morphdom stripping the JS-owned attribute on the LV patch.
    delete el.dataset.roomState

    hook._adoptRoom(room)

    expect(el.dataset.roomState).toBe("connected")
  })

  // 3d. v4 case-3 fix: the LiveView reconnected() hook callback fires after a
  //     1006 socket reconnect — by which time morphdom has re-patched the
  //     element and stripped `data-room-state`. The callback must re-stamp it
  //     against the surviving room so the attribute is present after the
  //     reconnect SETTLES (the reviewer probed it absent across 28s).
  it("reconnected() re-stamps roomState='connected' after the LV patch wipes it", () => {
    const room = fakeRoom({ state: "connected", camera: false })
    globalThis.window.__livekit_room = room
    const el = fakeHookEl({ cameraEnabled: "true", micEnabled: "false" })
    const hook = buildReconnectHook(el)
    hook._room = room

    // morphdom stripped the JS-owned attribute on the reconnect patch.
    delete el.dataset.roomState

    hook.reconnected()

    expect(el.dataset.roomState).toBe("connected")
    // And re-reconciles committed camera intent (mirrors the adopt path).
    expect(room.localParticipant.setCameraCalls).toEqual([true])
  })

  // 4. Reconnected with committed camera intent re-engages the camera.
  it("Reconnected re-engages the camera when intent is on but track dropped", () => {
    const room = fakeRoom({ state: "connected", camera: false })
    const el = fakeHookEl({ cameraEnabled: "true", micEnabled: "false" })
    const hook = buildReconnectHook(el)

    hook._reconcileLocalMedia(room)

    expect(room.localParticipant.setCameraCalls).toEqual([true])
    // Mic intent is off → not re-engaged.
    expect(room.localParticipant.setMicCalls).toEqual([])
  })

  it("Reconnected does NOT re-engage the camera when intent is off", () => {
    const room = fakeRoom({ state: "connected", camera: false })
    const el = fakeHookEl({ cameraEnabled: "false", micEnabled: "false" })
    const hook = buildReconnectHook(el)

    hook._reconcileLocalMedia(room)

    expect(room.localParticipant.setCameraCalls).toEqual([])
  })

  it("Reconnected does NOT re-engage the camera when it is already on", () => {
    const room = fakeRoom({ state: "connected", camera: true })
    const el = fakeHookEl({ cameraEnabled: "true", micEnabled: "false" })
    const hook = buildReconnectHook(el)

    hook._reconcileLocalMedia(room)

    // Already enabled → no redundant setCameraEnabled(true).
    expect(room.localParticipant.setCameraCalls).toEqual([])
  })

  // 5. Each transition sets dataset.roomState + dispatches livekit:state.
  it("_emitState sets dataset.roomState and dispatches livekit:state", () => {
    const room = fakeRoom({ state: "connected", camera: true, mic: false })
    const el = fakeHookEl()
    const hook = buildReconnectHook(el)

    hook._emitState("reconnected", room)

    expect(el.dataset.roomState).toBe("reconnected")
    const evt = globalThis.document._events.find((e) => e.type === "livekit:state")
    expect(evt).toBeTruthy()
    expect(evt.detail.state).toBe("reconnected")
    expect(evt.detail.roomName).toBe("space-room")
    expect(evt.detail.localPublishing).toEqual({ camera: true, mic: false })
  })

  it("the Reconnected room event emits state 'reconnected' and reconciles media", () => {
    const room = fakeRoom({ state: "connected", camera: false })
    const el = fakeHookEl({ cameraEnabled: "true", micEnabled: "false" })
    const hook = buildReconnectHook(el)

    // Wire the handlers, then fire the LiveKit Reconnected event.
    hook._adoptRoom(room)
    globalThis.document._events.length = 0
    room.localParticipant.setCameraCalls.length = 0
    // Simulate the SFU dropping the camera publication during the network
    // interruption so the post-reconnect reconcile has work to do.
    room.localParticipant.isCameraEnabled = false

    room.emit("reconnected")

    expect(el.dataset.roomState).toBe("reconnected")
    expect(
      globalThis.document._events.some(
        (e) => e.type === "livekit:state" && e.detail.state === "reconnected",
      ),
    ).toBe(true)
    expect(room.localParticipant.setCameraCalls).toEqual([true])
  })
})

/**
 * Tests for the /chat quick-meet camera publish + dock convergence
 * (task 019e4b3e v4 stage 2). Two compounding defects on the broken
 * surface:
 *   (a) `_join` only enabled the mic — the camera never published on a
 *       fresh join. Fix: `_join` runs `_reconcileLocalMedia` so the
 *       committed `data-camera-enabled` intent drives setCameraEnabled.
 *   (b) the local <video> had no parking slot / dock in the quick-meet
 *       panel. Fix: partials.ex adds `[data-role="local-self-view"]` +
 *       `[data-local-video-dock][data-dock-mode="gallery"]`, and the hook
 *       resolves them (pane-scoped on /chat, unscoped on MeetingLive).
 */
describe("MeetingClient — quick-meet camera publish + dock (v4 stage 2)", () => {
  let priorWindow

  beforeEach(() => {
    globalThis.console = globalThis.console || { warn() {}, error() {}, info() {} }
    if (!globalThis.console.info) globalThis.console.info = () => {}
    priorWindow = globalThis.window
    globalThis.window = {
      __livekit_room: null,
      __livekitRoom: null,
      addEventListener() {},
      removeEventListener() {},
      dispatchEvent() {
        return true
      },
      matchMedia() {
        return { matches: true, addEventListener() {}, removeEventListener() {} }
      },
    }
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
    delete globalThis.document
    delete globalThis.CustomEvent
    globalThis.window = priorWindow
  })

  // 1. _join drives _reconcileLocalMedia so the camera engages from the
  //    committed dataset intent (not just reconnect). The fresh-connect path
  //    constructs a real `new Room()` (un-mockable here), so we exercise the
  //    /chat-realistic adopt branch: a connected room left on window by a
  //    prior hook instance. _join → _adoptRoom → _reconcileLocalMedia.
  it("_join engages the camera from dataset intent via the adopt branch", async () => {
    const room = fakeRoom({ state: "connected", camera: false, mic: false })
    globalThis.document = buildSignalDocument()
    globalThis.window.__livekit_room = room
    const el = fakeHookEl({ cameraEnabled: "true", micEnabled: "true" })
    const hook = buildReconnectHook(el)

    await hook._join({ token: "tok", url: "wss://livekit.test" })

    // No reconnect thrash AND the camera engaged from committed intent.
    expect(room.connectCalls).toBe(0)
    expect(room.localParticipant.setCameraCalls).toEqual([true])
  })

  // 1b. _reconcileLocalMedia does NOT enable the camera when intent is off
  //     (the helper _join routes through honors a camera-off join).
  it("does NOT engage the camera when dataset intent is 'false'", () => {
    const room = fakeRoom({ state: "connected", camera: false })
    globalThis.document = buildSignalDocument()
    const el = fakeHookEl({ cameraEnabled: "false", micEnabled: "true" })
    const hook = buildReconnectHook(el)

    hook._reconcileLocalMedia(room)
    expect(room.localParticipant.setCameraCalls).toEqual([])
  })

  // 2. _attachLocalVideo resolves [data-role="local-self-view"] and parks
  //    the <video> when the quick-meet parking slot exists (pane-scoped).
  it("_attachLocalVideo parks the <video> in the quick-meet desktop parking slot", () => {
    const parkingDesktop = fakeNode({ role: "local-self-view", pane: "desktop" })
    const galleryDesktop = fakeNode({
      localVideoDock: "",
      dockMode: "gallery",
      pane: "desktop",
    })

    globalThis.document = {
      createElement() {
        return fakeNode()
      },
      querySelector(sel) {
        if (sel === '[data-role="local-self-view"][data-pane="desktop"]')
          return parkingDesktop
        if (
          sel === '[data-local-video-dock][data-dock-mode="gallery"][data-pane="desktop"]'
        )
          return galleryDesktop
        return null
      },
    }

    const hook = buildHook()
    const track = fakeTrack()
    hook._attachLocalVideo(track)

    // The <video> was minted, attached once, and docked into the gallery
    // dock resolved via the pane-scoped quick-meet selectors.
    expect(hook._localVideoEl).not.toBeNull()
    expect(track.attachCalls).toEqual([hook._localVideoEl])
    expect(hook._localVideoEl.parentElement).toBe(galleryDesktop)
  })

  // 3. _dockLocalVideo resolves the quick-meet gallery dock on /chat with
  //    NO MeetingLive stage modes present (pane-scoped fallback).
  it("_dockLocalVideo resolves the quick-meet gallery dock without stage modes", () => {
    const parkingDesktop = fakeNode({ role: "local-self-view", pane: "desktop" })
    const galleryDesktop = fakeNode({
      localVideoDock: "",
      dockMode: "gallery",
      pane: "desktop",
    })

    globalThis.document = {
      createElement() {
        return fakeNode()
      },
      querySelector(sel) {
        if (sel === '[data-role="local-self-view"][data-pane="desktop"]')
          return parkingDesktop
        if (
          sel === '[data-local-video-dock][data-dock-mode="gallery"][data-pane="desktop"]'
        )
          return galleryDesktop
        // No [data-pane="center-stage"] on /chat → _currentStageMode
        // defaults to "gallery".
        return null
      },
    }

    const hook = buildHook()
    const track = fakeTrack()
    hook._attachLocalVideo(track)
    // _currentStageMode() returns "gallery" (no center-stage), so it docks
    // into the quick-meet gallery dock.
    expect(hook._localVideoEl.parentElement).toBe(galleryDesktop)
  })
})

// ── Quick-meet screen-share routing (/chat surface) ─────────────────────────
// On /chat the page-level MeetingClient hook owns screen-share attach (there
// is no MeetingScreenShare hook — that's the /meetings center-stage path). A
// LOCAL screen-share publish must route through LocalTrackPublished →
// _attachTrack → _attachScreenShareTrack into [data-quickmeet-screen-share-
// slot], NOT the camera dock. The slot carries phx-update="ignore" + a stable
// id in the markup, so once the <video> lands it survives LV patches.
describe("MeetingClient — quick-meet screen-share routing", () => {
  let priorWindow

  function fakeScreenTrack(source = "screen_share") {
    return {
      kind: "video",
      source,
      _el: null,
      attachCalls: 0,
      detachCalls: 0,
      attach() {
        this.attachCalls += 1
        this._el = fakeNode()
        return this._el
      },
      detach() {
        this.detachCalls += 1
        const el = this._el
        this._el = null
        return el ? [el] : []
      },
    }
  }

  function buildScreenShareDoc() {
    const slot = fakeNode({ pane: "desktop" })
    slot.classList = {
      _set: new Set(["hidden"]),
      add(c) {
        this._set.add(c)
      },
      remove(c) {
        this._set.delete(c)
      },
      contains(c) {
        return this._set.has(c)
      },
    }
    slot.querySelectorAll = () => []
    // sharer label sibling lookup via slot.parentElement?.querySelector
    slot.parentElement = {
      querySelector() {
        return null
      },
    }
    return {
      _slot: slot,
      createElement() {
        return fakeNode()
      },
      querySelector(sel) {
        if (sel === "[data-quickmeet-screen-share-slot][data-pane='desktop']")
          return slot
        return null
      },
      querySelectorAll() {
        return [slot]
      },
    }
  }

  beforeEach(() => {
    globalThis.console = globalThis.console || { warn() {}, info() {} }
    priorWindow = globalThis.window
    globalThis.window = {
      matchMedia() {
        return { matches: true, addEventListener() {}, removeEventListener() {} }
      },
    }
  })

  afterEach(() => {
    delete globalThis.document
    globalThis.window = priorWindow
  })

  it("a LOCAL screen-share publish lands in the screen-share slot, not the camera dock", () => {
    globalThis.document = buildScreenShareDoc()
    const hook = buildHook()
    const track = fakeScreenTrack("screen_share")
    const localParticipant = {
      identity: "user:local",
      name: "Ada",
      isLocal: true,
    }

    // Mirror the LocalTrackPublished branch for a screen-share source: it is
    // video AND a screen-share, so it routes to _attachTrack (NOT
    // _attachLocalVideo, which is camera-only).
    hook._attachTrack(track, localParticipant)

    expect(track.attachCalls).toBe(1)
    expect(globalThis.document._slot.children.length).toBe(1)
    expect(globalThis.document._slot.classList.contains("hidden")).toBe(false)
    expect(globalThis.document._slot.dataset.screenShareActive).toBe("true")
    expect(globalThis.document._slot.dataset.screenShareSharer).toBe("user:local")
    // No camera self-view element was minted for the screen-share.
    expect(hook._localVideoEl).toBeNull()
    expect(hook._screenShareTrack).toBe(track)
  })

  it("single-sharer policy: a second screen-share does not replace the first", () => {
    globalThis.document = buildScreenShareDoc()
    const hook = buildHook()
    const first = fakeScreenTrack("screen_share")
    const second = fakeScreenTrack("screen_share")

    hook._attachTrack(first, { identity: "user:a" })
    hook._attachTrack(second, { identity: "user:b" })

    // First wins; the second is ignored until the first ends.
    expect(first.attachCalls).toBe(1)
    expect(second.attachCalls).toBe(0)
    expect(hook._screenShareTrack).toBe(first)
    expect(globalThis.document._slot.children.length).toBe(1)
  })

  it("detaching the active screen-share clears the slot and re-hides it", () => {
    globalThis.document = buildScreenShareDoc()
    const hook = buildHook()
    const track = fakeScreenTrack("screen_share")
    hook._attachTrack(track, { identity: "user:local" })
    expect(globalThis.document._slot.children.length).toBe(1)

    hook._detachScreenShareTrack(track)

    expect(track.detachCalls).toBe(1)
    expect(hook._screenShareTrack).toBeNull()
    expect(globalThis.document._slot.classList.contains("hidden")).toBe(true)
    expect(globalThis.document._slot.dataset.screenShareActive).toBe("false")
  })
})


/**
 * Camera-off must show the avatar backdrop on the LOCAL tile
 * ("when I mute my video, it just shows a black video track, and it
 * doesn't show the user thumbnail backdrop").
 *
 * Mechanism: in livekit-client v2 `setCameraEnabled(false)` MUTES the
 * publication (LocalParticipant.setTrackEnabled only unpublishes for
 * screen-share) and merely flips `mediaStreamTrack.enabled = false`. The
 * publication stays, so `LocalTrackUnpublished` -- the hook's only
 * `_suspendLocalVideo` trigger -- never fires. The persistent local
 * <video> stays attached and docked over the local gallery cell, and a
 * disabled MediaStreamTrack paints BLACK, hiding the server-rendered
 * `[data-avatar-fallback]` underneath.
 *
 * The fix mirrors `MeetingVideoTile._reconcile` (remote tiles) rather than
 * inventing a second policy: trackMuted/trackUnmuted listeners plus a
 * `_localCameraOff` predicate consulted before every re-dock.
 */

// A local camera publication that can be muted/unmuted like LiveKit's.
function fakeCameraPub(track, { muted = false, source = "camera" } = {}) {
  return {
    kind: "video",
    source,
    isMuted: muted,
    track,
  }
}

function buildBoundHook(room, doc) {
  globalThis.document = doc
  const hook = buildHook()
  hook.el = fakeNode()
  hook._tiles = new Map()
  hook._boundRoom = null
  hook._roomListeners = []
  // `_bindRoomEvents` also wires the REMOTE media-state path (task
  // 01a0740c stage 1), which pushes to the LiveView. Phoenix always gives
  // a mounted hook a `pushEvent`; this fixture predates the push, so it
  // records instead of throwing. The pushes are asserted in
  // `meeting_client_media_states.test.js` — here they are noise, and what
  // matters is that they never disturb the LOCAL self-view assertions
  // below.
  hook.pushedMediaStates = []
  hook.pushEvent = (event, payload) => hook.pushedMediaStates.push([event, payload])
  hook._room = room
  hook._bindRoomEvents(room)
  return hook
}

describe("MeetingClient -- local camera mute shows the avatar backdrop", () => {
  beforeEach(() => {
    globalThis.requestAnimationFrame = (cb) => cb()
  })

  afterEach(() => {
    delete globalThis.document
    delete globalThis.requestAnimationFrame
  })

  function setup({ stageMode = "gallery" } = {}) {
    const doc = buildDocument({ stageMode })
    const room = fakeRoom({ camera: true })
    const track = fakeTrack()
    track.mediaStreamTrack = { readyState: "live" }
    const pub = fakeCameraPub(track)
    room.localParticipant.trackPublications.set("camera", pub)
    const hook = buildBoundHook(room, doc)
    hook._attachLocalVideo(track)
    return { doc, room, track, pub, hook, el: hook._localVideoEl }
  }

  it("POSITIVE: camera on -> the video element is docked over the local cell and painting", () => {
    const { doc, track, el } = setup()
    expect(el.parentElement).toBe(doc._gallery)
    expect(el.style.display).toBe("")
    expect(track.detachCalls).toEqual([])
  })

  it("THE BUG: trackMuted parks + detaches the local video so the avatar shows", () => {
    const { doc, room, track, pub, hook, el } = setup()

    pub.isMuted = true
    room.emit("trackMuted", pub, room.localParticipant)

    // No video left in the dock -> the server-rendered avatar fallback in the
    // tile underneath is what the user sees. No black rectangle over it.
    expect(doc._gallery.children).not.toContain(el)
    expect(el.parentElement).toBe(doc._parking)
    expect(el.style.display).toBe("none")
    expect(track.detachCalls).toEqual([el])
    expect(hook._localVideoTrack).toBeNull()
    // Same element kept for the re-engage.
    expect(hook._localVideoEl).toBe(el)
  })

  it("trackUnmuted re-attaches the SAME element and re-docks it", () => {
    const { doc, room, track, pub, hook, el } = setup()

    pub.isMuted = true
    room.emit("trackMuted", pub, room.localParticipant)
    pub.isMuted = false
    room.emit("trackUnmuted", pub, room.localParticipant)

    expect(hook._localVideoEl).toBe(el)
    expect(el.parentElement).toBe(doc._gallery)
    expect(el.style.display).toBe("")
    expect(track.attachCalls).toEqual([el, el])
  })

  it("ROUND-TRIP: off -> on -> off -> on with NO re-render in between", () => {
    const { doc, room, pub, hook, el } = setup()

    for (let i = 0; i < 2; i++) {
      pub.isMuted = true
      room.emit("trackMuted", pub, room.localParticipant)
      expect(el.parentElement).toBe(doc._parking)
      expect(el.style.display).toBe("none")

      pub.isMuted = false
      room.emit("trackUnmuted", pub, room.localParticipant)
      expect(el.parentElement).toBe(doc._gallery)
      expect(el.style.display).toBe("")
    }
    // Exactly one element the whole way through.
    expect(hook._localVideoEl).toBe(el)
  })

  it("updated() does NOT re-dock a muted camera (the black-rectangle re-entry)", () => {
    const { doc, room, pub, hook, el } = setup()
    pub.isMuted = true
    room.emit("trackMuted", pub, room.localParticipant)

    // An unrelated LiveView patch lands.
    hook.updated()

    expect(el.parentElement).toBe(doc._parking)
    expect(doc._gallery.children).not.toContain(el)
  })

  it("updated() still re-docks when the camera is live (no regression)", () => {
    const { doc, hook, el } = setup()
    el.remove()
    hook.updated()
    expect(el.parentElement).toBe(doc._gallery)
  })

  it("ignores a REMOTE mute", () => {
    const { doc, room, el } = setup()
    const remote = { identity: "user:remote", trackPublications: new Map() }
    const remotePub = fakeCameraPub(fakeTrack(), { muted: true })

    room.emit("trackMuted", remotePub, remote)

    expect(el.parentElement).toBe(doc._gallery)
    expect(el.style.display).toBe("")
  })

  it("ignores a screen-share mute and leaves the camera docked", () => {
    const { doc, room, el } = setup()
    const ssPub = fakeCameraPub(fakeTrack("screen_share"), {
      muted: true,
      source: "screen_share",
    })

    room.emit("trackMuted", ssPub, room.localParticipant)

    expect(el.parentElement).toBe(doc._gallery)
    expect(el.style.display).toBe("")
  })

  it("ignores an audio (mic) mute", () => {
    const { doc, room, el } = setup()
    const micPub = { kind: "audio", isMuted: true, track: { kind: "audio" } }

    room.emit("trackMuted", micPub, room.localParticipant)

    expect(el.parentElement).toBe(doc._gallery)
    expect(el.style.display).toBe("")
  })

  it("_adoptRoom does not attach a published-but-MUTED camera", () => {
    const doc = buildDocument({ stageMode: "gallery" })
    doc.dispatchEvent = () => true
    doc.querySelectorAll = () => []
    doc.getElementById = () => null
    globalThis.document = doc
    const priorWindow = globalThis.window
    globalThis.window = {
      __livekit_room: null,
      __livekitRoom: null,
      addEventListener() {},
      removeEventListener() {},
      dispatchEvent() {
        return true
      },
      matchMedia: () => ({ matches: true, addEventListener() {}, removeEventListener() {} }),
    }
    globalThis.CustomEvent =
      globalThis.CustomEvent ||
      class {
        constructor(type, init) {
          this.type = type
          Object.assign(this, init)
        }
      }
    const room = fakeRoom({ camera: false })
    const track = fakeTrack()
    room.localParticipant.trackPublications.set(
      "camera",
      fakeCameraPub(track, { muted: true }),
    )
    const hook = buildHook()
    hook.el = fakeNode()
    hook._tiles = new Map()
    hook._boundRoom = null
    hook._roomListeners = []

    hook._adoptRoom(room)

    expect(track.attachCalls).toEqual([])
    expect(hook._localVideoEl).toBeNull()

    globalThis.window = priorWindow
  })

  it("_localCameraOff reads 'not off' when the room cannot be asked", () => {
    globalThis.document = buildDocument()
    const hook = buildHook()
    expect(hook._localCameraOff(null)).toBe(false)
    expect(hook._localCameraOff({})).toBe(false)
    expect(hook._localCameraOff({ localParticipant: {} })).toBe(false)
  })

  it("_localCameraOff treats an ended MediaStreamTrack as off", () => {
    globalThis.document = buildDocument()
    const hook = buildHook()
    const room = fakeRoom()
    const track = fakeTrack()
    track.mediaStreamTrack = { readyState: "ended" }
    room.localParticipant.trackPublications.set("camera", fakeCameraPub(track))
    expect(hook._localCameraOff(room)).toBe(true)
  })
})

// ── Live-navigation audio survival (task 019ffe99) ───────────────────────
//
// The bug only manifests ACROSS a LiveView swap: `/meetings` -> `/org_memory`
// sits inside `live_session :authenticated`, so it is a live redirect with no
// page reload. LiveView removes `#meeting-media`, taking every remote <audio>
// child with it, while the LiveKit Room happily survives on
// window.__livekit_room. A test that never navigates cannot catch that —
// which is exactly how it shipped. So this block builds the media, asserts it
// is really there (positive control), THEN removes `#meeting-media` and calls
// destroyed(), and only then asserts survival.
//
// Harness note: `Phoenix.LiveViewTest` cannot observe any of this. These
// <audio> elements are minted client-side by `track.attach()` and never
// appear in server-rendered HTML, so a server-side live_redirect test would
// assert something adjacent and prove nothing. The end-to-end coverage is the
// e2e_behavior cases driven through CDP against a live two-party meeting.

function camelize(name) {
  return name.replace(/-([a-z])/g, (_m, c) => c.toUpperCase())
}

function descendants(node) {
  return node.children.flatMap((c) => [c, ...descendants(c)])
}

// fakeNode + the bits `_mediaContainer()` / the audio branch actually touch:
// id, setAttribute, a `[data-audio-track="..."]` querySelector, and a REAL
// `isConnected` computed by walking to the root (so removing an ancestor
// genuinely disconnects the subtree, the way a LiveView swap does).
function navNode(attrs = {}) {
  const node = fakeNode(attrs)
  node.tagName = "DIV"
  node.id = ""
  node.setAttribute = function (name, value) {
    if (name === "id") this.id = value
    else if (name.startsWith("data-")) this.dataset[camelize(name.slice(5))] = value
    else this[name] = value
  }
  node.querySelector = function (sel) {
    const m = /^\[data-audio-track="(.+)"\]$/.exec(sel)
    if (!m) return null
    return descendants(this).find((n) => n.dataset.audioTrack === m[1]) || null
  }
  Object.defineProperty(node, "isConnected", {
    get() {
      let n = this
      while (n.parentElement) n = n.parentElement
      return n._isBody === true
    },
  })
  return node
}

function buildNavDocument({ meetingMedia = true } = {}) {
  const body = navNode()
  body._isBody = true
  const doc = {
    body,
    createElement(tag) {
      const n = navNode()
      n.tagName = String(tag).toUpperCase()
      return n
    },
    getElementById(id) {
      return descendants(body).find((n) => n.id === id) || null
    },
    querySelector() {
      return null
    },
  }
  if (meetingMedia) doc._media = addMeetingMedia(body)
  return doc
}

// The server-rendered sink (meeting_live.html.heex:142 / partials.ex:1377).
function addMeetingMedia(body) {
  const media = navNode()
  media.id = "meeting-media"
  body.appendChild(media)
  return media
}

function fakeAudioTrack(sid) {
  return {
    kind: "audio",
    sid,
    attachCalls: [],
    detachCalls: [],
    attach() {
      const el = globalThis.document.createElement("audio")
      this.attachCalls.push(el)
      return el
    },
    detach(el) {
      this.detachCalls.push(el === undefined ? null : el)
      return el ? [el] : []
    },
  }
}

function mountNavHook() {
  const hook = Object.create(MeetingClient)
  hook.el = navNode()
  hook.handleEvent = () => {}
  hook.mounted()
  return hook
}

function sinkAudioFor(sid) {
  const sink = globalThis.document.getElementById("meeting-audio-sink")
  if (!sink) return []
  return descendants(sink).filter((n) => n.dataset.audioTrack === sid)
}

describe("MeetingClient — remote audio survives a LiveView navigation", () => {
  beforeEach(() => {
    globalThis.console = globalThis.console || { warn() {}, error() {} }
    globalThis.window = {
      matchMedia: () => ({
        matches: true,
        addEventListener() {},
        removeEventListener() {},
      }),
      addEventListener() {},
      removeEventListener() {},
    }
    globalThis.document = buildNavDocument()
  })

  afterEach(() => {
    delete globalThis.document
    delete globalThis.window
  })

  it("keeps the remote <audio> connected when #meeting-media is swapped away, and does not duplicate it on the way back", () => {
    const hook = mountNavHook()
    const track = fakeAudioTrack("TR_remote_1")
    const remote = { identity: "bob", isLocal: false }

    hook._attachTrack(track, remote)

    // (1) POSITIVE CONTROL — there really is audio in the document before we
    // navigate. An assertion that passes because no audio ever existed would
    // prove nothing.
    expect(track.attachCalls).toHaveLength(1)
    const el = track.attachCalls[0]
    expect(el.isConnected).toBe(true)
    expect(el.parentElement).not.toBeNull()

    // (2) THE SWAP — LiveView going /meetings -> /org_memory (which declares
    // no #meeting-media) removes the node and destroys the hook.
    globalThis.document._media.remove()
    hook.destroyed()

    // (3) SURVIVAL — same element, still connected, parked in the body-level
    // sink, and the track was never detached.
    expect(el.isConnected).toBe(true)
    expect(el.parentElement).toBe(
      globalThis.document.getElementById("meeting-audio-sink"),
    )
    expect(track.detachCalls).toEqual([])

    // (4) NAVIGATE BACK — re-render #meeting-media, re-mount the hook, re-run
    // the attach path for the SAME track. Reparent, never re-attach.
    globalThis.document._media = addMeetingMedia(globalThis.document.body)
    const hook2 = mountNavHook()
    hook2._attachTrack(track, remote)

    expect(track.attachCalls).toHaveLength(1)
    expect(track.detachCalls).toEqual([])
    expect(sinkAudioFor("TR_remote_1")).toEqual([el])
    expect(el.parentElement).toBe(
      globalThis.document.getElementById("meeting-audio-sink"),
    )
  })

  it("still attaches zero audio elements for the LOCAL participant (echo-loop guard)", () => {
    const hook = mountNavHook()
    const local = fakeAudioTrack("TR_local")

    hook._attachTrack(local, { identity: "me", isLocal: true })

    expect(local.attachCalls).toEqual([])
    expect(sinkAudioFor("TR_local")).toEqual([])
  })
})
