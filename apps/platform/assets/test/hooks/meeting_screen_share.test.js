import { describe, it, expect, beforeEach, afterEach } from "vitest"
import MeetingScreenShare from "../../js/hooks/meeting_screen_share.js"

/**
 * Tests for the `MeetingScreenShare` hook — the `/meetings` center-stage
 * Screen-mode renderer that attaches the active LiveKit screen-share track
 * into `[data-screen-share-slot]`.
 *
 * Screen-share-not-displaying fix: the LOCAL sharer's track is published via
 * `localTrackPublished` (not `trackSubscribed`), so the hook must route a
 * local screen-share into the slot too — otherwise the sharer sees nothing.
 * And once attached, the JS-owned <video> must SURVIVE an LV patch (the slot
 * carries `phx-update="ignore"` in the markup, but the hook's `updated()`
 * re-sync must not double-attach or drop a still-live track).
 *
 * The hook runs in the default vitest `node` env (no jsdom), so we build a
 * minimal fake `el` (the `#meeting-screen-stage` div) holding the slot +
 * empty-state placeholder, plus a fake LiveKit room. The fake track records
 * attach/detach so the load-bearing invariant — the live track is never
 * detached on a mere re-render — is assertable.
 */

// ── Fakes ────────────────────────────────────────────────────────────────

function fakeNode(attrs = {}) {
  const node = {
    dataset: { ...attrs },
    classList: {
      _set: new Set(),
      add(c) {
        this._set.add(c)
      },
      remove(c) {
        this._set.delete(c)
      },
      contains(c) {
        return this._set.has(c)
      },
    },
    children: [],
    parentElement: null,
    _selectorTag: null,
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
    querySelector(sel) {
      if (sel === "[data-screen-share-slot]") return this._slot || null
      if (sel === "[data-screen-share-empty]") return this._empty || null
      return null
    },
  }
  return node
}

function fakeTrack(source = "screen_share") {
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

function fakeParticipant({ identity = "user:abc", name = "Ada", isLocal = false } = {}) {
  return {
    identity,
    name,
    isLocal,
    trackPublications: new Map(),
  }
}

function fakeRoom() {
  const handlers = new Map()
  return {
    localParticipant: fakeParticipant({ identity: "user:local", isLocal: true }),
    remoteParticipants: new Map(),
    on(event, cb) {
      const list = handlers.get(event) || []
      list.push(cb)
      handlers.set(event, list)
    },
    off(event, cb) {
      const list = handlers.get(event) || []
      handlers.set(
        event,
        list.filter((h) => h !== cb),
      )
    },
    emit(event, ...args) {
      ;(handlers.get(event) || []).forEach((cb) => cb(...args))
    },
  }
}

// Build the hook's `el` (#meeting-screen-stage) with the slot + placeholder.
function buildStage() {
  const stage = fakeNode({ screenShareActive: "false" })
  const slot = fakeNode()
  slot.classList.add("hidden")
  const empty = fakeNode()
  stage._slot = slot
  stage._empty = empty
  return stage
}

function buildHook(el) {
  const hook = Object.create(MeetingScreenShare)
  hook.el = el
  return hook
}

describe("MeetingScreenShare — local + remote screen-share attach", () => {
  let priorWindow

  beforeEach(() => {
    globalThis.console = globalThis.console || { warn() {}, info() {} }
    priorWindow = globalThis.window
    globalThis.window = { __livekit_room: null, __livekitRoom: null }
    globalThis.document = {
      addEventListener() {},
      removeEventListener() {},
    }
  })

  afterEach(() => {
    globalThis.window = priorWindow
    delete globalThis.document
  })

  it("attaches the LOCAL sharer's screen-share into the slot on localTrackPublished", () => {
    // The whole bug: the sharer's OWN track arrives via localTrackPublished,
    // not trackSubscribed. If the hook only handled remote subscriptions the
    // sharer would publish into the void and see nothing rendered.
    const room = fakeRoom()
    globalThis.window.__livekit_room = room
    const stage = buildStage()
    const hook = buildHook(stage)

    hook.mounted()

    const track = fakeTrack("screen_share")
    room.emit("localTrackPublished", { track, source: "screen_share" })

    // The <video> landed in the slot, the slot is shown, the empty-state hid.
    expect(track.attachCalls).toBe(1)
    expect(stage._slot.children.length).toBe(1)
    expect(stage._slot.classList.contains("hidden")).toBe(false)
    expect(stage._empty.classList.contains("hidden")).toBe(true)
    expect(stage.dataset.screenShareActive).toBe("true")
  })

  it("attaches a REMOTE screen-share via trackSubscribed", () => {
    const room = fakeRoom()
    globalThis.window.__livekit_room = room
    const stage = buildStage()
    const hook = buildHook(stage)
    hook.mounted()

    const track = fakeTrack("screen_share")
    const peer = fakeParticipant({ identity: "user:peer", name: "Grace" })
    room.emit("trackSubscribed", track, { source: "screen_share" }, peer)

    expect(track.attachCalls).toBe(1)
    expect(stage._slot.children.length).toBe(1)
    expect(stage.dataset.screenShareSharer).toBe("user:peer")
  })

  it("ignores camera/mic publications — only screen_share lands in the slot", () => {
    const room = fakeRoom()
    globalThis.window.__livekit_room = room
    const stage = buildStage()
    const hook = buildHook(stage)
    hook.mounted()

    const cam = fakeTrack("camera")
    room.emit("localTrackPublished", { track: cam, source: "camera" })

    expect(cam.attachCalls).toBe(0)
    expect(stage._slot.children.length).toBe(0)
    expect(stage._slot.classList.contains("hidden")).toBe(true)
  })

  it("syncs an ALREADY-published local share when mounting into Screen mode", () => {
    // Switching INTO Screen mode after starting the share: the track is
    // already published, so mounted()→_tryBind→_syncExistingTrack must find
    // and attach it (covers the auto-switch-to-screen server fix landing the
    // user in Screen mode with the share already live).
    const room = fakeRoom()
    const track = fakeTrack("screen_share")
    room.localParticipant.trackPublications.set("sid", {
      track,
      source: "screen_share",
    })
    globalThis.window.__livekit_room = room
    const stage = buildStage()
    const hook = buildHook(stage)

    hook.mounted()

    expect(track.attachCalls).toBe(1)
    expect(stage._slot.children.length).toBe(1)
    expect(stage.dataset.screenShareActive).toBe("true")
  })

  it("updated() (LV patch) does NOT detach or re-attach a still-live share", () => {
    // The slot carries phx-update="ignore" so morphdom keeps the <video>;
    // the hook's updated() re-sync must be idempotent — it must not detach the
    // live track or stack a duplicate <video> on every LV re-render.
    const room = fakeRoom()
    globalThis.window.__livekit_room = room
    const stage = buildStage()
    const hook = buildHook(stage)
    hook.mounted()

    const track = fakeTrack("screen_share")
    room.emit("localTrackPublished", { track, source: "screen_share" })
    expect(track.attachCalls).toBe(1)

    // Simulate several LV patches.
    hook.updated()
    hook.updated()

    // Still exactly one attach, zero detaches — the live track is untouched.
    expect(track.attachCalls).toBe(1)
    expect(track.detachCalls).toBe(0)
    expect(stage._slot.children.length).toBe(1)
    expect(stage.dataset.screenShareActive).toBe("true")
  })

  it("detaches and restores the empty state when the share ends", () => {
    const room = fakeRoom()
    globalThis.window.__livekit_room = room
    const stage = buildStage()
    const hook = buildHook(stage)
    hook.mounted()

    const track = fakeTrack("screen_share")
    room.emit("localTrackPublished", { track, source: "screen_share" })
    room.emit("localTrackUnpublished", { track, source: "screen_share" })

    expect(track.detachCalls).toBe(1)
    expect(stage._slot.classList.contains("hidden")).toBe(true)
    expect(stage._empty.classList.contains("hidden")).toBe(false)
    expect(stage.dataset.screenShareActive).toBe("false")
  })
})

// ── Task 01a13ca2 stage 5: the sharer by NAME, surviving LiveView patches ──
//
// The behavioural review found that on /meetings no surface named the
// sharer: every LiveView patch reset the root's data-screen-share-active to
// "false", removed data-screen-share-sharer and put the "No active
// screen-share" placeholder back over the live video. The root is now
// phx-update="ignore" (children are the hook's), and `updated()` re-stamps
// the root's data attributes, which LiveView still copies from the template.

function buildNamedStage() {
  const stage = buildStage()
  const label = fakeNode()
  label.hidden = true
  const name = fakeNode()
  name.textContent = ""
  stage._label = label
  stage._name = name
  stage._button = { hidden: true, addEventListener() {}, removeEventListener() {}, setAttribute() {}, dataset: {} }
  stage.querySelector = (sel) => {
    if (sel === "[data-screen-share-slot]") return stage._slot
    if (sel === "[data-screen-share-empty]") return stage._empty
    if (sel === "[data-screen-share-sharer-label]") return stage._label
    if (sel === "[data-screen-share-sharer-name]") return stage._name
    if (sel === "[data-screen-share-fullscreen]") return stage._button
    return null
  }
  return stage
}

// What a LiveView patch does to the ignored root: the template's data-*
// are copied back ("false"), and data-* the template lacks are removed.
// The children are untouched (phx-update="ignore").
function lvPatchRoot(stage) {
  stage.dataset = { screenShareActive: "false" }
}

describe("MeetingScreenShare — the sharer's name (task 01a13ca2 stage 5)", () => {
  let priorWindow

  beforeEach(() => {
    globalThis.console = globalThis.console || { warn() {}, info() {} }
    priorWindow = globalThis.window
    globalThis.window = { __livekit_room: null, __livekitRoom: null }
    globalThis.document = { addEventListener() {}, removeEventListener() {} }
  })

  afterEach(() => {
    globalThis.window = priorWindow
    delete globalThis.document
  })

  function mountWithShare(peer, { room = fakeRoom() } = {}) {
    globalThis.window.__livekit_room = room
    const stage = buildNamedStage()
    const hook = buildHook(stage)
    hook.mounted()
    const track = fakeTrack("screen_share")
    room.emit("trackSubscribed", track, { source: "screen_share" }, peer)
    return { stage, hook, room, track }
  }

  it("names the sharer and hides the placeholder on the attach path", () => {
    const { stage } = mountWithShare(fakeParticipant({ identity: "user:W", name: "Wes" }))

    expect(stage._name.textContent).toBe("Wes")
    expect(stage._label.hidden).toBe(false)
    expect(stage._empty.classList.contains("hidden")).toBe(true)
    expect(stage.dataset.screenShareActive).toBe("true")
    expect(stage.dataset.screenShareSharer).toBe("user:W")
  })

  it("a LiveView patch does not un-name the share or bring the placeholder back", () => {
    const { stage, hook, track } = mountWithShare(
      fakeParticipant({ identity: "user:W", name: "Wes" }),
    )

    for (let i = 0; i < 3; i++) {
      lvPatchRoot(stage)
      hook.updated()

      expect(stage.dataset.screenShareActive).toBe("true")
      expect(stage.dataset.screenShareSharer).toBe("user:W")
      expect(stage._name.textContent).toBe("Wes")
      expect(stage._label.hidden).toBe(false)
      expect(stage._empty.classList.contains("hidden")).toBe(true)
      expect(stage._slot.classList.contains("hidden")).toBe(false)
    }
    expect(track.attachCalls).toBe(1)
    expect(track.detachCalls).toBe(0)
  })

  it("a share by a nameless video:user:X is labelled with X's person name, never video:", () => {
    const room = fakeRoom()
    room.remoteParticipants.set("user:X", fakeParticipant({ identity: "user:X", name: "Xavier" }))
    const companion = fakeParticipant({ identity: "video:user:X", name: "" })
    room.remoteParticipants.set("video:user:X", companion)

    const { stage, hook } = mountWithShare(companion, { room })
    lvPatchRoot(stage)
    hook.updated()

    expect(stage._name.textContent).toBe("Xavier")
    expect(stage.dataset.screenShareSharer).toBe("user:X")
    expect(JSON.stringify(stage.dataset) + stage._name.textContent).not.toContain("video:")
  })

  it("falls back to the server's name map on #meeting-client", () => {
    globalThis.document.getElementById = (id) =>
      id === "meeting-client"
        ? { dataset: { participantNames: JSON.stringify({ "user:X": "Xavier" }) } }
        : null
    const { stage } = mountWithShare(fakeParticipant({ identity: "video:user:X", name: "" }))

    expect(stage._name.textContent).toBe("Xavier")
  })

  it("the share ending empties and hides the label, and a later patch keeps it hidden", () => {
    const { stage, hook, room, track } = mountWithShare(
      fakeParticipant({ identity: "user:W", name: "Wes" }),
    )
    room.emit("trackUnsubscribed", track, { source: "screen_share" }, null)
    lvPatchRoot(stage)
    hook.updated()

    expect(stage._name.textContent).toBe("")
    expect(stage._label.hidden).toBe(true)
    expect(stage._empty.classList.contains("hidden")).toBe(false)
    expect(stage.dataset.screenShareActive).toBe("false")
    expect(stage.dataset.screenShareSharer).toBeUndefined()
  })
})

// ── Task 01a13ca2: the share ENDING must clear the stage (stage-5 regression) ──
//
// Stage 5 made #meeting-screen-stage phx-update="ignore", so a LiveView patch
// no longer puts the "No active screen-share" placeholder back. The review
// re-run at 45dd90786 saw "Dev Wes is sharing" stay over a black frame after
// W stopped: the hook only released the share on `trackUnsubscribed` with an
// exact track match. These cases end the share by the OTHER routes LiveKit
// uses and assert the whole cleared state.

describe("MeetingScreenShare — share-end teardown (task 01a13ca2 regression)", () => {
  let priorWindow

  beforeEach(() => {
    globalThis.console = globalThis.console || { warn() {}, info() {} }
    priorWindow = globalThis.window
    globalThis.window = { __livekit_room: null, __livekitRoom: null }
    globalThis.document = { addEventListener() {}, removeEventListener() {} }
  })

  afterEach(() => {
    globalThis.window = priorWindow
    delete globalThis.document
  })

  function emitterTrack() {
    const track = fakeTrack("screen_share")
    const handlers = new Map()
    track.sid = "TR_share"
    track.mediaStreamTrack = { readyState: "live" }
    track.on = (ev, cb) => handlers.set(ev, [...(handlers.get(ev) || []), cb])
    track.off = (ev, cb) => handlers.set(ev, (handlers.get(ev) || []).filter((h) => h !== cb))
    track.fire = (ev) => (handlers.get(ev) || []).forEach((cb) => cb(track))
    return track
  }

  // W shares: the publication lives on W, as in LiveKit, with a trackSid.
  function startShare() {
    const room = fakeRoom()
    globalThis.window.__livekit_room = room
    const peer = fakeParticipant({ identity: "user:W", name: "Dev Wes" })
    room.remoteParticipants.set(peer.identity, peer)
    const stage = buildNamedStage()
    const hook = buildHook(stage)
    hook.mounted()
    const track = emitterTrack()
    const pub = { trackSid: "TR_share", source: "screen_share", kind: "video", track }
    peer.trackPublications.set(pub.trackSid, pub)
    room.emit("trackSubscribed", track, pub, peer)
    // Sanity: the share is on screen and named.
    expect(stage.dataset.screenShareActive).toBe("true")
    expect(stage._name.textContent).toBe("Dev Wes")
    stage._button.hidden = false
    return { room, peer, stage, hook, track, pub }
  }

  function expectCleared(stage, track) {
    expect(stage.dataset.screenShareActive).toBe("false")
    expect(stage.dataset.screenShareSharer).toBeUndefined()
    expect(stage._name.textContent).toBe("")
    expect(stage._label.hidden).toBe(true)
    expect(stage._empty.classList.contains("hidden")).toBe(false)
    expect(stage._slot.classList.contains("hidden")).toBe(true)
    expect(stage._slot.children.length).toBe(0)
    expect(stage._button.hidden).toBe(true)
    expect(track.detachCalls).toBe(1)
  }

  // LiveKit's RemoteParticipant.unpublishTrack: clear pub.track, drop the
  // publication from the participant, then emit TrackUnpublished.
  function unpublish(room, peer, pub) {
    pub.track = undefined
    peer.trackPublications.delete(pub.trackSid)
    room.emit("trackUnpublished", pub, peer)
  }

  it("share starts then is UNPUBLISHED with no trackUnsubscribed: placeholder back, no label, inactive", () => {
    const { room, peer, stage, track, pub } = startShare()
    unpublish(room, peer, pub)
    expectCleared(stage, track)
  })

  it("trackUnpublished matches by trackSid when it carries a different publication object", () => {
    const { room, peer, stage, track } = startShare()
    peer.trackPublications.delete("TR_share")
    room.emit("trackUnpublished", { trackSid: "TR_share", source: "screen_share" }, peer)
    expectCleared(stage, track)
  })

  it("the sharer DISCONNECTS mid-share: same cleared state", () => {
    const { room, peer, stage, track } = startShare()
    room.remoteParticipants.delete(peer.identity)
    room.emit("participantDisconnected", peer)
    expectCleared(stage, track)
  })

  it("the share track fires `ended`: same cleared state", () => {
    const { stage, track } = startShare()
    track.mediaStreamTrack.readyState = "ended"
    track.fire("ended")
    expectCleared(stage, track)
  })

  it("after the share ends, LiveView updated() does not resurrect the label", () => {
    const { room, peer, stage, hook, track, pub } = startShare()
    unpublish(room, peer, pub)
    for (let i = 0; i < 3; i++) {
      lvPatchRoot(stage)
      hook.updated()
      expectCleared(stage, track)
    }
    expect(track.attachCalls).toBe(1)
  })

  it("updated() drops a share the room already let go of, even if no event reached the hook", () => {
    const { peer, stage, hook, track, pub } = startShare()
    // The events were missed: the publication is simply gone from W.
    pub.track = undefined
    peer.trackPublications.delete(pub.trackSid)
    lvPatchRoot(stage)
    hook.updated()
    expectCleared(stage, track)
  })

  it("a different track ending leaves the live share alone", () => {
    const { room, peer, stage, track } = startShare()
    room.emit("trackUnpublished", { trackSid: "TR_other", source: "camera" }, peer)
    room.emit("participantDisconnected", fakeParticipant({ identity: "user:Z", name: "Zed" }))
    expect(stage.dataset.screenShareActive).toBe("true")
    expect(stage._name.textContent).toBe("Dev Wes")
    expect(track.detachCalls).toBe(0)
  })
})
