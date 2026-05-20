import { Room, RoomEvent, Track } from "livekit-client"

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

const MeetingClient = {
  mounted() {
    this._room = null
    this._tiles = new Map()

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

    this.handleEvent("join-meeting", (payload) => this._join(payload))
    this.handleEvent("leave-meeting", () => this._leave())
    this.handleEvent("toggle-mic", () => this._toggleMic())
    this.handleEvent("toggle-camera", () => this._toggleCamera())
    this.handleEvent("toggle-screen-share", () => this._toggleScreenShare())
    // The server pushes this on every `set_stage_mode` (meeting_live.ex).
    this.handleEvent("meeting_stage_mode_changed", ({ mode }) =>
      this._dockLocalVideo(mode),
    )

    // Migrate tiles between desktop/mobile grids when the viewport crosses
    // the lg breakpoint (rotation, window resize, dev tools toggle).
    this._viewportQuery = window.matchMedia("(min-width: 1024px)")
    this._onViewportChange = () => this._rehomeTiles()
    this._viewportQuery.addEventListener("change", this._onViewportChange)
  },

  destroyed() {
    this._teardownLocalVideo()
    this._leave()
    this._viewportQuery?.removeEventListener("change", this._onViewportChange)
  },

  // ── Local self-view: single persistent <video>, reparented per mode ──────

  // The off-layout parking node the persistent local <video> is born in and
  // returns to between docks. Stable id + phx-update="ignore" in the markup.
  _localParkingSlot() {
    return document.querySelector('[data-role="local-self-view"]')
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
    const dock = document.querySelector(selector)

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
      const parking = this._localParkingSlot()
      if (parking && el.parentElement !== parking) parking.appendChild(el)
    }
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

  async _join({ token, url }) {
    if (this._room) {
      console.warn("[MeetingClient] join-meeting while already connected; disconnecting first")
      await this._room.disconnect().catch(() => {})
      this._room = null
    }

    if (!token || !url) {
      console.error("[MeetingClient] join-meeting missing token or url", { url })
      return
    }

    const room = new Room({
      adaptiveStream: true,
      dynacast: true,
      publishDefaults: { simulcast: true },
    })

    room.on(RoomEvent.ParticipantConnected, (p) => this._ensureTile(p))
    room.on(RoomEvent.ParticipantDisconnected, (p) => this._removeTile(p.identity))
    room.on(RoomEvent.TrackSubscribed, (track, pub, participant) =>
      this._attachTrack(track, participant),
    )
    room.on(RoomEvent.TrackUnsubscribed, (track, pub, participant) =>
      this._detachTrack(track, participant),
    )
    room.on(RoomEvent.LocalTrackPublished, (pub) => {
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
        this._attachTrack(pub.track, room.localParticipant)
      }
    })
    room.on(RoomEvent.LocalTrackUnpublished, (pub) => {
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
    room.on(RoomEvent.ActiveSpeakersChanged, (speakers) => {
      const identities = speakers.map((p) => p.identity)
      this._markSpeakers(identities)
    })
    room.on(RoomEvent.Disconnected, () => {
      this._cleanupRoom()
      this.pushEvent("meeting_left", {})
    })

    try {
      await room.connect(url, token)
    } catch (err) {
      console.error("[MeetingClient] room.connect failed", err)
      return
    }

    this._room = room
    window.__livekit_room = room
    window.__livekitRoom = room
    window.dispatchEvent(new CustomEvent("livekit:room-connected", { detail: { room } }))
    document.dispatchEvent(new CustomEvent("livekit:room-connected", { detail: { room } }))

    try {
      await room.localParticipant.setMicrophoneEnabled(true)
    } catch (err) {
      console.warn("[MeetingClient] could not enable mic:", err)
    }

    this._ensureTile(room.localParticipant)

    // v2: if a local camera track is already published (e.g. fast re-join),
    // adopt it into the persistent self-view + dock into the current mode so
    // a fresh join lands the video in the right place without a switch.
    for (const pub of room.localParticipant.trackPublications.values()) {
      if (
        pub.track &&
        pub.kind === Track.Kind.Video &&
        !isScreenShareSource(pub.track.source)
      ) {
        this._attachLocalVideo(pub.track)
        break
      }
    }

    for (const participant of room.remoteParticipants.values()) {
      this._ensureTile(participant)
      for (const pub of participant.trackPublications.values()) {
        if (pub.track) this._attachTrack(pub.track, participant)
      }
    }
  },

  async _leave() {
    if (!this._room) return
    try {
      await this._room.disconnect()
    } catch (_) { /* already gone */ }
    this._cleanupRoom()
  },

  _cleanupRoom() {
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
      document
        .querySelectorAll("[data-quickmeet-screen-share-slot]")
        .forEach((slot) => {
          while (slot.firstChild) slot.removeChild(slot.firstChild)
          slot.classList.add("hidden")
          slot.dataset.screenShareActive = "false"
          delete slot.dataset.screenShareSharer
        })
    }
  },

  async _toggleMic() {
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

  async _toggleCamera() {
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
    const enabled = room.localParticipant.isScreenShareEnabled
    try {
      await room.localParticipant.setScreenShareEnabled(!enabled)
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

  _mediaContainer() {
    return document.getElementById("meeting-media") || document.body
  },

  // DEAD camera-path cruft (task 019e42f6): `_ensureTile`/`_grid` target the
  // `#meeting-participants` / `#meeting-participants-mobile` grids that no
  // longer exist in meeting_live.html.heex, so `_grid()` returns null and
  // this path no-ops. The local camera lifecycle is owned entirely by the
  // `MeetingVideoTile` hook now. Do NOT re-wire these — re-wiring would
  // resurrect the global-detach race fixed in 019e42f6.
  _ensureTile(participant) {
    const grid = this._grid()
    if (!grid) return
    const { identity } = participant
    if (this._tiles.has(identity)) return

    const displayName = participant.name || identity
    const initial = (displayName.trim()[0] || "?").toUpperCase()

    const tile = document.createElement("div")
    tile.dataset.participant = identity
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
    this._tiles.set(identity, tile)
  },

  _removeTile(identity) {
    const tile = this._tiles.get(identity)
    if (!tile) return
    tile.remove()
    this._tiles.delete(identity)
  },

  _clearTiles() {
    for (const tile of this._tiles.values()) tile.remove()
    this._tiles.clear()
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

  _attachTrack(track, participant) {
    if (track.kind === Track.Kind.Video) {
      // Task 019e420f stage 3: route screen-share video to a dedicated
      // full-width container instead of cramming it into the
      // participant's avatar tile (where it rendered ~80×80). Cameras
      // continue to attach into the tile as before.
      if (isScreenShareSource(track.source)) {
        this._attachScreenShareTrack(track, participant)
        return
      }

      this._ensureTile(participant)
      const tile = this._tiles.get(participant.identity)
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
    } else if (track.kind === Track.Kind.Audio) {
      if (participant.isLocal) return
      const el = track.attach()
      el.autoplay = true
      this._mediaContainer().appendChild(el)
    }
  },

  /**
   * Attach the first published screen-share track into the Quick Meet
   * dedicated preview slot above the participants grid. Single-sharer
   * policy: if a track is already attached, the second one is ignored
   * until the first ends (mirrors `MeetingScreenShare._syncExistingTrack`).
   */
  _attachScreenShareTrack(track, participant) {
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
    el.className = "h-full w-full object-contain bg-black"

    // Clear any prior <video> children defensively (e.g. a hot-reload
    // landed mid-share and left a stale node).
    while (slot.firstChild) slot.removeChild(slot.firstChild)
    slot.appendChild(el)

    slot.classList.remove("hidden")
    slot.dataset.screenShareActive = "true"
    if (participant?.identity) {
      slot.dataset.screenShareSharer = participant.identity
    }

    const sharerLabel = slot.parentElement?.querySelector(
      "[data-quickmeet-screen-share-sharer]",
    )
    if (sharerLabel) {
      sharerLabel.textContent = participant?.name || participant?.identity || ""
    }

    this._screenShareTrack = track
    this._screenShareEl = el
  },

  _detachTrack(track, participant) {
    if (track.kind === Track.Kind.Video && isScreenShareSource(track.source)) {
      this._detachScreenShareTrack(track)
      return
    }

    const elements = track.detach()
    elements.forEach((el) => el.remove())

    if (track.kind === Track.Kind.Video) {
      const tile = this._tiles.get(participant?.identity)
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

    this._screenShareTrack = null
    this._screenShareEl = null

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

  _markSpeakers(identities) {
    const speaking = new Set(identities)
    for (const [identity, tile] of this._tiles) {
      tile.classList.toggle("meeting-tile-speaking", speaking.has(identity))
    }
  },
}

export default MeetingClient
