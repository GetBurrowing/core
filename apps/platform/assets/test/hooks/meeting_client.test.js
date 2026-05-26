import { describe, it, expect, beforeEach, afterEach } from "vitest"
import MeetingClient from "../../js/hooks/meeting_client.js"

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

// Minimal fake LiveKit Room: .on registers handlers, .emit fires them,
// .disconnect is a spy. state defaults to "connected".
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
    emit(event, ...args) {
      ;(handlers.get(event) || []).forEach((cb) => cb(...args))
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

function buildReconnectHook(el) {
  const hook = Object.create(MeetingClient)
  hook._tiles = new Map()
  hook._localVideoEl = null
  hook._localVideoTrack = null
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

  // 3. _join adopts instead of disconnect-reconnect when already connected.
  it("_join adopts the existing connected room instead of reconnecting", async () => {
    const room = fakeRoom({ state: "connected" })
    globalThis.window.__livekit_room = room
    const hook = buildReconnectHook(fakeHookEl())

    await hook._join({ token: "tok", url: "wss://livekit.test" })

    // No disconnect-then-reconnect thrash; the live room is adopted.
    expect(room.disconnectCalls).toBe(0)
    expect(room.connectCalls).toBe(0)
    expect(hook._room).toBe(room)
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
