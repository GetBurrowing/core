/**
 * MeetingRoom hook — bridges LiveKit events to the Phoenix LiveView.
 *
 * Subscribes to:
 * 1. `TranscriptionReceived` — emits `meeting:caption` custom DOM events
 *    that the MeetingCaptions hook consumes.
 * 2. `activeSpeakersChanged` — pushes active speaker identities to the
 *    LiveView for speaking indicator rendering.
 *
 * The LiveKit Room object is expected at `window.__livekit_room` (or the
 * legacy `window.__livekitRoom`). The hook gracefully no-ops when no room
 * is available, and binds once a `livekit:room-connected` event fires.
 */
// Trailing-debounce window for `activeSpeakersChanged` pushes, in ms.
const ACTIVE_SPEAKER_DEBOUNCE_MS = 250

const MeetingRoom = {
  mounted() {
    this._boundOnTranscription = this._onTranscription.bind(this)
    this._boundOnActiveSpeaker = this._onActiveSpeaker.bind(this)
    this._tryBind()
  },

  updated() {
    // Re-bind if the room reference changed
    this._tryBind()
  },

  destroyed() {
    if (this._speakerTimer) {
      clearTimeout(this._speakerTimer)
      this._speakerTimer = null
    }
    this._unbind()
  },

  // ── Private ──────────────────────────────────────────────────────────

  _tryBind() {
    const room = window.__livekit_room || window.__livekitRoom
    if (!room) {
      if (!this._waitingForRoom) {
        this._waitingForRoom = true
        this._roomListener = (e) => {
          this._waitingForRoom = false
          if (e.detail && e.detail.room) {
            window.__livekit_room = e.detail.room
          }
          this._tryBind()
        }
        document.addEventListener("livekit:room-connected", this._roomListener, { once: true })
      }
      return
    }

    // Avoid double-binding
    if (this._room === room) return
    this._unbind()
    this._room = room

    try {
      room.on("transcriptionReceived", this._boundOnTranscription)
      room.on("activeSpeakersChanged", this._boundOnActiveSpeaker)
    } catch (e) {
      console.warn("[MeetingRoom] Failed to subscribe to room events:", e)
    }
  },

  _unbind() {
    if (this._room) {
      try {
        this._room.off("transcriptionReceived", this._boundOnTranscription)
        this._room.off("activeSpeakersChanged", this._boundOnActiveSpeaker)
      } catch (_) { /* room may already be disconnected */ }
      this._room = null
    }
  },

  /**
   * Handle a TranscriptionReceived event from LiveKit.
   *
   * The event payload contains an array of TranscriptionSegment objects:
   *   { id, text, language, startTime, endTime, final, firstReceivedTime }
   * and a Participant reference.
   */
  _onTranscription(segments, participant) {
    if (!segments || segments.length === 0) return

    const speakerName = participant?.name || participant?.identity || "Unknown"

    // `identity` is threaded through so downstream consumers
    // (MeetingCaptions' guest-suffix render, per-tile overlay slots
    // added in stage 2) can key on the same identity string the
    // MeetingVideoTile hook uses (`data-participant`). Falls back to an
    // empty string when the participant object is malformed so the
    // rest of the payload still flows.
    const speakerIdentity = participant?.identity || ""

    for (const seg of segments) {
      const detail = {
        id: seg.id || crypto.randomUUID(),
        speaker: speakerName,
        identity: speakerIdentity,
        text: seg.text || "",
        final: seg.final !== false,
        timestamp: seg.startTime || Date.now(),
      }

      document.dispatchEvent(new CustomEvent("meeting:caption", { detail }))
    }
  },

  /**
   * Handle activeSpeakersChanged by pushing the speaking identities to the
   * LiveView, which assigns `:speaking_identities` and paints the ring on
   * the matching `[data-participant]` tile.
   *
   * This is NOT a client-side class toggle. The historical comment here
   * claimed tile highlighting was handled by `MeetingClient._markSpeakers`
   * — that is false on this surface: `_markSpeakers` toggles
   * `meeting-tile-speaking` over MeetingClient's OWN generated
   * `.meeting-tile` nodes, while MeetingLive renders `.meeting-video-tile`
   * nodes keyed by `data-participant`. The two registries never intersect,
   * so the event was dropped, not missing. A JS-added class on the tile
   * root would also be clobbered by morphdom on the next LV render (only
   * the inner video slot is `phx-update="ignore"`), so the server assign
   * is the only stable home for this.
   *
   * `pushEvent` (not `pushEventTo`): a hook's pushEvent ignores
   * `phx-target` and always lands on the root LiveView. MeetingRoom is
   * mounted on `#meeting-room` inside MeetingLive, so `handle_event/3`
   * lives in `meeting_live.ex`. If this markup is ever extracted into a
   * LiveComponent the push silently stops arriving.
   *
   * DEBOUNCE: LiveKit fires activeSpeakersChanged many times a second, and
   * an undebounced push is a render storm. Two guards, in order:
   *   1. Identity-set equality — an unchanged set is dropped outright.
   *   2. A 250ms TRAILING timer — bursts of genuinely-changing sets
   *      collapse into a single push carrying the LAST set seen.
   */
  _onActiveSpeaker(speakers) {
    const identities = (speakers || [])
      .map((p) => (p && p.identity) || "")
      .filter((id) => id !== "")
      .sort()

    const key = identities.join("\u0000")

    // Guard 1: nothing changed since the last push — drop it.
    if (key === this._lastSpeakerKey) return

    // Guard 2: trailing 250ms debounce. Keep the newest payload and reset
    // the timer so a burst results in exactly one push.
    this._pendingSpeakers = identities
    if (this._speakerTimer) clearTimeout(this._speakerTimer)
    this._speakerTimer = setTimeout(() => {
      this._speakerTimer = null
      const pending = this._pendingSpeakers || []
      const pendingKey = pending.join("\u0000")
      if (pendingKey === this._lastSpeakerKey) return
      this._lastSpeakerKey = pendingKey
      this.pushEvent("active_speakers", { identities: pending })
    }, ACTIVE_SPEAKER_DEBOUNCE_MS)
  },
}

export default MeetingRoom
