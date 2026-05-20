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
