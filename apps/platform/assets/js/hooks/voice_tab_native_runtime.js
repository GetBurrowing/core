// The on-device half of the Voice tab hook (task 01a20dc5 stage 3), built
// as its own island (js/voice_native_island.js, esbuild profile
// `voice_native`) so app.js, which loads on every page, carries none of it.
// voice_tab.js loads the island only inside the iOS app with a BurrowVoice
// plugin present, then copies these methods onto the hook and calls
// `_probeOnDevice()`. The capability seam (lib/on_device_voice.js) ships
// here too. See voice_tab.js's header for the behaviour.

import ClientState from "../client_state.js"
import { onDeviceVoiceCapability } from "../lib/on_device_voice"
import {
  DRAG_CANCEL_PX,
  MIC_TIMEOUT_MS,
  NO_WORDS_MS,
  RESTORE_MS,
  STOP_TIMEOUT_MS,
  TIMED_OUT,
  TURN_CAP_MS,
  TURN_WARN_MS,
  localClock,
  newTurnId,
  now,
  withTimeout,
} from "./voice_tab_shared"

// The reply voice picked on this device, per user (ClientState namespace
// "voice", like the partner and context VoiceContext remembers).
export const VOICE_NAMESPACE = "voice"
export const REPLY_VOICE_KEY = "burrow-voice-reply-voice"
const QUALITIES = ["premium", "enhanced", "default"]

const VoiceTabNative = {
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

  async _probeOnDevice() {
    const cap = await onDeviceVoiceCapability()
    if (this._destroyed) return
    if (cap.available) return this._goNative(cap)
    if (cap.reason !== "assets_missing" || !cap.plugin || typeof cap.plugin.prepare !== "function") return
    // "Preparing speech on this iPhone" (canvas state 13): iOS is fetching
    // its speech files. The server draws the on-device mic disabled with that
    // line; a press does nothing until the files are in. If they never come,
    // the tab goes back to today's.
    const begin = this._begin
    this._begin = () => {}
    this._nativeCap = cap
    this._announceNative()
    this._nativeMicState("preparing")
    this._prepared = this._prepareOnDevice(cap, begin)
  },

  async _prepareOnDevice(cap, begin) {
    let caps = null
    try {
      caps = await cap.plugin.prepare()
    } catch (_e) {
      caps = null
    }
    this._begin = begin
    if (this._destroyed) return
    if (caps && caps.onDeviceSpeech === true) {
      this._goNative({ ...cap, available: true, reason: null, testBuild: caps.testBuild === true, micPermission: caps.micPermission })
      this._nativeMicState("idle")
    } else {
      this._nativeCap = null
      this.pushEvent("voice_native_ready", { available: false, reason: (caps && caps.reason) || "assets_missing" })
    }
  },

  _nativeToggle() {
    this._toggled = true
    if (this._phase === "live") this._nativeMicState("toggled")
  },

  // The socket came back (airplane mode off, a network change). The server
  // mounted a fresh VoiceLive that knows nothing of the device path, so it
  // is told again, and the "Not sent" turns this hook still holds are put
  // back into #voice-native-pending once the server has drawn it, so Retry
  // still resends the same client_turn_id. Installed as the hook's
  // `reconnected` callback by _goNative (LiveView calls this.reconnected()).
  _nativeReconnected() {
    this._announceNative()
    this._restorePending()
  },

  _goNative(cap) {
    const plugin = cap.plugin
    this._nativeHandles = []
    this._nativeTurn = null
    this._nativeTurns = new Map()
    this._onPointerMove = (e) => this._pointerMove(e)
    this._onClick = (e) => this._click(e)
    this._onHidden = () => {
      if (typeof document !== "undefined" && document.visibilityState === "visible") return
      this._nativeLeave("hidden")
    }
    this._onPageHide = () => this._nativeLeave("hidden")
    this._native = plugin
    // From here a press, a release and leaving take the device path. The
    // LiveKit path's methods are replaced on this hook only.
    const leaveRoom = this._disconnect
    this._begin = this._nativeBegin
    this._end = this._nativeEnd
    this._toggle = this._nativeToggle
    this.reconnected = this._nativeReconnected
    this._disconnect = function () {
      this._nativeLeave("left")
      return leaveRoom.call(this)
    }
    this.handleEvent("voice_native_speak", (p) => this._nativeSpeak(p))
    this.handleEvent("voice_native_stop", () => this._nativeStop())
    this.handleEvent("voice_native_voice", (p) => this._pickVoice(p && p.id))
    this._loadVoices()
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
    this._nativeCap = cap
    this._announceNative()
  },

  _announceNative() {
    const cap = this._nativeCap || {}
    this.pushEvent("voice_native_ready", {
      available: true,
      reason: null,
      locale: cap.locale || null,
      test_build: cap.testBuild === true,
      route: this._nativeRoute || null,
    })
    if (cap.micPermission === "denied") this.pushEvent("voice_native_permission", { mic: "denied" })
  },

  // Re-attach the held turns' nodes once #voice-native-pending exists again
  // (polled for up to RESTORE_MS; the server draws it after voice_native_ready).
  _restorePending(waited = 0) {
    const turns = Array.from(this._nativeTurns.values()).filter((t) => t.node && t !== this._nativeTurn)
    if (turns.length === 0) return
    const root = this._pendingEl()
    if (!root) {
      if (waited < RESTORE_MS) setTimeout(() => this._restorePending(waited + 100), 100)
      return
    }
    for (const turn of turns) {
      if (turn.node.parentNode !== root) root.appendChild(turn.node)
    }
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
    on("route", (d) => {
      this._nativeRoute = (d && d.label) || null
      this.pushEvent("voice_native_route", { label: this._nativeRoute })
    })
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
    const args = { id: p.id, text: p.text }
    if (this._voice) args.voice = this._voice
    try {
      Promise.resolve(this._native.speak(args))
        .then((r) => r && r.fellBack === true && this._loadVoices(true))
        .catch(() => {})
    } catch (_e) {
      // the plugin refused; nothing to undo
    }
  },

  // ── reply voices ──────────────────────────────────────────────────────

  _voiceKey() {
    return `${REPLY_VOICE_KEY}:${this.el.dataset.userId}`
  },

  // The phone's on-device voices for its language, best first, pushed as
  // `voice_native_voices {voices, selected, missing}` for the picker. The
  // device's remembered choice is used when it is still installed; else the
  // plugin's default (the best installed) reads, and `missing` says so.
  async _loadVoices(fellBack = false) {
    const plugin = this._native
    if (!plugin || typeof plugin.voices !== "function") return
    let r
    try {
      r = await plugin.voices()
    } catch (_e) {
      return
    }
    if (this._destroyed || !r) return
    const voices = (Array.isArray(r.voices) ? r.voices : [])
      .filter((v) => v && typeof v.id === "string" && typeof v.name === "string")
      .map((v) => ({ id: v.id, name: v.name, quality: QUALITIES.includes(v.quality) ? v.quality : "default" }))
    const stored = ClientState.get(VOICE_NAMESPACE, this._voiceKey(), null)
    const installed = voices.some((v) => v.id === stored)
    this._voice = installed ? stored : null
    const fallback = typeof r.default === "string" ? r.default : voices[0] ? voices[0].id : null
    this.pushEvent("voice_native_voices", {
      voices,
      selected: this._voice || fallback,
      missing: fellBack || (!!stored && !installed),
    })
  },

  _pickVoice(id) {
    if (typeof id !== "string" || !id) return
    this._voice = id
    ClientState.set(VOICE_NAMESPACE, this._voiceKey(), id)
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
}

export default VoiceTabNative
