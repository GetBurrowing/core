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
// ## A press never fails silently
//
// Every way a press can end before `voice_press` that is not a refusal pushes
// `voice_mic_failed` {reason}, and the server renders "Couldn't start the
// microphone. Hold to try again.":
//
//   * no_api: navigator.mediaDevices or getUserMedia is missing (settings
//     cannot fix that, so it is not the blocked line);
//   * timeout: getUserMedia did not settle within MIC_TIMEOUT_MS (seen in
//     WKWebView). A stream that arrives later has its tracks stopped and
//     records permission as granted; a timeout never records a refusal;
//   * not_live: the published track is not live after unmute;
//   * reply_timeout: no voice_start reply within MIC_TIMEOUT_MS.
//
// None of them pushes voice_press, and the next press starts a fresh attempt.
// MIC_TIMEOUT_MS is 10s: a granted getUserMedia resolves well under a second,
// but the first iOS microphone prompt holds the promise until it is answered.
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
// `voice:caption` {identity, text, final, id}. The hook listens for that event
// whether or not a room is connected and pushes FINAL segments only, as
// `voice_turn` {who, text, at, final: true, segment_id}: who "me" for identity
// "user:<self>", "agent" for "agent:<partner id>"; anything else is ignored.
// `segment_id` is the LiveKit segment id (null when the caption has none); the
// server posts each turn into the DM and dedupes a re-delivered segment id. The seam is deliberate,
// so a browser test can inject captions without a worker.
//
// ## On the device (task 01a20dc5 stage 3)
//
// In the iOS app, on an iPhone whose `BurrowVoice` plugin can transcribe on
// the device (`onDeviceVoiceCapability()`, lib/on_device_voice.js), mounted()
// pushes `voice_native_ready` and sets `this._native`. From then on a press
// NEVER calls getUserMedia, `voice_start` or a LiveKit Room:
//
//   * press -> `plugin.start()` (which stops any reply first). `{started:
//     true}` pushes `voice_native_mic {state: "held"}` (and "toggled" for a
//     tap); a refusal pushes `voice_native_mic {state: "in_use"}`,
//     `voice_native_permission {mic: "denied"}` or `voice_mic_failed`.
//   * `partial` events write the words still forming into
//     #voice-native-pending with textContent (never innerHTML).
//   * release -> `plugin.stop()` -> "Sending" -> `voice_native_turn {text,
//     client_turn_id}` with a reply, under MIC_TIMEOUT_MS. ok: the pending
//     words go (the server's confirmed turn takes their place). Not ok, a
//     timeout or the socket down: "Not sent" with Retry, which resends the
//     SAME client_turn_id (the server posts it once). No words: "No words
//     heard" for NO_WORDS_MS, nothing pushed.
//   * The pointer leaving the mic, or a vertical drag from it, while held
//     cancels the turn (`plugin.cancel()`); nothing is sent.
//   * A turn is capped at TURN_CAP_MS: "10 seconds left" at TURN_WARN_MS,
//     then it sends as if released.
//   * `voice_native_speak` -> `plugin.speak`; `voice_native_stop` -> cancel
//     and `stopSpeaking`; the plugin's `speech` and `route` events are pushed
//     back as `voice_native_speaking` and `voice_native_route`.
//
// Mic release (the core #289 rule): `_disconnect()` (destroyed(), a
// `voice_disconnect`) also cancels the native turn and stops speaking, a
// `start()` that resolves after `_connGen` moved is cancelled at once, and
// the page going hidden (visibilitychange, pagehide) does the same. Nothing
// here touches the meetings plugin. Transcript and reply text are never
// logged.

import { Room, RoomEvent, Track } from "livekit-client"
import { paintBars } from "./lib/ptt_waveform"
import {
  announceActiveDevice,
  handleDevicesChanged,
  preferredDeviceId,
  registerRoom,
  roomDefaults,
  seedInUse,
  unregisterRoom,
} from "../lib/media_devices"
import { onDeviceVoiceCapability } from "../lib/on_device_voice"

export const HOLD_MS = 280
export const CAPTION_EVENT = "voice:caption"
export const MIC_TIMEOUT_MS = 10000
const TIMED_OUT = Symbol("timed out")
const LEFT = Symbol("left during connect")
const METER_MS = 90
export const TURN_WARN_MS = 50000
export const TURN_CAP_MS = 60000
export const NO_WORDS_MS = 2000
// How far a held pointer may travel vertically from where it went down
// before the turn counts as a drag and is cancelled (deviation D3).
export const DRAG_CANCEL_PX = 24
// stop() finalises the transcript; give it longer than a start.
const STOP_TIMEOUT_MS = 15000
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

// Settles with the promise, or with TIMED_OUT after `ms`, whichever is first.
function withTimeout(promise, ms) {
  let timer
  const timeout = new Promise((resolve) => {
    timer = setTimeout(() => resolve(TIMED_OUT), ms)
  })
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer))
}

function stopTracks(stream) {
  if (stream && typeof stream.getTracks === "function") {
    stream.getTracks().forEach((t) => t.stop())
  }
}

function newTurnId() {
  try {
    if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
      return crypto.randomUUID()
    }
  } catch (_e) {
    // fall through
  }
  return `t-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`
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
    this._attempt = 0
    this._toggled = false
    this._downInTurn = false
    this._spaceHeld = false
    this._pressAt = 0
    this._turnAt = 0
    this._permission = null
    this._room = null
    this._pub = null
    // Bumped by every _disconnect(): a _connect still awaiting the server or
    // LiveKit when the user leaves sees it changed and releases its room.
    this._connGen = 0
    this._meterTimer = null
    this._analyser = null
    // On the device (task 01a20dc5 stage 3): the BurrowVoice plugin once the
    // capability probe said yes, else null (the LiveKit path, unchanged).
    this._native = null
    this._nativeHandles = []
    this._nativeTurn = null
    this._nativeTurns = new Map()
    this._destroyed = false
    this._downAt = null

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
    this._onPointerMove = (e) => this._pointerMove(e)
    this._onClick = (e) => this._click(e)
    this._onHidden = () => {
      if (typeof document !== "undefined" && document.visibilityState === "visible") return
      this._nativeLeave("hidden")
    }
    this._onPageHide = () => this._nativeLeave("hidden")

    this.handleEvent("voice_disconnect", () => this._disconnect())
    this.handleEvent("voice_reset", () => this._abandon())
    this.handleEvent("voice_focus_mic", () => {
      const mic = this._mic()
      if (mic && typeof mic.focus === "function") mic.focus()
    })
    this.handleEvent("voice_native_speak", (p) => this._nativeSpeak(p))
    this.handleEvent("voice_native_stop", () => this._nativeStop())

    this._pinTranscript()
    this._probe = this._probeNative()
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this._onPointerDown)
    this.el.removeEventListener("pointerup", this._onPointerUp)
    this.el.removeEventListener("pointercancel", this._onPointerCancel)
    this.el.removeEventListener("keydown", this._onKeyDown)
    this.el.removeEventListener("keyup", this._onKeyUp)
    document.removeEventListener(CAPTION_EVENT, this._onCaption)
    if (this._observer) this._observer.disconnect()
    this._destroyed = true
    this._disconnect()
    this._unlistenNative()
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
    this._downAt = { x: e.clientX, y: e.clientY }
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
    this._downAt = null
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
    this._downAt = null
    this._downInTurn = false
    this._toggled = false
    if (this._native) this._nativeCancel()
    else this._end()
  },

  // On the device only: while held, the pointer leaving the mic or a
  // vertical drag that started on it cancels the turn (slide-off, canvas
  // state 3; deviation D3: the drag cancels, it does not scroll).
  _pointerMove(e) {
    if (!this._native || !this._downAt || !this.inTurn() || this._toggled) return
    const mic = this._mic()
    const dy = typeof e.clientY === "number" && typeof this._downAt.y === "number" ? Math.abs(e.clientY - this._downAt.y) : 0
    let outside = false
    if (mic && typeof mic.getBoundingClientRect === "function" && typeof e.clientX === "number") {
      const r = mic.getBoundingClientRect()
      outside = e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom
    }
    if (outside || dy > DRAG_CANCEL_PX) {
      this._downAt = null
      this._nativeCancel()
    }
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
    if (this._native) {
      if (this._phase === "live") this._nativeMicState("toggled")
      return
    }
    if (this._phase === "live") this.pushEvent("voice_toggled", {})
  },

  async _begin() {
    if (this._native) return this._nativeBegin()
    const seq = ++this._seq
    const attempt = ++this._attempt
    this._phase = "arming"
    const stale = () => seq !== this._seq || this._phase !== "arming"
    // A failure is reported even after the release (a hold that let go
    // while getUserMedia hung still gets a line), but not once a newer
    // press has started its own attempt.
    const fail = (reason) => {
      if (seq === this._seq) this._reset()
      if (attempt === this._attempt) this.pushEvent("voice_mic_failed", { reason })
    }

    const permission = await this._ensurePermission()
    if (permission === "denied") {
      if (seq === this._seq) this._reset()
      this.pushEvent("voice_mic_blocked", {})
      return
    }
    if (permission !== "granted") {
      fail(permission)
      return
    }
    if (stale()) return

    if (!this._room) {
      const connected = await this._connect()
      if (connected === "reply_timeout") {
        fail("reply_timeout")
        return
      }
      if (connected !== true) {
        if (seq === this._seq) this._reset()
        return
      }
    }
    if (stale()) return

    const live = await this._unmute()
    if (!live) {
      fail("not_live")
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
    if (this._native) return this._nativeEnd()
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

  // "granted" | "denied" (a real refusal) | "no_api" | "timeout".
  async _ensurePermission() {
    if (this._permission === "granted") return "granted"
    const md = typeof navigator !== "undefined" ? navigator.mediaDevices : null
    if (!md || typeof md.getUserMedia !== "function") return "no_api"

    let request
    try {
      // The remembered microphone (task 01a1f4c5 stage 1), NON-exact: a
      // device that is gone falls back to the browser's choice instead of
      // failing the press.
      const deviceId = preferredDeviceId("audioinput")
      request = Promise.resolve(md.getUserMedia({ audio: deviceId ? { deviceId } : true }))
    } catch (_err) {
      this._permission = "denied"
      return "denied"
    }
    try {
      const stream = await withTimeout(request, MIC_TIMEOUT_MS)
      if (stream === TIMED_OUT) {
        // The stream may still come: release it, and let the next press
        // skip the prompt. A late refusal records nothing.
        request.then(
          (late) => {
            stopTracks(late)
            this._permission = "granted"
          },
          () => {},
        )
        return "timeout"
      }
      stopTracks(stream)
      this._permission = "granted"
      return "granted"
    } catch (_err) {
      this._permission = "denied"
      return "denied"
    }
  },

  // The voice_start reply, or TIMED_OUT after MIC_TIMEOUT_MS.
  _start() {
    const reply = new Promise((resolve) => {
      this.pushEvent("voice_start", {}, (r) => resolve(r))
    })
    return withTimeout(reply, MIC_TIMEOUT_MS)
  },

  // true | false | "reply_timeout"
  //
  // A leave (destroyed() or voice_disconnect, both through _disconnect)
  // can land while this awaits voice_start, room.connect or
  // setMicrophoneEnabled. `_disconnect` then finds no room to release, so
  // this checks `_connGen` after each await and, once superseded, disconnects
  // the room it built (which stops the mic track) instead of adopting it.
  async _connect() {
    const gen = this._connGen
    const left = () => gen !== this._connGen
    const reply = await this._start()
    if (left()) return false
    if (reply === TIMED_OUT) return "reply_timeout"
    if (!reply || reply.ok !== true || !reply.token || !reply.url) return false

    // No camera here: the Voice tab never publishes video.
    //
    // stopMicTrackOnMute: a release mutes, and without it livekit-client
    // only disables the MediaStreamTrack, so the capture (and the browser's
    // mic-in-use indicator) stays on between turns. With it the track is
    // stopped on mute and re-acquired by the next unmute.
    const room = new Room({
      adaptiveStream: true,
      dynacast: true,
      ...roomDefaults({ video: false }),
      publishDefaults: { stopMicTrackOnMute: true },
    })
    room.on(RoomEvent.TranscriptionReceived, (segments, participant) =>
      this._transcription(segments, participant),
    )
    room.on(RoomEvent.TrackSubscribed, (track) => this._attachAudio(track))
    room.on(RoomEvent.MediaDevicesChanged, () => {
      handleDevicesChanged(room, { kinds: ["audioinput", "audiooutput"] }).catch(() => {})
    })
    room.on(RoomEvent.ActiveDeviceChanged, (kind, deviceId) =>
      announceActiveDevice(kind, deviceId),
    )
    room.on(RoomEvent.Disconnected, () => {
      unregisterRoom(room)
      if (this._room === room) {
        this._room = null
        this._pub = null
        this._abandon()
      }
    })

    try {
      await room.connect(reply.url, reply.token)
      if (left()) throw LEFT
      await room.localParticipant.setMicrophoneEnabled(true)
      if (left()) throw LEFT
      const pub = room.localParticipant.getTrackPublication(Track.Source.Microphone)
      if (!pub) throw new Error("no microphone publication")
      this._room = room
      this._pub = pub
      registerRoom(room, "voice")
      // The mic published with no ActiveDeviceChanged: record the device it
      // is on, so an unplug can say which one went (stage 5 round 2).
      await seedInUse(room, { kinds: ["audioinput", "audiooutput"] }).catch(() => {})
      await this._mute()
      return true
    } catch (err) {
      try {
        await room.disconnect()
      } catch (_e) {
        // already gone
      }
      if (err === LEFT) return false
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
    this._connGen++
    if (this._native) this._nativeLeave("left")
    this._abandon()
    const room = this._room
    this._room = null
    this._pub = null
    if (room) {
      unregisterRoom(room)
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

  // ── on the device (task 01a20dc5 stage 3) ─────────────────────────────

  async _probeNative() {
    const cap = await onDeviceVoiceCapability()
    if (this._destroyed) return
    if (cap.available) {
      this._goNative(cap)
    } else if (cap.reason === "assets_missing" && cap.plugin && typeof cap.plugin.prepare === "function") {
      // "Preparing": iOS downloads its speech files; until they are in, the
      // tab stays today's (deviation D8). Adopt the device path only if no
      // LiveKit turn or room started meanwhile.
      try {
        const caps = await cap.plugin.prepare()
        if (this._destroyed || this._room || this.inTurn()) return
        if (caps && caps.onDeviceSpeech === true) {
          this._goNative({ ...cap, available: true, testBuild: caps.testBuild === true, micPermission: caps.micPermission })
        }
      } catch (_e) {
        // stays on today's path
      }
    }
  },

  _goNative(cap) {
    const plugin = cap.plugin
    this._native = plugin
    this._listenNative(plugin)
    this.el.addEventListener("pointermove", this._onPointerMove)
    // On the document: Retry sits in #voice-native-pending, outside this
    // element; Open Settings sits inside it.
    if (typeof document !== "undefined" && typeof document.addEventListener === "function") {
      document.addEventListener("visibilitychange", this._onHidden)
      document.addEventListener("click", this._onClick)
    }
    if (typeof window !== "undefined" && typeof window.addEventListener === "function") {
      window.addEventListener("pagehide", this._onPageHide)
    }
    this.pushEvent("voice_native_ready", {
      available: true,
      reason: null,
      locale: cap.locale || null,
      test_build: cap.testBuild === true,
      route: null,
    })
    if (cap.micPermission === "denied") this.pushEvent("voice_native_permission", { mic: "denied" })
  },

  _listenNative(plugin) {
    if (typeof plugin.addListener !== "function") return
    const on = (event, fn) => {
      try {
        const handle = plugin.addListener(event, fn)
        this._nativeHandles.push(handle)
      } catch (_e) {
        // an older plugin without the event
      }
    }
    on("partial", (d) => this._nativePartial(d))
    on("ended", (d) => this._nativeEnded(d))
    on("speech", (d) => {
      if (!d || typeof d.id !== "string" || typeof d.state !== "string") return
      this.pushEvent("voice_native_speaking", { id: d.id, state: d.state, reason: d.reason || null })
    })
    on("route", (d) => this.pushEvent("voice_native_route", { label: (d && d.label) || null }))
  },

  _unlistenNative() {
    for (const h of this._nativeHandles) {
      Promise.resolve(h)
        .then((handle) => handle && typeof handle.remove === "function" && handle.remove())
        .catch(() => {})
    }
    this._nativeHandles = []
    if (typeof window !== "undefined" && typeof window.removeEventListener === "function") {
      window.removeEventListener("pagehide", this._onPageHide)
    }
    if (typeof document !== "undefined" && typeof document.removeEventListener === "function") {
      document.removeEventListener("visibilitychange", this._onHidden)
      document.removeEventListener("click", this._onClick)
    }
    if (this.el && typeof this.el.removeEventListener === "function") {
      this.el.removeEventListener("pointermove", this._onPointerMove)
    }
  },

  _nativeMicState(state) {
    this.pushEvent("voice_native_mic", { state })
  },

  async _nativeBegin() {
    const plugin = this._native
    const seq = ++this._seq
    const gen = this._connGen
    this._phase = "arming"
    let result
    try {
      result = await withTimeout(Promise.resolve(plugin.start()), MIC_TIMEOUT_MS)
    } catch (_e) {
      result = { started: false, reason: "start_failed" }
    }
    // Left (destroyed, voice_disconnect, hidden) while start() was in
    // flight: the mic it may just have opened is closed at once.
    if (gen !== this._connGen) {
      this._nativeCall("cancel")
      return
    }
    if (result === TIMED_OUT || !result || result.started !== true) {
      if (seq === this._seq) this._reset()
      if (result === TIMED_OUT) this._nativeCall("cancel")
      this._nativeRefused(result === TIMED_OUT ? "timeout" : result && result.reason)
      return
    }
    // Released, cancelled or superseded before the mic opened: nothing was
    // heard, and the open mic is closed.
    if (seq !== this._seq || this._phase !== "arming") {
      this._nativeCall("cancel")
      return
    }
    this._phase = "live"
    this._turnAt = now()
    const turn = this._newNativeTurn()
    this._nativeTurn = turn
    turn.warn = setTimeout(() => this._paintCaption(turn, "10 seconds left"), TURN_WARN_MS)
    turn.cap = setTimeout(() => {
      if (this._nativeTurn === turn) this._nativeEnd()
    }, TURN_CAP_MS)
    this._nativeMicState("held")
    if (this._toggled) this._nativeMicState("toggled")
  },

  _nativeRefused(reason) {
    switch (reason) {
      case "busy":
      case "cancelled":
        return
      case "mic_in_use":
        this._nativeMicState("in_use")
        return
      case "mic_permission_denied":
        this.pushEvent("voice_native_permission", { mic: "denied" })
        return
      case "timeout":
        this.pushEvent("voice_mic_failed", { reason: "timeout" })
        return
      default:
        this.pushEvent("voice_mic_failed", { reason: "native_start_failed" })
    }
  },

  async _nativeEnd() {
    const turn = this._nativeTurn
    const wasLive = this._phase === "live" && turn
    this._seq++
    this._reset()
    if (!wasLive) return
    this._nativeTurn = null
    this._clearTurnTimers(turn)
    this._nativeMicState("idle")
    let text = ""
    try {
      const r = await withTimeout(Promise.resolve(this._native.stop()), STOP_TIMEOUT_MS)
      text = r && r !== TIMED_OUT && typeof r.text === "string" ? r.text.trim() : ""
    } catch (_e) {
      text = ""
    }
    if (text === "") {
      this._removeTurn(turn)
      this._noWords()
      return
    }
    turn.text = text
    this._paintText(turn, text)
    this._nativeSend(turn)
  },

  // Slide-off, a partner or context change, leaving: the turn is
  // discarded, nothing is sent.
  _nativeCancel() {
    const turn = this._nativeTurn
    const wasTurn = this.inTurn()
    this._seq++
    this._reset()
    if (!wasTurn) return
    this._nativeTurn = null
    if (turn) {
      this._clearTurnTimers(turn)
      this._removeTurn(turn)
    }
    this._nativeCall("cancel")
    this._nativeMicState("idle")
  },

  _nativeLeave(_why) {
    if (!this._native) return
    this._connGen++
    this._nativeCancel()
    this._nativeCall("cancel")
    this._nativeCall("stopSpeaking", { reason: "left" })
  },

  _nativeStop() {
    if (!this._native) return
    this._nativeCancel()
    this._nativeCall("stopSpeaking", { reason: "stopped" })
  },

  _nativeSpeak(p) {
    if (!this._native || !p || typeof p.id !== "string" || typeof p.text !== "string") return
    this._nativeCall("speak", { id: p.id, text: p.text })
  },

  _nativeCall(method, args) {
    const plugin = this._native
    if (!plugin || typeof plugin[method] !== "function") return
    try {
      Promise.resolve(args === undefined ? plugin[method]() : plugin[method](args)).catch(() => {})
    } catch (_e) {
      // the plugin refused; nothing to undo
    }
  },

  _nativePartial(d) {
    const turn = this._nativeTurn
    if (!turn || this._phase !== "live" || !d || typeof d.text !== "string") return
    turn.partial = d.text
    this._paintText(turn, d.text)
  },

  // The system ended the turn (a call, Siri, the route dropping, the app
  // going to the background): the half-formed turn is discarded.
  _nativeEnded(d) {
    const reason = d && d.reason
    if (reason === "released" || reason === "no_words") return
    if (this._nativeTurn || this.inTurn()) {
      const turn = this._nativeTurn
      this._seq++
      this._reset()
      this._nativeTurn = null
      if (turn) {
        this._clearTurnTimers(turn)
        this._removeTurn(turn)
      }
      this._nativeMicState("idle")
    }
  },

  async _nativeSend(turn) {
    this._paintCaption(turn, "Sending")
    const reply = new Promise((resolve) => {
      try {
        this.pushEvent(
          "voice_native_turn",
          { text: turn.text, client_turn_id: turn.id, at: localClock() },
          (r) => resolve(r),
        )
      } catch (_e) {
        resolve(null)
      }
    })
    const r = await withTimeout(reply, MIC_TIMEOUT_MS)
    if (r && r !== TIMED_OUT && r.ok === true) {
      this._removeTurn(turn)
    } else {
      this._paintFailed(turn)
    }
  },

  _click(e) {
    const t = e && e.target
    if (!t || typeof t.closest !== "function") return
    const retry = t.closest("[data-native-retry]")
    if (retry) {
      const id = retry.getAttribute("data-native-retry")
      const turn = this._nativeTurns.get(id) || this._adoptTurn(retry, id)
      if (turn && turn.text) this._nativeSend(turn)
      return
    }
    if (t.closest("[data-native-action=open-settings]")) this._nativeCall("openSettings")
  },

  // A "Not sent" turn drawn by an earlier instance of this hook (the page
  // reconnected): rebuild it from the DOM so Retry resends the same id.
  _adoptTurn(retry, id) {
    const node = typeof retry.closest === "function" ? retry.closest("[data-native-turn]") : null
    if (!node || typeof node.querySelector !== "function") return null
    const textNode = node.querySelector("[data-native-text]")
    const captionNode = node.querySelector("[data-native-caption]")
    const text = textNode ? (textNode.textContent || "").trim() : ""
    if (!text) return null
    const turn = { id, text, partial: "", node, textNode, captionNode }
    this._nativeTurns.set(id, turn)
    return turn
  },

  _clearTurnTimers(turn) {
    clearTimeout(turn.warn)
    clearTimeout(turn.cap)
  },

  // ── the pending area (#voice-native-pending, phx-update="ignore") ─────

  _pendingEl() {
    return typeof document !== "undefined" && typeof document.getElementById === "function"
      ? document.getElementById("voice-native-pending")
      : null
  },

  _newNativeTurn() {
    const turn = { id: newTurnId(), text: "", partial: "", node: null, textNode: null, captionNode: null }
    this._nativeTurns.set(turn.id, turn)
    const root = this._pendingEl()
    if (root && typeof document.createElement === "function") {
      const node = document.createElement("div")
      node.className =
        "bubble me max-w-[82%] self-end rounded-2xl rounded-br-sm border border-edge bg-base-100 px-3.5 py-2.5 text-[15px] leading-snug text-secondary break-words"
      node.setAttribute("data-native-turn", turn.id)
      const text = document.createElement("span")
      text.setAttribute("data-native-text", "")
      const caption = document.createElement("span")
      caption.className = "mt-1 block text-xs text-secondary"
      caption.setAttribute("data-native-caption", "")
      node.appendChild(text)
      node.appendChild(caption)
      root.appendChild(node)
      turn.node = node
      turn.textNode = text
      turn.captionNode = caption
    }
    return turn
  },

  _paintText(turn, text) {
    if (turn.textNode) turn.textNode.textContent = text
  },

  _paintCaption(turn, caption) {
    if (turn.captionNode) {
      turn.captionNode.className = "mt-1 block text-xs text-secondary"
      turn.captionNode.textContent = caption
    }
  },

  _paintFailed(turn) {
    const c = turn.captionNode
    if (!c || typeof document.createElement !== "function") return
    c.textContent = ""
    c.className = "mt-1 flex items-center gap-2 text-xs"
    const label = document.createElement("span")
    label.className = "text-error"
    label.textContent = "Not sent"
    const retry = document.createElement("button")
    retry.setAttribute("type", "button")
    retry.setAttribute("data-native-retry", turn.id)
    retry.className = "font-semibold text-base-content underline"
    retry.textContent = "Retry"
    c.appendChild(label)
    c.appendChild(retry)
  },

  _removeTurn(turn) {
    this._nativeTurns.delete(turn.id)
    if (turn.node && typeof turn.node.remove === "function") turn.node.remove()
    turn.node = null
    turn.textNode = null
    turn.captionNode = null
  },

  _noWords() {
    const root = this._pendingEl()
    if (!root || typeof document.createElement !== "function") return
    const note = document.createElement("div")
    note.className = "self-center text-xs text-secondary"
    note.setAttribute("data-native-note", "")
    note.textContent = "No words heard"
    root.appendChild(note)
    setTimeout(() => {
      if (typeof note.remove === "function") note.remove()
    }, NO_WORDS_MS)
  },

  // ── captions ──────────────────────────────────────────────────────────

  _transcription(segments, participant) {
    if (!segments || segments.length === 0) return
    const identity = (participant && participant.identity) || ""
    for (const seg of segments) {
      document.dispatchEvent(
        new CustomEvent(CAPTION_EVENT, {
          detail: {
            identity,
            text: seg.text || "",
            final: seg.final === true,
            id: typeof seg.id === "string" ? seg.id : null,
          },
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
    const segment_id = typeof d.id === "string" && d.id !== "" ? d.id : null
    this.pushEvent("voice_turn", { who, text, at: localClock(), final: true, segment_id })
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
