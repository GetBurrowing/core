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
 * Mode-switch survival: `data-stage-mode` flips on the `<main>` ancestor, but
 * the LiveKit Room and its track subscriptions live on `window.__livekit_room`
 * — switching to Gallery and back does NOT re-subscribe; the next mount's
 * `_syncExistingTrack` reattaches the same `MediaStreamTrack` synchronously.
 */
const MeetingScreenShare = {
  mounted() {
    this._videoEl = null
    this._attachedTrack = null
    this._sharerIdentity = null
    this._publication = null
    this._fullscreenController = null

    this._boundTrackSubscribed = this._onTrackSubscribed.bind(this)
    this._boundTrackUnsubscribed = this._onTrackUnsubscribed.bind(this)
    this._boundLocalPublished = this._onLocalPublished.bind(this)
    this._boundLocalUnpublished = this._onLocalUnpublished.bind(this)

    this._tryBind()
  },

  updated() {
    this._tryBind()
    this._syncExistingTrack()
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
      room.on("trackUnsubscribed", this._boundTrackUnsubscribed)
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
        this._room.off("trackUnsubscribed", this._boundTrackUnsubscribed)
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
  _syncExistingTrack() {
    const room = this._room
    if (!room || this._attachedTrack) return

    const participants = []
    if (room.localParticipant) participants.push(room.localParticipant)
    if (room.remoteParticipants) {
      for (const p of room.remoteParticipants.values()) participants.push(p)
    }

    for (const participant of participants) {
      const pubs = participant.trackPublications || participant.tracks
      if (!pubs) continue
      for (const pub of pubs.values()) {
        if (pub.track && this._isScreenShare(pub)) {
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

  _onTrackUnsubscribed(track, _pub, participant) {
    if (this._attachedTrack !== track) return
    this._detach()
    // Try to find another sharer (rare: two peers both sharing, one ends).
    this._syncExistingTrack()
    void participant
  },

  _onLocalPublished(pub) {
    if (!this._isScreenShare(pub)) return
    if (this._attachedTrack) return
    if (pub?.track) this._attach(pub.track, this._room?.localParticipant, pub)
  },

  _onLocalUnpublished(pub) {
    if (!this._isScreenShare(pub)) return
    if (this._attachedTrack === pub?.track) this._detach()
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
    this._sharerIdentity = participant?.identity || null

    slot.classList.remove("hidden")
    const placeholder = this._placeholder()
    if (placeholder) placeholder.classList.add("hidden")
    this.el.dataset.screenShareActive = "true"
    if (this._sharerIdentity) {
      this.el.dataset.screenShareSharer = this._sharerIdentity
    }

    this._mountFullscreenController()
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

    const slot = this._slot()
    if (slot) slot.classList.add("hidden")
    const placeholder = this._placeholder()
    if (placeholder) placeholder.classList.remove("hidden")
    this.el.dataset.screenShareActive = "false"
    delete this.el.dataset.screenShareSharer
    this._sharerIdentity = null
    this._publication = null
  },
}

export default MeetingScreenShare
