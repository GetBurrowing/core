import { Room, RoomEvent, Track } from "livekit-client"

const MeetingClient = {
  mounted() {
    this._room = null
    this._tiles = new Map()

    this.handleEvent("join-meeting", (payload) => this._join(payload))
    this.handleEvent("leave-meeting", () => this._leave())
    this.handleEvent("toggle-mic", () => this._toggleMic())
    this.handleEvent("toggle-camera", () => this._toggleCamera())
    this.handleEvent("toggle-screen-share", () => this._toggleScreenShare())

    // Migrate tiles between desktop/mobile grids when the viewport crosses
    // the lg breakpoint (rotation, window resize, dev tools toggle).
    this._viewportQuery = window.matchMedia("(min-width: 1024px)")
    this._onViewportChange = () => this._rehomeTiles()
    this._viewportQuery.addEventListener("change", this._onViewportChange)
  },

  destroyed() {
    this._leave()
    this._viewportQuery?.removeEventListener("change", this._onViewportChange)
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
      if (room.localParticipant) this._ensureTile(room.localParticipant)
      if (pub.track && pub.kind === Track.Kind.Video) {
        this._attachTrack(pub.track, room.localParticipant)
      }
    })
    room.on(RoomEvent.LocalTrackUnpublished, (pub) => {
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

  _attachTrack(track, participant) {
    if (track.kind === Track.Kind.Video) {
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

  _detachTrack(track, participant) {
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

  _markSpeakers(identities) {
    const speaking = new Set(identities)
    for (const [identity, tile] of this._tiles) {
      tile.classList.toggle("meeting-tile-speaking", speaking.has(identity))
    }
  },
}

export default MeetingClient
