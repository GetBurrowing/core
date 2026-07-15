import { describe, it, expect, beforeEach, afterEach } from "vitest"
import MeetingVideoTile from "../../js/hooks/meeting_video_tile.js"

/**
 * Tests for the `MeetingVideoTile` hook's attach/detach lifecycle
 * (task 019e42f6 — "Switching Active Tab In Meeting Drops Video").
 *
 * Root cause covered by Stage 1: a zero-arg `track.detach()` in the
 * destroyed tile globally detached the MediaStreamTrack from EVERY <video>
 * in the document, black-screening a freshly-mounted sibling tile that
 * shares the same track across a mode-switch LiveView patch. The fix uses
 * the single-element `track.detach(element)` overload so only the
 * destroyed tile's own element is detached. Stage 2 hardens the
 * toggle-off-then-on path so a stale `_attachedTrack` ref never short-
 * circuits the re-attach.
 *
 * The hook runs in the default vitest `node` environment (no jsdom is
 * installed for the assets workspace), so these tests build lightweight
 * fakes for the DOM nodes + LiveKit Track the hook touches. The fakes
 * record the exact arguments passed to `track.detach(...)`, which is the
 * load-bearing assertion: detach MUST be called with the tile's own
 * element, never with zero args.
 */

// ── Fakes ──────────────────────────────────────────────────────────────

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

// A LiveKit-style video track. `detach()` records every call: with no
// args it pushes `null` (the dangerous global form); with an element it
// pushes that element (the single-element form).
function fakeTrack(kind = "video") {
  return {
    kind,
    detachCalls: [],
    _attachedEls: [],
    attach() {
      const el = fakeVideoEl()
      this._attachedEls.push(el)
      return el
    },
    detach(el) {
      this.detachCalls.push(el === undefined ? null : el)
      if (el) {
        this._attachedEls = this._attachedEls.filter((e) => e !== el)
        return [el]
      }
      const all = this._attachedEls
      this._attachedEls = []
      return all
    },
  }
}

// Build a hook instance with a fake `el` wired to a slot + avatar fallback.
function buildTile(identity) {
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

  const el = {
    dataset: { participant: identity, hasVideo: "false" },
    querySelector(sel) {
      if (sel === "[data-video-slot]") return slot
      if (sel === "[data-avatar-fallback]") return fallback
      return null
    },
  }

  const tile = Object.create(MeetingVideoTile)
  tile.el = el
  tile._slotRef = slot
  tile._fallbackRef = fallback
  // Mirror mounted() without the room-binding side effects.
  tile._identity = identity
  tile._videoEl = null
  tile._attachedTrack = null
  return tile
}

// Mark attached elements so the slot's querySelectorAll("video") finds them.
function markVideo(el) {
  el._isVideo = true
  return el
}

describe("MeetingVideoTile attach/detach lifecycle", () => {
  beforeEach(() => {
    globalThis.console = globalThis.console || { warn() {} }
  })

  afterEach(() => {
    delete globalThis.__livekit_room
  })

  it("attaches a track into its own slot and reveals the video", () => {
    const tile = buildTile("user:1")
    const track = fakeTrack()
    tile._attach(track, { isLocal: true })

    expect(tile._attachedTrack).toBe(track)
    expect(tile._videoEl).not.toBeNull()
    expect(tile._slotRef.children.length).toBe(1)
    expect(tile._slotRef.classList.has("hidden")).toBe(false)
    expect(tile._fallbackRef.classList.has("hidden")).toBe(true)
    expect(tile.el.dataset.hasVideo).toBe("true")
    // Local feed is mirrored.
    expect(tile._videoEl.style.transform).toBe("scaleX(-1)")
  })

  it("detach uses the SINGLE-ELEMENT track.detach(element) form, never the global zero-arg form", () => {
    const tile = buildTile("user:1")
    const track = fakeTrack()
    tile._attach(track, { isLocal: false })
    const ownEl = tile._videoEl

    tile._detach()

    // The load-bearing assertion: detach was called exactly once, with our
    // own element — NOT with `null` (the zero-arg global detach that ripped
    // the track out of sibling tiles and black-screened the local camera).
    expect(track.detachCalls).toEqual([ownEl])
    expect(track.detachCalls).not.toContain(null)
    expect(tile._attachedTrack).toBeNull()
    expect(tile._videoEl).toBeNull()
    expect(tile._slotRef.classList.has("hidden")).toBe(true)
    expect(tile._fallbackRef.classList.has("hidden")).toBe(false)
    expect(tile.el.dataset.hasVideo).toBe("false")
  })

  it("a destroyed tile does NOT detach the track from a sibling tile sharing the same MediaStreamTrack", () => {
    // Two tiles for the same identity (gallery + strip) attach the SAME
    // track object — this is the mode-switch scenario.
    const track = fakeTrack()
    const galleryTile = buildTile("user:1")
    const stripTile = buildTile("user:1")

    galleryTile._attach(track, { isLocal: true })
    stripTile._attach(track, { isLocal: true })
    const galleryEl = galleryTile._videoEl
    const stripEl = stripTile._videoEl

    // The gallery tile is destroyed during the mode-switch patch.
    galleryTile._detach()

    // Only the gallery element was detached; the strip element survives.
    expect(track.detachCalls).toEqual([galleryEl])
    expect(track._attachedEls).toContain(stripEl)
    expect(track._attachedEls).not.toContain(galleryEl)
  })

  it("falls back to removing only its own slot's <video> nodes when the element ref is lost", () => {
    const tile = buildTile("user:1")
    const track = fakeTrack()
    tile._attach(track, { isLocal: false })
    markVideo(tile._videoEl)
    // Simulate a lost element reference (track synced, element gone).
    tile._videoEl = null

    tile._detach()

    // With no element ref, the fix does NOT call the zero-arg global
    // `track.detach()` (which would rip the track out of sibling tiles).
    // Instead it scopes removal to its OWN slot's <video> nodes.
    expect(track.detachCalls).not.toContain(null)
    expect(track.detachCalls).toEqual([])
    expect(tile._slotRef.querySelectorAll("video").length).toBe(0)
    expect(tile._attachedTrack).toBeNull()
  })

  // ── Stage 2: toggle off-then-on re-engagement ─────────────────────────

  it("re-engages the camera after a toggle-off-then-on (publish → unpublish → publish)", () => {
    const tile = buildTile("user:1")
    const localParticipant = { identity: "user:1", isLocal: true }
    tile._room = { localParticipant }

    const track1 = fakeTrack()
    tile._onLocalPublished({ track: track1 })
    expect(tile._attachedTrack).toBe(track1)
    expect(tile._slotRef.classList.has("hidden")).toBe(false)

    // Toggle camera OFF — LiveKit may emit unpublish with a nulled track.
    tile._onLocalUnpublished({ track: null })
    expect(tile._attachedTrack).toBeNull()
    expect(tile._slotRef.classList.has("hidden")).toBe(true)
    expect(tile._videoEl).toBeNull()

    // Toggle camera ON again with a BRAND-NEW track object.
    const track2 = fakeTrack()
    tile._onLocalPublished({ track: track2 })
    expect(tile._attachedTrack).toBe(track2)
    expect(tile._slotRef.classList.has("hidden")).toBe(false)
    expect(tile._videoEl).not.toBeNull()
  })

  it("clears a STALE _attachedTrack ref on publish so a fresh track re-attaches instead of short-circuiting", () => {
    const tile = buildTile("user:1")
    const localParticipant = { identity: "user:1", isLocal: true }
    tile._room = { localParticipant }

    // Simulate the post-mode-switch state: _attachedTrack points at a
    // track whose element was already detached out from under us, but the
    // ref was never cleared.
    const staleTrack = fakeTrack()
    tile._attachedTrack = staleTrack
    tile._videoEl = markVideo(fakeVideoEl())
    tile._slotRef.appendChild(tile._videoEl)

    const freshTrack = fakeTrack()
    tile._onLocalPublished({ track: freshTrack })

    // The stale track was detached (single-element form) and the fresh
    // track is now attached — no early-return short-circuit.
    expect(staleTrack.detachCalls.length).toBe(1)
    expect(tile._attachedTrack).toBe(freshTrack)
    expect(tile._videoEl).not.toBeNull()
  })

  it("ignores publish/unpublish events for a different identity", () => {
    const tile = buildTile("user:1")
    tile._room = { localParticipant: { identity: "user:2", isLocal: true } }

    const track = fakeTrack()
    tile._onLocalPublished({ track })
    expect(tile._attachedTrack).toBeNull()
  })

  // ── v2: local-dock tiles never self-attach ────────────────────────────

  it("a local-dock tile (data-local-dock) NEVER attaches its own track", () => {
    // The local participant's per-mode tile is flagged data-local-dock so
    // MeetingClient's single persistent <video> is the only live local feed.
    const tile = buildTile("user:1")
    tile._localDock = true

    const track = fakeTrack()
    tile._attach(track, { isLocal: true })

    // No element minted, no track attached, slot stays hidden (avatar shows).
    expect(tile._attachedTrack).toBeNull()
    expect(tile._videoEl).toBeNull()
    expect(tile._slotRef.children.length).toBe(0)
    expect(track._attachedEls.length).toBe(0)
  })

  // ── Resize-kick: adaptive-stream re-engagement on layout jump ─────────
  //
  // The Room is constructed with `adaptiveStream: true`, which pauses
  // subscriptions whose <video> element shrinks below an SDK threshold
  // and doesn't always cleanly resume when the element grows back. On
  // gallery layout changes (2p → 3p adds a row and shrinks every existing
  // tile), that manifests as "when a new user joins, the first non-local
  // user's video disappears until you switch stage mode". These tests
  // exercise `_resizeKick` — the manual publication.setSubscribed(false→true)
  // toggle that kicks a stuck subscription back into "actively sending
  // frames".

  it("resize-kick toggles setSubscribed(false)→setSubscribed(true) on the matching remote publication", () => {
    const tile = buildTile("user:1")
    const track = fakeTrack()
    tile._attach(track, { isLocal: false })

    const setCalls = []
    const pub = {
      track,
      setSubscribed(v) {
        setCalls.push(v)
      },
    }
    // Non-matching participant to prove the walk filters by identity.
    const otherPub = {
      track: fakeTrack(),
      setSubscribed() {
        throw new Error("must not be called on a different-identity pub")
      },
    }
    tile._room = {
      remoteParticipants: new Map([
        [
          "user:2",
          { identity: "user:2", trackPublications: new Map([["other", otherPub]]) },
        ],
        [
          "user:1",
          { identity: "user:1", trackPublications: new Map([["pub", pub]]) },
        ],
      ]),
    }

    tile._resizeKick()

    expect(setCalls).toEqual([false, true])
  })

  it("resize-kick is a no-op when no track is attached (initial mount resize)", () => {
    const tile = buildTile("user:1")
    const pub = {
      track: fakeTrack(),
      setSubscribed() {
        throw new Error("must not be called when no track is attached")
      },
    }
    tile._room = {
      remoteParticipants: new Map([
        ["user:1", { identity: "user:1", trackPublications: new Map([["pub", pub]]) }],
      ]),
    }

    // No _attach() call → _attachedTrack stays null.
    tile._resizeKick()
    // No throw + no assertion failure = pass.
  })

  it("resize-kick bails on a local-dock tile — MeetingClient owns the local video, we don't poke it", () => {
    const tile = buildTile("user:1")
    tile._localDock = true
    // Pretend we have an attached track even though local-dock tiles don't
    // actually attach — the guard should catch _localDock BEFORE the track
    // check, so the pub.setSubscribed must never fire.
    tile._attachedTrack = fakeTrack()

    const pub = {
      track: tile._attachedTrack,
      setSubscribed() {
        throw new Error("must not toggle subscription on a local-dock tile")
      },
    }
    tile._room = {
      remoteParticipants: new Map([
        ["user:1", { identity: "user:1", trackPublications: new Map([["pub", pub]]) }],
      ]),
    }

    tile._resizeKick()
    // No throw = pass.
  })

  it("resize-kick tolerates a publication with no setSubscribed method (older SDK / test fake)", () => {
    const tile = buildTile("user:1")
    const track = fakeTrack()
    tile._attach(track, { isLocal: false })

    // No setSubscribed on the pub — the walk must skip it, not throw.
    const pub = { track }
    tile._room = {
      remoteParticipants: new Map([
        ["user:1", { identity: "user:1", trackPublications: new Map([["pub", pub]]) }],
      ]),
    }

    tile._resizeKick()
    // No throw = pass.
  })
})
