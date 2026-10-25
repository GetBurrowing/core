// VoiceTab — hold-to-talk on the Voice tab (task 01a1557a-eab7 stage 3).
//
// Mounted on #voice-area (PlatformWeb.Components.Voice.voice_area/1). It owns
// the microphone and the LiveKit room; the server (PlatformWeb.VoiceLive)
// owns every word on screen and decides the talk state from what this hook
// pushes.
//
// ## The failure this is written against
//
// A screen that says "listening" while nothing is captured (the warning in
// meeting_push_to_talk.js). So `voice_press`, the event that makes the server
// render "listening…", is pushed only once the LOCAL mic publication is
// unmuted and its MediaStreamTrack is `live`. Until then nothing is pushed.
//
// ## Flow
//
//   1. First press: getUserMedia asks for the mic. Refused -> push
//      `voice_mic_blocked` (the server renders the blocked line) and NOTHING
//      else: no voice_start, no voice_press.
//   2. Granted -> push `voice_start`; the reply carries {ok, token, url, room}.
//      Connect, publish the mic and keep it MUTED outside a turn.
//   3. A turn: unmute, check the track is live, push `voice_press`; at the end
//      mute and push `voice_release` {duration_ms}.
//
// ## Hold vs tap (master-mobile.html :1074-1169)
//
// pointerdown starts the turn. At pointerup, a press of HOLD_MS or longer
// ends it; a shorter tap leaves it toggled on (`voice_toggled`) and the next
// tap ends it. pointercancel ends it. Pointer capture, as
// meeting_push_to_talk.js takes it. Keyboard, on #mic only (the listeners are
// on this element, so a key pressed with focus elsewhere never reaches them):
// Space down/up holds, repeats ignored; Enter toggles. No global key listener.
//
// ## Captions: the `voice:caption` seam
//
// LiveKit TranscriptionReceived is re-dispatched as a DOM CustomEvent
// `voice:caption` {identity, text, final}. The hook listens for that event
// whether or not a room is connected and pushes FINAL segments only, as
// `voice_turn` {who, text, at}: who "me" for identity "user:<self>", "agent"
// for "agent:<partner id>"; anything else is ignored. The seam is deliberate,
// so a browser test can inject captions without a worker.

import { Room, RoomEvent, Track } from "livekit-client"
import { paintBars } from "./lib/ptt_waveform"

export const HOLD_MS = 280
export const CAPTION_EVENT = "voice:caption"
const METER_MS = 90
const SILENCE = 128

function now() {
  return typeof performance !== "undefined" && performance.now ? performance.now() : Date.now()
}

function localClock() {
  try {
    return new Date()
      .toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
      .replace(/\s+/gu, " ")
  } catch (_e) {
    return null
  }
}

function micOf(event) {
  const t = event && event.target
  if (!t) return null
  if (t.id === "mic") return t
  return typeof t.closest === "function" ? t.closest("#mic") : null
}

const VoiceTab = {
  mounted() {
    this._phase = "idle" // idle | arming | live
    this._seq = 0
    this._toggled = false
    this._downInTurn = false
    this._spaceHeld = false
    this._pressAt = 0
    this._turnAt = 0
    this._permission = null
    this._room = null
    this._pub = null
    this._meterTimer = null
    this._analyser = null

    this._onPointerDown = (e) => this._pointerDown(e)
    this._onPointerUp = (e) => this._pointerUp(e)
    this._onPointerCancel = (e) => this._pointerCancel(e)
    this._onKeyDown = (e) => this._keyDown(e)
    this._onKeyUp = (e) => this._keyUp(e)
    this._onCaption = (e) => this._caption(e)

    this.el.addEventListener("pointerdown", this._onPointerDown)
    this.el.addEventListener("pointerup", this._onPointerUp)
    this.el.addEventListener("pointercancel", this._onPointerCancel)
    this.el.addEventListener("keydown", this._onKeyDown)
    this.el.addEventListener("keyup", this._onKeyUp)
    document.addEventListener(CAPTION_EVENT, this._onCaption)

    this.handleEvent("voice_disconnect", () => this._disconnect())
    this.handleEvent("voice_reset", () => this._abandon())
    this.handleEvent("voice_focus_mic", () => {
      const mic = this._mic()
      if (mic && typeof mic.focus === "function") mic.focus()
    })

    this._pinTranscript()
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this._onPointerDown)
    this.el.removeEventListener("pointerup", this._onPointerUp)
    this.el.removeEventListener("pointercancel", this._onPointerCancel)
    this.el.removeEventListener("keydown", this._onKeyDown)
    this.el.removeEventListener("keyup", this._onKeyUp)
    document.removeEventListener(CAPTION_EVENT, this._onCaption)
    if (this._observer) this._observer.disconnect()
    this._disconnect()
  },

  // ── state ─────────────────────────────────────────────────────────────

  inTurn() {
    return this._phase !== "idle"
  },

  phase() {
    return this._phase
  },

  _mic() {
    return this.el.querySelector ? this.el.querySelector("#mic") : null
  },

  // ── pointer ───────────────────────────────────────────────────────────

  _pointerDown(e) {
    const mic = micOf(e)
    if (!mic || mic.disabled) return
    if (typeof e.button === "number" && e.button !== 0) return
    if (typeof e.preventDefault === "function") e.preventDefault()
    try {
      if (e.pointerId != null && typeof mic.setPointerCapture === "function") {
        mic.setPointerCapture(e.pointerId)
      }
    } catch (_e) {
      // The pointer already ended; pointerup will not come for it.
      return
    }
    this._pressAt = now()
    if (this.inTurn()) {
      // A press during a toggled turn: its release ends the turn.
      this._downInTurn = true
      return
    }
    this._downInTurn = false
    this._toggled = false
    this._begin()
  },

  _pointerUp(e) {
    const mic = micOf(e)
    if (!mic) return
    try {
      if (e.pointerId != null && typeof mic.releasePointerCapture === "function") {
        mic.releasePointerCapture(e.pointerId)
      }
    } catch (_e) {
      // already released
    }
    const held = now() - this._pressAt
    if (this._downInTurn) {
      this._downInTurn = false
      this._end()
      return
    }
    if (!this.inTurn()) return
    if (held < HOLD_MS) this._toggle()
    else this._end()
  },

  _pointerCancel(e) {
    if (!micOf(e)) return
    this._downInTurn = false
    this._toggled = false
    this._end()
  },

  // ── keyboard (on #mic only) ───────────────────────────────────────────

  _keyDown(e) {
    const mic = micOf(e)
    if (!mic || mic.disabled) return
    if (e.key === " ") {
      if (typeof e.preventDefault === "function") e.preventDefault()
      if (e.repeat || this._spaceHeld) return
      if (this.inTurn()) return
      this._spaceHeld = true
      this._toggled = false
      this._pressAt = now()
      this._begin()
    } else if (e.key === "Enter") {
      if (typeof e.preventDefault === "function") e.preventDefault()
      if (e.repeat) return
      if (this.inTurn()) {
        this._end()
      } else {
        this._pressAt = now()
        this._begin()
        this._toggle()
      }
    }
  },

  _keyUp(e) {
    if (!micOf(e) || e.key !== " ") return
    if (typeof e.preventDefault === "function") e.preventDefault()
    if (!this._spaceHeld) return
    this._spaceHeld = false
    this._end()
  },

  // ── a turn ────────────────────────────────────────────────────────────

  _toggle() {
    this._toggled = true
    if (this._phase === "live") this.pushEvent("voice_toggled", {})
  },

  async _begin() {
    const seq = ++this._seq
    this._phase = "arming"
    const stale = () => seq !== this._seq || this._phase !== "arming"

    if (!(await this._ensurePermission())) {
      if (seq === this._seq) this._reset()
      this.pushEvent("voice_mic_blocked", {})
      return
    }
    if (stale()) return

    if (!this._room && !(await this._connect())) {
      if (seq === this._seq) this._reset()
      return
    }
    if (stale()) return

    const live = await this._unmute()
    if (!live) {
      if (seq === this._seq) this._reset()
      await this._mute()
      return
    }
    if (stale()) {
      await this._mute()
      return
    }

    this._phase = "live"
    this._turnAt = now()
    this.pushEvent("voice_press", {})
    if (this._toggled) this.pushEvent("voice_toggled", {})
    this._startMeter()
  },

  _end() {
    const wasLive = this._phase === "live"
    this._seq++
    this._reset()
    if (!wasLive) return
    this._stopMeter()
    this._mute()
    this.pushEvent("voice_release", { duration_ms: Math.round(now() - this._turnAt) })
  },

  // The server refused the press, or a partner change: leave the turn
  // without pushing anything.
  _abandon() {
    this._seq++
    const wasLive = this._phase === "live"
    this._reset()
    this._stopMeter()
    if (wasLive) this._mute()
  },

  _reset() {
    this._phase = "idle"
    this._toggled = false
    this._spaceHeld = false
  },

  // ── microphone + room ────────────────────────────────────────────────

  async _ensurePermission() {
    if (this._permission === "granted") return true
    const md = typeof navigator !== "undefined" ? navigator.mediaDevices : null
    if (!md || typeof md.getUserMedia !== "function") {
      this._permission = "denied"
      return false
    }
    try {
      const stream = await md.getUserMedia({ audio: true })
      if (stream && typeof stream.getTracks === "function") {
        stream.getTracks().forEach((t) => t.stop())
      }
      this._permission = "granted"
      return true
    } catch (_err) {
      this._permission = "denied"
      return false
    }
  },

  _start() {
    return new Promise((resolve) => {
      this.pushEvent("voice_start", {}, (reply) => resolve(reply))
    })
  },

  async _connect() {
    const reply = await this._start()
    if (!reply || reply.ok !== true || !reply.token || !reply.url) return false

    const room = new Room({ adaptiveStream: true, dynacast: true })
    room.on(RoomEvent.TranscriptionReceived, (segments, participant) =>
      this._transcription(segments, participant),
    )
    room.on(RoomEvent.TrackSubscribed, (track) => this._attachAudio(track))
    room.on(RoomEvent.Disconnected, () => {
      if (this._room === room) {
        this._room = null
        this._pub = null
        this._abandon()
      }
    })

    try {
      await room.connect(reply.url, reply.token)
      await room.localParticipant.setMicrophoneEnabled(true)
      const pub = room.localParticipant.getTrackPublication(Track.Source.Microphone)
      if (!pub) throw new Error("no microphone publication")
      this._room = room
      this._pub = pub
      await this._mute()
      return true
    } catch (_err) {
      try {
        await room.disconnect()
      } catch (_e) {
        // already gone
      }
      this.pushEvent("voice_connect_failed", {})
      return false
    }
  },

  async _unmute() {
    const pub = this._pub
    if (!pub) return false
    try {
      if (typeof pub.unmute === "function") await pub.unmute()
    } catch (_e) {
      return false
    }
    const mst = pub.track && pub.track.mediaStreamTrack
    return !pub.isMuted && !!mst && mst.readyState === "live" && mst.enabled !== false
  },

  async _mute() {
    const pub = this._pub
    if (!pub || typeof pub.mute !== "function") return
    try {
      await pub.mute()
    } catch (_e) {
      // the track is gone; nothing is captured either way
    }
  },

  _disconnect() {
    this._abandon()
    const room = this._room
    this._room = null
    this._pub = null
    if (room) {
      try {
        room.disconnect()
      } catch (_e) {
        // already gone
      }
    }
    const audio = this.el.querySelector ? this.el.querySelector("#voice-audio") : null
    if (audio) audio.replaceChildren()
  },

  _attachAudio(track) {
    if (!track || track.kind !== "audio" || typeof track.attach !== "function") return
    const audio = this.el.querySelector ? this.el.querySelector("#voice-audio") : null
    if (!audio) return
    audio.appendChild(track.attach())
  },

  // ── captions ──────────────────────────────────────────────────────────

  _transcription(segments, participant) {
    if (!segments || segments.length === 0) return
    const identity = (participant && participant.identity) || ""
    for (const seg of segments) {
      document.dispatchEvent(
        new CustomEvent(CAPTION_EVENT, {
          detail: { identity, text: seg.text || "", final: seg.final === true },
        }),
      )
    }
  },

  _caption(e) {
    const d = e && e.detail
    if (!d || d.final !== true || typeof d.text !== "string") return
    const text = d.text.trim()
    if (text === "") return
    const { userId, partnerId } = this.el.dataset || {}
    let who = null
    if (userId && d.identity === `user:${userId}`) who = "me"
    else if (partnerId && d.identity === `agent:${partnerId}`) who = "agent"
    if (!who) return
    this.pushEvent("voice_turn", { who, text, at: localClock() })
  },

  // ── meter ─────────────────────────────────────────────────────────────

  _bars() {
    return this.el.querySelectorAll ? Array.from(this.el.querySelectorAll("[data-meter-bar]")) : []
  },

  _startMeter() {
    this._stopMeter()
    const mst = this._pub && this._pub.track && this._pub.track.mediaStreamTrack
    const Ctx = typeof window !== "undefined" && (window.AudioContext || window.webkitAudioContext)
    if (!mst || !Ctx || typeof MediaStream === "undefined") return
    try {
      const ctx = new Ctx()
      const src = ctx.createMediaStreamSource(new MediaStream([mst]))
      const analyser = ctx.createAnalyser()
      analyser.fftSize = 256
      src.connect(analyser)
      const data = new Uint8Array(analyser.fftSize)
      this._analyser = { ctx, analyser }
      const bars = this._bars()
      this._meterTimer = setInterval(() => {
        analyser.getByteTimeDomainData(data)
        let sum = 0
        for (let i = 0; i < data.length; i++) {
          const v = (data[i] - SILENCE) / SILENCE
          sum += v * v
        }
        paintBars(bars, Math.sqrt(sum / data.length))
      }, METER_MS)
    } catch (_e) {
      this._analyser = null
    }
  },

  _stopMeter() {
    if (this._meterTimer) clearInterval(this._meterTimer)
    this._meterTimer = null
    if (this._analyser) {
      try {
        this._analyser.ctx.close()
      } catch (_e) {
        // closed
      }
    }
    this._analyser = null
    for (const b of this._bars()) b.style.transform = ""
  },

  // ── transcript pinned to newest ──────────────────────────────────────

  _pinTranscript() {
    const scroller = typeof document !== "undefined" ? document.getElementById("voice-scroll") : null
    if (!scroller || typeof MutationObserver === "undefined") return
    const pin = () => {
      scroller.scrollTop = scroller.scrollHeight
    }
    this._observer = new MutationObserver(pin)
    this._observer.observe(scroller, { childList: true, subtree: true })
    pin()
  },
}

export default VoiceTab
