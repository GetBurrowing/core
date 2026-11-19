import * as MD from "../lib/media_devices"
import { ACTIVE_DEVICE_EVENT, preferredDeviceId } from "../lib/media_devices"
import { COPY as PANEL_COPY, OPEN_PANEL_EVENT, playTestTone } from "./meeting_device_panel.js"
import { paintBars } from "./lib/ptt_waveform.js"

// The mic check (task 01a1f4c5 stage 3; canvas 01a1f4c7 "Lobby mic check").
export const METER_MS = 90
// RMS (0..1) a voice clears and a quiet room does not (about -34 dBFS).
export const NOISE_FLOOR = 0.02
// Flat for this long AFTER the invitation shows: the warning.
export const FLAT_WARN_MS = 5000
// Every sample exactly zero for this long: the warning, without waiting out
// FLAT_WARN_MS. A real microphone never reads exact zeros; a muted interface,
// a dead virtual device or a privacy switch does. The short window absorbs
// the zero frames an analyser returns before audio first flows.
export const DIGITAL_SILENCE_MS = 1500
// "We can hear you" fades after this long.
export const HEARD_FADE_MS = 2000
const FADE_OUT_MS = 500

export const LOBBY_DEVICES_ROLE = "meeting-lobby-devices"
export const LOBBY_LABEL_CHARS = 34
const DEFAULT_LABEL = {
  audioinput: "Default microphone",
  videoinput: "Default camera",
  audiooutput: "Default speaker",
}

/**
 * MeetingLobbyPreview — the self-preview tile on the pre-join lobby
 * (task 01a07410 / FE-17 stage 4).
 *
 * ## What it owns, and what it deliberately does not
 *
 * It owns ONE local `MediaStream` for the `<video>` inside `this.el`, and
 * nothing else. The mic and camera CHOICE lives on the server, in the
 * `:mic_enabled` / `:camera_enabled` assigns `MeetingHooks` already owns
 * for the in-call controls; this hook only reads that choice off
 * `data-camera-enabled` and starts or stops the preview to match. It never
 * pushes an event and never touches LiveKit — the room does not exist yet,
 * and the state that carries INTO the room travels on the join payload,
 * not through here. A second media-state store beside `meeting_hooks.ex`
 * is exactly what the stage forbids.
 *
 * The preview has a camera stream and, since task 01a1f4c5 stage 3, a
 * SEPARATE microphone stream. The mic stream exists for the level meter on
 * the "You'll join with" microphone row and for the mic check under it; it
 * starts only while `data-mic-enabled="true"` (the server's `:mic_enabled`,
 * mirrored exactly like `data-camera-enabled`) and stops the moment the
 * toggle goes off. It never feeds the call: the lobby's mic toggle is
 * honoured by the connect path (`meeting_client.js` `_join`), which opens
 * its own capture on the same remembered device.
 *
 * ## Lifecycle
 *
 * `mounted` and `updated` both run `_sync`: camera on and no stream ->
 * `getUserMedia({ video: true })` into the `<video>`; camera off and a
 * stream -> stop every track and clear `srcObject`. `destroyed` stops the
 * stream, and so does `_join`'s hand-off: when the LiveView leaves the
 * lobby the element is removed and LiveView calls `destroyed`, so the
 * camera light does not stay on behind the call.
 *
 * `getUserMedia` refusal (no device, permission denied, insecure context)
 * is not an error the user can act on from here: the tile stamps
 * `data-preview="unavailable"` so the CSS can show the placeholder, and
 * the Join action stays enabled — the room may still grant media later.
 *
 * ## Which camera (task 01a1f4c5 stage 1)
 *
 * The preview opens the person's remembered camera
 * (`media_devices.preferredDeviceId("videoinput")`, NON-exact so a missing
 * camera falls back instead of failing), and re-acquires when
 * `meeting:active-device` reports a new `videoinput` — a pick in the lobby's
 * device panel persists the choice and the preview follows it. The Room built
 * at Join reads the same preference, so what the lobby shows is what joins.
 *
 * ## "You'll join with" (task 01a1f4c5 stage 3)
 *
 * `DevicePanel.lobby_devices/1` renders the rows, the mic-check line and
 * the remembered-device lines with every string in place, inside one
 * `phx-update="ignore"` container; this hook fills the device names and
 * shows or hides each piece:
 *
 *   * Rows name `resolvePreferred(kind)`, middle-truncated. Before a
 *     permission grant there are no labels, so a row says the remembered
 *     label or "Default microphone"; a denied permission says "Microphone /
 *     Camera blocked by browser" beside the error icon.
 *   * The remembered-device line shows when `resolvePreferred(...)
 *     .substituted` is true.
 *   * The speaker row is REMOVED where `supportsOutputSelection()` is false.
 *     Its Test sound plays a short tone through the chosen output.
 *   * The mic check: the invitation shows once the mic stream is live; the
 *     first sample over NOISE_FLOOR turns it into "We can hear you", which
 *     fades after HEARD_FADE_MS. It becomes the warning ONLY on
 *     DIGITAL_SILENCE_MS of exact zeros or FLAT_WARN_MS of flat input after
 *     the invitation showed, and the warning asks the device panel to open
 *     MICROPHONE inline. A quiet person is never warned before they are
 *     invited to speak. Time only counts while the AudioContext is running
 *     (a suspended context reads as silence, and must not warn).
 *
 * The Change links belong to the `MeetingDevicePanel` hook beside the rows.
 * A pick there persists through `selectDevice` (there is no room yet) and
 * announces `meeting:active-device`, which this hook answers by re-opening
 * that kind's stream and re-naming its row.
 *
 * Every track this hook opened, camera and microphone, stops in
 * `destroyed`: Join leaves the lobby, LiveView removes the element, and
 * neither the camera light nor the mic indicator outlives it.
 */
const MeetingLobbyPreview = {
  mounted() {
    this._stream = null
    this._mic = null
    this._blocked = {}
    this._onActiveDevice = (event) => {
      const detail = (event && event.detail) || {}
      if (detail.kind === "videoinput") this._restart()
      if (detail.kind === "audioinput") this._restartMic()
      this._renderRows()
    }
    this._onDevicesChanged = () => this._renderRows()
    this._onRowsClick = (event) => {
      const t = event && event.target
      if (t && typeof t.closest === "function" && t.closest("[data-lobby-test-sound]")) {
        this.testSound()
      }
    }
    if (typeof window !== "undefined" && typeof window.addEventListener === "function") {
      window.addEventListener(ACTIVE_DEVICE_EVENT, this._onActiveDevice)
      window.addEventListener(MD.DEVICES_CHANGED_EVENT, this._onDevicesChanged)
    }
    const block = this._block()
    if (block) {
      if (!MD.supportsOutputSelection()) {
        const speaker = block.querySelector('[data-lobby-device="audiooutput"]')
        if (speaker && speaker.parentNode) speaker.parentNode.removeChild(speaker)
      }
      block.addEventListener("click", this._onRowsClick)
      // No room exists in the lobby: listen for plug / unplug directly.
      MD.watchDevices()
    }
    this._sync()
    this._renderRows()
  },

  updated() {
    this._sync()
  },

  destroyed() {
    this._destroyed = true
    if (typeof window !== "undefined" && typeof window.removeEventListener === "function") {
      window.removeEventListener(ACTIVE_DEVICE_EVENT, this._onActiveDevice)
      window.removeEventListener(MD.DEVICES_CHANGED_EVENT, this._onDevicesChanged)
    }
    const block = this._block()
    if (block && typeof block.removeEventListener === "function") {
      block.removeEventListener("click", this._onRowsClick)
    }
    if (this._toneHandle) this._toneHandle.stop()
    this._stop()
    this._stopMic()
  },

  // The camera changed: drop the current stream and open the new one. A
  // capture still pending is superseded: `_start` stops any stream that
  // resolves for an older generation.
  _restart() {
    if (!this._wantCamera()) return
    if (this._stream) {
      this._stream.getTracks().forEach((t) => t.stop())
      this._stream = null
    }
    this._pending = false
    this._start()
  },

  _wantCamera() {
    return this.el.dataset.cameraEnabled === "true"
  },

  _video() {
    return this.el.querySelector("video")
  },

  _sync() {
    this._syncMic()
    if (this._wantCamera()) {
      if (!this._stream && !this._pending) this._start()
    } else if (this._stream || this._pending) {
      this._stop()
    } else if (!this.el.dataset.preview) {
      this.el.dataset.preview = "off"
    }
  },

  _start() {
    const media = typeof navigator !== "undefined" && navigator.mediaDevices
    if (!media || typeof media.getUserMedia !== "function") {
      this.el.dataset.preview = "unavailable"
      return
    }

    this._pending = true
    this.el.dataset.preview = "starting"
    const gen = (this._gen = (this._gen || 0) + 1)

    // List first (never prompts): a remembered camera whose deviceId rotated
    // is found by label only against a fresh list.
    freshList("videoinput")
      .then(() => {
        const deviceId = preferredDeviceId("videoinput")
        const constraint = deviceId ? { deviceId } : true
        return media.getUserMedia({ video: constraint, audio: false })
      })
      .then((stream) => {
        // A newer `_start` (a camera switch) superseded this one.
        if (gen !== this._gen) {
          stream.getTracks().forEach((t) => t.stop())
          return
        }
        this._pending = false
        // The toggle flipped back to off while the prompt was up.
        if (!this._wantCamera()) {
          stream.getTracks().forEach((t) => t.stop())
          this.el.dataset.preview = "off"
          return
        }
        this._stream = stream
        const video = this._video()
        if (video) {
          video.srcObject = stream
          if (typeof video.play === "function") {
            Promise.resolve(video.play()).catch(() => {})
          }
        }
        this.el.dataset.preview = "live"
        this._blocked.videoinput = false
        // A grant makes labels readable.
        this._renderRows()
      })
      .catch((err) => {
        if (gen !== this._gen) return
        this._pending = false
        this.el.dataset.preview = "unavailable"
        this._blocked.videoinput = isDenied(err)
        this._renderRows()
        console.warn("[MeetingLobbyPreview] camera preview unavailable:", err)
      })
  },

  _stop() {
    // Any capture still in flight is now stale.
    this._gen = (this._gen || 0) + 1
    if (this._stream) {
      this._stream.getTracks().forEach((t) => t.stop())
      this._stream = null
    }
    this._pending = false
    const video = this._video()
    if (video) video.srcObject = null
    this.el.dataset.preview = "off"
  },

  // ── the microphone stream (meter + mic check) ─────────────────────

  _wantMic() {
    return this.el.dataset.micEnabled === "true"
  },

  _syncMic() {
    if (this._wantMic()) {
      if (!this._mic) this._startMic()
    } else if (this._mic) {
      this._stopMic()
    }
  },

  _restartMic() {
    if (!this._wantMic()) return
    this._stopMic()
    this._startMic()
  },

  _startMic() {
    const media = typeof navigator !== "undefined" && navigator.mediaDevices
    if (!media || typeof media.getUserMedia !== "function") return
    const gen = (this._micGen = (this._micGen || 0) + 1)
    const mic = (this._mic = { gen, stream: null, pending: true })

    freshList("audioinput")
      .then(() => {
        if (this._mic !== mic) return null
        const deviceId = preferredDeviceId("audioinput")
        const constraint = deviceId ? { deviceId } : true
        return media.getUserMedia({ audio: constraint, video: false })
      })
      .then((stream) => {
        if (!stream) return
        if (this._mic !== mic || this._destroyed || !this._wantMic()) {
          stopTracks(stream)
          return
        }
        mic.pending = false
        mic.stream = stream
        this._blocked.audioinput = false
        this._attachMeter(mic)
        this._setCheck("invitation")
        this._renderRows()
      })
      .catch((err) => {
        if (this._mic !== mic) return
        this._mic = null
        this._blocked.audioinput = isDenied(err)
        this._setCheck("off")
        this._renderRows()
        console.warn("[MeetingLobbyPreview] microphone preview unavailable:", err)
      })
  },

  _stopMic() {
    this._micGen = (this._micGen || 0) + 1
    const mic = this._mic
    this._mic = null
    this._setCheck("off")
    const meter = this._meter()
    if (meter) meter.setAttribute("hidden", "")
    if (!mic) return
    if (mic.timer) clearInterval(mic.timer)
    if (mic.src && typeof mic.src.disconnect === "function") {
      try {
        mic.src.disconnect()
      } catch (_e) {}
    }
    if (mic.ctx && typeof mic.ctx.close === "function") {
      try {
        mic.ctx.close()
      } catch (_e) {}
    }
    if (mic.onGesture) {
      const doc = this._doc()
      if (doc && typeof doc.removeEventListener === "function") {
        doc.removeEventListener("pointerdown", mic.onGesture, true)
        doc.removeEventListener("keydown", mic.onGesture, true)
      }
    }
    stopTracks(mic.stream)
  },

  _attachMeter(mic) {
    const w = typeof window !== "undefined" ? window : null
    const Ctx = w && (w.AudioContext || w.webkitAudioContext)
    const meter = this._meter()
    if (meter) meter.removeAttribute("hidden")
    if (!Ctx) return
    let ctx
    try {
      ctx = new Ctx()
      const src = ctx.createMediaStreamSource(mic.stream)
      const analyser = ctx.createAnalyser()
      analyser.fftSize = 512
      src.connect(analyser)
      mic.ctx = ctx
      mic.src = src
      mic.analyser = analyser
    } catch (_e) {
      return
    }
    // Chrome starts an AudioContext made without a gesture SUSPENDED, and a
    // suspended analyser reads exact silence: resume now, and again on the
    // first gesture.
    const resume = () => {
      if (ctx.state === "suspended" && typeof ctx.resume === "function") {
        Promise.resolve(ctx.resume()).catch(() => {})
      }
    }
    resume()
    const doc = this._doc()
    if (doc && typeof doc.addEventListener === "function") {
      mic.onGesture = resume
      doc.addEventListener("pointerdown", resume, true)
      doc.addEventListener("keydown", resume, true)
    }
    mic.timer = setInterval(() => this._micTick(mic), METER_MS)
  },

  // One analyser read: paint the meter, and advance the mic check.
  _micTick(mic) {
    if (this._mic !== mic || !mic.analyser) return
    const { rms, allZero } = readLevel(mic.analyser, mic)
    const meter = this._meter()
    if (meter) paintBars(Array.from(meter.querySelectorAll("[data-meter-bar]")), rms)

    const running = !mic.ctx || mic.ctx.state === undefined || mic.ctx.state === "running"
    const now = Date.now()
    if (!running) {
      // Not listening yet: none of this time counts toward a warning.
      mic.flatSince = null
      mic.zeroSince = null
      return
    }
    if (mic.flatSince == null) mic.flatSince = Math.max(now, this._checkSince || now)

    if (rms > NOISE_FLOOR) {
      mic.zeroSince = null
      if (this._check === "invitation" || this._check === "warning") this._setCheck("heard")
      return
    }
    if (this._check !== "invitation") return
    if (allZero) {
      if (mic.zeroSince == null) mic.zeroSince = now
      if (now - mic.zeroSince >= DIGITAL_SILENCE_MS) return this._warn()
    } else {
      mic.zeroSince = null
    }
    if (now - mic.flatSince >= FLAT_WARN_MS) this._warn()
  },

  _warn() {
    this._setCheck("warning")
    const block = this._block()
    const panel = block && block.querySelector('[data-role="meeting-devices"]')
    if (!panel || typeof window === "undefined" || typeof window.dispatchEvent !== "function") return
    try {
      window.dispatchEvent(
        new CustomEvent(OPEN_PANEL_EVENT, {
          detail: { id: panel.id || panel.getAttribute("id"), container: "inline", section: "audioinput" },
        }),
      )
    } catch (_e) {}
  },

  // invitation | heard | warning | off
  _setCheck(state) {
    const prev = this._check
    this._check = state
    if (state === "invitation" && prev !== "invitation") this._checkSince = Date.now()
    if (this._fadeTimer) clearTimeout(this._fadeTimer)
    if (this._hideTimer) clearTimeout(this._hideTimer)
    this._fadeTimer = null
    this._hideTimer = null
    const line = this._checkLine()
    if (!line) return
    line.setAttribute("data-state", state)
    line.removeAttribute("data-faded")
    for (const node of line.querySelectorAll("[data-mic-check-copy]")) {
      setHidden(node, node.getAttribute("data-mic-check-copy") !== state)
    }
    for (const node of line.querySelectorAll("[data-mic-check-icon]")) {
      setHidden(node, node.getAttribute("data-mic-check-icon") !== state)
    }
    setHidden(line, state === "off")
    if (state === "heard") {
      this._fadeTimer = setTimeout(() => {
        line.setAttribute("data-faded", "true")
        this._hideTimer = setTimeout(() => setHidden(line, true), FADE_OUT_MS)
      }, HEARD_FADE_MS)
    }
  },

  // ── the "You'll join with" rows ───────────────────────────────────

  _doc() {
    return this.el.ownerDocument || (typeof document !== "undefined" ? document : null)
  },

  _block() {
    const doc = this._doc()
    if (!doc || typeof doc.querySelector !== "function") return null
    return doc.querySelector(`[data-role="${LOBBY_DEVICES_ROLE}"]`)
  },

  _meter() {
    const block = this._block()
    return block ? block.querySelector("[data-lobby-meter]") : null
  },

  _checkLine() {
    const block = this._block()
    return block ? block.querySelector('[data-role="meeting-lobby-mic-check"]') : null
  },

  async _renderRows() {
    const block = this._block()
    if (!block) return
    const gen = (this._rowsGen = (this._rowsGen || 0) + 1)
    const lists = {}
    for (const kind of MD.KINDS) lists[kind] = await MD.listDevices(kind)
    if (gen !== this._rowsGen || this._destroyed) return
    for (const kind of MD.KINDS) {
      const group = block.querySelector(`[data-lobby-device="${kind}"]`)
      if (group) this._renderRow(group, kind, lists[kind])
    }
  },

  _renderRow(group, kind, devices) {
    const label = group.querySelector("[data-lobby-device-label]")
    const alert = group.querySelector("[data-lobby-device-alert]")
    const line = group.querySelector('[data-role="meeting-lobby-device-substituted"]')
    const blocked = !!this._blocked[kind] && devices.length === 0
    let text
    let substituted = false
    if (blocked) {
      text = PANEL_COPY[kind].blocked
    } else if (devices.length > 0) {
      const resolved = MD.resolvePreferred(kind, devices)
      text = resolved.device ? resolved.device.label : DEFAULT_LABEL[kind]
      substituted = resolved.substituted
    } else {
      // No labels yet (no grant): the remembered name, else the default.
      const pref = MD.getPreference(kind)
      text = (pref && pref.label) || DEFAULT_LABEL[kind]
    }
    if (label) {
      const shown = MD.truncateMiddle(text, LOBBY_LABEL_CHARS)
      label.replaceChildren(this._doc().createTextNode(shown))
      if (shown !== text) label.setAttribute("title", text)
      else label.removeAttribute("title")
      label.setAttribute("data-device-label-full", text)
    }
    if (alert) setHidden(alert, !blocked)
    if (line) setHidden(line, !substituted)
  },

  // ── Test sound (the speaker row) ──────────────────────────────────

  async testSound() {
    if (this._toneHandle) return
    const button = this._block() && this._block().querySelector("[data-lobby-test-sound]")
    const sink = (MD.resolvePreferred("audiooutput").device || {}).deviceId || null
    const pending = { stop() {} }
    this._toneHandle = pending
    if (button) button.setAttribute("data-playing", "true")
    const handle = await playTestTone({
      win: typeof window !== "undefined" ? window : null,
      doc: this._doc(),
      sink,
      onEnd: () => {
        if (button) button.removeAttribute("data-playing")
        if (this._toneHandle === pending || this._toneHandle === handle) this._toneHandle = null
      },
    })
    if (!handle) {
      if (button) button.removeAttribute("data-playing")
      if (this._toneHandle === pending) this._toneHandle = null
      return
    }
    if (this._toneHandle === pending && !this._destroyed) this._toneHandle = handle
    else handle.stop()
  },
}

function freshList(kind) {
  return Promise.resolve()
    .then(() => MD.listDevices(kind))
    .catch(() => [])
}

function stopTracks(stream) {
  if (!stream || typeof stream.getTracks !== "function") return
  for (const t of stream.getTracks()) {
    try {
      t.stop()
    } catch (_e) {}
  }
}

function setHidden(node, hidden) {
  if (!node) return
  if (hidden) node.setAttribute("hidden", "")
  else node.removeAttribute("hidden")
}

function isDenied(err) {
  const name = err && err.name
  return name === "NotAllowedError" || name === "SecurityError" || name === "PermissionDeniedError"
}

// RMS (0..1) and whether every sample was exactly zero. Float samples when
// the analyser has them (exact zero is meaningful there); bytes otherwise,
// where 128 is zero.
export function readLevel(analyser, scratch = {}) {
  if (typeof analyser.getFloatTimeDomainData === "function") {
    const n = analyser.fftSize || 512
    if (!scratch.f32 || scratch.f32.length !== n) scratch.f32 = new Float32Array(n)
    const data = scratch.f32
    analyser.getFloatTimeDomainData(data)
    let sum = 0
    let allZero = true
    for (let i = 0; i < data.length; i++) {
      const v = data[i]
      if (v !== 0) allZero = false
      sum += v * v
    }
    return { rms: Math.sqrt(sum / data.length), allZero }
  }
  const n = analyser.fftSize || 512
  if (!scratch.u8 || scratch.u8.length !== n) scratch.u8 = new Uint8Array(n)
  const data = scratch.u8
  analyser.getByteTimeDomainData(data)
  let sum = 0
  let allZero = true
  for (let i = 0; i < data.length; i++) {
    if (data[i] !== 128) allZero = false
    const v = (data[i] - 128) / 128
    sum += v * v
  }
  return { rms: Math.sqrt(sum / data.length), allZero }
}

export default MeetingLobbyPreview
