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
import { personIdentity } from "./lib/participant_label"

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
    this._boundMuteChanged = this._onMuteChanged.bind(this)

    this._tryBind()
  },

  updated() {
    // The participant identity is stable per tile id, but re-bind defensively
    // in case the room reference changed between renders.
    this._identity = this.el.dataset.participant
    this._localDock = this.el.dataset.localDock === "true"
    this._tryBind()
    // Reconcile against the LiveKit room, NOT against the server-rendered
    // `data-has-video` attribute. See `_reconcile` for why.
    this._reconcile()
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
      // Camera-off does NOT unpublish in livekit-client v2 — it MUTES the
      // publication and stops the underlying MediaStreamTrack, leaving the
      // RemoteTrackPublication subscribed with `isMuted === true`. Since the
      // tile now decides visibility from publication state (`_findLiveVideo`)
      // rather than from the server attribute, it must hear mute transitions
      // or a remote who turns their camera back on would stay on the avatar
      // until the next unrelated re-render.
      room.on("trackMuted", this._boundMuteChanged)
      room.on("trackUnmuted", this._boundMuteChanged)
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
        this._room.off("trackMuted", this._boundMuteChanged)
        this._room.off("trackUnmuted", this._boundMuteChanged)
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
    if (!this._room || this._attachedTrack) return
    const live = this._findLiveVideo()
    if (live) this._attach(live.track, live.participant)
  },

  /**
   * The single source of truth for "does this participant have a video the
   * tile should be showing right now?" — read off the LiveKit Room, never off
   * the server-rendered `data-has-video` attribute.
   *
   * Returns `{ track, participant }` for the first publication that is:
   *   - owned by THIS tile's identity,
   *   - a video track that is actually subscribed (`pub.track` is present),
   *   - not muted (camera-off mutes the publication in livekit-client v2 —
   *     the subscription survives, so `pub.track` alone would wrongly read as
   *     "has video" for a participant sitting with their camera off), and
   *   - backed by a MediaStreamTrack that has not ended.
   *
   * Returns `null` otherwise — which is what keeps the avatar fallback correct
   * for audio-only and camera-off participants.
   */
  _findLiveVideo() {
    const participant = this._findParticipant()
    return participant ? this._liveVideoOf(participant) : null
  },

  /**
   * True when a LiveKit identity belongs to THIS tile's person. The tile's
   * `data-participant` is always the person (`user:<uuid>`); a person's
   * video-only companion connection (`video:user:<uuid>`, task 01a13ca2)
   * folds onto it through `personIdentity`, so its camera lands here.
   */
  _isOurs(identity) {
    return personIdentity(identity) === this._identity
  },

  /** Every Room participant (connection) that belongs to this tile's person. */
  _participantsForTile() {
    const room = this._room
    if (!room) return []
    const found = []
    if (room.localParticipant && this._isOurs(room.localParticipant.identity)) {
      found.push(room.localParticipant)
    }
    if (room.remoteParticipants) {
      for (const p of room.remoteParticipants.values()) {
        if (p && this._isOurs(p.identity)) found.push(p)
      }
    }
    return found
  },

  /**
   * The Room's participant object for this tile's person, or null. With
   * more than one connection (the person plus their companion) prefer the
   * one with a live camera, then the one holding any camera publication.
   */
  _findParticipant() {
    const found = this._participantsForTile()
    if (found.length <= 1) return found[0] || null
    return (
      found.find((p) => this._liveVideoOf(p)) ||
      found.find((p) => this._hasCameraPublication(p)) ||
      found[0]
    )
  },

  _hasCameraPublication(participant) {
    const pubs = participant.trackPublications || participant.tracks
    if (!pubs || typeof pubs.values !== "function") return false
    for (const pub of pubs.values()) {
      if (pub && (pub.kind === "video" || (pub.track && this._isVideo(pub.track)))) return true
    }
    return false
  },

  _liveVideoOf(participant) {
    const pubs = participant.trackPublications || participant.tracks
    if (!pubs || typeof pubs.values !== "function") return null
    for (const pub of pubs.values()) {
      if (!pub || !pub.track || !this._isVideo(pub.track)) continue
      if (this._isMuted(pub)) continue
      if (this._hasEndedMedia(pub.track)) continue
      return { track: pub.track, participant }
    }
    return null
  },

  _isMuted(pub) {
    // `pub.isMuted` is the publication-level flag LiveKit flips on
    // TrackMuted/TrackUnmuted. Fall back to the track's own flag; treat
    // "undefined" as not muted so an unexpected publication shape can never
    // black out a tile that really is publishing.
    if (pub.isMuted === true) return true
    if (pub.track && pub.track.isMuted === true) return true
    return false
  },

  _hasEndedMedia(track) {
    const mst = track.mediaStreamTrack
    return !!mst && mst.readyState === "ended"
  },

  /**
   * Reconcile the tile's DOM against `_findLiveVideo()`.
   *
   * Why this exists (the bug): a LiveView re-render triggered by ANY meeting
   * control (captions toggle, mic toggle, a new joiner) re-renders the tile
   * carrying the server's `has_video` verdict. When that verdict is stale
   * `false` while the remote is genuinely publishing, morphdom stamps the
   * `hidden` class back onto `[data-video-slot]`, un-hides
   * `[data-avatar-fallback]` over the live picture, and drops the injected
   * `<video>` — and NOTHING puts it back, because from LiveKit's side nothing
   * happened: no TrackUnsubscribed, no reconnect, no new subscription event to
   * re-trigger `_attach`. Confirmed with client-side instrumentation on an
   * experimental branch: a captions click produced hook `updated` →
   * `has_video` flip true→false → avatar covering video → video element
   * removed → no replacement, with no LiveKit event anywhere in the window.
   *
   * The LOCAL tile never showed this because `MeetingClient.updated()`
   * explicitly re-docks its single persistent local `<video>` after every
   * patch. This is the remote tiles' equivalent self-repair: same idea, same
   * seam (`updated()`), reusing `_attach`/`_detach` so the
   * StableTileElementInfo lifecycle stays intact.
   *
   * Deliberately NOT "never hide the slot": when the room CONFIRMS the
   * participant has no live video, this tears down and lets the avatar
   * fallback stand, so audio-only and camera-off participants keep rendering
   * their avatar.
   */
  _reconcile() {
    // The local dock's `<video>` is owned and repaired by MeetingClient — a
    // local-dock tile must never mint its own element (see `_attach`).
    if (this._localDock) return

    // Asymmetric on purpose. The RESTORATIVE direction runs off whatever the
    // room can tell us; the DESTRUCTIVE direction only runs when the room
    // positively reports this participant with no live video. If we cannot
    // even see the participant (room not bound yet, mid-reconnect, an
    // unexpected SDK shape) we leave an existing attachment strictly alone —
    // authoritative teardown belongs to `trackUnsubscribed` /
    // `localTrackUnpublished`, not to a re-render.
    const participant = this._findParticipant()
    const live = participant ? this._liveVideoOf(participant) : null

    if (!live) {
      // Genuinely no video: audio-only participant, camera off (muted
      // publication), or the media track ended. Drop anything we still hold
      // and leave the server's avatar fallback exactly where it is. This
      // branch is what stops the fix from degenerating into "always show the
      // video slot".
      if (participant && (this._attachedTrack || this._videoEl)) this._detach()
      return
    }

    const slot = this._slot()
    if (!slot) return

    // Re-attach when the track changed, when our element was never created,
    // or when the patch removed/moved it out of the slot.
    const mounted = !!this._videoEl && this._videoEl.parentNode === slot
    if (this._attachedTrack !== live.track || !mounted) {
      this._detach()
      this._attach(live.track, live.participant)
      return
    }

    // Element survived the patch but the server's stale `has_video` re-hid it
    // behind the avatar. Re-assert the visible state and nudge playback — a
    // node that gets detached/re-inserted by morphdom can come back paused.
    this._revealVideo()
    if (this._videoEl.paused === true) {
      try {
        const p = this._videoEl.play?.()
        if (p && typeof p.catch === "function") p.catch(() => {})
      } catch (_) {
        /* autoplay policy / element not ready */
      }
    }
  },

  /**
   * Show the video slot and hide the avatar fallback. Shared by `_attach` and
   * `_reconcile` so there is exactly one definition of "video is showing".
   */
  _revealVideo() {
    const slot = this._slot()
    if (slot) slot.classList.remove("hidden")
    const fallback = this.el.querySelector("[data-avatar-fallback]")
    if (fallback) fallback.classList.add("hidden")
    this.el.dataset.hasVideo = "true"
  },

  _isVideo(track) {
    // Track.Kind.Video === "video" in livekit-client; compare by string so we
    // don't need to import the enum.
    return track && track.kind === "video"
  },

  _onTrackSubscribed(track, pub, participant) {
    if (!this._isOurs(participant?.identity)) return
    if (!this._isVideo(track)) return
    // A participant who joins with their camera off still delivers a
    // subscribed-but-muted video publication. Route that through `_reconcile`
    // so the avatar stays up instead of attaching an empty <video>.
    if (pub && this._isMuted(pub)) {
      this._reconcile()
      return
    }
    this._attach(track, participant)
  },

  // trackMuted / trackUnmuted for OUR identity's camera. Muting is how
  // livekit-client v2 expresses "camera off", so these are the transitions
  // that flip a remote tile between live video and avatar.
  _onMuteChanged(pub, participant) {
    if (!this._isOurs(participant?.identity)) return
    if (pub && pub.kind && pub.kind !== "video") return
    if (pub && pub.track && !this._isVideo(pub.track)) return
    this._reconcile()
  },

  _onTrackUnsubscribed(track, _pub, participant) {
    if (!this._isOurs(participant?.identity)) return
    if (!this._isVideo(track)) return
    this._detach()
  },

  _onLocalPublished(pub) {
    const lp = this._room?.localParticipant
    if (!lp || !this._isOurs(lp.identity)) return
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
    if (!lp || !this._isOurs(lp.identity)) return
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
    // immediately without waiting for a round-trip. When that server render
    // disagrees (stale `has_video="false"`), `_reconcile` re-asserts this same
    // state after the patch.
    this._revealVideo()
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
