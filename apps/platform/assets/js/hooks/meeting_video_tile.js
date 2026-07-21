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
import { RemoteVideoTrack } from "livekit-client"

/**
 * StableTileElementInfo — a custom LiveKit `ElementInfo` implementation (see the
 * interface in livekit-client's RemoteVideoTrack.d.ts) that we pre-register on
 * an adaptive-stream remote video track BEFORE calling `track.attach(el)`.
 *
 * Why this exists (the structural fix, task 019f8153):
 * The Room is built with `adaptiveStream: true` (meeting_client.js:479). On a
 * bare zero-arg `track.attach()`, the SDK installs its OWN default
 * `HTMLElementInfo`, whose IntersectionObserver watches the inner <video>
 * element directly. During a morphdom patch — a caption-slot sibling
 * detach/re-append, a mute/speaking-ring flip, or a participant-join re-layout
 * — that inner <video> can be transiently unmounted or measured mid-reflow, so
 * the default watcher reports a false "not visible", the SDK pauses the
 * subscription, and the tile goes black with no clean resume. PR #519's
 * resize-kick papered over that reactively (toggling setSubscribed off/on after
 * the pause); this eliminates the false signal at the source.
 *
 * By measuring and observing the OUTER, `phx-update="ignore"` tile element
 * (`hookEl` = `this.el`) — which morphdom never replaces across LiveView
 * patches — visibility and dimensions stay stable, while `width()`/`height()`
 * still report the real outer pixel size so the SDK's adaptive-bitrate /
 * pixel-density optimization keeps working.
 *
 * SDK contract (verified against the installed livekit-client 2.18.1 esm
 * bundle, `observeElementInfo` + `updateVisibility` + `HTMLElementInfo`):
 *   - `observeElementInfo(info)` ASSIGNS `info.handleResize` and
 *     `info.handleVisibilityChanged` onto our object, then calls
 *     `info.observe()`. Our observers MUST invoke those callbacks, or the SDK
 *     never re-evaluates and the whole fix is inert.
 *   - `updateVisibility()` reads `info.visible` and `info.visibilityChangedAt`
 *     (honoring a 100ms REACTION_DELAY), so on a visibility flip we stamp
 *     `visibilityChangedAt = Date.now()` THEN call `handleVisibilityChanged`.
 *   - `updateDimensions()` reads `info.width()`/`info.height()`.
 * This mirrors the SDK's own `HTMLElementInfo.observe()` callback shape.
 */
class StableTileElementInfo {
  constructor(hookEl, videoEl) {
    this._hookEl = hookEl
    // ElementInfo.element — the SDK matches its attach() guard against this, and
    // StableTileElementInfo holds a direct reference to the single stable
    // <video> node. See the [data-video-slot] contract note in video_tile.ex.
    this.element = videoEl
    this.pictureInPicture = false
    this.visibilityChangedAt = 0
    // Optimistic default (matches the SDK's HTMLElementInfo) — assume the tile
    // intersects the viewport until our IntersectionObserver proves otherwise,
    // so we never emit a spurious initial pause.
    this._intersecting = true
    this._mounted = true
    // Assigned by the SDK inside observeElementInfo(); called with ?. below.
    this.handleResize = undefined
    this.handleVisibilityChanged = undefined
    this._resizeObserver = null
    this._intersectionObserver = null
    this._onDocVisibility = null
    this._lastVisible = undefined
  }

  // OUTER tile dimensions — real pixel size, so adaptive bitrate keeps working.
  width() {
    return this._hookEl ? this._hookEl.clientWidth : 0
  }

  height() {
    return this._hookEl ? this._hookEl.clientHeight : 0
  }

  // Visible iff the hook is mounted, the outer tile has real size, the tab is
  // not hidden, and the tile intersects the document viewport. Measuring the
  // OUTER element is what makes this immune to inner-<video> morphdom churn.
  get visible() {
    return (
      this._mounted &&
      !!this._hookEl &&
      this._hookEl.clientWidth > 0 &&
      this._hookEl.clientHeight > 0 &&
      (typeof document === "undefined" ||
        document.visibilityState !== "hidden") &&
      this._intersecting
    )
  }

  observe() {
    // (a) ResizeObserver on the OUTER tile → drives the SDK's handleResize
    // (updateDimensions) and re-checks visibility (a shrink to 0×0 is a
    // genuine hide the IntersectionObserver would not otherwise report).
    if (typeof ResizeObserver !== "undefined") {
      this._resizeObserver = new ResizeObserver(() => {
        this.handleResize?.()
        this._reevaluateVisibility()
      })
      this._resizeObserver.observe(this._hookEl)
    }

    // (b) document visibilitychange → tab backgrounded/foregrounded.
    if (typeof document !== "undefined") {
      this._onDocVisibility = () => this._reevaluateVisibility()
      document.addEventListener("visibilitychange", this._onDocVisibility)
    }

    // (c) A single document-rooted IntersectionObserver (root:null == the
    // document viewport) on the OUTER tile → tile scrolled off-screen.
    if (typeof IntersectionObserver !== "undefined") {
      this._intersectionObserver = new IntersectionObserver(
        (entries) => {
          for (const entry of entries) {
            if (entry.target === this._hookEl) {
              this._intersecting = entry.isIntersecting
            }
          }
          this._reevaluateVisibility()
        },
        { root: null },
      )
      this._intersectionObserver.observe(this._hookEl)
    }

    this._lastVisible = this.visible
  }

  // Recompute visibility; when it flips, stamp visibilityChangedAt (the SDK
  // reads it to honor REACTION_DELAY) THEN notify the SDK — mirroring the
  // SDK's own HTMLElementInfo.onVisibilityChanged ordering.
  _reevaluateVisibility() {
    const now = this.visible
    if (now === this._lastVisible) return
    this._lastVisible = now
    this.visibilityChangedAt = Date.now()
    this.handleVisibilityChanged?.()
  }

  stopObserving() {
    this._mounted = false
    if (this._resizeObserver) {
      try {
        this._resizeObserver.disconnect()
      } catch (_) {}
      this._resizeObserver = null
    }
    if (this._intersectionObserver) {
      try {
        this._intersectionObserver.disconnect()
      } catch (_) {}
      this._intersectionObserver = null
    }
    if (this._onDocVisibility && typeof document !== "undefined") {
      document.removeEventListener("visibilitychange", this._onDocVisibility)
      this._onDocVisibility = null
    }
  }
}

const MeetingVideoTile = {
  mounted() {
    this._identity = this.el.dataset.participant
    this._videoEl = null
    this._attachedTrack = null
    // Custom LiveKit ElementInfo for adaptive remote tracks (task 019f8153).
    // Null unless we've pre-registered one for an adaptive remote track.
    this._elementInfo = null
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

  // Attach ordering is LOAD-BEARING (task 019f8153): for an adaptive-stream
  // remote track we create the <video> ourselves and call
  // `track.observeElementInfo(customInfo)` BEFORE `track.attach(el)`. The
  // element-arg attach() overload then finds our pre-registered ElementInfo
  // (`elementInfos.find(i => i.element === el)`) and SKIPS installing the SDK's
  // default HTMLElementInfo watcher — the false-negative visibility oracle that
  // black-screened tiles across morphdom patches. A bare `track.attach()` would
  // install that default watcher; because we pre-register first, our
  // StableTileElementInfo is the SOLE visibility oracle the SDK consults for
  // this track (its default IntersectionObserver watcher is never installed).
  // See StableTileElementInfo above, the
  // [data-video-slot] contract note in video_tile.ex, and the regression tests:
  // assets/test/hooks/meeting_video_tile_adaptive.test.js (harness),
  // meeting_video_tile_contract.test.js (SDK seam), and
  // test/platform_web/live/meeting_live_test.exs (slot identity/phx-update).
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

    // Create the <video> ourselves (same attrs as before) instead of a zero-arg
    // track.attach(), which would make the SDK install its default watcher.
    const el = document.createElement("video")
    el.autoplay = true
    el.playsInline = true
    el.muted = true // video element; audio is handled separately by MeetingClient
    el.className = "h-full w-full object-cover"
    if (participant?.isLocal) {
      // Mirror local feeds so they read like a mirror, matching meeting_client.
      el.style.transform = "scaleX(-1)"
    }

    // Adaptive-stream remote tracks: pre-register our stable ElementInfo BEFORE
    // attach so the SDK's default watcher is never installed (see the boundary
    // note above). Non-adaptive / non-remote tracks keep the plain attach path.
    if (track instanceof RemoteVideoTrack && track.isAdaptiveStream) {
      const customInfo = new StableTileElementInfo(this.el, el)
      try {
        track.observeElementInfo(customInfo)
        this._elementInfo = customInfo
      } catch (e) {
        console.warn("[MeetingVideoTile] observeElementInfo failed:", e)
        this._elementInfo = null
      }
    }

    track.attach(el)

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

  _detach() {
    // Tear down the custom ElementInfo first (task 019f8153): stop the SDK
    // observing it, then disconnect our own observers. Both guarded — the track
    // may already be gone, or stopObservingElementInfo may be a no-op.
    if (this._elementInfo) {
      try {
        this._attachedTrack?.stopObservingElementInfo(this._elementInfo)
      } catch (_) {
        /* track may already be detached */
      }
      try {
        this._elementInfo.stopObserving()
      } catch (_) {
        /* observers may already be disconnected */
      }
      this._elementInfo = null
    }

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
