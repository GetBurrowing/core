import {
  Room,
  RoomEvent,
  Track,
  ConnectionState,
  createLocalTracks,
} from "livekit-client"

/**
 * MeetingRoom LiveView Hook
 *
 * Manages the LiveKit client-side connection for video/audio meetings.
 *
 * ## Server → Client events
 *   - "join-meeting" {token, url}  — connect to LiveKit room
 *   - "leave-meeting" {}           — disconnect from room
 *
 * ## Client → Server events
 *   - "meeting-connected" {}       — room connected successfully
 *   - "meeting-disconnected" {}    — room disconnected
 *   - "meeting-error" {reason}     — connection error
 */
const MeetingRoom = {
  mounted() {
    this.room = null
    this.localTracks = []
    this.micEnabled = true
    this.camEnabled = false
    this.screenShareTrack = null

    // Listen for server push events
    this.handleEvent("join-meeting", ({ token, url }) => {
      this.connect(url, token)
    })

    this.handleEvent("leave-meeting", () => {
      this.disconnect()
    })

    // Bind control buttons
    this.el.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-meeting-action]")
      if (!btn) return

      const action = btn.dataset.meetingAction
      switch (action) {
        case "toggle-mic":
          this.toggleMic()
          break
        case "toggle-camera":
          this.toggleCamera()
          break
        case "toggle-screenshare":
          this.toggleScreenShare()
          break
        case "leave":
          this.pushEvent("leave_meeting", {})
          break
      }
    })
  },

  destroyed() {
    this.disconnect()
  },

  async connect(url, token) {
    try {
      this.room = new Room({
        adaptiveStream: true,
        dynacast: true,
        videoCaptureDefaults: {
          resolution: { width: 640, height: 480, frameRate: 24 },
        },
      })

      this.setupRoomListeners()

      await this.room.connect(url, token)

      // Publish local audio by default
      await this.room.localParticipant.setMicrophoneEnabled(true)
      this.micEnabled = true

      this.pushEvent("meeting-connected", {})
      this.renderParticipants()
    } catch (err) {
      console.error("[MeetingRoom] Connection failed:", err)
      this.pushEvent("meeting-error", { reason: err.message || "Connection failed" })
    }
  },

  disconnect() {
    if (this.screenShareTrack) {
      this.screenShareTrack.stop()
      this.screenShareTrack = null
    }

    for (const track of this.localTracks) {
      track.stop()
    }
    this.localTracks = []

    if (this.room) {
      this.room.disconnect(true)
      this.room = null
    }

    this.clearParticipantTiles()
  },

  setupRoomListeners() {
    const room = this.room

    room.on(RoomEvent.ParticipantConnected, (participant) => {
      this.renderParticipants()
    })

    room.on(RoomEvent.ParticipantDisconnected, (participant) => {
      this.renderParticipants()
    })

    room.on(RoomEvent.TrackSubscribed, (track, publication, participant) => {
      this.attachTrack(track, participant)
    })

    room.on(RoomEvent.TrackUnsubscribed, (track, publication, participant) => {
      this.detachTrack(track, participant)
    })

    room.on(RoomEvent.LocalTrackPublished, (publication, participant) => {
      if (publication.track) {
        this.attachTrack(publication.track, participant)
      }
    })

    room.on(RoomEvent.LocalTrackUnpublished, (publication, participant) => {
      if (publication.track) {
        this.detachTrack(publication.track, participant)
      }
    })

    room.on(RoomEvent.ActiveSpeakersChanged, (speakers) => {
      this.updateActiveSpeakers(speakers)
    })

    room.on(RoomEvent.Disconnected, (reason) => {
      console.log("[MeetingRoom] Disconnected:", reason)
      this.pushEvent("meeting-disconnected", {})
      this.clearParticipantTiles()
    })

    room.on(RoomEvent.ConnectionStateChanged, (state) => {
      this.updateConnectionState(state)
    })
  },

  // ── Media Controls ──────────────────────────────────────────────────────

  async toggleMic() {
    if (!this.room) return
    this.micEnabled = !this.micEnabled
    await this.room.localParticipant.setMicrophoneEnabled(this.micEnabled)
    this.updateControlState("toggle-mic", this.micEnabled)
  },

  async toggleCamera() {
    if (!this.room) return
    this.camEnabled = !this.camEnabled
    await this.room.localParticipant.setCameraEnabled(this.camEnabled)
    this.updateControlState("toggle-camera", this.camEnabled)
  },

  async toggleScreenShare() {
    if (!this.room) return
    try {
      const enabled = this.room.localParticipant.isScreenShareEnabled
      await this.room.localParticipant.setScreenShareEnabled(!enabled)
      this.updateControlState("toggle-screenshare", !enabled)
    } catch (err) {
      console.warn("[MeetingRoom] Screen share error:", err)
    }
  },

  updateControlState(action, enabled) {
    const btn = this.el.querySelector(`[data-meeting-action="${action}"]`)
    if (!btn) return
    btn.classList.toggle("meeting-control-active", enabled)
    btn.classList.toggle("meeting-control-muted", !enabled)
  },

  // ── Participant Rendering ───────────────────────────────────────────────

  renderParticipants() {
    if (!this.room) return

    const grid = this.el.querySelector("[data-meeting-grid]")
    if (!grid) return

    const participants = [
      this.room.localParticipant,
      ...Array.from(this.room.remoteParticipants.values()),
    ]

    // Remove tiles for participants who left
    const currentIds = new Set(participants.map((p) => p.identity))
    grid.querySelectorAll("[data-participant-id]").forEach((tile) => {
      if (!currentIds.has(tile.dataset.participantId)) {
        tile.remove()
      }
    })

    // Add/update tiles
    for (const participant of participants) {
      let tile = grid.querySelector(
        `[data-participant-id="${participant.identity}"]`
      )

      if (!tile) {
        tile = this.createParticipantTile(participant)
        grid.appendChild(tile)
      }

      this.updateParticipantTile(tile, participant)
    }
  },

  createParticipantTile(participant) {
    const tile = document.createElement("div")
    tile.dataset.participantId = participant.identity
    tile.className =
      "meeting-tile relative flex items-center justify-center bg-base-300 rounded-xl overflow-hidden aspect-video"

    const videoContainer = document.createElement("div")
    videoContainer.className = "meeting-tile-video absolute inset-0"
    videoContainer.dataset.videoContainer = ""
    tile.appendChild(videoContainer)

    const nameOverlay = document.createElement("div")
    nameOverlay.className =
      "meeting-tile-name absolute bottom-2 left-2 px-2 py-0.5 bg-base-100/70 text-base-content text-xs rounded-md backdrop-blur-sm"
    nameOverlay.textContent = participant.name || participant.identity
    tile.appendChild(nameOverlay)

    const muteIndicator = document.createElement("div")
    muteIndicator.className =
      "meeting-tile-mute absolute top-2 right-2 text-error hidden"
    muteIndicator.dataset.muteIndicator = ""
    muteIndicator.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" class="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="1" y1="1" x2="23" y2="23"/><path d="M9 9v3a3 3 0 0 0 5.12 2.12M15 9.34V4a3 3 0 0 0-5.94-.6"/><path d="M17 16.95A7 7 0 0 1 5 12v-2m14 0v2c0 .76-.13 1.49-.35 2.17"/><line x1="12" y1="19" x2="12" y2="23"/><line x1="8" y1="23" x2="16" y2="23"/></svg>`
    tile.appendChild(muteIndicator)

    return tile
  },

  updateParticipantTile(tile, participant) {
    const isMuted = !participant.isMicrophoneEnabled
    const muteIndicator = tile.querySelector("[data-mute-indicator]")
    if (muteIndicator) {
      muteIndicator.classList.toggle("hidden", !isMuted)
    }
  },

  attachTrack(track, participant) {
    if (track.kind === Track.Kind.Audio) {
      // Audio tracks get attached to a hidden audio element
      const audioEl = track.attach()
      audioEl.dataset.trackSid = track.sid
      audioEl.dataset.participantId = participant.identity
      // Don't play local audio back to the user
      if (participant === this.room?.localParticipant) {
        audioEl.muted = true
      }
      this.el.appendChild(audioEl)
      return
    }

    if (track.kind === Track.Kind.Video) {
      const grid = this.el.querySelector("[data-meeting-grid]")
      if (!grid) return

      let tile = grid.querySelector(
        `[data-participant-id="${participant.identity}"]`
      )
      if (!tile) {
        tile = this.createParticipantTile(participant)
        grid.appendChild(tile)
      }

      const container = tile.querySelector("[data-video-container]")
      if (container) {
        // Clear existing video
        container.innerHTML = ""
        const videoEl = track.attach()
        videoEl.className = "w-full h-full object-cover"
        videoEl.dataset.trackSid = track.sid
        container.appendChild(videoEl)
      }
    }
  },

  detachTrack(track, participant) {
    // Remove all elements attached to this track
    const elements = track.detach()
    for (const el of elements) {
      el.remove()
    }

    // If it was a video track, clear the container
    if (track.kind === Track.Kind.Video) {
      const grid = this.el.querySelector("[data-meeting-grid]")
      if (!grid) return

      const tile = grid.querySelector(
        `[data-participant-id="${participant.identity}"]`
      )
      if (tile) {
        const container = tile.querySelector("[data-video-container]")
        if (container) {
          container.innerHTML = ""
        }
      }
    }
  },

  updateActiveSpeakers(speakers) {
    const grid = this.el.querySelector("[data-meeting-grid]")
    if (!grid) return

    // Remove active speaker highlight from all tiles
    grid.querySelectorAll("[data-participant-id]").forEach((tile) => {
      tile.classList.remove("ring-2", "ring-primary")
    })

    // Add highlight to active speakers
    for (const speaker of speakers) {
      const tile = grid.querySelector(
        `[data-participant-id="${speaker.identity}"]`
      )
      if (tile) {
        tile.classList.add("ring-2", "ring-primary")
      }
    }
  },

  updateConnectionState(state) {
    const indicator = this.el.querySelector("[data-connection-state]")
    if (!indicator) return

    indicator.dataset.connectionState = state
    indicator.textContent =
      state === ConnectionState.Connected
        ? "Connected"
        : state === ConnectionState.Reconnecting
          ? "Reconnecting..."
          : "Disconnected"
  },

  clearParticipantTiles() {
    const grid = this.el.querySelector("[data-meeting-grid]")
    if (grid) {
      grid.innerHTML = ""
    }

    // Remove any orphaned audio elements
    this.el.querySelectorAll("audio[data-track-sid]").forEach((el) => el.remove())
  },
}

export default MeetingRoom
