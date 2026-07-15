/**
 * MeetingVideoTile hook — attaches a LiveKit video track to a server-rendered
 * <.video_tile> component.
 *
 * Task: 019e2475-0037 — Meetings: bottom video strip.
 *
 * Unlike MeetingClient (assets/js/hooks/meeting_client.js), which builds tiles
 * imperatively, this hook owns a tile whose chrome (avatar fallback, mute
 * overlay, speaking ring, name label) is rendered by Phoenix. Its only job is
 * the media plumbing: find this participant's published video track on the
 * LiveKit room and attach/detach the <video> element into [data-video-slot].
 *
 * The LiveKit Room object is expected at `window.__livekit_room` (mirrors
 * meeting_room.js). The hook gracefully no-ops when no room is available and
 * binds once a `livekit:room-connected` event fires.
 */
const MeetingVideoTile = {
  mounted() {
    this._identity = this.el.dataset.participant
    this._videoEl = null
    this._attachedTrack = null
    // v2 (task 019e42f6): the LOCAL participant's tile carries
    // `data-local-dock="true"`. The single persistent local <video> is owned
    // and reparented by the page-level MeetingClient hook (into
    // [data-local-video-dock] per stage mode), so this tile must NOT attach
    // its own camera track — that would duplicate the local <video> and
    // resurrect the multi-element detach race v1 fought. Remote tiles are
    // untouched and keep attaching their own tracks.
    this._localDock = this.el.dataset.localDock === "true"

    this._boundTrackSubscribed = this._onTrackSubscribed.bind(this)
    this._boundTrackUnsubscribed = this._onTrackUnsubscribed.bind(this)
    this._boundLocalPublished = this._onLocalPublished.bind(this)
    this._boundLocalUnpublished = this._onLocalUnpublished.bind(this)

    this._tryBind()
    this._installResizeKick()
  },

  updated() {
    // The participant identity is stable per tile id, but re-bind defensively
    // in case the room reference changed between renders.
    this._identity = this.el.dataset.participant
    this._localDock = this.el.dataset.localDock === "true"
    this._tryBind()
    this._syncExistingTrack()
  },

  destroyed() {
    this._detach()
    this._unbind()
    this._teardownResizeKick()
  },

  // ── Private ────────────────────────────────────────────────────────────

  _slot() {
    return this.el.querySelector("[data-video-slot]")
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
      console.warn("[MeetingVideoTile] failed to subscribe to room events:", e)
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
   * Walk the room's participants looking for our identity's published video
   * track and attach it if found. Covers the case where the track already
   * existed before this tile mounted.
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
      if (participant.identity !== this._identity) continue
      const pubs = participant.trackPublications || participant.tracks
      if (!pubs) continue
      for (const pub of pubs.values()) {
        if (pub.track && this._isVideo(pub.track)) {
          this._attach(pub.track, participant)
          return
        }
      }
    }
  },

  _isVideo(track) {
    // Track.Kind.Video === "video" in livekit-client; compare by string so we
    // don't need to import the enum.
    return track && track.kind === "video"
  },

  _onTrackSubscribed(track, _pub, participant) {
    if (participant?.identity !== this._identity) return
    if (!this._isVideo(track)) return
    this._attach(track, participant)
  },

  _onTrackUnsubscribed(track, _pub, participant) {
    if (participant?.identity !== this._identity) return
    if (!this._isVideo(track)) return
    this._detach()
  },

  _onLocalPublished(pub) {
    const lp = this._room?.localParticipant
    if (!lp || lp.identity !== this._identity) return
    const track = pub?.track
    if (!track || !this._isVideo(track)) return
    // Stage 2: defend against a stale `_attachedTrack` left over from a
    // prior mode-switch global-detach. If we still hold a reference to a
    // DIFFERENT (now-detached) track, tear it down first so `_attach`'s
    // identity short-circuit (`this._attachedTrack === track`) doesn't
    // wrongly no-op and leave the camera dark.
    if (this._attachedTrack && this._attachedTrack !== track) this._detach()
    this._attach(track, lp)
  },

  _onLocalUnpublished(pub) {
    const lp = this._room?.localParticipant
    if (!lp || lp.identity !== this._identity) return
    // Stage 2: LiveKit sometimes emits the unpublish with a nulled
    // `pub.track`, so we can't rely on a track-identity match. Any
    // camera-unpublish for OUR identity must clear `_attachedTrack` to
    // null so a subsequent `localTrackPublished` reliably re-attaches.
    // Guard against an audio-only unpublish round-tripping a real video
    // track ref that isn't ours.
    const track = pub?.track
    if (track && !this._isVideo(track)) return
    this._detach()
  },

  _attach(track, participant) {
    // v2 (task 019e42f6): a local-dock tile never attaches its own track —
    // MeetingClient owns the single persistent local <video> and reparents it
    // into this tile's sibling [data-local-video-dock]. Bailing here keeps
    // exactly one live local <video> in the DOM.
    if (this._localDock) return
    const slot = this._slot()
    if (!slot) return
    if (this._attachedTrack === track) return

    this._detach()

    const el = track.attach()
    el.autoplay = true
    el.playsInline = true
    el.muted = true // video element; audio is handled separately by MeetingClient
    el.className = "h-full w-full object-cover"
    if (participant?.isLocal) {
      // Mirror local feeds so they read like a mirror, matching meeting_client.
      el.style.transform = "scaleX(-1)"
    }

    slot.appendChild(el)
    this._videoEl = el
    this._attachedTrack = track

    // Reveal the video slot, hide the avatar fallback. The server also toggles
    // these via data-has-video on the next render; this keeps the UI in sync
    // immediately without waiting for a round-trip.
    slot.classList.remove("hidden")
    const fallback = this.el.querySelector("[data-avatar-fallback]")
    if (fallback) fallback.classList.add("hidden")
    this.el.dataset.hasVideo = "true"
  },

  // ── Adaptive-stream resize kick ────────────────────────────────────────
  //
  // LiveKit's Room is constructed with `adaptiveStream: true` in
  // `meeting_client.js` — the SDK auto-pauses subscribed video tracks whose
  // <video> elements are hidden or below a minimum visible size, and resumes
  // them when the element grows back. That saves bandwidth on off-screen
  // tiles, but has a rough edge on layout jumps:
  //
  // When a new remote participant joins, the gallery grid shape changes
  // (e.g. 2-tile 1x2 → 3-tile 1x3), and EVERY existing tile briefly resizes
  // — sometimes through a very-small intermediate frame or a
  // display:none-adjacent state during morphdom's patch. Adaptive stream
  // pauses the affected subscription, and doesn't always cleanly resume
  // when the tile settles at its new size — the SDK's ResizeObserver
  // firing order + our own DOM patch order don't line up perfectly, so
  // the subscription stays paused. The user sees the pre-join tile go
  // black; switching stage_mode remounts the tile which triggers
  // `_syncExistingTrack`, which re-attaches fresh, and the video returns.
  //
  // Fix: watch this tile's OUTER element for size changes, and after the
  // change settles (250ms debounce so we fire once per burst, not once per
  // resize frame), toggle the remote publication's subscription off/on to
  // force adaptive stream to re-evaluate. `setSubscribed(true)` alone is
  // idempotent when the SDK thinks it's already subscribed, so the toggle
  // pair is what actually kicks it back into "actively sending frames".
  //
  // Local tiles bail — MeetingClient owns the local <video> and this hook
  // never attaches its own track for a local-dock tile (see `_attach`).
  _installResizeKick() {
    if (typeof ResizeObserver === "undefined") return
    this._resizeObserver = new ResizeObserver(() => this._scheduleResizeKick())
    this._resizeObserver.observe(this.el)
  },

  _teardownResizeKick() {
    if (this._resizeObserver) {
      try { this._resizeObserver.disconnect() } catch (_) {}
      this._resizeObserver = null
    }
    if (this._resizeKickTimer) {
      clearTimeout(this._resizeKickTimer)
      this._resizeKickTimer = null
    }
  },

  _scheduleResizeKick() {
    if (this._resizeKickTimer) clearTimeout(this._resizeKickTimer)
    this._resizeKickTimer = setTimeout(() => this._resizeKick(), 250)
  },

  _resizeKick() {
    this._resizeKickTimer = null
    if (this._localDock || !this._room) return
    // Only nudge if we have an attached track that adaptive stream might
    // have paused. If nothing is attached the normal track-subscribed path
    // will run when the track arrives — no work to do here.
    if (!this._attachedTrack) return

    // Find the RemoteTrackPublication for our currently-attached track and
    // toggle its subscription. Walking remoteParticipants is O(participants
    // × publications-per-participant) — cheap even in a big meeting.
    const remotes = this._room.remoteParticipants
    if (!remotes) return
    for (const participant of remotes.values()) {
      if (participant.identity !== this._identity) continue
      const pubs = participant.trackPublications || participant.tracks
      if (!pubs) continue
      for (const pub of pubs.values()) {
        if (pub.track !== this._attachedTrack) continue
        if (typeof pub.setSubscribed !== "function") continue
        try {
          pub.setSubscribed(false)
          pub.setSubscribed(true)
        } catch (_) {
          /* participant may have disconnected between iterations */
        }
        return
      }
    }
  },

  _detach() {
    if (this._attachedTrack) {
      try {
        if (this._videoEl) {
          // Stage 1 fix (root cause of "switching active tab drops video"):
          // use the SINGLE-ELEMENT `track.detach(element)` overload so we
          // only detach OUR slot's <video>. The zero-arg `track.detach()`
          // detaches the MediaStreamTrack from EVERY <video> in the
          // document — including the freshly-mounted sibling tile that
          // shares the same MediaStreamTrack across a mode-switch LiveView
          // patch — which black-screened the local camera with no recovery.
          this._attachedTrack.detach(this._videoEl)
        } else {
          // Fallback: no element reference (track synced but element lost).
          // Remove only the <video> nodes inside OUR slot so we still never
          // rip the track out from under a sibling tile globally.
          const slot = this._slot()
          if (slot) {
            slot.querySelectorAll("video").forEach((el) => el.remove())
          }
        }
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
    const fallback = this.el.querySelector("[data-avatar-fallback]")
    if (fallback) fallback.classList.remove("hidden")
    this.el.dataset.hasVideo = "false"
  },
}

export default MeetingVideoTile
