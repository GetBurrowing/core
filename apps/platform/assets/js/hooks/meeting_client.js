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
  },

  destroyed() {
    this._leave()
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
      this.pushEvent("mic_toggled", { enabled: !enabled })
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
      this.pushEvent("camera_toggled", { enabled: !enabled })
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
    return document.getElementById("meeting-participants")
  },

  _mediaContainer() {
    return document.getElementById("meeting-media") || document.body
  },

  _ensureTile(participant) {
    const grid = this._grid()
    if (!grid) return
    const { identity } = participant
    if (this._tiles.has(identity)) return

    const tile = document.createElement("div")
    tile.dataset.participant = identity
    tile.className =
      "meeting-tile relative aspect-video overflow-hidden rounded-lg bg-base-300 flex items-center justify-center"

    const label = document.createElement("span")
    label.className =
      "absolute bottom-1 left-1 rounded bg-base-100/80 px-1.5 py-0.5 text-xs font-medium"
    label.textContent = participant.name || identity
    tile.appendChild(label)

    const placeholder = document.createElement("span")
    placeholder.dataset.placeholder = ""
    placeholder.className = "text-base-content/50 text-sm"
    placeholder.textContent = (participant.name || identity).slice(0, 16)
    tile.appendChild(placeholder)

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
      const placeholder = tile.querySelector("[data-placeholder]")
      if (placeholder) placeholder.remove()
      const el = track.attach()
      el.className = "h-full w-full object-cover"
      el.autoplay = true
      el.playsInline = true
      el.muted = participant.isLocal === true
      tile.insertBefore(el, tile.firstChild)
    } else if (track.kind === Track.Kind.Audio) {
      if (participant.isLocal) return
      const el = track.attach()
      el.autoplay = true
      this._mediaContainer().appendChild(el)
    }
  },

  _detachTrack(track, _participant) {
    const elements = track.detach()
    elements.forEach((el) => el.remove())
  },

  _markSpeakers(identities) {
    const speaking = new Set(identities)
    for (const [identity, tile] of this._tiles) {
      tile.classList.toggle("ring-2", speaking.has(identity))
      tile.classList.toggle("ring-primary", speaking.has(identity))
    }
  },
}

export default MeetingClient
