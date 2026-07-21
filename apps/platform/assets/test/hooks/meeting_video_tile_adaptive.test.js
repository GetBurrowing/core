import { describe, it, expect, beforeEach, afterEach } from "vitest"
import { RemoteVideoTrack } from "livekit-client"
import MeetingVideoTile from "../../js/hooks/meeting_video_tile.js"

/**
 * Hook-harness regression test for the custom `StableTileElementInfo`
 * (task 019f8153 stage 2). It exercises the observeElementInfo seam stage 1
 * wired onto the tile hook and proves the structural fix for the black-tile
 * class: pre-registering OUR ElementInfo before `track.attach(el)` so the
 * SDK's default (false-negative) HTMLElementInfo IntersectionObserver watcher
 * is never installed, while still emitting a genuine invisible signal when the
 * tile is truly off-screen (so adaptiveStream keeps saving bandwidth).
 *
 * Runs in vitest's default `node` env (no jsdom in the assets workspace), so
 * we build lightweight fakes for the DOM nodes + LiveKit track the hook
 * touches, mirroring the fake-DOM style in embed_canvas_scale.test.js and
 * meeting_video_tile.test.js.
 *
 * The load-bearing detail: `FakeRemoteVideoTrack.observeElementInfo(info)`
 * ASSIGNS `info.handleResize` / `info.handleVisibilityChanged` and calls
 * `info.observe()` EXACTLY as livekit-client 2.18.1 does (verified in the
 * installed esm bundle; see journal 2026-07-20). Without that, the harness
 * would not exercise the callback wiring stage 1 built and would prove nothing.
 *
 * Assertion → acceptance-criterion map:
 *   #1  observeElementInfo runs before attach; exactly one info, ours.
 *   #2  morphdom churn immunity: visible stays true, no false pause emitted.
 *   #3  mic-toggle updated() round-trip: our info is not replaced.
 *   #4  genuine hide (size 0 / IntersectionObserver / document hidden) each
 *       flips visible false, advances visibilityChangedAt, fires the callback;
 *       restore flips back true and fires again — adaptiveStream is live, not
 *       stubbed off.
 *   #5  teardown: destroyed() calls stopObservingElementInfo and disconnects
 *       both observers.
 */

// ── DOM / observer fakes ─────────────────────────────────────────────────

function fakeClassList() {
  const set = new Set()
  return {
    add: (c) => set.add(c),
    remove: (c) => set.delete(c),
    has: (c) => set.has(c),
  }
}

function fakeVideoEl() {
  return {
    autoplay: false,
    playsInline: false,
    muted: false,
    className: "",
    style: {},
    _isVideo: true,
    _removed: false,
    _parent: null,
    remove() {
      this._removed = true
      if (this._parent) {
        const i = this._parent.children.indexOf(this)
        if (i >= 0) this._parent.children.splice(i, 1)
        this._parent = null
      }
    },
  }
}

// Global observer fakes that capture their callback + observed targets so the
// test can drive them. Module-level arrays record every instance created
// during an `observe()` so a test can find the one rooted at the tile element.
let resizeObservers
let intersectionObservers

class FakeResizeObserver {
  constructor(cb) {
    this.cb = cb
    this.targets = []
    this.disconnected = false
    resizeObservers.push(this)
  }
  observe(el) {
    this.targets.push(el)
  }
  disconnect() {
    this.disconnected = true
  }
  // Drive a resize notification (the entries payload is unused by the hook).
  trigger() {
    this.cb([], this)
  }
}

class FakeIntersectionObserver {
  constructor(cb, opts) {
    this.cb = cb
    this.opts = opts
    this.targets = []
    this.disconnected = false
    intersectionObservers.push(this)
  }
  observe(el) {
    this.targets.push(el)
  }
  disconnect() {
    this.disconnected = true
  }
  trigger(entries) {
    this.cb(entries, this)
  }
}

// Controllable document with a mutable visibilityState + listener registry.
function fakeDocument() {
  const listeners = {}
  return {
    visibilityState: "visible",
    _listeners: listeners,
    createElement() {
      return fakeVideoEl()
    },
    addEventListener(type, fn) {
      ;(listeners[type] = listeners[type] || []).push(fn)
    },
    removeEventListener(type, fn) {
      const arr = listeners[type]
      if (arr) {
        const i = arr.indexOf(fn)
        if (i >= 0) arr.splice(i, 1)
      }
    },
    _dispatch(type) {
      for (const fn of (listeners[type] || []).slice()) fn()
    },
  }
}

// Fake outer tile element (this.el / hookEl). Non-zero clientWidth/clientHeight
// so the tile reads visible by default; carries the slot + avatar fallback.
function fakeHookEl(identity) {
  const slot = {
    classList: fakeClassList(),
    children: [],
    appendChild(child) {
      child._parent = this
      this.children.push(child)
    },
    querySelectorAll(sel) {
      if (sel === "video") return this.children.filter((c) => c._isVideo)
      return []
    },
  }
  slot.classList.add("hidden")
  const fallback = { classList: fakeClassList() }

  return {
    dataset: { participant: identity, hasVideo: "false" },
    clientWidth: 320,
    clientHeight: 180,
    classList: fakeClassList(),
    _slot: slot,
    _fallback: fallback,
    querySelector(sel) {
      if (sel === "[data-video-slot]") return this._slot
      if (sel === "[data-avatar-fallback]") return this._fallback
      return null
    },
  }
}

// A LiveKit-style adaptive remote video track. Its prototype is set to the real
// RemoteVideoTrack.prototype so the hook's `track instanceof RemoteVideoTrack`
// gate passes; the own-property methods below shadow the real ones (incl. the
// isAdaptiveStream getter), so no real SDK internals are ever invoked.
// observeElementInfo mirrors the real SDK: it assigns the two callbacks onto
// our info and calls info.observe().
function fakeRemoteAdaptiveTrack() {
  const track = {
    kind: "video",
    isAdaptiveStream: true,
    elementInfos: [],
    callOrder: [],
    attachedEls: [],
    handleResizeCalls: [],
    visibilityChangedCalls: [],
    stopObservingCalls: [],
    observeElementInfo(info) {
      this.callOrder.push("observeElementInfo")
      this.elementInfos.push(info)
      info.handleResize = () => {
        this.handleResizeCalls.push({ w: info.width(), h: info.height() })
      }
      info.handleVisibilityChanged = () => {
        this.visibilityChangedCalls.push({
          visible: info.visible,
          at: info.visibilityChangedAt,
        })
      }
      info.observe()
    },
    stopObservingElementInfo(info) {
      this.callOrder.push("stopObservingElementInfo")
      this.stopObservingCalls.push(info)
      const i = this.elementInfos.indexOf(info)
      if (i >= 0) this.elementInfos.splice(i, 1)
    },
    attach(el) {
      this.callOrder.push("attach")
      this.attachedEls.push(el)
      return el
    },
    detach(el) {
      this.callOrder.push("detach")
      this.attachedEls = this.attachedEls.filter((e) => e !== el)
      return el ? [el] : []
    },
  }
  Object.setPrototypeOf(track, RemoteVideoTrack.prototype)
  return track
}

function buildTile(identity, hookEl) {
  const tile = Object.create(MeetingVideoTile)
  tile.el = hookEl
  // Mirror mounted() without the room-binding side effects.
  tile._identity = identity
  tile._videoEl = null
  tile._attachedTrack = null
  tile._elementInfo = null
  tile._localDock = false
  return tile
}

// Find the observer instance rooted at a given tile element.
function observerFor(list, el) {
  return list.find((o) => o.targets.includes(el))
}

// ── Tests ────────────────────────────────────────────────────────────────

describe("MeetingVideoTile — custom StableTileElementInfo harness", () => {
  let realDateNow

  beforeEach(() => {
    resizeObservers = []
    intersectionObservers = []
    globalThis.ResizeObserver = FakeResizeObserver
    globalThis.IntersectionObserver = FakeIntersectionObserver
    globalThis.document = fakeDocument()
    globalThis.console = globalThis.console || { warn() {} }
    realDateNow = Date.now
  })

  afterEach(() => {
    Date.now = realDateNow
    delete globalThis.ResizeObserver
    delete globalThis.IntersectionObserver
    delete globalThis.document
    delete globalThis.window
  })

  // ── #1: pre-register-before-attach, single info, ours ──────────────────
  it("pre-registers exactly one custom ElementInfo and calls observeElementInfo BEFORE attach", () => {
    const hookEl = fakeHookEl("user:1")
    const tile = buildTile("user:1", hookEl)
    const track = fakeRemoteAdaptiveTrack()

    tile._attach(track, { isLocal: false })

    // Exactly one info registered, and it is ours (element === the <video> the
    // hook minted). The SDK's default HTMLElementInfo is never installed.
    expect(track.elementInfos.length).toBe(1)
    expect(track.elementInfos[0]).toBe(tile._elementInfo)
    expect(track.elementInfos[0].element).toBe(tile._videoEl)

    // observeElementInfo MUST precede attach so the element-arg attach()
    // overload matches our info and skips the default watcher.
    const obs = track.callOrder.indexOf("observeElementInfo")
    const att = track.callOrder.indexOf("attach")
    expect(obs).toBeGreaterThanOrEqual(0)
    expect(att).toBeGreaterThan(obs)
  })

  // ── #2: morphdom churn immunity — no false pause ───────────────────────
  it("keeps visible=true and never emits a false pause across morphdom churn", () => {
    const hookEl = fakeHookEl("user:1")
    const tile = buildTile("user:1", hookEl)
    const track = fakeRemoteAdaptiveTrack()

    tile._attach(track, { isLocal: false })
    const info = tile._elementInfo
    expect(info.visible).toBe(true)

    // Churn a morphdom patch would cause WITHOUT changing the outer tile size:
    // a caption-sibling detach + re-append inside the tile, and a
    // mute/speaking-ring class flip on the outer element.
    const caption = { _isCaption: true }
    hookEl._slot.children.push(caption)
    hookEl._slot.children.splice(hookEl._slot.children.indexOf(caption), 1)
    hookEl.classList.add("ring-2")
    hookEl.classList.remove("ring-2")

    // A reflow may fire the ResizeObserver; the outer tile is still 320x180.
    resizeObservers.forEach((ro) => ro.trigger())

    expect(info.visible).toBe(true)
    // handleVisibilityChanged was NEVER called with a false value.
    expect(track.visibilityChangedCalls.some((c) => c.visible === false)).toBe(
      false,
    )
  })

  // ── #3: mic-toggle updated() round-trip does not replace our info ───────
  it("does not replace our ElementInfo across a mic-toggle updated() round-trip", () => {
    const hookEl = fakeHookEl("user:1")
    const tile = buildTile("user:1", hookEl)
    const track = fakeRemoteAdaptiveTrack()
    const room = { on() {}, off() {}, localParticipant: null }
    tile._room = room
    globalThis.window = { __livekit_room: room }

    tile._attach(track, { isLocal: false })
    const info = tile._elementInfo
    expect(track.elementInfos.length).toBe(1)

    // A mic toggle re-renders the tile → LiveView calls updated(). Our track is
    // already attached, so this is a no-op that must leave our info in place
    // (not tear it down and re-register a fresh one).
    tile.updated()

    expect(track.elementInfos.length).toBe(1)
    expect(track.elementInfos[0]).toBe(info)
    expect(tile._elementInfo).toBe(info)
    expect(info.visible).toBe(true)
    expect(track.visibilityChangedCalls.some((c) => c.visible === false)).toBe(
      false,
    )
  })

  // ── #4a: genuine hide via outer size shrink to 0 ───────────────────────
  it("size shrink to 0 flips visible false, advances visibilityChangedAt, fires handleVisibilityChanged; restore resumes", () => {
    let clock = 1000
    Date.now = () => clock

    const hookEl = fakeHookEl("user:1")
    const tile = buildTile("user:1", hookEl)
    const track = fakeRemoteAdaptiveTrack()
    tile._attach(track, { isLocal: false })
    const info = tile._elementInfo
    expect(info.visible).toBe(true)
    const before = track.visibilityChangedCalls.length

    // Genuine hide: the outer tile collapses to zero height.
    clock = 2000
    hookEl.clientHeight = 0
    resizeObservers.forEach((ro) => ro.trigger())

    expect(info.visible).toBe(false)
    expect(info.visibilityChangedAt).toBe(2000)
    expect(track.visibilityChangedCalls.length).toBe(before + 1)
    expect(track.visibilityChangedCalls.at(-1).visible).toBe(false)

    // Restore: the tile regains size → visible true again, fires again.
    clock = 3000
    hookEl.clientHeight = 180
    resizeObservers.forEach((ro) => ro.trigger())

    expect(info.visible).toBe(true)
    expect(info.visibilityChangedAt).toBe(3000)
    expect(track.visibilityChangedCalls.length).toBe(before + 2)
    expect(track.visibilityChangedCalls.at(-1).visible).toBe(true)
  })

  // ── #4b: genuine hide via IntersectionObserver (scrolled off-screen) ────
  it("IntersectionObserver isIntersecting:false flips invisible; restore resumes", () => {
    let clock = 1000
    Date.now = () => clock

    const hookEl = fakeHookEl("user:1")
    const tile = buildTile("user:1", hookEl)
    const track = fakeRemoteAdaptiveTrack()
    tile._attach(track, { isLocal: false })
    const info = tile._elementInfo
    const io = observerFor(intersectionObservers, hookEl)
    expect(io).toBeTruthy()
    expect(info.visible).toBe(true)

    // Tile scrolled out of the document viewport.
    clock = 2000
    io.trigger([{ target: hookEl, isIntersecting: false }])
    expect(info.visible).toBe(false)
    expect(info.visibilityChangedAt).toBe(2000)
    expect(track.visibilityChangedCalls.at(-1).visible).toBe(false)

    // Scrolled back into view.
    clock = 3000
    io.trigger([{ target: hookEl, isIntersecting: true }])
    expect(info.visible).toBe(true)
    expect(info.visibilityChangedAt).toBe(3000)
    expect(track.visibilityChangedCalls.at(-1).visible).toBe(true)
  })

  // ── #4c: genuine hide via document.visibilityState (tab backgrounded) ───
  it("document hidden flips invisible; restore resumes", () => {
    let clock = 1000
    Date.now = () => clock

    const hookEl = fakeHookEl("user:1")
    const tile = buildTile("user:1", hookEl)
    const track = fakeRemoteAdaptiveTrack()
    tile._attach(track, { isLocal: false })
    const info = tile._elementInfo
    expect(info.visible).toBe(true)

    // Tab backgrounded.
    clock = 2000
    globalThis.document.visibilityState = "hidden"
    globalThis.document._dispatch("visibilitychange")
    expect(info.visible).toBe(false)
    expect(info.visibilityChangedAt).toBe(2000)
    expect(track.visibilityChangedCalls.at(-1).visible).toBe(false)

    // Tab foregrounded.
    clock = 3000
    globalThis.document.visibilityState = "visible"
    globalThis.document._dispatch("visibilitychange")
    expect(info.visible).toBe(true)
    expect(info.visibilityChangedAt).toBe(3000)
    expect(track.visibilityChangedCalls.at(-1).visible).toBe(true)
  })

  // ── #5: teardown disconnects everything ────────────────────────────────
  it("destroyed() stops observing the ElementInfo and disconnects the observers", () => {
    const hookEl = fakeHookEl("user:1")
    const tile = buildTile("user:1", hookEl)
    const track = fakeRemoteAdaptiveTrack()
    const room = { on() {}, off() {} }
    tile._room = room
    globalThis.window = { __livekit_room: room }

    tile._attach(track, { isLocal: false })
    const info = tile._elementInfo
    const ro = observerFor(resizeObservers, hookEl)
    const io = observerFor(intersectionObservers, hookEl)

    tile.destroyed()

    // The SDK is told to stop observing OUR info, and our own observers +
    // visibilitychange listener are torn down.
    expect(track.stopObservingCalls).toContain(info)
    expect(ro.disconnected).toBe(true)
    expect(io.disconnected).toBe(true)
    expect(tile._elementInfo).toBeNull()
    expect(globalThis.document._listeners.visibilitychange.length).toBe(0)
  })
})
