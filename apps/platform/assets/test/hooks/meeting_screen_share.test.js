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
