import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { RoomEvent, Track } from "livekit-client"
import MeetingClient from "../../js/hooks/meeting_client.js"

// `_join`'s fresh-connect path constructs `new Room(...)`, so the only way
// to test it is to swap that ONE export (RoomEvent / Track stay real —
// every assertion below is keyed on the real event names). `connect()`
// installs whoever `livekitFake.joinRoster` declares, which is how a real
// join response delivers the people already sitting in the call: they are
// never announced as `ParticipantConnected`.
const livekitFake = vi.hoisted(() => ({ joinRoster: [] }))

vi.mock("livekit-client", async (importOriginal) => {
  const actual = await importOriginal()
  class Room {
    constructor() {
      this.name = "space-room"
      this.state = "disconnected"
      this.emitted = []
      this._handlers = new Map()
      this.remoteParticipants = new Map()
      this.localParticipant = {
        identity: "user:me",
        isLocal: true,
        isCameraEnabled: false,
        isMicrophoneEnabled: false,
        trackPublications: new Map(),
        setCameraEnabled() {
          return Promise.resolve()
        },
        setMicrophoneEnabled() {
          return Promise.resolve()
        },
      }
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
    emit(event, ...args) {
      this.emitted.push(event)
      for (const cb of this._handlers.get(event) || []) cb(...args)
      return true
    }
    connect() {
      this.state = "connected"
      for (const p of livekitFake.joinRoster) this.remoteParticipants.set(p.identity, p)
      return Promise.resolve()
    }
    disconnect() {
      this.state = "disconnected"
      return Promise.resolve()
    }
  }
  return { ...actual, Room }
})

/**
 * Remote per-identity media state (task 01a0740c stage 1).
 *
 * Before this, a meeting tile could not show whether someone had muted
 * themselves. The gallery binding was `audio_muted?={false}` — hardcoded,
 * so nobody was ever muted — and the bottom strip read
 * `attention_config["mic_on"]`, a key NOTHING in the app writes, so it
 * rendered every human as muted, permanently. Neither number had ever
 * been near LiveKit.
 *
 * These tests drive `_bindRoomEvents` and fire the real `RoomEvent`s,
 * because the claim is about which handler is bound to what: the new
 * remote path must see a REMOTE participant (a unit test calling
 * `_pushMediaStates` directly would pass with the handler unbound, or
 * bound behind a local-identity guard), and `onLocalMuteChanged` must
 * stay untouched by remote traffic.
 */

// A LiveKit-shaped track publication. `isMuted` is the publication-level
// flag the SDK flips on a remote `setMicrophoneEnabled(false)`.
function pub(kind, { muted = false, source = null } = {}) {
  return { kind, source, isMuted: muted }
}

function remote(identity, publications) {
  return {
    identity,
    trackPublications: new Map(publications.map((p, i) => [`sid-${i}`, p])),
  }
}

function fakeRoom(remotes) {
  const handlers = new Map()
  return {
    localParticipant: { identity: "user:me" },
    remoteParticipants: new Map(remotes.map((p) => [p.identity, p])),
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
      for (const cb of handlers.get(event) || []) cb(...args)
    },
  }
}

function buildHook() {
  const hook = Object.create(MeetingClient)
  hook._boundRoom = null
  hook._roomListeners = []
  hook._lastMediaStatesKey = null
  hook.pushed = []
  hook.pushEvent = (event, payload) => hook.pushed.push([event, payload])
  // Stubbed so a stray call is COUNTED rather than exploding on the
  // absent `document` — the count is the assertion in the guard test
  // below, and a throw would read as a different failure.
  hook.localReconciles = 0
  hook._reconcileLocalVideo = () => {
    hook.localReconciles += 1
  }
  return hook
}

const AUDIO = Track.Kind.Audio
const VIDEO = Track.Kind.Video

describe("MeetingClient — remote media states", () => {
  it("pushes a REMOTE participant's mute; an unmuted remote is in neither list", () => {
    const alice = remote("user:alice", [
      pub(AUDIO, { muted: true }),
      pub(VIDEO, { muted: false }),
    ])
    const bob = remote("user:bob", [
      pub(AUDIO, { muted: false }),
      pub(VIDEO, { muted: false }),
    ])
    const room = fakeRoom([alice, bob])
    const hook = buildHook()

    hook._bindRoomEvents(room)

    // DIRECTION CONTROL: binding alone pushes nothing. Without this the
    // assertion below could pass on a push that had already happened for
    // reasons unrelated to the event.
    expect(hook.pushed).toEqual([])

    // The SDK hands the handler `(publication, participant)`. This is a
    // REMOTE participant — the case the old code could not see.
    room.emit(RoomEvent.TrackMuted, pub(AUDIO, { muted: true }), alice)

    expect(hook.pushed).toEqual([
      ["media_states", { muted: ["user:alice"], camera_off: [] }],
    ])
  })

  it("does NOT re-run local self-view reconciliation for a remote mute", () => {
    // `onLocalMuteChanged` owns `_reconcileLocalVideo`, which swaps the
    // LOCAL self-view between live video and the avatar fallback. If the
    // remote path were ever folded into it (or its identity guard
    // widened), every remote mute would re-run local reconciliation and
    // the viewer's OWN video would flicker when somebody else muted.
    const alice = remote("user:alice", [pub(AUDIO, { muted: true })])
    const room = fakeRoom([alice])
    const hook = buildHook()

    hook._bindRoomEvents(room)
    room.emit(RoomEvent.TrackMuted, pub(AUDIO, { muted: true }), alice)
    room.emit(RoomEvent.TrackUnmuted, pub(AUDIO, { muted: false }), alice)

    expect(hook.localReconciles).toBe(0)
    // …and the remote traffic still landed, so this is not a test that
    // passes because nothing ran at all.
    expect(hook.pushed.length).toBeGreaterThan(0)
  })

  it("unmuting removes the identity again", () => {
    const alice = remote("user:alice", [
      pub(AUDIO, { muted: true }),
      pub(VIDEO, { muted: false }),
    ])
    const room = fakeRoom([alice])
    const hook = buildHook()
    hook._bindRoomEvents(room)

    room.emit(RoomEvent.TrackMuted, pub(AUDIO, { muted: true }), alice)
    expect(hook.pushed.at(-1)[1].muted).toEqual(["user:alice"])

    // The SDK mutates the publication in place before firing.
    alice.trackPublications.get("sid-0").isMuted = false
    room.emit(RoomEvent.TrackUnmuted, pub(AUDIO, { muted: false }), alice)

    expect(hook.pushed.at(-1)[1].muted).toEqual([])
  })

  it("reports a camera-off remote without putting them in `muted`", () => {
    const alice = remote("user:alice", [
      pub(AUDIO, { muted: false }),
      pub(VIDEO, { muted: true }),
    ])
    const room = fakeRoom([alice])
    const hook = buildHook()
    hook._bindRoomEvents(room)

    room.emit(RoomEvent.TrackMuted, pub(VIDEO, { muted: true }), alice)

    expect(hook.pushed.at(-1)[1]).toEqual({
      muted: [],
      camera_off: ["user:alice"],
    })
  })

  it("a stopped screen share does not read as the camera going off", () => {
    // Screen share FIRST in publication order, so a path that took the
    // first video publication it saw would answer with the share.
    const alice = remote("user:alice", [
      pub(VIDEO, { muted: true, source: Track.Source.ScreenShare }),
      pub(AUDIO, { muted: false }),
      pub(VIDEO, { muted: false, source: Track.Source.Camera }),
    ])
    const room = fakeRoom([alice])
    const hook = buildHook()
    hook._bindRoomEvents(room)

    room.emit(
      RoomEvent.TrackMuted,
      pub(VIDEO, { muted: true, source: Track.Source.ScreenShare }),
      alice,
    )

    expect(hook.pushed.at(-1)[1]).toEqual({ muted: [], camera_off: [] })
  })

  it("a participant publishing nothing reads as muted and camera-off", () => {
    const ghost = remote("user:ghost", [])
    const room = fakeRoom([ghost])
    const hook = buildHook()
    hook._bindRoomEvents(room)

    room.emit(RoomEvent.TrackMuted, pub(AUDIO, { muted: true }), ghost)

    expect(hook.pushed.at(-1)[1]).toEqual({
      muted: ["user:ghost"],
      camera_off: ["user:ghost"],
    })
  })

  it("drops a push that would repeat the last one", () => {
    // TrackMuted fires once PER PUBLICATION, so muting mic and camera
    // together is two events for one visible change.
    const alice = remote("user:alice", [
      pub(AUDIO, { muted: true }),
      pub(VIDEO, { muted: true }),
    ])
    const room = fakeRoom([alice])
    const hook = buildHook()
    hook._bindRoomEvents(room)

    room.emit(RoomEvent.TrackMuted, pub(AUDIO, { muted: true }), alice)
    room.emit(RoomEvent.TrackMuted, pub(VIDEO, { muted: true }), alice)
    room.emit(RoomEvent.TrackMuted, pub(AUDIO, { muted: true }), alice)

    expect(hook.pushed).toHaveLength(1)
    expect(hook.pushed[0][1]).toEqual({
      muted: ["user:alice"],
      camera_off: ["user:alice"],
    })
  })
})

/**
 * Media state at JOIN (task 01a0740c stage 2).
 *
 * `RoomEvent.TrackMuted` / `TrackUnmuted` fire on a TRANSITION. A
 * participant who muted BEFORE this client subscribed fires neither, so
 * the stage-1 handler — bound to those two events and nothing else —
 * renders them unmuted indefinitely. That is the bug in the ticket: you
 * join a call, somebody is already muted, and their tile lies to you.
 *
 * The bug is invisible in any test where the remote toggles DURING the
 * test, which is every test above this line. So nothing below emits a
 * `TrackMuted` or `TrackUnmuted` at all, and each test asserts the room
 * emitted only the events it names. Delete the sweep and they go red;
 * that is the whole point of them.
 */

// Same fake Room as above plus an `emitted` log, so a test can PROVE no
// mute event was in play rather than just declining to send one.
function sweepRoom(remotes) {
  const handlers = new Map()
  return {
    name: "space-room",
    state: "connected",
    emitted: [],
    localParticipant: {
      identity: "user:me",
      isLocal: true,
      isCameraEnabled: false,
      isMicrophoneEnabled: false,
      trackPublications: new Map(),
      setCameraEnabled() {
        return Promise.resolve()
      },
      setMicrophoneEnabled() {
        return Promise.resolve()
      },
    },
    remoteParticipants: new Map(remotes.map((p) => [p.identity, p])),
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
      this.emitted.push(event)
      for (const cb of handlers.get(event) || []) cb(...args)
    },
  }
}

// A hook wired for the join paths. `_ensureTile` and `_attachTrack` are
// COUNTED rather than stubbed away: stage 2 chains onto the two handlers
// that call them, and "the existing handler still runs" is one of the
// claims here, not an incidental detail.
function buildJoinHook() {
  const hook = Object.create(MeetingClient)
  hook._tiles = new Map()
  hook._localVideoEl = null
  hook._localVideoTrack = null
  hook._boundRoom = null
  hook._roomListeners = []
  hook._lastMediaStatesKey = null
  hook.el = { dataset: {} }
  hook.pushed = []
  hook.pushEvent = (event, payload) => hook.pushed.push([event, payload])
  hook.tiled = []
  hook._ensureTile = (p) => hook.tiled.push(p && p.identity)
  hook.attached = []
  hook._attachTrack = (track, p) => hook.attached.push([track, p && p.identity])
  return hook
}

function mediaPushes(hook) {
  return hook.pushed.filter(([event]) => event === "media_states")
}

// Somebody who is muted and camera-off and has been since before we
// arrived. Sources are set so the screen-share filter has something real
// to discriminate against.
function alreadyDark(identity) {
  return remote(identity, [
    pub(AUDIO, { muted: true, source: Track.Source.Microphone }),
    pub(VIDEO, { muted: true, source: Track.Source.Camera }),
  ])
}

describe("MeetingClient — media state at join", () => {
  let priorWindow
  let priorDocument

  beforeEach(() => {
    globalThis.console = globalThis.console || { warn() {}, error() {}, info() {} }
    if (!globalThis.console.info) globalThis.console.info = () => {}
    priorDocument = globalThis.document
    priorWindow = globalThis.window
    globalThis.document = {
      createElement: () => ({ dataset: {}, appendChild() {}, style: {} }),
      querySelector: () => null,
      querySelectorAll: () => [],
      getElementById: () => null,
      addEventListener() {},
      removeEventListener() {},
      dispatchEvent: () => true,
    }
    globalThis.window = {
      __livekit_room: null,
      __livekitRoom: null,
      addEventListener() {},
      removeEventListener() {},
      dispatchEvent: () => true,
      matchMedia: () => ({ matches: true, addEventListener() {}, removeEventListener() {} }),
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
    globalThis.document = priorDocument
    globalThis.window = priorWindow
  })

  // THE test. Nothing transitions; there is no mute event in existence for
  // a handler to hear. The only thing that can produce this push is a
  // sweep of the room at connect.
  it("reports a participant who was ALREADY muted and camera-off before we connected", () => {
    const room = sweepRoom([alreadyDark("user:bob")])
    const hook = buildJoinHook()

    hook._adoptRoom(room)

    expect(room.emitted).toEqual([])
    expect(mediaPushes(hook)).toHaveLength(1)
    expect(mediaPushes(hook)[0][1]).toEqual({
      muted: ["user:bob"],
      camera_off: ["user:bob"],
    })
  })

  // The sweep is a sweep, not a "first remote wins": a room we walk into
  // mid-call has a mix, and every identity has to be classified.
  it("classifies every remote in the room at connect, not just the first", () => {
    const room = sweepRoom([
      alreadyDark("user:bob"),
      remote("user:carol", [
        pub(AUDIO, { muted: false, source: Track.Source.Microphone }),
        pub(VIDEO, { muted: true, source: Track.Source.Camera }),
      ]),
      remote("user:dave", [
        pub(AUDIO, { muted: false, source: Track.Source.Microphone }),
        pub(VIDEO, { muted: false, source: Track.Source.Camera }),
      ]),
    ])
    const hook = buildJoinHook()

    hook._adoptRoom(room)

    expect(room.emitted).toEqual([])
    expect(mediaPushes(hook)[0][1]).toEqual({
      muted: ["user:bob"],
      camera_off: ["user:bob", "user:carol"],
    })
  })

  // A participant already sharing their screen at the moment we join must
  // not read as camera-on. Stage 1 filters screen-share publications out;
  // the connect-time sweep has to go through the same filter, or walking
  // into a presentation shows the presenter's camera as live.
  it("ignores a screen-share publication in the connect sweep", () => {
    const presenter = remote("user:erin", [
      pub(AUDIO, { muted: true, source: Track.Source.Microphone }),
      pub(VIDEO, { muted: false, source: Track.Source.ScreenShare }),
    ])
    const room = sweepRoom([presenter])
    const hook = buildJoinHook()

    hook._adoptRoom(room)

    expect(room.emitted).toEqual([])
    expect(mediaPushes(hook)[0][1]).toEqual({
      muted: ["user:erin"],
      camera_off: ["user:erin"],
    })
  })

  // Somebody who joins the call already muted. LiveKit hands us
  // ParticipantConnected; it does NOT then invent a TrackMuted for state
  // that never changed while we were watching.
  it("re-sweeps on ParticipantConnected, and still builds the tile", () => {
    const room = sweepRoom([])
    const hook = buildJoinHook()
    hook._bindRoomEvents(room)

    const frank = alreadyDark("user:frank")
    room.remoteParticipants.set(frank.identity, frank)
    room.emit(RoomEvent.ParticipantConnected, frank)

    expect(room.emitted).toEqual([RoomEvent.ParticipantConnected])
    // The pre-existing handler is untouched: the tile is still created.
    expect(hook.tiled).toEqual(["user:frank"])
    expect(mediaPushes(hook).length).toBeGreaterThan(0)
    expect(mediaPushes(hook).at(-1)[1]).toEqual({
      muted: ["user:frank"],
      camera_off: ["user:frank"],
    })
  })

  // The publication's `track` only exists once the subscription lands, and
  // `pub.track.isMuted` is the authoritative read for a subscribed track.
  // Subscribing to an already-muted track emits TrackSubscribed and
  // nothing else.
  it("re-sweeps on TrackSubscribed, and still attaches the track", () => {
    const gina = remote("user:gina", [
      pub(AUDIO, { muted: false, source: Track.Source.Microphone }),
      pub(VIDEO, { muted: false, source: Track.Source.Camera }),
    ])
    const room = sweepRoom([gina])
    const hook = buildJoinHook()
    hook._bindRoomEvents(room)

    // The subscription lands and the track turns out to have been muted
    // at the source all along.
    const micPub = [...gina.trackPublications.values()][0]
    micPub.track = { isMuted: true, source: Track.Source.Microphone }
    room.emit(RoomEvent.TrackSubscribed, micPub.track, micPub, gina)

    expect(room.emitted).toEqual([RoomEvent.TrackSubscribed])
    // The pre-existing handler is untouched: the track is still attached.
    expect(hook.attached).toEqual([[micPub.track, "user:gina"]])
    expect(mediaPushes(hook).length).toBeGreaterThan(0)
    expect(mediaPushes(hook).at(-1)[1]).toEqual({
      muted: ["user:gina"],
      camera_off: [],
    })
  })

  // The local participant's own mute is the `:mic_enabled` assign, driven
  // by their own button. It must never leak into the remote sets, and the
  // adopt path walks past `room.localParticipant` on its way to the sweep.
  it("never puts the local participant in the pushed sets", () => {
    const room = sweepRoom([])
    room.localParticipant.trackPublications = new Map([
      ["sid-0", pub(AUDIO, { muted: true, source: Track.Source.Microphone })],
    ])
    const hook = buildJoinHook()

    hook._adoptRoom(room)

    expect(room.emitted).toEqual([])
    expect(mediaPushes(hook)).toHaveLength(1)
    expect(mediaPushes(hook)[0][1]).toEqual({ muted: [], camera_off: [] })
  })

  // The FRESH-CONNECT path, which is what a first-time joiner actually
  // takes. `_adoptRoom` is the remount/reconnect branch; a sweep that
  // exists only there leaves the ticket's bug in place for everybody who
  // joins a call normally.
  //
  // Nothing here can lean on `TrackSubscribed` either: the roster below
  // publishes a muted mic and a muted camera, and no subscription is ever
  // announced. `pub.isMuted` comes from the join response, so the sweep
  // has everything it needs the moment `connect()` resolves.
  it("reports an already-muted participant on the FRESH-CONNECT path, not just adopt", async () => {
    livekitFake.joinRoster = [alreadyDark("user:hana")]
    const hook = buildJoinHook()
    hook._audioEls = new Map()

    await hook._join({ token: "tok", url: "wss://livekit.test", room_name: "space-room" })

    expect(hook._room.emitted).toEqual([])
    expect(mediaPushes(hook)).toHaveLength(1)
    expect(mediaPushes(hook)[0][1]).toEqual({
      muted: ["user:hana"],
      camera_off: ["user:hana"],
    })
  })

  // The dedupe key must not outlive a push that never landed.
  // `View.pushHookEvent` REJECTS when the LiveView socket is not connected
  // ("unable to push hook event. LiveView not connected"), and this stage
  // pushes during the join burst — precisely when the socket is most
  // likely still settling. A key committed for a dropped push swallows
  // the state permanently, which is the bug the stage exists to fix.
  it("rolls the dedupe key back when the push is refused, so a retry lands", async () => {
    const room = sweepRoom([alreadyDark("user:iris")])
    const hook = buildJoinHook()
    let connected = false
    hook.pushed = []
    hook.pushEvent = (event, payload) => {
      if (!connected) return Promise.reject(new Error("LiveView not connected"))
      hook.pushed.push([event, payload])
      return Promise.resolve()
    }

    hook._adoptRoom(room)
    await Promise.resolve()
    await Promise.resolve()
    expect(mediaPushes(hook)).toHaveLength(0)

    // The socket comes up. The SAME payload must be allowed through, not
    // deduped away against a push nobody received.
    connected = true
    hook._pushMediaStates(room)
    expect(mediaPushes(hook)).toHaveLength(1)
    expect(mediaPushes(hook)[0][1]).toEqual({
      muted: ["user:iris"],
      camera_off: ["user:iris"],
    })
  })

  // A LiveView socket reconnect re-runs `mount/3`, which re-seeds
  // `:muted_identities` / `:camera_off_identities` to an empty MapSet
  // (`meeting_live.ex:387`, `:534`). The hook instance survives, so its
  // dedupe key still claims the server has been told. Without a reset,
  // every mic badge stays gone until somebody physically toggles a mic:
  // the same loss this stage exists to prevent, arriving over the socket
  // instead of the SFU.
  it("re-reports the room after a LiveView reconnect wipes the server assigns", () => {
    const room = sweepRoom([alreadyDark("user:jonas")])
    const hook = buildJoinHook()

    // `_adoptRoom` pins `this._room` itself; pre-setting it here would
    // trip its same-room early return and there would be nothing to
    // reconnect to.
    hook._adoptRoom(room)
    expect(mediaPushes(hook)).toHaveLength(1)

    hook.reconnected()

    expect(room.emitted).toEqual([])
    expect(mediaPushes(hook)).toHaveLength(2)
    expect(mediaPushes(hook)[1][1]).toEqual({
      muted: ["user:jonas"],
      camera_off: ["user:jonas"],
    })
  })

  // A redundancy fence, not a behaviour claim. `_pushMediaStates` drops a
  // push identical to the last one, so a SECOND sweep on the same path is
  // invisible to every assertion above — which is exactly how a duplicated
  // call site survives a mutation matrix. Count the calls, not the pushes.
  it("sweeps exactly once per join path", async () => {
    const room = sweepRoom([alreadyDark("user:bob")])
    const hook = buildJoinHook()
    let sweeps = 0
    const real = MeetingClient._pushMediaStates
    hook._pushMediaStates = function (r) {
      sweeps += 1
      return real.call(this, r)
    }

    hook._adoptRoom(room)
    expect(sweeps).toBe(1)

    livekitFake.joinRoster = [alreadyDark("user:bob")]
    const joinHook = buildJoinHook()
    joinHook._audioEls = new Map()
    let joinSweeps = 0
    joinHook._pushMediaStates = function (r) {
      joinSweeps += 1
      return real.call(this, r)
    }

    await joinHook._join({ token: "tok", url: "wss://livekit.test", room_name: "space-room" })
    expect(joinSweeps).toBe(1)
  })
})
