import { Room, RoomEvent, Track } from "livekit-client"
import {
  participantLabel,
  personIdentity,
  personLabel,
  readParticipantNames,
} from "./lib/participant_label"
import { cancelActiveSpeakers, offerActiveSpeakers } from "./lib/active_speakers_debounce"
import { toggleScreenShare } from "./lib/screen_share_policy"
import { ScreenShareFullscreenController } from "./lib/screen_share_viewer"

/**
 * True when the LiveKit track / publication is a screen-share video
 * source. LiveKit exposes `source` on both publications and tracks; we
 * accept either. Mirrors the helper in `meeting_screen_share.js`.
 *
 * Task 019e420f stage 3: routes incoming screen-share tracks to a
 * dedicated container instead of jamming them into a participant tile
 * (where they render as a tiny 80×80 thumbnail).
 */
function isScreenShareSource(source) {
  // LiveKit Track.Source.ScreenShare is the string "screen_share". The
  // matching audio source is "screen_share_audio" — we don't route that
  // to the dedicated container (it just plays through #meeting-media).
  return source === Track.Source.ScreenShare || source === "screen_share"
}

// How long the page waits for the native call to confirm a page mute before
// it reads the native state back and tells the server the change failed
// (task 01a13c62 stage 3, design canvas 01a13c62-5ef3: "about 3 s"). The
// plugin's own `setMuted` gives up at 5 s; a confirmation landing between
// the two arrives as `mediaChanged`, which clears the failure.
export const NATIVE_MUTE_TIMEOUT_MS = 3000

// What a build without `capabilities()` can do from the page: nothing. Its
// `SuiteMeetings` has no `setMuted`, so the mic button cannot drive it.
const LEGACY_NATIVE_CAPABILITIES = Object.freeze({
  mic: false,
  camera: false,
  activeSpeakers: false,
})

// How long the page waits for the companion's camera PUBLICATION to report
// a change before it reads the publication back and pushes it with
// `failed: "camera"` (task 01a13ca2 stage 3). The same budget as the mic.
export const COMPANION_CAMERA_TIMEOUT_MS = 3000

// The Rooms this page opened as a person's video-only COMPANION connection
// (`video:user:<uuid>`, task 01a13ca2 stage 3). Module-level, not a hook
// field, because the Room outlives the hook (pinned on window) and a
// re-mounted hook adopting it must still know what it is: a companion never
// touches the microphone and never re-enables its camera on its own.
const companionRooms = new WeakSet()

export function isCompanionRoom(room) {
  return !!room && typeof room === "object" && companionRooms.has(room)
}

// A companion receives VIDEO only (camera and screen share). Audio is the
// native call's; subscribing to it here would play the call twice.
function isVideoPublication(pub) {
  return !!pub && pub.kind === Track.Kind.Video
}

const MeetingClient = {
  mounted() {
    this._room = null
    // Tiles are keyed by PERSON (`personIdentity`), never by raw LiveKit
    // identity: a person's video-only companion connection
    // (`video:user:<uuid>`, task 01a13ca2) shares its person's tile.
    this._tiles = new Map()
    // Remote <audio> elements, keyed by `track.sid || track.mediaStreamID`.
    // The MAP is per-instance bookkeeping; the ELEMENTS deliberately outlive
    // the hook — they live in the body-level `#meeting-audio-sink` so a
    // LiveView live-navigation swap (which removes `#meeting-media`) cannot
    // take remote audio with it. destroyed() clears the Map, never the nodes.
    this._audioEls = new Map()
    // Per-instance bookkeeping for the Room we've wired listeners onto,
    // and the listener refs themselves. Cleared in destroyed() so a
    // re-mount against the surviving window-pinned Room doesn't
    // accumulate listener sets (task 019ee06b stage 2 v2 e2e fix — the
    // case-3 unbounded growth lived here).
    this._boundRoom = null
    this._roomListeners = []
    // Last `media_states` payload pushed, serialised. Dedupe key for
    // `_pushMediaStates`; reset whenever we bind a new Room so an adopted
    // room re-reports rather than being swallowed by a stale key.
    this._lastMediaStatesKey = null

    // v2 (task 019e42f6): the single persistent local self-view <video>.
    // Born once in the [data-role="local-self-view"] parking slot, attached
    // to the live camera track exactly once, then REPARENTED (appendChild,
    // never detach) into the active stage mode's dock on every switch. This
    // replaces v1's free-floating PiP: the element now docks into the
    // gallery tile (gallery mode) or the bottom strip (canvas/screen/
    // whiteboard). The track is never touched after first attach — only the
    // element's parent changes — so the camera never goes black mid-switch.
    this._localVideoEl = null
    this._localVideoTrack = null
    this._screenShareController = null
    this._screenSharePublication = null
    this._screenShareParticipant = null

    this.handleEvent("join-meeting", (payload) => this._join(payload))
    this.handleEvent("leave-meeting", () => {
      this._leaveNative()
      this._leave()
    })
    this.handleEvent("toggle-mic", (payload) => this._toggleMic(payload))
    this.handleEvent("toggle-camera", (payload) => this._toggleCamera(payload))
    // Task 01a13ca2 stage 3: the iOS app's video-only companion connection.
    this.handleEvent("join-companion", (payload) => this._joinCompanion(payload))
    this.handleEvent("toggle-screen-share", () => this._toggleScreenShare())
    // The server pushes this on every `set_stage_mode` (meeting_live.ex).
    this.handleEvent("meeting_stage_mode_changed", ({ mode }) =>
      this._dockLocalVideo(mode),
    )

    // Migrate tiles between desktop/mobile grids when the viewport crosses
    // the lg breakpoint (rotation, window resize, dev tools toggle).
    this._viewportQuery = window.matchMedia("(min-width: 1024px)")
    this._onViewportChange = () => {
      this._rehomeTiles()
      this._rehomeScreenShare()
    }
    this._viewportQuery.addEventListener("change", this._onViewportChange)

    // ── Reconnect survival (task 019e4b3e stage 1) ──────────────────────
    // The live LiveKit Room object only exists inside this hook instance.
    // Phoenix LiveView fires destroyed()/mounted() on a 1006 abnormal
    // socket close (an operator console: publish track -> "LiveView not
    // connected" -> code:1006 -> "disconnect from room"). If destroyed()
    // disconnects the room, the media session dies and the camera never
    // re-engages. So: a genuine page exit (pagehide/beforeunload) is the
    // only thing that should tear the room down here; an LV element
    // re-mount must ADOPT the still-connected room left on
    // window.__livekit_room (mirrors meeting_room.js:32-52).
    this._onPageHide = () => {
      this._companionCameraOff()
      this._leave()
    }
    window.addEventListener("pagehide", this._onPageHide)
    window.addEventListener("beforeunload", this._onPageHide)

    // The companion camera goes OFF when the page is hidden (the app went to
    // the background, the screen locked) and stays off on return: the user
    // taps again. A no-op without a companion Room, so the browser path is
    // untouched.
    this._onVisibilityChange = () => {
      if (document.visibilityState === "hidden") this._companionCameraOff()
    }
    if (typeof document.addEventListener === "function") {
      document.addEventListener("visibilitychange", this._onVisibilityChange)
    }

    // Adopt an existing connected room left behind by a prior hook
    // instance (LV repatch/reconnect). Re-wire listeners + rebuild tiles
    // WITHOUT reconnecting so the media session survives the remount.
    const existing = window.__livekit_room || window.__livekitRoom
    if (existing && existing.state === "connected") {
      this._adoptRoom(existing)
    }
  },

  destroyed() {
    // Do NOT disconnect the LiveKit room here. A destroyed() can be a
    // transient LV repatch/reconnect (1006) — the room must outlive it so
    // the next mounted() can re-adopt it. True leaves go through the
    // server "leave-meeting" push + RoomEvent.Disconnected, and a real
    // page exit goes through the pagehide/beforeunload listener above.
    //
    // BUT we MUST detach the RoomEvent listeners we installed: the Room
    // object survives via window.__livekit_room across the destroy/mount
    // cycle, and without an off() walk every shell repatch (or every
    // navigation between /chat, /meetings, and back) would leak a fresh
    // listener set onto the same Room. That's exactly what the case-3
    // e2e reviewer caught — listener count 1 → 2 → 3 → … and duplicate
    // `livekit:state` events firing per RoomEvent. (task 019ee06b stage 2
    // v2 fix.)
    this._releaseRoomListeners()
    // The native call (if any) outlives this element; only our listener goes.
    this._releaseNativeListener()

    // Clear the MAP, never the DOM elements. The remote <audio> nodes live in
    // the body-level `#meeting-audio-sink` and must outlive this hook — that
    // is the entire point of the fix. Do NOT re-wire the detach side here:
    // re-wiring resurrects the global-detach race fixed in 019e42f6.
    this._audioEls?.clear()

    window.removeEventListener("pagehide", this._onPageHide)
    window.removeEventListener("beforeunload", this._onPageHide)
    if (typeof document.removeEventListener === "function") {
      document.removeEventListener("visibilitychange", this._onVisibilityChange)
    }
    this._viewportQuery?.removeEventListener("change", this._onViewportChange)
    this._screenShareController?.destroy()
    this._screenShareController = null
  },

  // v4 case-3 fix: Phoenix LiveView calls reconnected() on the hook after
  // its socket reconnects (a 1006 close blip). On a pure socket reconnect
  // the `#meeting-client` element is re-patched by morphdom from
  // server-rendered HTML that carries NO `data-room-state` (it's a
  // JS-owned attribute), so the breadcrumb the reviewer asserts gets
  // stripped even though the LiveKit room never disconnected and survives
  // on window.__livekit_room. Re-stamp it here against the surviving room
  // so `dataset.roomState` returns to 'connected' after the reconnect
  // settles — and re-reconcile camera/mic from committed intent so the
  // local feed re-engages, mirroring the adopt path.
  reconnected() {
    const room = this._room || window.__livekit_room || window.__livekitRoom
    if (room && room.state === "connected") {
      this._emitState("connected", room)
      this._reconcileLocalMedia(room)
      // The socket reconnect re-ran `mount/3`, which re-seeds
      // `:muted_identities` / `:camera_off_identities` to an empty MapSet
      // (`meeting_live.ex:387`, `:534`). This hook INSTANCE survives the
      // reconnect, so its dedupe key still claims the server has been
      // told, and every mic badge would stay gone until somebody
      // physically toggled a mic. Clear the key, then re-report: the same
      // loss task 01a0740c stage 2 exists to prevent, arriving over the
      // socket instead of the SFU.
      this._lastMediaStatesKey = null
      this._pushMediaStates(room)
    }
  },

  // Re-dock the persistent local <video> after EVERY LiveView patch (task
  // "flash-close-kills-video"). The single self-view <video> is created by
  // this hook and REPARENTED (appendChild, never re-attach) into the active
  // mode's dock. On `/meetings` that dock lives inside the server `:for` over
  // gallery participants (meeting_live.html.heex) — it carries no stable id
  // and no `phx-update="ignore"`, so ANY re-render (closing the "Meeting
  // started" flash via `lv:clear-flash`, a presence/participant update, a
  // control toggle) lets morphdom replace the dock node and discard the
  // JS-injected <video>. Without an `updated()` callback nothing re-parented
  // it, so the local camera feed vanished from the gallery. Re-docking here
  // moves only the element into the (possibly freshly-rendered) dock — the
  // live MediaStreamTrack is never touched, mirroring `_dockLocalVideo`'s
  // reparent-not-reattach discipline. No-op when there's no local video.
  //
  // Camera-off correction: in
  // livekit-client v2 turning the camera off MUTES the publication instead
  // of unpublishing it, so `LocalTrackUnpublished` (our only suspend
  // trigger) never fires and the still-attached <video> keeps getting
  // re-docked here — painting a BLACK rectangle over the avatar fallback.
  // Ask the room whether the camera is actually live before re-docking, and
  // park it (revealing the avatar) when it positively is not. Teardown is
  // deliberately asymmetric: with
  // no room to ask (pre-join, mid-reconnect) we keep the old re-dock
  // behaviour rather than blanking a feed that may well be live.
  updated() {
    this._rehomeScreenShare()
    if (!this._localVideoEl) return
    if (this._localCameraOff(this._room)) {
      this._suspendLocalVideo()
      return
    }
    this._dockLocalVideo(this._currentStageMode())
  },

  // Adopt an already-connected Room object (reconnect/remount path). Wires
  // the shared RoomEvent listeners, rebuilds local + remote tiles, and
  // reconciles the local camera/mic against committed server intent —
  // never re-connecting. Symmetric with meeting_room.js's _tryBind.
  _adoptRoom(room) {
    // Even when we've already adopted THIS room object (a pure LV repatch
    // where the hook re-mounts against the same surviving Room), re-stamp
    // the connection state: LiveView's morphdom patch re-renders the
    // server-owned `#meeting-client` element, which carries no
    // `data-room-state` (it's JS-owned), so the attribute gets WIPED on the
    // patch. Re-emitting here puts `dataset.roomState='connected'` back
    // without re-binding listeners or re-attaching media. This is the v4
    // case-3 fix: the room survives the 1006 blip but the breadcrumb the
    // reviewer asserts (`#meeting-client.dataset.roomState === 'connected'`)
    // was absent after the reconnect settled.
    if (this._room === room) {
      this._emitState("connected", room)
      return
    }
    this._room = room
    window.__livekit_room = room
    window.__livekitRoom = room
    if (isCompanionRoom(room)) this._companionRoom = room

    this._bindRoomEvents(room)
    this._emitState("connected", room)

    this._ensureTile(room.localParticipant)

    // Re-attach an already-published local camera into the persistent
    // self-view + dock for the current mode.
    // Routed through the reconcile so a camera that is published-but-MUTED
    // (joined / re-joined with the camera off) parks instead of attaching a
    // black frame over the avatar.
    this._reconcileLocalVideo(room)

    for (const pub of room.localParticipant?.trackPublications?.values?.() || []) {
      const source = pub.source || pub.track?.source
      if (pub.track && isScreenShareSource(source)) {
        this._attachTrack(pub.track, room.localParticipant, pub)
      }
    }

    for (const participant of room.remoteParticipants.values()) {
      this._ensureTile(participant)
      for (const pub of participant.trackPublications.values()) {
        if (pub.track) this._attachTrack(pub.track, participant, pub)
      }
    }

    // Report what the room ALREADY looks like (task 01a0740c stage 2).
    // Everyone present when we adopt got here without firing a single
    // `TrackMuted` at us, so without this the tiles of the people already
    // in the call all read as unmuted. `_bindRoomEvents` above cleared
    // `_lastMediaStatesKey`, so this first push is never deduped away.
    this._pushMediaStates(room)

    // Reconcile camera/mic against committed intent (stage 3): the LV
    // socket may still be settling, so read intent from the DOM dataset
    // rather than waiting for a server push.
    this._reconcileLocalMedia(room)
  },

  // ── Local self-view: single persistent <video>, reparented per mode ──────

  // The off-layout parking node the persistent local <video> is born in and
  // returns to between docks. Stable id + phx-update="ignore" in the markup.
  //
  // v4 stage 2: the /chat quick-meet panel renders TWO parking slots
  // simultaneously — desktop side pane (`lg:flex`) and mobile overlay
  // (`lg:hidden`) — tagged `data-pane="desktop"`/`"mobile"`. Pick the
  // currently-visible pane (matchMedia, parity with `_grid()` /
  // `_screenShareSlot()`) so the <video> parks in the on-screen panel.
  // MeetingLive renders a SINGLE unscoped slot (no `data-pane`), so we
  // fall back to the plain `[data-role="local-self-view"]` selector there.
  _localParkingSlot() {
    return this._paneScoped('[data-role="local-self-view"]')
  },

  // Resolve the pane-scoped variant of `selector` for the visible viewport,
  // falling back to a mobile/desktop sibling, then to the unscoped node
  // (MeetingLive's single-layout surface, which carries no `data-pane`).
  _paneScoped(selector) {
    const desktop = document.querySelector(`${selector}[data-pane="desktop"]`)
    const mobile = document.querySelector(`${selector}[data-pane="mobile"]`)
    if (desktop || mobile) {
      const isDesktop =
        typeof window !== "undefined" && window.matchMedia
          ? window.matchMedia("(min-width: 1024px)").matches
          : true
      return isDesktop ? desktop || mobile : mobile || desktop
    }
    return document.querySelector(selector)
  },

  // Read the active stage mode from the center-stage data attribute (the
  // server's `data-stage-mode` contract). Defaults to gallery.
  _currentStageMode() {
    const stage = document.querySelector('[data-pane="center-stage"]')
    return (stage && stage.dataset.stageMode) || "gallery"
  },

  // Create (once) the persistent local <video>, attach the camera track to
  // it, park it, then dock it into the current mode. Idempotent on the
  // element: a re-publish re-attaches the new track to the SAME element.
  _attachLocalVideo(track) {
    if (!track) return
    this._localVideoTrack = track

    if (!this._localVideoEl) {
      const parking = this._localParkingSlot()
      // Use single-element attach into a freshly-created node so we own one
      // element; never the zero-arg attach() that mints elements globally.
      const el = document.createElement("video")
      el.autoplay = true
      el.playsInline = true
      el.muted = true
      el.dataset.role = "local-self-video"
      el.className = "h-full w-full object-cover"
      el.style.transform = "scaleX(-1)" // mirror local feed (matches v1 tile)
      this._localVideoEl = el
      if (parking) parking.appendChild(el)
    }

    track.attach(this._localVideoEl)
    this._localVideoEl.style.display = ""
    this._dockLocalVideo(this._currentStageMode())
  },

  // Reparent the persistent local <video> into the dock for `mode`. Gallery
  // → the gallery dock inside the local [data-gallery-cell]; everything else
  // → the bottom-strip dock. If the dock isn't in the DOM yet (LV patch
  // ordering), retry once on the next frame; if still absent, leave the
  // video parked (never orphaned floating over content).
  _dockLocalVideo(mode, _retried = false) {
    const el = this._localVideoEl
    if (!el) return

    const selector =
      mode === "gallery"
        ? '[data-local-video-dock][data-dock-mode="gallery"]'
        : '[data-local-video-dock][data-dock-mode="strip"]'
    // v4 stage 2: pick the visible-pane dock on /chat (two coexisting
    // quick-meet variants tagged data-pane); falls back to the unscoped
    // dock on MeetingLive (single layout, no data-pane).
    const dock = this._paneScoped(selector)

    if (!dock) {
      if (!_retried) {
        requestAnimationFrame(() => this._dockLocalVideo(mode, true))
      } else {
        // Park it rather than leave it floating in whatever stale parent.
        const parking = this._localParkingSlot()
        if (parking && el.parentElement !== parking) parking.appendChild(el)
      }
      return
    }

    // Move only the element — the MediaStreamTrack stays attached.
    if (el.parentElement !== dock) dock.appendChild(el)
  },

  // Camera toggled OFF: keep the element + parking node, just stop painting
  // and park it so the avatar fallback shows in the dock. The next
  // publish re-attaches to the SAME element (preserves v1's re-engage win).
  _suspendLocalVideo() {
    if (this._localVideoTrack && this._localVideoEl) {
      try {
        this._localVideoTrack.detach(this._localVideoEl)
      } catch (_) {
        /* track may already be detached */
      }
    }
    this._localVideoTrack = null
    const el = this._localVideoEl
    if (el) {
      // Belt-and-suspenders with the parking move: if anything re-docks a
      // suspended element before `_attachLocalVideo` runs, it must not
      // paint a black rectangle over the avatar. `_attachLocalVideo`
      // clears this on the way back up.
      el.style.display = "none"
      const parking = this._localParkingSlot()
      if (parking && el.parentElement !== parking) parking.appendChild(el)
    }
  },

  // The local CAMERA publication (never screen-share), or null. LiveKit
  // exposes local publications on `localParticipant.trackPublications`.
  _localCameraPublication(room) {
    const lp = room && room.localParticipant
    const pubs = lp && (lp.trackPublications || lp.tracks)
    if (!pubs || typeof pubs.values !== "function") return null
    for (const pub of pubs.values()) {
      if (!pub || pub.kind !== Track.Kind.Video) continue
      const source = (pub.track && pub.track.source) || pub.source
      if (isScreenShareSource(source)) continue
      return pub
    }
    return null
  },

  // True only when the room POSITIVELY reports the local camera as not
  // painting: a muted publication, or one whose MediaStreamTrack ended.
  // Unknown shapes and
  // an absent room read as "not off" — never blank a live feed on a guess.
  _localCameraOff(room) {
    const pub = this._localCameraPublication(room)
    if (!pub) return false
    if (pub.isMuted === true) return true
    if (pub.track && pub.track.isMuted === true) return true
    const mst = pub.track && pub.track.mediaStreamTrack
    if (mst && mst.readyState === "ended") return true
    return false
  },

  // ── Remote media state (task 01a0740c stage 1) ─────────────────────────
  //
  // Publication-level mute, the same two flags `meeting_video_tile.js` and
  // `meeting_push_to_talk.js` read. `pub.isMuted` is what LiveKit flips on
  // a remote `setMicrophoneEnabled(false)`; `pub.track.isMuted` covers the
  // subscribed-track shape. Anything else reads as unmuted.
  _publicationMuted(pub) {
    if (!pub) return true
    if (pub.isMuted === true) return true
    if (pub.track && pub.track.isMuted === true) return true
    return false
  },

  // Which REMOTE identities have their mic muted and their camera off, as
  // `{ muted, camera_off }` — two sorted arrays of LiveKit identities,
  // mirroring the `active_speakers` payload shape.
  //
  // `room.remoteParticipants` excludes the local participant by
  // construction: the viewer's own mute is already the `:mic_enabled`
  // assign, driven by their own button, and does not need a round trip
  // through the SFU to be known.
  //
  // NO PUBLICATION READS AS OFF. A participant who has published no mic
  // has nothing for anyone to hear, and one who has published no camera is
  // already showing the tile's avatar fallback; both are the states the
  // indicators exist to name.
  //
  // Screen-share publications are skipped on both axes via
  // `isScreenShareSource`. Without that, stopping a share unpublishes a
  // video track and the tile would read it as the camera going off.
  //
  // GROUPED BY PERSON (task 01a13ca2 stage 2). A person may hold two
  // connections: `user:<uuid>` (audio, maybe camera) and the video-only
  // companion `video:user:<uuid>`. Both report under `personIdentity`, so no
  // `video:` identity ever reaches the payload. `muted` reads the first
  // connection that publishes a mic (a companion cannot, its grant has no
  // microphone source). `camera_off` holds the person only when NO
  // connection of theirs has a live, unmuted camera. With one connection per
  // person this is exactly the per-identity computation it replaced.
  _remoteMediaStates(room) {
    const muted = []
    const cameraOff = []
    const remotes = room && room.remoteParticipants

    if (!remotes || typeof remotes.values !== "function") {
      return { muted, camera_off: cameraOff }
    }

    // person -> { mic, cameraLive }, in first-seen order.
    const people = new Map()

    for (const participant of remotes.values()) {
      if (!participant || !participant.identity) continue

      const pubs = participant.trackPublications || participant.tracks
      let mic = null
      let camera = null

      if (pubs && typeof pubs.values === "function") {
        for (const pub of pubs.values()) {
          if (!pub) continue
          const source = (pub.track && pub.track.source) || pub.source
          if (isScreenShareSource(source)) continue
          if (pub.kind === Track.Kind.Audio && !mic) mic = pub
          else if (pub.kind === Track.Kind.Video && !camera) camera = pub
        }
      }

      const person = personIdentity(participant.identity)
      const entry = people.get(person) || { mic: null, cameraLive: false }
      if (!entry.mic && mic) entry.mic = mic
      if (!this._publicationMuted(camera)) entry.cameraLive = true
      people.set(person, entry)
    }

    for (const [person, entry] of people) {
      if (this._publicationMuted(entry.mic)) muted.push(person)
      if (!entry.cameraLive) cameraOff.push(person)
    }

    muted.sort()
    cameraOff.sort()
    return { muted, camera_off: cameraOff }
  },

  // Push the remote media state to the LiveView, dropping a push that would
  // repeat the last one. `RoomEvent.TrackMuted` fires once PER PUBLICATION,
  // so somebody muting mic and camera together fires twice for one visible
  // change; the equality guard mirrors guard 1 in `MeetingRoom`.
  //
  // The push is root-targeted (a hook's `pushEvent` ignores `phx-target`),
  // and `MeetingClient` is mounted on BOTH surfaces — `chat_live.html.heex`
  // and `meeting_live.html.heex` — so this one call site reaches every
  // `handle_event("media_states", …)` family.
  _pushMediaStates(room) {
    const next = this._remoteMediaStates(room)
    // Both arrays are sorted, so serialising the whole payload is a stable
    // identity for it. `JSON.stringify` rather than a joined string because
    // an identity may legally contain any separator character we could pick.
    const key = JSON.stringify(next)
    if (key === this._lastMediaStatesKey) return
    // Commit the key BEFORE awaiting, so the synchronous burst this guard
    // exists for (TrackMuted fires once per publication) still collapses
    // to one push. Then roll it back if the push was refused:
    // `View.pushHookEvent` REJECTS with "unable to push hook event.
    // LiveView not connected", and task 01a0740c stage 2 pushes during
    // the join burst and on every `TrackSubscribed` — exactly when the
    // socket is most likely still settling. A key left committed for a
    // push nobody received swallows the state permanently, which is the
    // bug this stage exists to fix. The `=== key` check keeps a stale
    // rejection from clobbering a newer push's key.
    this._lastMediaStatesKey = key
    Promise.resolve(this.pushEvent("media_states", next)).catch(() => {
      if (this._lastMediaStatesKey === key) this._lastMediaStatesKey = null
    })
  },

  // Single decision point for "should the local self-view be painting?".
  // Live → attach (idempotent; re-uses the SAME element) and dock. Off →
  // suspend, which parks + detaches so the dock is empty and the server
  // rendered avatar fallback beneath it shows through.
  _reconcileLocalVideo(room) {
    const pub = this._localCameraPublication(room)
    if (pub && pub.track && !this._localCameraOff(room)) {
      this._attachLocalVideo(pub.track)
      return
    }
    if (pub && this._localCameraOff(room)) this._suspendLocalVideo()
  },

  _teardownLocalVideo() {
    if (this._localVideoTrack && this._localVideoEl) {
      try {
        this._localVideoTrack.detach(this._localVideoEl)
      } catch (_) {
        /* already detached */
      }
    }
    if (this._localVideoEl) this._localVideoEl.remove()
    this._localVideoEl = null
    this._localVideoTrack = null
  },

  _rehomeTiles() {
    const grid = this._grid()
    if (!grid) return
    for (const tile of this._tiles.values()) {
      if (tile.parentElement !== grid) grid.appendChild(tile)
    }
  },

  // Wire the shared RoomEvent listeners onto a Room. Factored out of
  // `_join` (task 019e4b3e stage 1) so the adopt path (mounted() finding a
  // surviving room after an LV reconnect) re-binds the identical handler
  // set without duplicating them.
  //
  // Idempotency (task 019ee06b stage 2 v2 — case-3 e2e fix):
  // - PER-INSTANCE: `this._boundRoom === room` short-circuits a redundant
  //   bind on the SAME hook instance (e.g. `_adoptRoom` called twice
  //   against the same Room during a quick succession of LV repatches).
  //   Without this, even with the destroyed() cleanup below, a re-adopt
  //   inside one mount cycle would double-bind.
  // - ACROSS INSTANCES: every set of refs we register is tracked in
  //   `this._roomListeners` so `destroyed()` can `room.off()` them. The
  //   Room object outlives our hook instance (window.__livekit_room is
  //   pinned across LV navigation), so without explicit off() walks, each
  //   navigation between /chat ↔ /meetings ↔ back would leak a fresh
  //   listener set onto the same Room — exactly what the case-3 reviewer
  //   probe surfaced (listenerCount('reconnected') growing 1 → 2 → 3).
  //
  // NOTE: this hook installs its own listeners independently of
  // MeetingWatchdog. They both register handlers on the Room's
  // Reconnecting/Reconnected/etc. — but each tags `source` on the emitted
  // `livekit:state` CustomEvent so downstream consumers can dedupe by
  // origin, and they stamp DIFFERENT dataset elements
  // (`#meeting-client.dataset.roomState` vs
  // `#meeting-watchdog.dataset.roomState`) so neither overwrites the
  // other. The previous `room.__watchdogBound` band-aid was an
  // asymmetric flag that produced both the case-1 (watchdog never
  // installed listeners) and case-3 (MeetingClient never cleaned up)
  // failures; this hook no longer sets or reads it.
  _bindRoomEvents(room) {
    if (this._boundRoom === room) return
    if (this._boundRoom) this._releaseRoomListeners()
    this._boundRoom = room
    this._roomListeners = []
    this._lastMediaStatesKey = null

    const bind = (event, fn) => {
      room.on(event, fn)
      this._roomListeners.push([event, fn])
    }

    // ── Media state at JOIN (task 01a0740c stage 2) ─────────────────────
    //
    // `RoomEvent.TrackMuted`/`TrackUnmuted` fire on a TRANSITION, so the
    // stage-1 handler below hears nothing about somebody who muted BEFORE
    // we subscribed and renders them unmuted indefinitely. Sweeping the
    // room at the two points a participant or a publication can appear
    // WITHOUT a transition closes that:
    //
    //   * `ParticipantConnected` — somebody who joins already muted.
    //   * `TrackSubscribed` — a publication's `track` only exists once the
    //     subscription lands, and `pub.track.isMuted` is the authoritative
    //     read for a subscribed track. Everyone already in the room when
    //     we arrive comes in on the join response and is subscribed here,
    //     never announced as `ParticipantConnected`.
    //
    // Chained onto the existing handlers rather than bound as a second
    // listener: `_ensureTile`/`_attachTrack` keep running first and
    // unchanged, and the per-event listener counts the reconnect-survival
    // tests assert stay at one. `_pushMediaStates` recomputes the whole
    // set and drops a push identical to the last one, so re-sweeping on
    // every one of these is cheap.
    bind(RoomEvent.ParticipantConnected, (p) => {
      this._ensureTile(p)
      this._pushMediaStates(room)
    })
    // A companion leaving drops only its video; the tile goes with the
    // person's LAST connection (`_removeTile`).
    bind(RoomEvent.ParticipantDisconnected, (p) => this._removeTile(p.identity))
    bind(RoomEvent.TrackSubscribed, (track, pub, participant) => {
      this._attachTrack(track, participant, pub)
      this._pushMediaStates(room)
    })
    bind(RoomEvent.TrackUnsubscribed, (track, pub, participant) =>
      this._detachTrack(track, participant),
    )
    bind(RoomEvent.LocalTrackPublished, (pub) => {
      // v2 (task 019e42f6): the local CAMERA is owned by the persistent
      // self-view element + reparented per mode; do NOT route it through the
      // imperative tile path. Screen-share still flows to its dedicated slot
      // via _attachTrack. Other local video (none today) keeps the old path.
      if (
        pub.track &&
        pub.kind === Track.Kind.Video &&
        !isScreenShareSource(pub.track.source)
      ) {
        this._attachLocalVideo(pub.track)
        return
      }
      if (pub.track && pub.kind === Track.Kind.Video) {
        this._attachTrack(pub.track, room.localParticipant, pub)
      }
    })
    bind(RoomEvent.LocalTrackUnpublished, (pub) => {
      if (
        pub.kind === Track.Kind.Video &&
        (!pub.track || !isScreenShareSource(pub.track.source))
      ) {
        // Camera off: keep the persistent element, park + clear it so the
        // next publish re-attaches to the SAME element and re-docks.
        this._suspendLocalVideo()
        return
      }
      if (pub.track) this._detachTrack(pub.track, room.localParticipant)
    })
    // Camera-off in livekit-client v2 MUTES the local publication (see
    // LocalParticipant.setTrackEnabled: only screen-share unpublishes), so
    // LocalTrackUnpublished above never fires for a camera toggle. These are
    // the transitions that actually flip the local tile between live video
    // and the avatar fallback. Remote identities are ignored here — this
    // handler is strictly about the local self-view and must not disturb
    // remote tiles.
    const onLocalMuteChanged = (pub, participant) => {
      const lp = room.localParticipant
      if (!lp || !participant || participant.identity !== lp.identity) return
      if (pub && pub.kind && pub.kind !== Track.Kind.Video) return
      const source = (pub && pub.track && pub.track.source) || (pub && pub.source)
      if (isScreenShareSource(source)) return
      this._reconcileLocalVideo(room)
    }
    bind(RoomEvent.TrackMuted, onLocalMuteChanged)
    bind(RoomEvent.TrackUnmuted, onLocalMuteChanged)

    // ── Remote per-identity media state (task 01a0740c stage 1) ──────────
    //
    // A SEPARATE handler on the same two events, deliberately NOT a widened
    // `onLocalMuteChanged`. That handler's identity guard exists to protect
    // `_reconcileLocalVideo(room)`, which swaps the LOCAL self-view between
    // live video and the avatar fallback. Admitting remote identities there
    // would re-run local self-view reconciliation every time somebody ELSE
    // muted, and the failure mode is your own video flickering or vanishing
    // for a reason that has nothing to do with you. This handler reads the
    // room and pushes; it touches no local media state at all, so it needs
    // no identity guard and must not grow one.
    //
    // Same contract as `active_speakers` (see `meeting_room.js`): VIEWER-
    // LOCAL presentation state. Each client runs its own LiveKit room and
    // reports what IT observes. Never persisted, never broadcast.
    const onRemoteMediaChanged = () => this._pushMediaStates(room)
    bind(RoomEvent.TrackMuted, onRemoteMediaChanged)
    bind(RoomEvent.TrackUnmuted, onRemoteMediaChanged)

    bind(RoomEvent.ActiveSpeakersChanged, (speakers) => {
      const identities = speakers.map((p) => p.identity)
      this._markSpeakers(identities)
    })

    // ── Reconnect lifecycle (task 019e4b3e stages 3+4) ───────────────────
    // LiveKit runs its own ICE-restart machinery; on a transient network
    // blip the SFU can drop the local camera publication while the server's
    // :camera_enabled intent still reads true. On Reconnected we reconcile
    // local media against committed intent read from the DOM dataset
    // (reconnect-safe — no dependency on a fresh LV push).
    bind(RoomEvent.Reconnecting, () => {
      this._emitState("reconnecting", room)
    })
    bind(RoomEvent.Reconnected, () => {
      this._emitState("reconnected", room)
      this._reconcileLocalMedia(room)
    })

    if (isCompanionRoom(room)) {
      this._bindCompanionEvents(room, bind)
      return
    }

    bind(RoomEvent.Disconnected, () => {
      this._emitState("disconnected", room)
      this._cleanupRoom()
      this.pushEvent("meeting_left", {})
    })
  },

  // ── The companion Room (task 01a13ca2 stage 3) ──────────────────────────
  //
  // Inside the Burrow iOS app with a build whose `capabilities().camera` is
  // true, the native call keeps audio, CallKit and the lock screen, and the
  // page joins a SECOND time as `video:user:<uuid>` for the camera and for
  // viewing video. Its token cannot publish a microphone (the SFU refuses
  // it); this page never asks, never subscribes to audio and never attaches
  // an <audio> from it. Everything else (tiles, the self-view dock, the
  // screen-share slot, `meeting_video_tile.js`) runs unchanged on it,
  // because it is pinned as `this._room` / `window.__livekit_room`.
  _bindCompanionEvents(room, bind) {
    // `autoSubscribe: false`: subscribe each VIDEO publication explicitly.
    bind(RoomEvent.TrackPublished, (pub) => this._subscribeCompanionVideo(pub))

    // The camera button follows the PUBLICATION, never the click.
    const onLocalCamera = (pub) => {
      if (!isVideoPublication(pub)) return
      const source = (pub.track && pub.track.source) || pub.source
      if (isScreenShareSource(source)) return
      this._pushCompanionState(room)
    }
    bind(RoomEvent.LocalTrackPublished, onLocalCamera)
    bind(RoomEvent.LocalTrackUnpublished, onLocalCamera)
    const onLocalMute = (pub, participant) => {
      const lp = room.localParticipant
      if (!lp || !participant || participant.identity !== lp.identity) return
      onLocalCamera(pub)
    }
    bind(RoomEvent.TrackMuted, onLocalMute)
    bind(RoomEvent.TrackUnmuted, onLocalMute)

    // The companion dropping is NOT the person leaving: the native call
    // still carries them. Clean the page up and report the camera off.
    bind(RoomEvent.Disconnected, () => {
      this._emitState("disconnected", room)
      if (this._companionRoom === room) this._companionRoom = null
      this._cleanupRoom()
      this._pushCompanionState(null)
    })
  },

  _subscribeCompanionVideo(pub) {
    if (!isVideoPublication(pub)) return
    if (pub.isSubscribed === true) return
    try {
      pub.setSubscribed(true)
    } catch (err) {
      console.warn("[MeetingClient] companion video subscribe failed:", err)
    }
  },

  // The companion's camera as its local PUBLICATION reports it.
  _companionCameraOn(room) {
    if (!room) return false
    const pub = this._localCameraPublication(room)
    return !!(pub && pub.track && !this._localCameraOff(room))
  },

  // Tell the server (and the native call, for CallKit's hasVideo) what the
  // publication confirms. `room` null means the companion is gone: off.
  _pushCompanionState(room, extra = {}) {
    if (this._companionConfirmTimer) {
      clearTimeout(this._companionConfirmTimer)
      this._companionConfirmTimer = null
    }
    const camera = this._companionCameraOn(room)
    if (room) this._watchCompanionTrack(room)
    this.pushEvent("companion_media_state", { camera, ...extra })
    const native = this._nativeMeetings()
    // Stage 4 adds `setVideoActive`; an older build rejects unknown methods.
    if (native && typeof native.setVideoActive === "function") {
      try {
        Promise.resolve(native.setVideoActive({ camera })).catch(() => {})
      } catch (_) {
        /* an older bridge throwing synchronously */
      }
    }
  },

  // The camera track ending or being muted by the system (the camera taken
  // by another app, the app suspended) turns the companion camera OFF, so
  // remote tiles show the avatar rather than a frozen frame.
  _watchCompanionTrack(room) {
    const pub = this._localCameraPublication(room)
    const mst = pub && pub.track && pub.track.mediaStreamTrack
    if (!mst || typeof mst.addEventListener !== "function") return
    if (!this._watchedCompanionTracks) this._watchedCompanionTracks = new WeakSet()
    if (this._watchedCompanionTracks.has(mst)) return
    this._watchedCompanionTracks.add(mst)
    const off = () => this._companionCameraOff()
    mst.addEventListener("ended", off)
    mst.addEventListener("mute", off)
  },

  async _joinCompanion({ token, url, room_name } = {}) {
    // Only a native call whose build reported `capabilities().camera`. A
    // legacy or audio-only build keeps exactly today's page: no Room.
    if (!this._nativeMeetings() || this._nativeCapabilities?.camera !== true) return
    if (!token || !url) {
      console.error("[MeetingClient] join-companion missing token or url", { url })
      return
    }
    const existing = this._companionRoom
    if (existing && existing.state === "connected" && existing.name === room_name) {
      // A re-attach ("Open full meeting" on a call already up): report.
      this._pushCompanionState(existing)
      return
    }
    if (existing) await this._leaveCompanion()

    const room = this._newRoom()
    companionRooms.add(room)
    this._companionRoom = room
    if (!(await this._connectRoom(room, url, token, { autoSubscribe: false }))) {
      if (this._companionRoom === room) this._companionRoom = null
      return
    }

    this._reconcileLocalVideo(room)
    for (const participant of room.remoteParticipants.values()) {
      this._ensureTile(participant)
      for (const pub of participant.trackPublications.values()) {
        this._subscribeCompanionVideo(pub)
        if (pub.track && isVideoPublication(pub)) this._attachTrack(pub.track, participant, pub)
      }
    }
    this._pushMediaStates(room)
    this._pushCompanionState(room)
  },

  // `toggle-camera %{want}`: ask the companion and wait for its publication.
  // A rejection pushes the real state with `failed: "camera"`; no event
  // within COMPANION_CAMERA_TIMEOUT_MS reads the publication back the same
  // way, so a pending button always has an exit.
  async _setCompanionCamera(want) {
    const room = this._companionRoom
    if (!room || !room.localParticipant) {
      this._pushCompanionState(null, { failed: "camera" })
      return
    }
    if (this._companionConfirmTimer) clearTimeout(this._companionConfirmTimer)
    this._companionConfirmTimer = setTimeout(() => {
      this._companionConfirmTimer = null
      const camera = this._companionCameraOn(this._companionRoom)
      this._pushCompanionState(
        this._companionRoom,
        camera === want ? {} : { failed: "camera" },
      )
    }, COMPANION_CAMERA_TIMEOUT_MS)
    try {
      await room.localParticipant.setCameraEnabled(want)
    } catch (err) {
      console.warn("[MeetingClient] companion camera failed:", err && err.message)
      this._pushCompanionState(room, { failed: "camera" })
    }
  },

  // Background, page exit, the app resigning active, the track ending:
  // camera OFF, confirmed through the publication like any other change.
  // Nothing ever turns it back on except a tap.
  _companionCameraOff() {
    const room = this._companionRoom
    if (!room || !room.localParticipant) return
    Promise.resolve()
      .then(() => room.localParticipant.setCameraEnabled(false))
      .catch((err) => {
        console.warn("[MeetingClient] companion camera off failed:", err && err.message)
        this._pushCompanionState(room, { failed: "camera" })
      })
  },

  async _leaveCompanion() {
    const room = this._companionRoom
    if (!room) return
    this._companionRoom = null
    if (this._companionConfirmTimer) {
      clearTimeout(this._companionConfirmTimer)
      this._companionConfirmTimer = null
    }
    if (this._room === room) {
      await this._leave()
      return
    }
    await Promise.resolve(room.disconnect()).catch(() => {})
  },

  // Detach every RoomEvent listener we installed in `_bindRoomEvents` so
  // a subsequent re-bind (or a destroyed() cycle) doesn't accumulate.
  // Safe to call when nothing is bound. Called from `destroyed()`,
  // `_cleanupRoom()`, and `_bindRoomEvents()` (when re-binding to a
  // different Room object).
  _releaseRoomListeners() {
    const room = this._boundRoom
    if (room && typeof room.off === "function") {
      for (const [event, fn] of this._roomListeners) {
        try {
          room.off(event, fn)
        } catch (_) {
          /* listener may already be gone */
        }
      }
    }
    this._boundRoom = null
    this._roomListeners = []
  },

  // ── Native hand-off (task 01a10db7 stage 3) ─────────────────────────────
  //
  // Inside the Burrow iOS app the `SuiteMeetings` Capacitor plugin runs the
  // call natively (CallKit + the LiveKit Swift SDK). The page must then NOT
  // build its own Room: both connections would be the same `user:<id>`
  // identity, LiveKit would kick one out for the other, and the person would
  // hear the call twice. A payload without `meeting_id` (a chat quick-meet
  // whose space has no meeting row), or a browser without the plugin, keeps
  // the web path exactly as before.
  _nativeMeetings() {
    const plugins = window.Capacitor && window.Capacitor.Plugins
    // `BurrowMeetings` in newer app builds, `SuiteMeetings` in older ones
    // (task 01a14ba9): read either, Burrow first.
    return (plugins && (plugins.BurrowMeetings || plugins.SuiteMeetings)) || null
  },

  async _joinNative(native, meetingId) {
    this._nativeMeetingId = meetingId
    if (!this._nativeEndedHandle && typeof native.addListener === "function") {
      // The same `meeting_left` the Disconnected handler pushes, so the
      // server's roster and the mini-bar behave as for a web leave.
      this._nativeEndedHandle = native.addListener("callEnded", ({ meetingId: ended } = {}) => {
        if (!this._nativeMeetingId || ended !== this._nativeMeetingId) return
        this._nativeMeetingId = null
        this._leaveCompanion()
        this.pushEvent("meeting_left", {})
      })
    }
    try {
      // A call already up for this meeting ("Open full meeting") resolves
      // `already_in_call` natively: a no-op.
      await native.join({ meetingId })
    } catch (error) {
      console.error("[MeetingClient] native join failed", error && error.message)
      this._nativeMeetingId = null
      this.pushEvent("meeting_left", {})
      return
    }
    await this._attachNativeMedia(native)
  },

  // Task 01a13c62 stage 3. Tell the server the native call owns the media,
  // what this build can do from the page, and the CONFIRMED mic/camera.
  // Listeners go on first so a change between the read and the push is not
  // lost: it arrives as `native_media_state` after the attach.
  async _attachNativeMedia(native) {
    this._listenNativeMedia(native)

    let capabilities = LEGACY_NATIVE_CAPABILITIES
    try {
      if (typeof native.capabilities !== "function") throw new Error("no capabilities()")
      const caps = (await native.capabilities()) || {}
      capabilities = {
        mic: caps.mic === true,
        camera: caps.camera === true,
        activeSpeakers: caps.activeSpeakers === true,
      }
    } catch (_error) {
      // A build from before stage 2 rejects the unknown method.
      capabilities = LEGACY_NATIVE_CAPABILITIES
    }

    // `_joinCompanion` reads this: a build that did not say `camera: true`
    // never gets a companion Room, whatever the server pushes.
    this._nativeCapabilities = capabilities
    const state = await this._readNativeState(native)
    this.pushEvent("native_call_attached", {
      capabilities,
      mic: state.mic,
      camera: state.camera,
    })
  },

  // `{mic, camera}` from `state()`, each a boolean or null when the build
  // does not report it (a legacy `state()` has neither).
  async _readNativeState(native) {
    try {
      const state = (await native.state()) || {}
      return {
        mic: typeof state.mic === "boolean" ? state.mic : null,
        camera: typeof state.camera === "boolean" ? state.camera : null,
      }
    } catch (_error) {
      return { mic: null, camera: null }
    }
  },

  _listenNativeMedia(native) {
    if (typeof native.addListener !== "function") return
    if (!this._nativeMediaHandle) {
      // Every CONFIRMED change, whatever caused it: this page, the native
      // call screen, Control Centre, AirPods or the host.
      this._nativeMediaHandle = native.addListener("mediaChanged", (data = {}) => {
        this.pushEvent("native_media_state", {
          mic: typeof data.mic === "boolean" ? data.mic : null,
          camera: typeof data.camera === "boolean" ? data.camera : null,
        })
      })
    }
    if (!this._nativeAppStateHandle) {
      // Stage 4's plugin fires this on willResignActive, BEFORE the web view
      // is suspended: the last moment to take the companion camera down.
      this._nativeAppStateHandle = native.addListener("appStateChanged", (data = {}) => {
        if (data.active === false) this._companionCameraOff()
      })
    }
    if (!this._nativeSpeakersHandle) {
      // Same guards as `MeetingRoom._onActiveSpeaker`, from the same helper.
      this._nativeSpeakersHandle = native.addListener("activeSpeakers", (data = {}) => {
        offerActiveSpeakers(this, data.identities, (identities) =>
          this.pushEvent("active_speakers", { identities }),
        )
      })
    }
  },

  _leaveNative() {
    this._leaveCompanion()
    if (!this._nativeMeetingId) return
    const native = this._nativeMeetings()
    this._nativeMeetingId = null
    if (native && typeof native.leave === "function") native.leave().catch(() => {})
  },

  _releaseNativeListener() {
    const handles = [
      this._nativeEndedHandle,
      this._nativeMediaHandle,
      this._nativeSpeakersHandle,
      this._nativeAppStateHandle,
    ]
    this._nativeEndedHandle = null
    this._nativeMediaHandle = null
    this._nativeSpeakersHandle = null
    this._nativeAppStateHandle = null
    cancelActiveSpeakers(this)
    for (const handle of handles) {
      if (!handle) continue
      Promise.resolve(handle)
        .then((h) => h && typeof h.remove === "function" && h.remove())
        .catch(() => {})
    }
  },

  async _join({ token, url, room_name, mic_enabled, camera_enabled, meeting_id }) {
    const native = this._nativeMeetings()
    if (native && meeting_id) {
      await this._joinNative(native, meeting_id)
      return
    }

    // The lobby's choice (task 01a07410 / FE-17 stage 4). `mic_enabled` /
    // `camera_enabled` are the server's `:mic_enabled` / `:camera_enabled`
    // assigns at the moment of the join push — the same pair the in-call
    // toggles flip and the `#meeting-client` dataset mirrors. Resolved ONCE
    // here, before any await, so a toggle that lands mid-connect cannot
    // change what "initial" meant.
    const desired = this._desiredInitialMedia({ mic_enabled, camera_enabled })

    // Adopt instead of disconnect-then-reconnect when we already hold a
    // connected room (task 019e4b3e stage 1) — avoids the
    // publish->disconnect->republish thrash seen in an operator console.
    //
    // ...but only when it is the SAME room (task 01a06925 stage 2). The
    // Room is pinned on window across LiveView navigation, so a tab that
    // joined a quickmeet in space A and then live-navigated to a /meetings
    // page backed by space B kept space A's connection while the server
    // wrote its roster row for B and dispatched the invited agent into
    // space-B: the page showed the human present, the SFU saw nobody. The
    // token's `video.room` is what LiveKit admits and `room_name` is the
    // server's statement of it (pinned equal to the token in
    // invite_room_parity_test.exs), so it is what the adopted room's `name`
    // has to match.
    const existing = this._room || window.__livekit_room || window.__livekitRoom
    if (existing && existing.state === "connected") {
      if (!room_name) {
        // The server always sends room_name; a payload without it is an
        // older or foreign push. Keep the pre-stage-2 behaviour, but say so.
        console.warn(
          "[MeetingClient] join-meeting carried no room_name; adopting the connected room",
          { connected: existing.name },
        )
        this._adoptRoom(existing)
        return
      }
      if (existing.name === room_name) {
        this._adoptRoom(existing)
        return
      }
      console.warn(
        "[MeetingClient] join-meeting names a different room than the connected one; reconnecting",
        { connected: existing.name, requested: room_name },
      )
      // Release OUR listeners before disconnecting: the Disconnected handler
      // bound in _bindRoomEvents runs _cleanupRoom() and pushes
      // "meeting_left", which would take the human out of the meeting they
      // are joining right now. Then drop the pinned refs, tiles and
      // self-view so the fresh connect below starts from a clean slate.
      this._releaseRoomListeners()
      await existing.disconnect().catch(() => {})
      this._room = null
      window.__livekit_room = null
      window.__livekitRoom = null
      this._cleanupRoom()
    }

    if (this._room) {
      console.warn("[MeetingClient] join-meeting while already connected; disconnecting first")
      await this._room.disconnect().catch(() => {})
      this._room = null
    }

    if (!token || !url) {
      console.error("[MeetingClient] join-meeting missing token or url", { url })
      return
    }

    const room = this._newRoom()
    if (!(await this._connectRoom(room, url, token))) return

    // Enter the room in the state the lobby chose — NOT unconditionally
    // live. This used to be `setMicrophoneEnabled(true)`, which made joining
    // muted impossible: whatever the user had set before Join, the connect
    // path switched the mic on. `desired` is the lobby's/server's value, so
    // a guest who muted in the lobby is muted from the first packet, and
    // `_reconcileLocalMedia` below only ever turns things ON from the same
    // server intent, so the two cannot disagree.
    try {
      await room.localParticipant.setMicrophoneEnabled(desired.mic)
    } catch (err) {
      console.warn("[MeetingClient] could not set initial mic state:", err)
    }

    try {
      await room.localParticipant.setCameraEnabled(desired.camera)
    } catch (err) {
      console.warn("[MeetingClient] could not set initial camera state:", err)
    }

    this._ensureTile(room.localParticipant)

    // v2: if a local camera track is already published (e.g. fast re-join),
    // adopt it into the persistent self-view + dock into the current mode so
    // a fresh join lands the video in the right place without a switch.
    // Routed through the reconcile so a camera that is published-but-MUTED
    // (joined / re-joined with the camera off) parks instead of attaching a
    // black frame over the avatar.
    this._reconcileLocalVideo(room)

    for (const pub of room.localParticipant?.trackPublications?.values?.() || []) {
      const source = pub.source || pub.track?.source
      if (pub.track && isScreenShareSource(source)) {
        this._attachTrack(pub.track, room.localParticipant, pub)
      }
    }

    for (const participant of room.remoteParticipants.values()) {
      this._ensureTile(participant)
      for (const pub of participant.trackPublications.values()) {
        if (pub.track) this._attachTrack(pub.track, participant, pub)
      }
    }

    // Report what the room ALREADY looks like (task 01a0740c stage 2).
    // The people who were in the call before we connected arrive in the
    // JOIN RESPONSE, never as `ParticipantConnected`, and nobody
    // transitions on our account — so without this sweep a first-time
    // joiner sees every already-muted tile as unmuted. `pub.isMuted` is
    // populated from that join response, so this reads correctly whether
    // or not the subscriptions have landed yet.
    this._pushMediaStates(room)

    // v4 stage 2: drive the camera from committed server intent on the
    // INITIAL join too — not just on Reconnected/adopt. `_join` previously
    // only enabled the mic (line above), so a fresh /chat quick-meet join
    // published audio-only and the camera never turned on (v3 e2e: "only
    // the microphone track is published, 0 video publications"). Reusing
    // the same intent-sourced reconcile keeps join + reconnect camera-
    // engage on ONE code path so they can't drift, and honors a user who
    // joined with camera intentionally off (data-camera-enabled="false").
    // The resulting LocalTrackPublished fires _attachLocalVideo via
    // _bindRoomEvents, which parks the <video> into the [data-role=
    // "local-self-view"] slot (stage 2 change B adds one to the quick-meet
    // panel) and docks it. On the INITIAL join the intent is `desired` —
    // the join payload — not the dataset: the two come from the same
    // server assigns, but the payload is the value at the moment of Join
    // and is the one the lobby test pins.
    this._reconcileLocalMedia(room, desired)
  },

  // The Room both connections use: the web call's and the app's companion
  // (task 01a13ca2 stage 3 factored these two out of `_join`).
  _newRoom() {
    return new Room({
      adaptiveStream: true,
      dynacast: true,
      publishDefaults: { simulcast: true },
    })
  },

  // Bind, connect, then pin the Room where every other meeting hook looks
  // for it. `connectOptions` is passed only when given, so the web call's
  // `connect(url, token)` is exactly what it was.
  async _connectRoom(room, url, token, connectOptions) {
    this._bindRoomEvents(room)

    try {
      if (connectOptions) await room.connect(url, token, connectOptions)
      else await room.connect(url, token)
    } catch (err) {
      console.error("[MeetingClient] room.connect failed", err)
      return false
    }

    this._room = room
    window.__livekit_room = room
    window.__livekitRoom = room
    window.dispatchEvent(new CustomEvent("livekit:room-connected", { detail: { room } }))
    document.dispatchEvent(new CustomEvent("livekit:room-connected", { detail: { room } }))
    this._emitState("connected", room)
    return true
  },

  async _leave() {
    if (!this._room) return
    try {
      await this._room.disconnect()
    } catch (_) { /* already gone */ }
    this._cleanupRoom()
  },

  _cleanupRoom() {
    // Detach any listeners we installed before nulling our ref so a
    // future _join against a fresh Room starts from a clean slate.
    this._releaseRoomListeners()
    this._room = null
    window.__livekit_room = null
    window.__livekitRoom = null
    window.dispatchEvent(new CustomEvent("livekit:room-disconnected"))
    document.dispatchEvent(new CustomEvent("livekit:room-disconnected"))
    this._clearTiles()
    // v2: drop the persistent local self-view so a stale camera frame
    // doesn't linger after disconnect.
    this._teardownLocalVideo()
    // Task 019e420f stage 3: leave + rejoin must not leave a stale
    // screen-share preview behind.
    if (this._screenShareTrack) {
      this._detachScreenShareTrack(this._screenShareTrack)
    } else {
      // Defensive: clear any orphaned slot state even if our tracking
      // got out of sync with the room.
      this._screenShareController?.destroy()
      this._screenShareController = null
      document
        .querySelectorAll("[data-quickmeet-screen-share-slot]")
        .forEach((slot) => {
          while (slot.firstChild) slot.removeChild(slot.firstChild)
          slot.classList.add("hidden")
          slot.dataset.screenShareActive = "false"
          delete slot.dataset.screenShareSharer
          const label = slot.parentElement?.querySelector?.(
            "[data-quickmeet-screen-share-sharer]",
          )
          if (label) label.textContent = ""
        })
    }
  },

  // ── Reconnect signal + media reconcile (stages 3 + 4) ───────────────────

  // Emit a deterministic, race-free reconnect/connection signal for tests
  // (stage 5 e2e) AND prod observability. Sets `dataset.roomState` on the
  // `#meeting-client` element and dispatches a `livekit:state` DOM
  // CustomEvent carrying the local publishing booleans. The legacy
  // `livekit:room-connected`/`-disconnected` events stay (back-compat with
  // meeting_room.js). The operator debugs from the Safari console, so a one-line
  // console.info breadcrumb is left on each transition.
  _emitState(state, room) {
    if (this.el && this.el.dataset) this.el.dataset.roomState = state

    const lp = room && room.localParticipant
    const detail = {
      state,
      roomName: (room && room.name) || null,
      localPublishing: {
        camera: lp ? lp.isCameraEnabled === true : false,
        mic: lp ? lp.isMicrophoneEnabled === true : false,
      },
    }

    console.info("[MeetingClient] state", state)
    document.dispatchEvent(new CustomEvent("livekit:state", { detail }))
  },

  // Which mic/camera state to ENTER the room with (task 01a07410 stage 4).
  // The join payload wins; it is the server's `:mic_enabled` /
  // `:camera_enabled` at push time. A payload that omits the pair (an older
  // server, or a test that only hands over token+url) falls back to the
  // `#meeting-client` dataset, which mirrors the same assigns, and finally
  // to `true` — the pre-lobby behaviour, so nothing that never rendered a
  // lobby joins silently muted.
  _desiredInitialMedia({ mic_enabled, camera_enabled } = {}) {
    const ds = (this.el && this.el.dataset) || {}
    const pick = (fromPayload, fromDataset) => {
      if (typeof fromPayload === "boolean") return fromPayload
      if (fromDataset === "true") return true
      if (fromDataset === "false") return false
      return true
    }
    return {
      mic: pick(mic_enabled, ds.micEnabled),
      camera: pick(camera_enabled, ds.cameraEnabled),
    }
  },

  // Reconcile the local camera/mic against committed server intent after a
  // reconnect or remount-adopt (stage 3). Intent lives on the
  // `#meeting-client` dataset (data-camera-enabled / data-mic-enabled),
  // which the server controls — reading it is reconnect-safe and does not
  // depend on a fresh LV push (the operator's exact error was "unable to push hook
  // event. LiveView not connected").
  //
  // `intent` (optional, task 01a07410 stage 4) overrides the dataset read:
  // `_join` passes the resolved join-payload pair so the initial join and
  // the reconnect re-engage share ONE reconcile without the payload being
  // second-guessed by a dataset the LiveView may not have patched yet.
  //
  // DELIBERATELY ENABLE-ONLY (task 01a08d5a stage 2 — decision recorded,
  // branch NOT added). There is no `!wantMic && isMicrophoneEnabled` mute
  // branch on EITHER the dataset path or the `intent` override path, and
  // there must not be one without on-screen attribution:
  //
  //   * Design constraint (Saru, execution space 01a08e9d-f99e-7001-bcc5-
  //     06dbac269fc3, message 01a08e9e-b23a-7001-8772-f91033d49d65): a
  //     bidirectional reconciler can mute a live mic mid-sentence after a
  //     SILENT reconnect with nothing on screen attributing the cause.
  //     `_join` enters the room in the `_desiredInitialMedia` state (FE-17
  //     stage 4, c1b076bc), so a hot mic is no longer reachable from a
  //     fresh join; the mute branch would be defence in depth only, and
  //     its failure mode is worse than the gap it closes.
  //   * Intent and the SDK flag can drift with nobody wrong: `_toggleMic`
  //     may fail `setMicrophoneEnabled` after `toggle_mic/1` already
  //     flipped the assign optimistically, and a morphdom repatch can
  //     briefly serve a stale dataset. This runs from `reconnected()`,
  //     `_adoptRoom`, the LiveKit `Reconnected` event and the tail of
  //     `_join`, so any 1006 blip would fire it. Muting silently on drift
  //     is Saru's case. (A LiveView socket reconnect used to re-seed
  //     `:mic_enabled` to `true` on remount; task 01a08d5a stage 3 keeps
  //     the committed pair across the remount instead.)
  //
  // Pinned by "reconciler is enable-only" tests in
  // test/hooks/meeting_client.test.js; a future bidirectional change must
  // fail those tests and re-read this comment.
  _reconcileLocalMedia(room, intent) {
    // A companion never touches the mic, and its camera comes back only on a
    // tap (task 01a13ca2 stage 3), so there is nothing to reconcile.
    if (isCompanionRoom(room)) return
    const lp = room && room.localParticipant
    if (!lp) return
    const ds = (this.el && this.el.dataset) || {}

    const wantCamera = intent ? intent.camera === true : ds.cameraEnabled === "true"
    const wantMic = intent ? intent.mic === true : ds.micEnabled === "true"

    if (wantCamera && lp.isCameraEnabled === false) {
      Promise.resolve(lp.setCameraEnabled(true)).catch((err) =>
        console.warn("[MeetingClient] reconnect camera re-engage failed:", err),
      )
    }
    if (wantMic && lp.isMicrophoneEnabled === false) {
      Promise.resolve(lp.setMicrophoneEnabled(true)).catch((err) =>
        console.warn("[MeetingClient] reconnect mic re-engage failed:", err),
      )
    }
  },

  async _toggleMic(payload) {
    // Native mode (task 01a13c62 stage 3): the server sends `want` only when
    // the native call owns the mic, and leaves the button pending until the
    // call CONFIRMS. A browser push carries no `want` and takes the Room path.
    const native = this._nativeMeetings()
    if (native && payload && typeof payload.want === "boolean") {
      await this._setNativeMuted(native, !payload.want)
      return
    }
    const room = this._room
    if (!room || !room.localParticipant) return
    const enabled = room.localParticipant.isMicrophoneEnabled
    try {
      await room.localParticipant.setMicrophoneEnabled(!enabled)
      // Server already flipped :mic_enabled optimistically via meeting_toggle_mic.
    } catch (err) {
      console.warn("[MeetingClient] mic toggle failed:", err)
    }
  },

  // Race the plugin's confirmed `setMuted` against NATIVE_MUTE_TIMEOUT_MS.
  // A confirmation pushes the confirmed state; a rejection or timeout reads
  // the native state back and pushes it with `failed: "mic"`, so the button
  // returns to what the call really has and shows the one-line error.
  async _setNativeMuted(native, muted) {
    let timer = null
    const timeout = new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error("timeout")), NATIVE_MUTE_TIMEOUT_MS)
    })
    try {
      if (typeof native.setMuted !== "function") throw new Error("no setMuted()")
      const result = (await Promise.race([native.setMuted({ muted }), timeout])) || {}
      const state = await this._readNativeState(native)
      this.pushEvent("native_media_state", {
        mic: typeof result.mic === "boolean" ? result.mic : state.mic,
        camera: state.camera,
      })
    } catch (error) {
      console.warn("[MeetingClient] native mute failed:", error && error.message)
      const state = await this._readNativeState(native)
      this.pushEvent("native_media_state", { ...state, failed: "mic" })
    } finally {
      clearTimeout(timer)
    }
  },

  async _toggleCamera(payload) {
    // With the companion the server sends `want` and waits for the
    // publication; a browser push carries no `want` and takes the Room path.
    if (payload && typeof payload.want === "boolean") {
      await this._setCompanionCamera(payload.want)
      return
    }
    const room = this._room
    if (!room || !room.localParticipant) return
    const enabled = room.localParticipant.isCameraEnabled
    try {
      await room.localParticipant.setCameraEnabled(!enabled)
      // Server already flipped :camera_enabled optimistically via meeting_toggle_camera.
    } catch (err) {
      console.warn("[MeetingClient] camera toggle failed:", err)
    }
  },

  async _toggleScreenShare() {
    const room = this._room
    if (!room || !room.localParticipant) return
    try {
      await toggleScreenShare(room)
    } catch (err) {
      console.warn("[MeetingClient] screen-share toggle failed:", err)
    }
  },

  // ── Tile rendering ─────────────────────────────────────────────────────

  _grid() {
    // Two panels render simultaneously — desktop side pane (lg:flex,
    // hidden below lg) and mobile full-screen overlay (lg:hidden).
    // `matchMedia` is deterministic where `offsetParent` isn't: the mobile
    // overlay uses position:fixed, which makes visibility probing brittle
    // and historically left tiles appended to the hidden desktop grid.
    const isDesktop = window.matchMedia("(min-width: 1024px)").matches
    return document.getElementById(
      isDesktop ? "meeting-participants" : "meeting-participants-mobile"
    )
  },

  // Lazily-created, JS-owned, body-level audio sink. Previously this returned
  // `#meeting-media`, which is server-rendered by meeting_live.html.heex and
  // chat/partials.ex — but NOT by OrgMemoryLive. All three surfaces sit in
  // `live_session :authenticated`, so navigating between them is a live
  // redirect with no page reload: LiveView swaps the DOM, `#meeting-media`
  // is removed, and every remote <audio> child goes with it while the
  // LiveKit Room happily survives on window.__livekit_room. No LiveView
  // renders `#meeting-audio-sink`, so no morphdom patch and no live-nav
  // swap can remove it.
  _mediaContainer() {
    const existing = document.getElementById("meeting-audio-sink")
    if (existing) return existing

    const sink = document.createElement("div")
    sink.id = "meeting-audio-sink"
    if (sink.style) sink.style.display = "none"
    // Guard a missing document.body (the vitest fake document): return the
    // sink itself rather than throwing.
    if (document.body) document.body.appendChild(sink)
    return sink
  },

  // On MeetingLive (`/meetings`) the `#meeting-participants` grids no longer
  // exist, so `_grid()` returns null and this path no-ops (the MeetingVideoTile
  // hook owns rendering there). BUT the quick-meet panel (ChatLive) DOES still
  // render `#meeting-participants` / `-mobile`, so this path is live there for
  // REMOTE participant tiles. Do NOT re-wire the detach side — re-wiring would
  // resurrect the global-detach race fixed in 019e42f6.
  _ensureTile(participant) {
    const grid = this._grid()
    if (!grid) return
    // The local participant is already shown by the self-view dock (live
    // video) + the server roster row (name). A grid tile here is a redundant
    // black duplicate — "(you)" with no video, since the local camera docks
    // into [data-local-video-dock], not this tile. Skip it so the local user
    // renders exactly once (parity with remote: one roster row + one tile).
    if (participant.isLocal) return
    // The app's own native call (`user:<me>`) is a REMOTE participant of the
    // companion Room (`video:user:<me>`): the same person as the local self,
    // who is shown by the self-view dock. A browser Room never holds a
    // remote with the local identity, so this is a no-op there.
    if (this._isSelf(participant)) return
    // Task 01a0d4fe stage 3: the meeting transcriber worker joins the room
    // as a LiveKit participant but is not a person, so it gets no tile.
    // Every tile path (ParticipantConnected, adopt, rejoin, _attachTrack)
    // funnels through here, so one check covers them all.
    if (this._isTranscriber(participant)) return
    // One tile per PERSON: a companion (`video:user:<uuid>`) joins its
    // person's tile, and creates it under the person's identity when it
    // arrives first. Idempotent by person.
    const { identity } = participant
    const person = personIdentity(identity)
    if (this._tiles.has(person)) {
      this._addTileConnection(person, identity)
      return
    }

    // Name, then the server's map for resolved agents (a legacy
    // `agent-AJ_…` voice worker has no LiveKit name; task 01a1117f stage 5),
    // then the identity.
    const displayName = participantLabel(participant, readParticipantNames(this.el))
    const initial = (displayName.trim()[0] || "?").toUpperCase()

    const tile = document.createElement("div")
    tile.dataset.participant = person
    if (participant.isLocal) tile.dataset.local = "true"
    tile.className = "meeting-tile"

    const avatar = document.createElement("div")
    avatar.className = "meeting-tile-avatar"
    avatar.dataset.placeholder = ""
    const circle = document.createElement("div")
    circle.className = "meeting-tile-avatar-circle"
    circle.textContent = initial
    avatar.appendChild(circle)
    tile.appendChild(avatar)

    const name = document.createElement("div")
    name.className = "meeting-tile-name"
    name.textContent = displayName
    if (participant.isLocal) {
      const you = document.createElement("span")
      you.className = "meeting-tile-you"
      you.textContent = "(you)"
      name.appendChild(you)
    }
    tile.appendChild(name)

    grid.appendChild(tile)
    this._tiles.set(person, tile)
    this._addTileConnection(person, identity)
  },

  _isSelf(participant) {
    const room = this._room || this._boundRoom
    const me = room && room.localParticipant && room.localParticipant.identity
    if (!me || !participant || !participant.identity) return false
    return personIdentity(participant.identity) === personIdentity(me)
  },

  // person -> Set of the raw LiveKit identities currently backing its tile.
  _addTileConnection(person, identity) {
    if (!this._tileConnections) this._tileConnections = new Map()
    let set = this._tileConnections.get(person)
    if (!set) {
      set = new Set()
      this._tileConnections.set(person, set)
    }
    set.add(identity)
  },

  // Camera <video> elements a tile holds, per raw connection identity, so a
  // companion disconnect can drop exactly its own video and nothing else.
  _rememberConnectionVideo(identity, track, el) {
    if (!identity) return
    if (!this._connectionVideos) this._connectionVideos = new Map()
    let list = this._connectionVideos.get(identity)
    if (!list) {
      list = []
      this._connectionVideos.set(identity, list)
    }
    list.push({ track, el })
  },

  _forgetConnectionTrack(identity, track) {
    const list = this._connectionVideos && this._connectionVideos.get(identity)
    if (!list) return
    const rest = list.filter((entry) => entry.track !== track)
    if (rest.length) this._connectionVideos.set(identity, rest)
    else this._connectionVideos.delete(identity)
  },

  _dropConnectionVideo(identity, tile) {
    const list = this._connectionVideos && this._connectionVideos.get(identity)
    if (this._connectionVideos) this._connectionVideos.delete(identity)
    if (!list || !tile) return
    for (const { track, el } of list) {
      try {
        track.detach?.(el)
      } catch (_) {
        /* already detached */
      }
      el.remove?.()
    }
    this._showTilePlaceholderIfDark(tile)
  },

  // After a companion's video leaves: back to the avatar only when the tile
  // holds no other video (the person's own connection may still have one).
  _showTilePlaceholderIfDark(tile) {
    const wrapper = tile.querySelector(".meeting-tile-video")
    if (wrapper && wrapper.querySelector("video")) return
    if (wrapper) wrapper.style.display = "none"
    const placeholder = tile.querySelector("[data-placeholder]")
    if (placeholder) placeholder.style.display = ""
  },

  // The transcriber identity markers, pushed by the server as JSON on
  // `#meeting-client[data-transcriber-markers]` from
  // `Platform.Meetings.transcriber_identity_markers/0` — the ONLY definition
  // of the list. Nothing is hard-coded here. Re-read on every call (no
  // caching) so a config change applied on the next LiveView patch takes
  // effect. A missing or malformed attribute yields `[]`: showing a tile
  // for the worker is the safe failure, hiding a human is not.
  _transcriberMarkers() {
    const raw = this.el && this.el.dataset && this.el.dataset.transcriberMarkers
    if (!raw) return []
    try {
      const parsed = JSON.parse(raw)
      if (!Array.isArray(parsed)) return []
      // Markers are used as given (the server does not downcase them
      // either). Empty strings are dropped: `"x".includes("")` is true, so
      // one would hide every participant.
      return parsed.filter((m) => typeof m === "string" && m !== "")
    } catch (_err) {
      return []
    }
  },

  // Mirrors `marker_match?/1` in Platform.Meetings: downcased substring
  // match of the participant's identity and name against each marker.
  _isTranscriber(participant) {
    if (!participant) return false
    const markers = this._transcriberMarkers()
    if (markers.length === 0) return false
    const haystacks = [participant.identity, participant.name]
      .filter((v) => typeof v === "string")
      .map((v) => v.toLowerCase())
    return haystacks.some((h) => markers.some((m) => h.includes(m)))
  },

  // One CONNECTION left. The person's tile stays while another of their
  // connections remains (only the leaver's video goes) and is removed with
  // the last one.
  _removeTile(identity) {
    const person = personIdentity(identity)
    const tile = this._tiles.get(person)
    if (!tile) return
    const connections = this._tileConnections && this._tileConnections.get(person)
    if (connections) {
      connections.delete(identity)
      if (connections.size > 0) {
        this._dropConnectionVideo(identity, tile)
        return
      }
      this._tileConnections.delete(person)
    }
    if (this._connectionVideos) this._connectionVideos.delete(identity)
    tile.remove()
    this._tiles.delete(person)
  },

  _clearTiles() {
    for (const tile of this._tiles.values()) tile.remove()
    this._tiles.clear()
    if (this._tileConnections) this._tileConnections.clear()
    if (this._connectionVideos) this._connectionVideos.clear()
  },

  // The screen-share sharer, as the PERSON: a share published by a
  // companion connection is attributed to its person, never `video:user:…`.
  _sharerIdentity(participant) {
    return personIdentity(participant?.identity || "")
  },

  // The sharer, by NAME (task 01a13ca2 stage 5): their own LiveKit name,
  // another connection of the same person in the room, then the server's
  // name map. A nameless `video:user:X` share reads as X's name.
  _sharerLabel(participant) {
    return personLabel(participant, this._room, readParticipantNames(this.el))
  },

  _screenShareSlot() {
    // Find the *visible* dedicated screen-share slot. Quick Meet renders
    // two: one in the desktop side pane (`lg:flex`, hidden below `lg`)
    // and one in the mobile overlay (`lg:hidden`). The hidden one is
    // display:none so its `offsetParent` is null; the visible one isn't.
    // We pick whichever is currently rendered (parity with the
    // `_grid()` matchMedia approach above).
    const isDesktop = window.matchMedia("(min-width: 1024px)").matches
    const desktopSlot = document.querySelector(
      "[data-quickmeet-screen-share-slot][data-pane='desktop']",
    )
    const mobileSlot = document.querySelector(
      "[data-quickmeet-screen-share-slot][data-pane='mobile']",
    )

    if (isDesktop) return desktopSlot || mobileSlot
    return mobileSlot || desktopSlot
  },

  _mountScreenShareController(slot, video, publication) {
    this._screenShareController?.destroy()
    const viewer = slot?.parentElement || slot
    const button = viewer?.querySelector?.("[data-screen-share-fullscreen]")
    this._screenShareController = new ScreenShareFullscreenController({
      root: viewer,
      viewport: viewer,
      button,
      video,
      publication,
      env: window,
    }).mount()
  },

  // Desktop and mobile Quick Meet panes coexist in the DOM. Move the already
  // attached video on a breakpoint/orientation change; never detach or
  // republish the LiveKit track merely because the visible pane changed.
  _rehomeScreenShare() {
    const track = this._screenShareTrack
    const video = this._screenShareEl
    if (!track || !video) return
    const slot = this._screenShareSlot()
    if (!slot) return
    if (video.parentElement === slot) {
      const button = slot.parentElement?.querySelector?.("[data-screen-share-fullscreen]")
      // The viewer is phx-update="ignore" (task 01a13ca2 stage 5), so a
      // patch no longer reaches the slot, button or sharer label. This
      // hook's `updated()` only runs when `#meeting-client` itself changes,
      // so it was never the thing keeping them alive. Re-stamp the active
      // surface on every hook update so fullscreen does not silently vanish
      // after a roster/timer/LiveView reconnect render.
      slot.classList?.remove("hidden")
      slot.dataset.screenShareActive = "true"
      if (this._screenShareParticipant?.identity) {
        slot.dataset.screenShareSharer = this._sharerIdentity(this._screenShareParticipant)
      }
      const label = slot.parentElement?.querySelector?.(
        "[data-quickmeet-screen-share-sharer]",
      )
      if (label) {
        label.textContent = this._sharerLabel(this._screenShareParticipant)
      }
      if (button) button.hidden = false
      if (this._screenShareController?.button !== button) {
        this._mountScreenShareController(slot, video, this._screenSharePublication)
      }
      return
    }

    const oldSlot = video.parentElement
    this._screenShareController?.destroy()
    this._screenShareController = null

    if (oldSlot?.dataset) {
      oldSlot.dataset.screenShareActive = "false"
      delete oldSlot.dataset.screenShareSharer
      oldSlot.classList?.add("hidden")
      const oldLabel = oldSlot.parentElement?.querySelector?.(
        "[data-quickmeet-screen-share-sharer]",
      )
      if (oldLabel) oldLabel.textContent = ""
    }

    while (slot.firstChild) slot.removeChild(slot.firstChild)
    slot.appendChild(video)
    slot.classList.remove("hidden")
    slot.dataset.screenShareActive = "true"
    if (this._screenShareParticipant?.identity) {
      slot.dataset.screenShareSharer = this._sharerIdentity(this._screenShareParticipant)
    }
    const label = slot.parentElement?.querySelector?.("[data-quickmeet-screen-share-sharer]")
    if (label) {
      label.textContent = this._sharerLabel(this._screenShareParticipant)
    }
    this._mountScreenShareController(slot, video, this._screenSharePublication)
  },

  _attachTrack(track, participant, publication = null) {
    if (track.kind === Track.Kind.Video) {
      // Task 019e420f stage 3: route screen-share video to a dedicated
      // full-width container instead of cramming it into the
      // participant's avatar tile (where it rendered ~80×80). Cameras
      // continue to attach into the tile as before.
      if (isScreenShareSource(track.source)) {
        this._attachScreenShareTrack(track, participant, publication)
        return
      }

      this._ensureTile(participant)
      const tile = this._tiles.get(personIdentity(participant.identity))
      if (!tile) return

      let wrapper = tile.querySelector(".meeting-tile-video")
      if (!wrapper) {
        wrapper = document.createElement("div")
        wrapper.className = "meeting-tile-video"
        tile.insertBefore(wrapper, tile.firstChild)
      }
      wrapper.style.display = "block"

      const placeholder = tile.querySelector("[data-placeholder]")
      if (placeholder) placeholder.style.display = "none"

      const el = track.attach()
      el.autoplay = true
      el.playsInline = true
      el.muted = participant.isLocal === true
      wrapper.appendChild(el)
      this._rememberConnectionVideo(participant.identity, track, el)
    } else if (track.kind === Track.Kind.Audio) {
      // STAYS: attaching local audio creates an echo loop.
      if (participant.isLocal) return

      const sink = this._mediaContainer()
      const key = track.sid || track.mediaStreamID
      // Map first; fall back to the sink itself, because destroyed() clears
      // the Map while the elements survive — after a live-nav re-mount the
      // element is still parked in the sink and must be re-adopted, not
      // re-attached (that is what would double the audio).
      const mapped = key ? this._audioEls?.get(key) : null
      const existing =
        mapped ||
        (key && sink.querySelector
          ? sink.querySelector(`[data-audio-track="${key}"]`)
          : null)

      // reparent, do not re-attach — `track.attach()` called repeatedly
      // creates duplicate elements and doubled audio.
      if (existing && existing.isConnected !== false && existing.parentElement) {
        sink.appendChild(existing)
        if (key) this._audioEls?.set(key, existing)
        return
      }

      const el = track.attach()
      el.autoplay = true
      if (key && el.setAttribute) el.setAttribute("data-audio-track", key)
      if (key && el.dataset) el.dataset.audioTrack = key
      sink.appendChild(el)
      if (key) this._audioEls?.set(key, el)
    }
  },

  /**
   * Attach the first published screen-share track into the Quick Meet
   * dedicated preview slot above the participants grid. Single-sharer
   * policy: if a track is already attached, the second one is ignored
   * until the first ends (mirrors `MeetingScreenShare._syncExistingTrack`).
   */
  _attachScreenShareTrack(track, participant, publication = null) {
    const slot = this._screenShareSlot()
    if (!slot) return
    if (this._screenShareTrack === track) return

    // First-published-wins: if a different track is already attached,
    // leave it alone — the user can stop sharing to free the slot.
    if (this._screenShareTrack) return

    const el = track.attach()
    el.autoplay = true
    el.playsInline = true
    el.muted = true
    el.className = "h-full w-full object-contain bg-viewer"

    // Clear any prior <video> children defensively (e.g. a hot-reload
    // landed mid-share and left a stale node).
    while (slot.firstChild) slot.removeChild(slot.firstChild)
    slot.appendChild(el)

    slot.classList.remove("hidden")
    slot.dataset.screenShareActive = "true"
    if (participant?.identity) {
      slot.dataset.screenShareSharer = this._sharerIdentity(participant)
    }

    const sharerLabel = slot.parentElement?.querySelector(
      "[data-quickmeet-screen-share-sharer]",
    )
    if (sharerLabel) {
      sharerLabel.textContent = this._sharerLabel(participant)
    }

    this._screenShareTrack = track
    this._screenShareEl = el
    this._screenSharePublication = publication
    this._screenShareParticipant = participant
    this._mountScreenShareController(slot, el, publication)
  },

  _detachTrack(track, participant) {
    if (track.kind === Track.Kind.Video && isScreenShareSource(track.source)) {
      this._detachScreenShareTrack(track)
      return
    }

    const elements = track.detach()
    elements.forEach((el) => el.remove())

    if (track.kind === Track.Kind.Video) {
      this._forgetConnectionTrack(participant?.identity, track)
      const tile = this._tiles.get(personIdentity(participant?.identity))
      if (!tile) return
      const wrapper = tile.querySelector(".meeting-tile-video")
      if (wrapper && !wrapper.querySelector("video")) {
        wrapper.style.display = "none"
      }
      const placeholder = tile.querySelector("[data-placeholder]")
      if (placeholder) placeholder.style.display = ""
    }
  },

  _detachScreenShareTrack(track) {
    // Drop our own reference if this matches; otherwise still detach the
    // <video> elements so a stale track doesn't keep painting.
    try {
      const elements = track.detach()
      elements.forEach((el) => el.remove())
    } catch (_) {
      /* track may already be detached */
    }

    if (this._screenShareTrack && this._screenShareTrack !== track) {
      // A different track ended — leave the currently-attached one alone.
      return
    }

    this._screenShareController?.destroy()
    this._screenShareController = null
    this._screenShareTrack = null
    this._screenShareEl = null
    this._screenSharePublication = null
    this._screenShareParticipant = null

    // Hide both slots — only one is visible at a time but resetting both
    // keeps the orientation-flip path clean.
    document
      .querySelectorAll("[data-quickmeet-screen-share-slot]")
      .forEach((slot) => {
        while (slot.firstChild) slot.removeChild(slot.firstChild)
        slot.classList.add("hidden")
        slot.dataset.screenShareActive = "false"
        delete slot.dataset.screenShareSharer
        const sharerLabel = slot.parentElement?.querySelector(
          "[data-quickmeet-screen-share-sharer]",
        )
        if (sharerLabel) sharerLabel.textContent = ""
      })
  },

  // Tiles are keyed by person, so speakers are folded to their person too
  // (a Set dedupes `user:A` + `video:user:A` into one ring).
  _markSpeakers(identities) {
    const speaking = new Set((identities || []).map(personIdentity))
    for (const [person, tile] of this._tiles) {
      tile.classList.toggle("meeting-tile-speaking", speaking.has(person))
    }
  },
}

export default MeetingClient
