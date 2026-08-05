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
    // Mirrors the real DOM property `_reconcile` reads to decide whether the
    // element is still mounted in its slot.
    parentNode: null,
    paused: false,
    remove() {
      this._removed = true
      if (this._parent) {
        const i = this._parent.children.indexOf(this)
        if (i >= 0) this._parent.children.splice(i, 1)
        this._parent = null
      }
      this.parentNode = null
    },
    play() {
      this.paused = false
      return Promise.resolve()
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
    // The hook now creates the <video> itself and passes it to attach(el)
    // (task 019f8153). Record the element it hands us; fall back to minting one
    // for any legacy zero-arg caller.
    attach(el) {
      const element = el || fakeVideoEl()
      this._attachedEls.push(element)
      return element
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
      child.parentNode = this
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
  tile._elementInfo = null
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
    // The hook now creates its own <video> via document.createElement (task
    // 019f8153). node has no DOM, so provide a minimal fake that returns the
    // same lightweight video stub the rest of the suite uses.
    globalThis.document = {
      createElement() {
        return fakeVideoEl()
      },
    }
  })

  afterEach(() => {
    delete globalThis.__livekit_room
    delete globalThis.document
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

  // ── Reconcile against LiveKit on updated() ────────────────────────────
  //
  // The bug: a meeting control (captions, mic) re-renders the tile with a
  // stale server `has_video="false"`; morphdom hides the slot, raises the
  // avatar over the live picture and drops the <video>, and NOTHING restores
  // it because LiveKit emitted no event. These cover the tile repairing
  // itself from real room state — and, critically, NOT repairing a tile whose
  // participant genuinely has no video.

  // Build a fake Room whose remote participant publishes `pubs`.
  function fakeRoom(identity, pubs) {
    const participant = { identity, isLocal: false }
    participant.trackPublications = new Map(
      pubs.map((p, i) => [String(i), p]),
    )
    return {
      localParticipant: { identity: "user:me", isLocal: true, trackPublications: new Map() },
      remoteParticipants: new Map([[identity, participant]]),
      _participant: participant,
    }
  }

  function livePub(track) {
    return { kind: "video", isMuted: false, track }
  }

  it("re-attaches when a re-render drops the <video> while LiveKit still has the track", () => {
    const tile = buildTile("user:remote")
    const track = fakeTrack()
    const room = fakeRoom("user:remote", [livePub(track)])
    tile._room = room

    tile._attach(track, room._participant)
    const firstEl = tile._videoEl
    expect(tile._slotRef.children.length).toBe(1)

    // Simulate the morphdom patch: <video> removed, slot hidden, avatar
    // raised over it, data-has-video stamped back to "false" — all WITHOUT
    // any LiveKit event.
    firstEl.remove()
    tile._slotRef.classList.add("hidden")
    tile._fallbackRef.classList.remove("hidden")
    tile.el.dataset.hasVideo = "false"

    tile._reconcile()

    // A live <video> is back in the slot and visible again.
    expect(tile._slotRef.children.length).toBe(1)
    expect(tile._videoEl).not.toBeNull()
    expect(tile._videoEl).not.toBe(firstEl)
    expect(tile._attachedTrack).toBe(track)
    expect(track._attachedEls).toContain(tile._videoEl)
    expect(tile._slotRef.classList.has("hidden")).toBe(false)
    expect(tile._fallbackRef.classList.has("hidden")).toBe(true)
    expect(tile.el.dataset.hasVideo).toBe("true")
  })

  it("re-reveals a surviving <video> that the stale render merely hid behind the avatar", () => {
    const tile = buildTile("user:remote")
    const track = fakeTrack()
    const room = fakeRoom("user:remote", [livePub(track)])
    tile._room = room

    tile._attach(track, room._participant)
    const el = tile._videoEl
    el.paused = true

    // phx-update="ignore" kept the node, but LiveView still merges the
    // server's class/attrs onto the ignored slot.
    tile._slotRef.classList.add("hidden")
    tile._fallbackRef.classList.remove("hidden")
    tile.el.dataset.hasVideo = "false"

    tile._reconcile()

    // Same element, no churn — just made visible and playing again.
    expect(tile._videoEl).toBe(el)
    expect(track.detachCalls).toEqual([])
    expect(tile._slotRef.classList.has("hidden")).toBe(false)
    expect(tile._fallbackRef.classList.has("hidden")).toBe(true)
    expect(tile.el.dataset.hasVideo).toBe("true")
    expect(el.paused).toBe(false)
  })

  // ── NEGATIVE CONTROL ──────────────────────────────────────────────────
  // The trivial wrong fix is "never hide the video slot". These two prove
  // the tile still falls back to the avatar when there really is no video.

  it("NEGATIVE CONTROL: an audio-only participant keeps the avatar fallback", () => {
    const tile = buildTile("user:remote")
    const audioTrack = fakeTrack("audio")
    const room = fakeRoom("user:remote", [
      { kind: "audio", isMuted: false, track: audioTrack },
    ])
    tile._room = room

    // Server rendered the avatar. Reconcile must leave it alone.
    expect(tile._slotRef.classList.has("hidden")).toBe(true)
    expect(tile._fallbackRef.classList.has("hidden")).toBe(false)

    tile._reconcile()

    expect(tile._findLiveVideo()).toBeNull()
    expect(tile._attachedTrack).toBeNull()
    expect(tile._videoEl).toBeNull()
    expect(tile._slotRef.children.length).toBe(0)
    expect(tile._slotRef.classList.has("hidden")).toBe(true)
    expect(tile._fallbackRef.classList.has("hidden")).toBe(false)
    expect(tile.el.dataset.hasVideo).toBe("false")
  })

  it("NEGATIVE CONTROL: a camera-off participant (muted publication) shows the avatar, not an empty video", () => {
    const tile = buildTile("user:remote")
    const track = fakeTrack()
    // livekit-client v2 camera-off = publication MUTED and still subscribed,
    // so `pub.track` is present. Reading `pub.track` alone would wrongly show
    // an empty <video>; the mute check is what keeps the avatar up.
    const pub = { kind: "video", isMuted: true, track }
    const room = fakeRoom("user:remote", [pub])
    tile._room = room

    // Nothing attaches on mount…
    tile._syncExistingTrack()
    expect(tile._attachedTrack).toBeNull()

    // …and reconcile agrees.
    tile._reconcile()
    expect(tile._findLiveVideo()).toBeNull()
    expect(tile._videoEl).toBeNull()
    expect(tile._slotRef.classList.has("hidden")).toBe(true)
    expect(tile._fallbackRef.classList.has("hidden")).toBe(false)
    expect(tile.el.dataset.hasVideo).toBe("false")

    // Camera comes back on → trackUnmuted → video appears.
    pub.isMuted = false
    tile._onMuteChanged(pub, room._participant)
    expect(tile._attachedTrack).toBe(track)
    expect(tile._slotRef.classList.has("hidden")).toBe(false)
    expect(tile._fallbackRef.classList.has("hidden")).toBe(true)

    // …and off again → back to the avatar, with a single-element detach.
    pub.isMuted = true
    tile._onMuteChanged(pub, room._participant)
    expect(tile._attachedTrack).toBeNull()
    expect(tile._videoEl).toBeNull()
    expect(track.detachCalls).not.toContain(null)
    expect(tile._slotRef.classList.has("hidden")).toBe(true)
    expect(tile._fallbackRef.classList.has("hidden")).toBe(false)
  })

  it("NEGATIVE CONTROL: a participant whose MediaStreamTrack has ended shows the avatar", () => {
    const tile = buildTile("user:remote")
    const track = fakeTrack()
    track.mediaStreamTrack = { readyState: "ended" }
    const room = fakeRoom("user:remote", [livePub(track)])
    tile._room = room

    tile._reconcile()

    expect(tile._findLiveVideo()).toBeNull()
    expect(tile._videoEl).toBeNull()
    expect(tile._fallbackRef.classList.has("hidden")).toBe(false)
  })

  it("does NOT tear down a live attachment when the room cannot see the participant", () => {
    // Mid-reconnect / not-yet-populated room. Reconcile must not be the thing
    // that kills a working video — teardown belongs to trackUnsubscribed.
    const tile = buildTile("user:remote")
    const track = fakeTrack()
    const room = fakeRoom("user:remote", [livePub(track)])
    tile._room = room
    tile._attach(track, room._participant)
    const el = tile._videoEl

    room.remoteParticipants = new Map()
    tile._reconcile()

    expect(tile._attachedTrack).toBe(track)
    expect(tile._videoEl).toBe(el)
    expect(track.detachCalls).toEqual([])
  })

  it("reconcile is a no-op on a local-dock tile (MeetingClient owns that <video>)", () => {
    const tile = buildTile("user:me")
    tile._localDock = true
    const track = fakeTrack()
    tile._room = fakeRoom("user:me", [livePub(track)])

    tile._reconcile()

    expect(tile._attachedTrack).toBeNull()
    expect(tile._videoEl).toBeNull()
    expect(tile._slotRef.children.length).toBe(0)
    expect(track._attachedEls.length).toBe(0)
  })

  it("swaps to a NEW track object when LiveKit republished under the same identity", () => {
    const tile = buildTile("user:remote")
    const oldTrack = fakeTrack()
    const newTrack = fakeTrack()
    const room = fakeRoom("user:remote", [livePub(oldTrack)])
    tile._room = room

    tile._attach(oldTrack, room._participant)
    const oldEl = tile._videoEl

    room._participant.trackPublications = new Map([["0", livePub(newTrack)]])
    tile._reconcile()

    expect(tile._attachedTrack).toBe(newTrack)
    expect(oldTrack.detachCalls).toEqual([oldEl])
    expect(newTrack._attachedEls).toContain(tile._videoEl)
  })

  // NOTE: the adaptive-stream resize-kick (`_resizeKick` and friends, PR #519)
  // was removed in task 019f8153 in favor of the StableTileElementInfo custom
  // ElementInfo, which prevents the false-negative pause at the source. Those
  // tests were deleted with the mechanism. The custom-ElementInfo behavior is
  // covered by test/hooks/meeting_video_tile_adaptive.test.js (added stage 2).
})
