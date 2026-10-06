/**
 * MeetingVoiceWaveform hook (task 01a1117f stage 4).
 *
 * Drives the voice-only presence glyph `VoiceWaveform`
 * (lib/platform_web/components/meeting/voice_waveform.ex) on an agent's
 * promoted gallery tile and its participant-rail row.
 *
 *   - Speaking: `data-wave-state="active"`, and an 80ms interval reads this
 *     participant's SFU `audioLevel` off the LiveKit Room into
 *     `paintVoiceBars` (below), as CSS `scaleY` only.
 *   - Silent: the interval is CLEARED (no polling while silent), the inline
 *     transforms are dropped and `data-wave-state="idle"` hands the bars to
 *     the CSS idle keyframe in app.css.
 *   - Hidden tab or off-screen glyph: updates stop until it is visible again.
 *   - `prefers-reduced-motion: reduce`: the state still flips, but nothing is
 *     painted; app.css shows a static mid-height profile.
 *
 * No requestAnimationFrame loop, no <canvas>, no AnalyserNode: the level is
 * the one the SFU already computes for every participant and the Room
 * already stores on `participant.audioLevel` (livekit-client's speaker
 * update handler). Speaking state comes from the Room's
 * `activeSpeakersChanged`, the event `meeting_room.js` already listens to.
 *
 * `this.el` is the component's outer, `phx-update="ignore"` span; every
 * JS-owned attribute goes on the inner `[data-voice-waveform]` glyph,
 * because LiveView strips unrendered `data-*` attributes off an ignored
 * element on each patch but never touches its children (see the
 * component's moduledoc).
 *
 * The Room is expected at `window.__livekit_room` (mirrors meeting_room.js
 * and meeting_video_tile.js); the hook no-ops until a
 * `livekit:room-connected` event names one.
 */
export const UPDATE_INTERVAL_MS = 80

// ── Bar math (task 01a1117f stage 5) ──────────────────────────────────────
//
// Stage 4 painted these bars with the Ask meter's `paintBars`
// (./lib/ptt_waveform.js). The task-level review measured what that gives a
// voice glyph: the SFU reports `audioLevel` in 1/8 steps that change roughly
// once a second, and `barScale` saturates the centre bars at 1 for any level
// above ~0.455. A steady voice therefore drew ONE frozen shape. Two changes,
// both local to this glyph; `ptt_waveform.js` and the Ask meter are untouched:
//
//   1. `base(level)` keeps ordinary speech (0.375-0.75) below the ceiling:
//      VOICE_FLOOR + (1 - VOICE_FLOOR) * level, so 0.53-0.81 at the centre.
//   2. Every tick multiplies each bar by its own random factor in
//      [JITTER_MIN, 1), so consecutive ticks differ even when the SFU level
//      holds still, while a louder level still draws taller bars on average.
//
// The motion still lives entirely in the 80ms interval: no rAF, no
// AnalyserNode, no keyframe while active, nothing while silent.

export const VOICE_FLOOR = 0.25
export const JITTER_MIN = 0.55

/** The un-jittered height of bar `index` of `count` at SFU `level`. */
export function voiceBarBase(level, index, count) {
  const clamped = Math.max(0, Math.min(1, Number(level) || 0))
  const distance = Math.abs(index - (count - 1) / 2) / ((count - 1) / 2 || 1)
  const weight = 1 - distance * 0.55
  return (VOICE_FLOOR + (1 - VOICE_FLOOR) * clamped) * weight
}

/** One bar's scale for one tick: base(level) times a factor in [JITTER_MIN, 1). */
export function voiceBarScale(level, index, count, random = Math.random) {
  const factor = JITTER_MIN + (1 - JITTER_MIN) * random()
  return Math.max(0.08, Math.min(1, voiceBarBase(level, index, count) * factor))
}

/** Paint every bar's `scaleY` for one tick. */
export function paintVoiceBars(bars, level, random = Math.random) {
  if (!bars || bars.length === 0) return
  const count = bars.length
  for (let i = 0; i < count; i++) {
    bars[i].style.transform = `scaleY(${voiceBarScale(level, i, count, random).toFixed(3)})`
  }
}

const MeetingVoiceWaveform = {
  mounted() {
    this._glyph = this.el.querySelector("[data-voice-waveform]") || this.el
    this._identity = this.el.dataset.identity || this._glyph.dataset.identity || ""
    this._bars = Array.from(this._glyph.querySelectorAll("[data-wave-bar]"))
    this._timer = null
    this._speaking = false
    this._onScreen = true
    this._room = null
    // Injectable for tests (a seeded generator); Math.random in the app.
    this._random = typeof this.random === "function" ? this.random : Math.random

    this._boundOnSpeakers = (speakers) => this._onSpeakers(speakers)
    this._boundOnVisibility = () => this._sync()
    this._boundOnRoomConnected = (e) => {
      if (e && e.detail && e.detail.room) window.__livekit_room = e.detail.room
      this._bindRoom()
    }

    this._setState("idle")

    document.addEventListener("visibilitychange", this._boundOnVisibility)
    // Not `{ once: true }`: a reconnect can park a NEW Room on the window,
    // and the glyph must follow it rather than keep listening to a dead one.
    document.addEventListener("livekit:room-connected", this._boundOnRoomConnected)

    if (typeof IntersectionObserver === "function") {
      this._observer = new IntersectionObserver((entries) => {
        const entry = entries[entries.length - 1]
        if (!entry) return
        this._onScreen = !!entry.isIntersecting
        this._sync()
      })
      this._observer.observe(this._glyph)
    }

    this._bindRoom()
  },

  // An ignored element still has its `data-*` synced, so a row whose
  // LiveKit identity changes (a legacy `agent-AJ_…` fold replaced by the
  // worker's `agent:<uuid>`) reaches here; follow it.
  updated() {
    const identity = this.el.dataset.identity || ""
    if (identity && identity !== this._identity) {
      this._identity = identity
      const participant = this._participant()
      this._speaking = !!(participant && participant.isSpeaking)
      this._sync()
    }
  },

  destroyed() {
    this._stopTimer()
    this._unbindRoom()
    document.removeEventListener("visibilitychange", this._boundOnVisibility)
    document.removeEventListener("livekit:room-connected", this._boundOnRoomConnected)
    if (this._observer) {
      this._observer.disconnect()
      this._observer = null
    }
  },

  // ── Room ──────────────────────────────────────────────────────────────

  _bindRoom() {
    const room = window.__livekit_room || window.__livekitRoom
    if (!room || room === this._room) return

    this._unbindRoom()
    this._room = room
    try {
      room.on("activeSpeakersChanged", this._boundOnSpeakers)
    } catch (e) {
      console.warn("[MeetingVoiceWaveform] failed to subscribe to room events:", e)
    }

    // The glyph can mount mid-sentence (an agent is promoted to a gallery
    // tile BECAUSE it started speaking), so read the current state rather
    // than wait for the next change.
    const participant = this._participant()
    this._speaking = !!(participant && participant.isSpeaking)
    this._sync()
  },

  _unbindRoom() {
    if (!this._room) return
    try {
      this._room.off("activeSpeakersChanged", this._boundOnSpeakers)
    } catch (_) {
      /* room may already be disconnected */
    }
    this._room = null
  },

  _participant() {
    const room = this._room
    if (!room || !this._identity) return null

    if (typeof room.getParticipantByIdentity === "function") {
      return room.getParticipantByIdentity(this._identity) || null
    }
    if (room.localParticipant && room.localParticipant.identity === this._identity) {
      return room.localParticipant
    }
    if (room.remoteParticipants && typeof room.remoteParticipants.values === "function") {
      for (const p of room.remoteParticipants.values()) {
        if (p && p.identity === this._identity) return p
      }
    }
    return null
  },

  _onSpeakers(speakers) {
    const list = Array.isArray(speakers) ? speakers : []
    this._speaking = list.some((p) => p && p.identity === this._identity)
    this._sync()
  },

  // ── State ─────────────────────────────────────────────────────────────

  /** Reconcile state, interval and transforms with the current facts. */
  _sync() {
    if (!this._speaking) {
      this._stopTimer()
      this._clearBars()
      this._setState("idle")
      return
    }

    this._setState("active")

    if (this._canPaint()) {
      this._startTimer()
    } else {
      this._stopTimer()
    }
  },

  _canPaint() {
    if (typeof document !== "undefined" && document.hidden) return false
    if (!this._onScreen) return false
    return !this._reducedMotion()
  },

  _reducedMotion() {
    try {
      return (
        typeof window.matchMedia === "function" &&
        window.matchMedia("(prefers-reduced-motion: reduce)").matches
      )
    } catch (_) {
      return false
    }
  },

  _startTimer() {
    if (this._timer) return
    this._paint()
    this._timer = setInterval(() => this._paint(), UPDATE_INTERVAL_MS)
  },

  _stopTimer() {
    if (!this._timer) return
    clearInterval(this._timer)
    this._timer = null
  },

  _paint() {
    const participant = this._participant()
    const level = participant && typeof participant.audioLevel === "number" ? participant.audioLevel : 0
    paintVoiceBars(this._bars, level, this._random)
  },

  _clearBars() {
    for (const bar of this._bars) bar.style.transform = ""
  },

  _setState(state) {
    if (this._glyph.dataset.waveState !== state) this._glyph.dataset.waveState = state
  },
}

export default MeetingVoiceWaveform
