/**
 * GameStream hook: the browser half of the `game_stream` canvas (task
 * 01a0db5f stage 4). Mounted on `Platform.Chat.Canvas.Kinds.GameStream`'s
 * wrapper (`phx-update="ignore"`, so this hook owns the DOM after mount);
 * the server half is `PlatformWeb.GameStreamHooks`.
 *
 * What it does:
 *   - attaches to the session (`game_stream_attach`), and answers the play
 *     host's WebRTC offer: the one the server hands over on attach
 *     (`pending_offer`) or one pushed later. The host's offer is complete
 *     (non-trickle), so the answer is sent once ICE gathering finishes and
 *     no `ice` signals are needed on the LAN;
 *   - keeps the video muted/autoplay/playsinline, counts fps with
 *     requestVideoFrameCallback, and reads the connection path from
 *     getStats' selected candidate pair (relay is TURN, anything else LAN);
 *   - runs the capture machine (`lib/game_stream_capture.js`) and forwards
 *     keys and gamepad snapshots (`lib/game_stream_input.js`) on the host's
 *     two data channels while captured;
 *   - sends a latency probe about once a second while the player is active
 *     and decodes it from the frame corner (`lib/game_stream_probe.js`).
 *     Probes count as input on the host, so they stop 30 s after the last
 *     real key or pad change: a probe must not hold an idle session open.
 *
 * One node can render twice in one page (panel and mobile overlay), and
 * both copies mount this hook. Only a copy that is actually rendered
 * attaches, and the page keeps one claimant per session (`claims`): a copy
 * that becomes visible takes the session over from its hidden twin.
 *
 * Which WINDOW plays (stage 6): an attach is `take` (a window the user acted
 * in) or `follow` (this page's node was re-rendered onto a session someone
 * else restarted; `lib/game_stream_session.js`). The server answers whether
 * this window is the viewer and hands it a `viewer_token`; every signal
 * carries it back, and a signal refused as `moved` (another window is the
 * viewer now) shows "Continued in another window" instead of hanging on
 * Connecting.
 */

import { captureReduce, initialCapture } from "./lib/game_stream_capture.js"
import {
  KeyForwarder,
  PadDiffer,
  controllerLabel,
  hintText,
  pickGamepad,
} from "./lib/game_stream_input.js"
import {
  CORNER_PX,
  RollingStats,
  decode,
  formatStats,
  latencyWarn,
  nextSeq,
  pairPath,
  peerConfig,
  readCorner,
} from "./lib/game_stream_probe.js"
import { SessionMemo, attachOutcome, signalMoved } from "./lib/game_stream_session.js"

const claims = new Map()
const memo = new SessionMemo()

const PROBE_EVERY_MS = 1000
const PROBE_TIMEOUT_MS = 1500
const PROBE_IDLE_STOP_MS = 30000
const STATS_PUSH_EVERY_MS = 5000
const GATHER_TIMEOUT_MS = 3000

const RUNNING = ["building", "connecting", "live"]

function rendered(el) {
  return el.getClientRects().length > 0
}

function formatElapsed(ms) {
  const total = Math.max(0, Math.floor(ms / 1000))
  const s = String(total % 60).padStart(2, "0")
  return `${Math.floor(total / 60)}:${s}`
}

function waitForGathering(pc, timeoutMs) {
  return new Promise(resolve => {
    if (pc.iceGatheringState === "complete") return resolve()
    const done = () => {
      if (pc.iceGatheringState === "complete") resolve()
    }
    pc.addEventListener("icegatheringstatechange", done)
    setTimeout(resolve, timeoutMs)
  })
}

const GameStream = {
  mounted() {
    const d = this.el.dataset
    this.sessionId = d.sessionId || null
    this.canvasId = d.canvasId || null
    this.nodeId = d.nodeId || null
    this.warnMs = parseInt(d.latencyWarnMs, 10) || 50
    this.serverState = d.state || "unavailable"
    this.buildStartedAt = Date.now() - (parseInt(d.elapsedMs, 10) || 0)
    this.attachMode = memo.mount(this.canvasId, this.nodeId, this.sessionId)
    this.viewerToken = null
    this.dead = false

    const q = sel => this.el.querySelector(sel)
    this.video = q("[data-gs-video]")
    this.ring = q("[data-gs-ring]")
    this.dot = q("[data-gs-live-dot]")
    this.endBtn = q("[data-gs-end]")
    this.statsEl = q("[data-gs-stats]")
    this.controllerEl = q("[data-gs-controller]")
    this.hintEl = q("[data-gs-hint]")
    this.elapsedEl = q("[data-gs-elapsed]")
    this.panels = Array.from(this.el.querySelectorAll("[data-gs-panel]"))

    this.capture = initialCapture()
    this.pc = null
    this.events = null
    this.stateCh = null
    this.frames = 0
    this.framesAtTick = 0
    this.fps = null
    this.path = null
    this.size = null
    this.hasFrames = false
    this.rtt = new RollingStats(60)
    this.pending = new Map()
    this.seq = 0
    this.lastInputAt = 0
    this.lastProbeAt = 0
    this.lastStatsPushAt = 0
    this.pad = null
    this.padDiffer = new PadDiffer()
    this.raf = null
    this.coarse = !!(window.matchMedia && window.matchMedia("(pointer: coarse)").matches)

    this.corner = document.createElement("canvas")
    this.corner.width = this.corner.height = CORNER_PX
    this.cornerCtx = this.corner.getContext("2d", { willReadFrequently: true })

    this.keys = new KeyForwarder({
      isCaptured: () => this.capture.captured && this.active(),
      send: m => this.sendEvent(m),
      onEscape: () => this.dispatch({ type: "key", code: "Escape" }),
      onInput: () => (this.lastInputAt = Date.now()),
      doc: document,
    })

    this.listen()
    this.handleEvent("game_stream", msg => this.onServer(msg))
    this.timer = setInterval(() => this.tick(), 1000)

    this.show(this.serverState)
    this.renderFooter()
    if (this.sessionId) this.whenRendered(() => this.attach())
  },

  // The wrapper is phx-update="ignore", but LiveView still patches ITS OWN
  // attributes on a re-render, so a status change on the server rewrote
  // data-state (e.g. back to "building" under a takeover panel). The hook
  // owns the rendered state: put it back.
  updated() {
    if (this.panel) this.el.dataset.state = this.panel
  },

  destroyed() {
    this.dead = true
    clearInterval(this.timer)
    if (this.observer) this.observer.disconnect()
    this.stopPadLoop()
    this.unlisten()
    this.closePeer()
    if (claims.get(this.sessionId) === this) claims.delete(this.sessionId)
  },

  // ── Wiring ────────────────────────────────────────────────────────────

  listen() {
    this.on = []
    const add = (target, type, fn, opts) => {
      target.addEventListener(type, fn, opts)
      this.on.push([target, type, fn, opts])
    }
    const click = (sel, fn) => this.el.querySelectorAll(sel).forEach(b => add(b, "click", fn))

    click("[data-gs-capture]", e => {
      e.stopPropagation()
      this.dispatch({ type: "click", live: this.isLive() })
    })
    add(this.el.querySelector("[data-gs-well]"), "click", () => {
      if (this.isLive()) this.dispatch({ type: "click", live: true })
    })
    click("[data-gs-end]", () => this.end())
    click("[data-gs-restart]", () => this.restart())
    click("[data-gs-play-here]", () => this.attach("take"))
    click("[data-gs-fullscreen]", () => this.toggleFullscreen())

    add(window, "keydown", e => this.keys.keydown(e), { capture: true })
    add(window, "keyup", e => this.keys.keyup(e), { capture: true })
    add(window, "blur", () => this.dispatch({ type: "blur" }))
    add(document, "visibilitychange", () => {
      if (document.visibilityState === "hidden") this.dispatch({ type: "hidden" })
    })
    add(document, "focusin", e => {
      if (this.keys.focusMovedToEditable(e.target)) this.dispatch({ type: "focus_editable" })
    })
    add(document, "fullscreenchange", () => {
      this.dispatch({ type: "fullscreen", on: document.fullscreenElement === this.el })
    })
    add(window, "gamepadconnected", () => this.renderFooter())
    add(window, "gamepaddisconnected", () => this.renderFooter())
    // Close the peer on unload so the host sees `closed` at once and
    // re-offers to the next window, instead of waiting out its 5 s timeout.
    add(window, "pagehide", () => this.closePeer())
  },

  unlisten() {
    for (const [target, type, fn, opts] of this.on || []) target.removeEventListener(type, fn, opts)
    this.on = []
  },

  whenRendered(fn) {
    if (rendered(this.el)) return fn()
    if (typeof ResizeObserver === "undefined") return
    this.observer = new ResizeObserver(() => {
      if (rendered(this.el) && claims.get(this.sessionId) !== this) fn()
    })
    this.observer.observe(this.el)
  },

  active() {
    return claims.get(this.sessionId) === this
  },

  push(event, payload) {
    return new Promise(resolve => this.pushEvent(event, payload, reply => resolve(reply || {})))
  },

  ids() {
    return { session_id: this.sessionId, canvas_id: this.canvasId, node_id: this.nodeId }
  },

  // ── Session ───────────────────────────────────────────────────────────

  async attach(mode) {
    if (this.dead) return
    // Only a node's FIRST attach after mounting can be a follower; a later
    // one (Play here, a twin becoming visible) is always the user's.
    const attachMode = mode || this.attachMode || "take"
    this.attachMode = "take"
    memo.attached(this.canvasId, this.nodeId, this.sessionId)
    const twin = claims.get(this.sessionId)
    if (twin && twin !== this) twin.suspend()
    claims.set(this.sessionId, this)

    const reply = await this.push("game_stream_attach", { ...this.ids(), mode: attachMode })
    if (this.dead || !this.active()) return
    const outcome = attachOutcome(reply)
    if (outcome.kind === "refused") return this.refused(reply.error)

    this.iceServers = reply.ice_servers || []
    this.iceTransportPolicy = reply.ice_transport_policy
    this.viewerToken = outcome.token
    const status = reply.status || {}
    if (outcome.kind === "takeover" && RUNNING.includes(status.state)) {
      // Another window holds the session: show the takeover panel with
      // Play here rather than a Connecting that no offer will ever end.
      this.serverState = status.state
      return this.movedAway()
    }
    this.applyStatus(status)
    if (reply.pending_offer) this.answer(reply.pending_offer)
  },

  // A hidden twin handing over to the copy that is now on screen.
  suspend() {
    this.dispatch({ type: "not_live" })
    this.closePeer()
    this.show("connecting")
  },

  onServer(msg) {
    if (!msg || msg.session_id !== this.sessionId || !this.active()) return
    // A window that was taken over answers nothing until "Play here": an
    // offer now belongs to the window that took over.
    if (this.panel === "takeover" && msg.type !== "moved") return
    if (msg.type === "status") this.applyStatus(msg.status || {})
    else if (msg.type === "signal" && msg.kind === "offer") this.answer(msg.data)
    else if (msg.type === "moved") this.movedAway()
  },

  applyStatus(status) {
    const state = status.state || "unavailable"
    this.serverState = state
    if (typeof status.elapsed_ms === "number") this.buildStartedAt = Date.now() - status.elapsed_ms

    if (state === "ended" || state === "failed") {
      this.setReason(state, status.ended_reason || status.detail)
      this.dispatch({ type: "not_live" })
      if (state === "ended") this.freezeFrame()
      this.closePeer()
      this.show(state)
    } else if (state === "live" || state === "connecting") {
      this.show(this.hasFrames && state === "live" ? "live" : "connecting")
    } else {
      this.show(state)
    }
  },

  refused(error) {
    if (error === "disabled") return this.show("unavailable")
    const line =
      error === "forbidden"
        ? "You cannot play this session from here"
        : error === "host_busy"
          ? "The play host is busy with another session"
          : error === "no_play_host"
            ? null
            : error === "not_in_review"
              ? "This task is no longer in review"
              : "Could not reach the play session"
    if (line === null) return this.show("unavailable")
    this.setReason("failed", line)
    this.show("failed")
  },

  movedAway() {
    this.dispatch({ type: "not_live" })
    this.closePeer()
    // A session that has already ended is shown as ended (with Start again),
    // not as continued somewhere else.
    this.show(RUNNING.includes(this.serverState) ? "takeover" : this.serverState)
  },

  async end() {
    const reply = await this.push("game_stream_end", { session_id: this.sessionId })
    if (reply.ok && reply.status) this.applyStatus(reply.status)
  },

  async restart() {
    const reply = await this.push("game_stream_restart", this.ids())
    if (!reply.ok) return this.refused(reply.error)
    if (claims.get(this.sessionId) === this) claims.delete(this.sessionId)
    memo.restarted(this.canvasId, this.nodeId, reply.session_id)
    this.sessionId = reply.session_id
    this.el.dataset.sessionId = reply.session_id
    this.hasFrames = false
    this.rtt = new RollingStats(60)
    this.applyStatus(reply.status || { state: "building" })
    this.attach("take")
  },

  setReason(state, text) {
    const panel = this.panels.find(p => p.dataset.gsPanel === state)
    const el = panel && panel.querySelector("[data-gs-reason]")
    if (el && text) el.textContent = text
  },

  // ── WebRTC ────────────────────────────────────────────────────────────

  async answer(offer) {
    const desc = typeof offer === "string" ? { type: "offer", sdp: offer } : offer
    if (!desc || !desc.sdp) return
    this.closePeer()
    const pc = new RTCPeerConnection(peerConfig(this.iceServers, this.iceTransportPolicy))
    this.pc = pc

    pc.ontrack = e => {
      this.video.removeAttribute("poster")
      try {
        e.receiver.jitterBufferTarget = 0
      } catch (_) {}
      this.video.muted = true
      this.video.srcObject = e.streams[0] || new MediaStream([e.track])
      this.video.play().catch(() => {})
      this.watchFrames()
    }
    pc.ondatachannel = e => {
      if (e.channel.label === "input-events") this.events = e.channel
      if (e.channel.label === "input-state") this.stateCh = e.channel
    }
    pc.onconnectionstatechange = () => {
      if (this.pc !== pc) return
      if (["failed", "disconnected", "closed"].includes(pc.connectionState)) {
        this.hasFrames = false
        if (RUNNING.includes(this.serverState)) this.show("connecting")
      }
    }

    try {
      await pc.setRemoteDescription({ type: "offer", sdp: desc.sdp })
      await pc.setLocalDescription(await pc.createAnswer())
      await waitForGathering(pc, GATHER_TIMEOUT_MS)
      if (this.pc !== pc || this.dead) return
      const reply = await this.push("game_stream_signal", {
        session_id: this.sessionId,
        kind: "answer",
        data: { type: "answer", sdp: pc.localDescription.sdp },
        viewer_token: this.viewerToken,
      })
      // Another window became the viewer while this one was connecting: its
      // answer never reached the host, so say where the stream went.
      if (signalMoved(reply) && this.pc === pc) this.movedAway()
    } catch (err) {
      if (this.pc === pc) {
        this.setReason("failed", "Could not connect to the play host")
        this.show("failed")
      }
    }
  },

  // Ended keeps the last frame on screen, dimmed. A closed peer ends the
  // track and the element would go black, so the frame is copied into the
  // poster first and the stream detached.
  freezeFrame() {
    const v = this.video
    if (!v || !v.videoWidth || !v.srcObject) return
    try {
      const c = document.createElement("canvas")
      c.width = v.videoWidth
      c.height = v.videoHeight
      c.getContext("2d").drawImage(v, 0, 0)
      v.poster = c.toDataURL("image/jpeg", 0.85)
      v.srcObject = null
    } catch (_) {}
  },

  closePeer() {
    const pc = this.pc
    this.pc = null
    this.events = null
    this.stateCh = null
    this.hasFrames = false
    if (pc) {
      try {
        pc.close()
      } catch (_) {}
    }
  },

  watchFrames() {
    const v = this.video
    if (!v || typeof v.requestVideoFrameCallback !== "function" || this.watching) return
    this.watching = true
    const onFrame = (now, meta) => {
      if (!this.pc) {
        this.watching = false
        return
      }
      this.frames++
      if (!this.hasFrames) {
        this.hasFrames = true
        if (this.serverState === "live" || this.serverState === "connecting") this.show("live")
      }
      if (meta && meta.width) this.size = { width: meta.width, height: meta.height }
      if (this.pending.size) this.decodeProbe(now)
      v.requestVideoFrameCallback(onFrame)
    }
    v.requestVideoFrameCallback(onFrame)
  },

  decodeProbe(now) {
    try {
      this.cornerCtx.drawImage(this.video, 0, 0, CORNER_PX, CORNER_PX, 0, 0, CORNER_PX, CORNER_PX)
      const data = this.cornerCtx.getImageData(0, 0, CORNER_PX, CORNER_PX).data
      // 0 is "no code in the corner", never a seq: it must not be looked up,
      // or an idle corner would read as a sample of `now - undefined`.
      const seq = decode(readCorner(data, CORNER_PX))
      if (seq && this.pending.has(seq)) {
        this.rtt.push(now - this.pending.get(seq))
        this.pending.delete(seq)
      }
    } catch (_) {}
  },

  sendEvent(message) {
    if (this.events && this.events.readyState === "open") this.events.send(JSON.stringify(message))
  },

  async readStats() {
    if (!this.pc) return
    const report = await this.pc.getStats()
    let pairId = null
    report.forEach(s => {
      if (s.type === "transport" && s.selectedCandidatePairId) pairId = s.selectedCandidatePairId
    })
    report.forEach(s => {
      if (s.type === "inbound-rtp" && s.kind === "video" && s.frameWidth) {
        this.size = { width: s.frameWidth, height: s.frameHeight }
      }
      if (!pairId && s.type === "candidate-pair" && s.nominated && s.state === "succeeded") {
        pairId = s.id
      }
    })
    const pair = pairId && report.get(pairId)
    const local = pair && report.get(pair.localCandidateId)
    const remote = pair && report.get(pair.remoteCandidateId)
    this.path = pair ? pairPath(local, remote) : null
  },

  // ── Capture ───────────────────────────────────────────────────────────

  isLive() {
    return this.active() && this.hasFrames && this.serverState === "live"
  },

  dispatch(event) {
    const { state, actions } = captureReduce(this.capture, event)
    this.capture = state
    for (const action of actions) {
      if (action === "capture") {
        this.keys.blurActive()
        this.lastInputAt = Date.now()
        this.startPadLoop()
      } else if (action === "release") {
        this.stopPadLoop()
      } else if (action === "release_all") {
        this.sendEvent({ t: "release_all" })
      } else if (action === "exit_fullscreen") {
        if (document.fullscreenElement && document.exitFullscreen) document.exitFullscreen().catch(() => {})
      }
    }
    this.renderCapture()
  },

  startPadLoop() {
    this.padDiffer.reset()
    const loop = () => {
      if (!this.capture.captured) return
      const pads = navigator.getGamepads ? navigator.getGamepads() : []
      const pad = pickGamepad(pads)
      if (!!pad !== !!this.pad) {
        this.pad = pad
        this.renderFooter()
      }
      this.pad = pad
      const msg = this.padDiffer.next(pad)
      if (msg && this.stateCh && this.stateCh.readyState === "open") {
        this.stateCh.send(JSON.stringify(msg))
        if (msg.connected) this.lastInputAt = Date.now()
      }
      this.raf = requestAnimationFrame(loop)
    }
    this.raf = requestAnimationFrame(loop)
  },

  stopPadLoop() {
    if (this.raf) cancelAnimationFrame(this.raf)
    this.raf = null
  },

  toggleFullscreen() {
    if (document.fullscreenElement === this.el) {
      document.exitFullscreen().catch(() => {})
      return
    }
    const req = this.el.requestFullscreen || this.el.webkitRequestFullscreen
    if (!req) return
    Promise.resolve(req.call(this.el))
      .then(() => {
        if (screen.orientation && screen.orientation.lock) {
          return screen.orientation.lock("landscape").catch(() => {})
        }
      })
      .catch(() => {})
  },

  // ── Render ────────────────────────────────────────────────────────────

  show(panel) {
    this.panel = panel
    const shown = panel === "live" && this.capture.captured ? null : panel
    for (const p of this.panels) p.hidden = p.dataset.gsPanel !== shown
    this.el.dataset.state = panel
    const live = panel === "live"
    this.dot.classList.toggle("bg-success", live)
    this.dot.classList.toggle("bg-base-content/20", !live)
    this.video.classList.toggle("opacity-40", panel === "ended")
    if (this.endBtn) this.endBtn.hidden = !RUNNING.includes(this.serverState) || panel === "takeover"
    if (panel === "building" && this.elapsedEl) {
      this.elapsedEl.textContent = formatElapsed(Date.now() - this.buildStartedAt)
    }
    this.renderCapture()
  },

  renderCapture() {
    const captured = this.capture.captured
    if (this.ring) this.ring.hidden = !captured
    if (this.panel === "live") {
      for (const p of this.panels) p.hidden = captured || p.dataset.gsPanel !== "live"
    }
    this.renderFooter()
  },

  renderFooter() {
    if (!this.controllerEl) return
    const pads = navigator.getGamepads ? navigator.getGamepads() : []
    const pad = this.pad || pickGamepad(pads)
    const playing = RUNNING.includes(this.serverState) && this.panel !== "takeover"
    const label = playing ? controllerLabel({ pad, coarse: this.coarse }) : ""
    this.controllerEl.textContent = label
    // Hidden when empty, so an ended frame does not keep a blank row on a phone.
    this.controllerEl.hidden = label === ""
    this.hintEl.textContent = hintText({ live: this.panel === "live", captured: this.capture.captured })
    const p50 = this.rtt.p50()
    this.statsEl.textContent = formatStats({
      p50,
      fps: this.fps,
      path: this.path,
      width: this.size && this.size.width,
      height: this.size && this.size.height,
    })
    const warn = latencyWarn(p50, this.warnMs)
    this.statsEl.classList.toggle("text-warning", warn)
    this.statsEl.classList.toggle("text-base-content/60", !warn)
  },

  tick() {
    const now = Date.now()
    this.fps = this.pc && this.hasFrames ? this.frames - this.framesAtTick : null
    this.framesAtTick = this.frames

    if (this.panel === "building" && this.elapsedEl) {
      this.elapsedEl.textContent = formatElapsed(now - this.buildStartedAt)
    }

    // Expire probes that never came back.
    const t = performance.now()
    for (const [seq, sentAt] of this.pending) if (t - sentAt > PROBE_TIMEOUT_MS) this.pending.delete(seq)

    if (
      this.capture.captured &&
      this.hasFrames &&
      now - this.lastInputAt < PROBE_IDLE_STOP_MS &&
      now - this.lastProbeAt >= PROBE_EVERY_MS
    ) {
      this.lastProbeAt = now
      this.seq = nextSeq(this.seq)
      this.pending.set(this.seq, performance.now())
      this.sendEvent({ t: "probe", seq: this.seq })
    }

    if (this.pc) this.readStats().catch(() => {})

    if (this.active() && this.pc && this.hasFrames && now - this.lastStatsPushAt >= STATS_PUSH_EVERY_MS) {
      this.lastStatsPushAt = now
      const stats = {}
      if (this.rtt.count) {
        stats.rtt_p50_ms = this.rtt.p50()
        stats.rtt_p95_ms = this.rtt.p95()
      }
      if (this.fps != null) stats.fps_avg = this.fps
      if (this.path) stats.connection_path = this.path.toLowerCase()
      this.push("game_stream_stats", { session_id: this.sessionId, stats })
    }

    this.renderFooter()
  },
}

export default GameStream
