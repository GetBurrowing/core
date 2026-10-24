import { personIdentity, personLabel, readParticipantNames } from "./lib/participant_label"
import { ScreenShareFullscreenController } from "./lib/screen_share_viewer"

/**
 * MeetingScreenShare hook — attaches the active LiveKit screen-share track
 * to the Screen-mode center stage.
 *
 * Task: 019e2474-bc7c — Meetings: stage-mode switcher (stage 3 — Screen +
 * Gallery mode renderers).
 *
 * Stage-mode contract: the server renders an empty `[data-screen-share-slot]`
 * inside the Screen-mode panel. This hook walks the LiveKit room looking for
 * the FIRST published track whose `source` is `screen_share` and attaches its
 * `<video>` element into the slot. When the screen-share track ends, the hook
 * detaches and toggles the empty-state placeholder back on.
 *
 * The LiveKit Room is expected at `window.__livekit_room` (mirrors
 * meeting_video_tile.js + meeting_client.js). The hook gracefully no-ops when
 * no room is available and binds once a `livekit:room-connected` event fires.
 *
 * Patch survival (task 01a13ca2 stage 5): every LiveView patch of the meeting
 * page used to revert this hook's state. morphdom reset the root's
 * `data-screen-share-active` to the template's "false", removed
 * `data-screen-share-sharer`, put the "No active screen-share" placeholder
 * back over the live video and re-hid the full-screen button, while
 * `updated()` only re-attached when it had NO track. The root now carries
 * `phx-update="ignore"`, so its children (slot, placeholder, button, sharer
 * label) are the hook's alone. LiveView still copies the root's own `data-*`
 * attributes from the template on every patch, and calls `updated()` when
 * that changed them, so `updated()` re-stamps the whole surface from the
 * hook's JS state (`_stamp`), never from the DOM it is correcting.
 *
 * Share-end teardown (task 01a13ca2, stage-5 regression): with the root
 * ignored, a LiveView patch no longer puts the placeholder back, so the hook
 * is the ONLY thing that can end the "X is sharing" state. Detaching only on
 * `trackUnsubscribed` with an exact track match left the label over a black
 * frame when the share ended by another route. The hook now releases the
 * share on any of: `trackUnsubscribed` (by track or publication),
 * `trackUnpublished` (by publication or trackSid — LiveKit clears
 * `pub.track` before emitting it), the track's own `ended`, and the
 * sharer's `participantDisconnected`. `updated()` also drops a share whose
 * publication has left its participant or whose media track has ended, then
 * stamps the cleared state (placeholder shown, label and full-screen button
 * hidden, `data-screen-share-active="false"`, no sharer).
 *
 * Mode-switch survival: `data-stage-mode` flips on the `<main>` ancestor, but
 * the LiveKit Room and its track subscriptions live on `window.__livekit_room`
 * — switching to Gallery and back does NOT re-subscribe; the next mount's
 * `_syncExistingTrack` reattaches the same `MediaStreamTrack` synchronously.
 */
const ended = (track) => track?.mediaStreamTrack?.readyState === "ended"

const MeetingScreenShare = {
  mounted() {
    this._videoEl = null
    this._attachedTrack = null
    this._sharerIdentity = null
    this._sharerParticipant = null
    this._publication = null
    this._fullscreenController = null

    this._boundTrackSubscribed = this._onTrackSubscribed.bind(this)
    // trackUnsubscribed(track, pub), trackUnpublished(pub) and the track's
    // own `ended`(track) all end the share when either argument is it.
    this._gone = (a, b) => {
      if ([a, b].some((x) => this._isAttached(x))) this._endShare()
    }
    this._left = (p) => {
      if (this._attachedTrack && p?.identity && p.identity === this._sharerParticipant?.identity) this._endShare(p)
    }
    this._boundLocalPublished = this._onLocalPublished.bind(this)
    this._boundLocalUnpublished = this._onLocalUnpublished.bind(this)

    this._tryBind()
  },

  updated() {
    this._tryBind()
    // A share the room already let go of: its media ended, or its
    // publication no longer holds it (LiveKit clears pub.track on unpublish).
    const t = this._attachedTrack
    const pub = this._publication
    if (t && (ended(t) || (pub && "track" in pub && pub.track !== t))) this._endShare()
    this._syncExistingTrack()
    this._stamp()
    if (
      this._attachedTrack &&
      this._fullscreenController?.button !== this._fullscreenButton()
    ) {
      this._mountFullscreenController()
    }
  },

  destroyed() {
    this._detach()
    this._unbind()
  },

  // ── Private ────────────────────────────────────────────────────────────

  _slot() {
    return this.el.querySelector("[data-screen-share-slot]")
  },

  _placeholder() {
    return this.el.querySelector("[data-screen-share-empty]")
  },

  _fullscreenButton() {
    return this.el.querySelector("[data-screen-share-fullscreen]")
  },

  _sharerLabelEl() {
    return this.el.querySelector("[data-screen-share-sharer-label]")
  },

  _sharerNameEl() {
    return this.el.querySelector("[data-screen-share-sharer-name]")
  },

  // The sharer, by NAME: their own LiveKit name, another connection of the
  // same person, or the server's name map. Never a `video:user:…` identity.
  _sharerName() {
    const client = typeof document !== "undefined" ? document.getElementById?.("meeting-client") : null
    return personLabel(this._sharerParticipant, this._room, readParticipantNames(client))
  },

  /**
   * Write the whole visible state from the hook's own fields: the slot, the
   * placeholder, the root's data attributes and the sharer label. Idempotent;
   * `_attach`, `_detach` and every `updated()` call it.
   */
  _stamp() {
    const active = !!this._attachedTrack
    const slot = this._slot()
    if (slot) {
      if (active) slot.classList.remove("hidden")
      else slot.classList.add("hidden")
    }
    const placeholder = this._placeholder()
    if (placeholder) {
      if (active) placeholder.classList.add("hidden")
      else placeholder.classList.remove("hidden")
    }

    this.el.dataset.screenShareActive = active ? "true" : "false"
    if (active && this._sharerIdentity) {
      this.el.dataset.screenShareSharer = this._sharerIdentity
    } else {
      delete this.el.dataset.screenShareSharer
    }

    const name = active ? this._sharerName() : ""
    const nameEl = this._sharerNameEl()
    if (nameEl && nameEl.textContent !== name) nameEl.textContent = name
    const label = this._sharerLabelEl()
    if (label) label.hidden = !name

    const button = this._fullscreenButton()
    if (active) {
      if (button && this._fullscreenController?.button === button) button.hidden = false
    } else if (button) {
      button.hidden = true
    }
  },

  _tryBind() {
    const room = window.__livekit_room || window.__livekitRoom
    if (!room) {
      if (!this._waitingForRoom) {
        this._waitingForRoom = true
        this._roomListener = () => {
          this._waitingForRoom = false
          this._tryBind()
          this._syncExistingTrack()
        }
        document.addEventListener("livekit:room-connected", this._roomListener, {
          once: true,
        })
      }
      return
    }

    if (this._room === room) return
    this._unbind()
    this._room = room

    try {
      room.on("trackSubscribed", this._boundTrackSubscribed)
      room.on("trackUnsubscribed", this._gone)
      room.on("trackUnpublished", this._gone)
      room.on("participantDisconnected", this._left)
      room.on("localTrackPublished", this._boundLocalPublished)
      room.on("localTrackUnpublished", this._boundLocalUnpublished)
    } catch (e) {
      console.warn("[MeetingScreenShare] failed to subscribe to room events:", e)
      return
    }

    this._syncExistingTrack()
  },

  _unbind() {
    if (this._room) {
      try {
        this._room.off("trackSubscribed", this._boundTrackSubscribed)
        this._room.off("trackUnsubscribed", this._gone)
        this._room.off("trackUnpublished", this._gone)
        this._room.off("participantDisconnected", this._left)
        this._room.off("localTrackPublished", this._boundLocalPublished)
        this._room.off("localTrackUnpublished", this._boundLocalUnpublished)
      } catch (_) {
        /* room may already be disconnected */
      }
      this._room = null
    }
  },

  /**
   * Walk the room's participants looking for the first published screen-share
   * track and attach it. Covers the case where someone was already sharing
   * before this hook mounted (e.g. the user switched from Gallery to Screen
   * after a peer started sharing).
   */
  _syncExistingTrack(skipTrack, skipParticipant) {
    const room = this._room
    if (!room || this._attachedTrack) return

    const participants = []
    if (room.localParticipant) participants.push(room.localParticipant)
    if (room.remoteParticipants) {
      for (const p of room.remoteParticipants.values()) participants.push(p)
    }

    for (const participant of participants) {
      if (participant === skipParticipant) continue
      const pubs = participant.trackPublications || participant.tracks
      if (!pubs) continue
      for (const pub of pubs.values()) {
        if (pub.track && pub.track !== skipTrack && this._isScreenShare(pub) && !ended(pub.track)) {
          this._attach(pub.track, participant, pub)
          return
        }
      }
    }
  },

  _isScreenShare(pubOrTrack) {
    // LiveKit exposes `source` on both publications and tracks. Track.Source
    // values: "camera", "microphone", "screen_share", "screen_share_audio",
    // "unknown". We only want the video source, not the optional audio.
    const source = pubOrTrack?.source || pubOrTrack?.track?.source
    return source === "screen_share"
  },

  _onTrackSubscribed(track, pub, participant) {
    if (!this._isScreenShare(pub) && !this._isScreenShare(track)) return
    if (this._attachedTrack) return
    this._attach(track, participant, pub)
  },

  // The attached share, by track, publication or trackSid.
  _isAttached(x) {
    const pub = this._publication
    return (
      !!this._attachedTrack &&
      !!x &&
      (x === this._attachedTrack || x === pub || (!!x.trackSid && x.trackSid === pub?.trackSid))
    )
  },

  // Release the share and stamp the cleared state, then pick up another
  // sharer if one exists (rare: two peers sharing, one ends), never the track
  // or participant that just went away.
  _endShare(skipParticipant) {
    const track = this._attachedTrack
    this._detach()
    this._syncExistingTrack(track, skipParticipant)
  },

  _onLocalPublished(pub) {
    if (!this._isScreenShare(pub)) return
    if (this._attachedTrack) return
    if (pub?.track) this._attach(pub.track, this._room?.localParticipant, pub)
  },

  _onLocalUnpublished(pub) {
    if (this._isScreenShare(pub)) this._gone(pub, pub?.track)
  },

  _attach(track, participant, publication = null) {
    const slot = this._slot()
    if (!slot) return
    if (this._attachedTrack === track) return

    this._detach()

    const el = track.attach()
    el.autoplay = true
    el.playsInline = true
    el.muted = true
    el.className = "h-full w-full object-contain bg-black"

    slot.appendChild(el)
    this._videoEl = el
    this._attachedTrack = track
    this._publication = publication
    track.on?.("ended", this._gone)
    // The person, never a companion's `video:user:…` (task 01a13ca2).
    this._sharerIdentity = personIdentity(participant?.identity) || null
    this._sharerParticipant = participant || null

    this._mountFullscreenController()
    this._stamp()
  },

  _mountFullscreenController() {
    this._fullscreenController?.destroy()
    this._fullscreenController = new ScreenShareFullscreenController({
      root: this.el,
      viewport: this.el,
      button: this._fullscreenButton(),
      video: this._videoEl,
      publication: this._publication,
      env: window,
    }).mount()
  },

  _detach() {
    this._fullscreenController?.destroy()
    this._fullscreenController = null
    if (this._attachedTrack) {
      this._attachedTrack.off?.("ended", this._gone)
      try {
        const els = this._attachedTrack.detach()
        els.forEach((el) => el.remove())
      } catch (_) {
        /* track may already be detached */
      }
      this._attachedTrack = null
    }
    if (this._videoEl) {
      this._videoEl.remove()
      this._videoEl = null
    }

    this._sharerIdentity = null
    this._sharerParticipant = null
    this._publication = null
    this._stamp()
  },
}

export default MeetingScreenShare
