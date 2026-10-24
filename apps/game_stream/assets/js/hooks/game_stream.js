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
 * Which copy shows what (task 01a0dbd6 stage 1, `lib/game_stream_attach_state.js`):
 * the frame is on Connecting only while the CURRENT peer connection has no
 * decoded frame in the last 2 s. Frames are counted per peer connection
 * (requestVideoFrameCallback, with getStats' framesDecoded as a fallback), so
 * a status message never demotes a frame that is decoding and a frame from a
 * closed peer never counts. After 10 s on Connecting the frame offers "Still
 * connecting" and Reload. A copy suspended by a twin takes the stream back
 * when it is on screen and the twin holding it is not: the rig reproduced a
 * desktop panel stuck on Connecting while its hidden mobile-overlay twin kept
 * decoding, after the window crossed the `lg` breakpoint and back.
 *
 * Several players (task 01a0dbd6 stage 4, design canvas 01a0e954-b12f): opening
 * the canvas attaches this LiveView's peer as a SPECTATOR, with live video and
 * no slot. The roster strip, the watching row with "Join as player N", Leave,
 * the overflow (take over, End session) and the phone line with its sheet are
 * re-rendered from core's `roster` messages with `lib/game_stream_roster.js`.
 * `displaced` (someone took this peer's slot) keeps the video and says who.
 * Each pad is a src (`PadSources`; src 0 is the keyboard plus the first pad);
 * a pad with no slot claims the next free one on a button press. Every write
 * to the host's data channels goes through ONE `InputRouter`, which sends only
 * for a src that holds a slot, so a spectator's page sends no input and no
 * probes at all. A v1 host (roster `multi: false`) keeps End and Play here.
 *
 * Which WINDOW plays (stage 6): an attach is `take` (a window the user acted
 * in) or `follow` (this page's node was re-rendered onto a session someone
 * else restarted; `lib/game_stream_session.js`). The server answers whether
 * this window is the viewer and hands it a `viewer_token`; every signal
 * carries it back, and a signal refused as `moved` (another window is the
 * viewer now) shows "Continued in another window" instead of hanging on
 * Connecting.
 *
 * Touch (task 01a0fe45 stage 2, `lib/game_stream_touch.js`): when core says
 * the host takes touch (`touch.enabled` on the status and roster), this copy
 * holds the stream, the peer is a player and the frame is live, the well gets
 * `data-gs-touch="on"` (`touch-action: none`) and a touch or pen on the
 * frame goes to the game, through the same router as keys. A mouse never
 * does. On a phone (coarse pointer) the Click to play panel is hidden so the
 * first tap reaches the game. Every touch is cancelled when the window blurs
 * or hides, the channel or peer closes, src 0's slot goes, or touch turns off.
 */

import { AudioPlayback, routeInboundTrack } from "./lib/game_stream_audio.js"
import { captureReduce, initialCapture } from "./lib/game_stream_capture.js"
import {
  InputRouter,
  KeyForwarder,
  PadDiffer,
  PadSources,
  controllerLabel,
  hintText,
  padPressed,
  pickGamepad,
  pickGamepads,
} from "./lib/game_stream_input.js"
import {
  CORNER_PX,
  PROBE_MAX_SLOT,
  RollingStats,
  decode,
  formatStats,
  latencyWarn,
  nextSeq,
  pairPath,
  peerConfig,
  probeSeqFor,
  readCorner,
} from "./lib/game_stream_probe.js"
import {
  chips,
  confirmLine,
  endLine,
  mySlotList,
  normalizeRoster,
  normalizeSlots,
  padRows,
  phoneLine,
  reconcileSlots,
  sheetWatchingText,
  takeOverItems,
  watchView,
  watchingText,
  watchingTitle,
} from "./lib/game_stream_roster.js"
import { SessionMemo, attachOutcome, signalMoved } from "./lib/game_stream_session.js"
import { TouchForwarder, contentRect, normalizeTouch, tallAspect } from "./lib/game_stream_touch.js"
import { panelFor, reclaim, stuck, stuckAt, suspendedPanel, twinHeldPanel } from "./lib/game_stream_attach_state.js"

const claims = new Map()
// Every mounted copy per session id, so a copy can tell whether another
// on-screen copy has the better claim (`reclaim`'s `outranked`).
const copies = new Map()
const memo = new SessionMemo()

const PROBE_EVERY_MS = 1000
const PROBE_TIMEOUT_MS = 1500
const PROBE_IDLE_STOP_MS = 30000
const STATS_PUSH_EVERY_MS = 5000
const GATHER_TIMEOUT_MS = 3000
const BLINK_MS = 250
// The compat click a browser fires after a forwarded touch's pointerup lands
// within this window; the well swallows it (no click-to-capture).
const TOUCH_CLICK_SWALLOW_MS = 700
const POINTER_EVENTS = ["pointerdown", "pointermove", "pointerup", "pointercancel", "lostpointercapture"]

const RUNNING = ["building", "connecting", "live"]

// A copy whose stream plays somewhere else: another window ("takeover") or a
// twin copy in this page ("elsewhere"). Neither shows End, Leave, the
// overflow, the watching row or the controller line.
function playingElsewhere(panel) {
  return panel === "takeover" || panel === "elsewhere"
}

function rendered(el) {
  return el.getClientRects().length > 0
}

// On screen means a person can see it: rendered, inside the viewport, and not
// covered (the mobile canvas overlay is `fixed inset-0` over the chat, whose
// inline copy still has client rects underneath it). Probed at the centre of
// the element's visible part.
function onScreen(el) {
  if (!rendered(el)) return false
  const r = el.getBoundingClientRect()
  const left = Math.max(r.left, 0)
  const top = Math.max(r.top, 0)
  const right = Math.min(r.right, window.innerWidth)
  const bottom = Math.min(r.bottom, window.innerHeight)
  if (right <= left || bottom <= top) return false
  const hit = document.elementFromPoint((left + right) / 2, (top + bottom) / 2)
  return !!hit && el.contains(hit)
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
    this.peerId = null
    this.dead = false

    const q = sel => this.el.querySelector(sel)
    this.video = q("[data-gs-video]")
    this.well = q("[data-gs-well]")
    this.audioEl = q("[data-gs-audio]")
    this.audioStateEl = q("[data-gs-audio-state]")
    this.muteBtn = q("[data-gs-mute]")
    this.ring = q("[data-gs-ring]")
    this.dot = q("[data-gs-live-dot]")
    this.endBtn = q("[data-gs-end]")
    this.statsEl = q("[data-gs-stats]")
    this.controllerEl = q("[data-gs-controller]")
    this.hintEl = q("[data-gs-hint]")
    this.elapsedEl = q("[data-gs-elapsed]")
    this.stuckEl = q("[data-gs-stuck]")
    this.connectingLineEl = q("[data-gs-connecting-line]")
    this.panels = Array.from(this.el.querySelectorAll("[data-gs-panel]"))
    // Multiplayer (stage 4). All optional: an older render has none of them.
    this.leaveBtn = q("[data-gs-leave]")
    this.overflowEl = q("[data-gs-overflow]")
    this.overflowToggle = q("[data-gs-overflow-toggle]")
    this.overflowMenu = q("[data-gs-overflow-menu]")
    this.takeItemsEl = q("[data-gs-take-items]")
    this.takeTemplate = q("template[data-gs-take-template]")
    this.confirmEl = q("[data-gs-confirm]")
    this.confirmLineEl = q("[data-gs-confirm-line]")
    this.endLineEl = q("[data-gs-end-line]")
    this.rosterEl = q("[data-gs-roster]")
    this.chipsEl = q("[data-gs-chips]")
    this.chipTemplate = q("template[data-gs-chip-template]")
    this.watchingEl = q("[data-gs-watching]")
    this.rosterLineText = q("[data-gs-roster-line-text]")
    this.sheet = q("dialog[data-gs-sheet]")
    this.sheetChipsEl = q("[data-gs-sheet-chips]")
    this.sheetWatchingEl = q("[data-gs-sheet-watching]")
    this.watchEl = q("[data-gs-watch]")
    this.watchLineEl = q("[data-gs-watch-line]")
    this.joinBtn = q("[data-gs-join]")
    this.padsEl = q("[data-gs-pads]")
    this.padTemplate = q("template[data-gs-pad-template]")

    this.capture = initialCapture()
    this.pc = null
    // Per-peer frame tracking (stage 1): the current pc's id, and the last
    // decoded frame as {pcId, at}. No hook-wide latch.
    this.pcSeq = 0
    this.pcId = null
    this.lastFrame = null
    this.statFrames = null
    this.connectingSince = null
    // True while a twin copy in this page holds the session and this copy
    // should take it back once it is the one on screen.
    this.suspended = false
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
    this.raf = null
    this.coarse = !!(window.matchMedia && window.matchMedia("(pointer: coarse)").matches)
    // The first frame's roster is the server's render: multi exactly when it
    // rendered the strip. Attach replies and roster messages replace it.
    this.multi = !!this.rosterEl && !this.rosterEl.hidden
    this.rosterKnown = false
    this.blinkTimers = new Map()

    this.corner = document.createElement("canvas")
    this.corner.width = this.corner.height = CORNER_PX
    this.cornerCtx = this.corner.getContext("2d", { willReadFrequently: true })

    this.audio = new AudioPlayback({
      element: this.audioEl,
      stateElement: this.audioStateEl,
      button: this.muteBtn,
    })
    this.initInput(document)

    this.track(this.sessionId)
    this.listen()
    this.handleEvent("game_stream", msg => this.onServer(msg))
    this.timer = setInterval(() => this.tick(), 1000)

    this.show(this.serverState)
    this.renderFooter()
    if (this.sessionId) this.whenRendered(() => this.attach())
  },

  // Input and roster state (stage 4): the router is the ONLY writer to the
  // host's data channels, and it writes only for a src that holds a slot.
  initInput(doc) {
    this.roster = normalizeRoster(null)
    this.mine = new Map()
    this.displaced = null
    this.probeSlot = null
    this.pads = []
    this.padSig = ""
    this.padSources = new PadSources()
    this.padDiffers = new Map()
    this.padWasPressed = new Map()
    this.router = new InputRouter({
      sendEvent: m => {
        if (this.events && this.events.readyState === "open") this.events.send(JSON.stringify(m))
      },
      sendState: m => {
        if (this.stateCh && this.stateCh.readyState === "open") this.stateCh.send(JSON.stringify(m))
      },
    })
    this.keys = new KeyForwarder({
      isCaptured: () => this.capture.captured && this.active(),
      send: m => this.router.key(m),
      onEscape: () => this.dispatch({ type: "key", code: "Escape" }),
      onMute: () => this.audio.toggleMute(),
      onInput: () => (this.lastInputAt = Date.now()),
      doc,
    })
    // Touch (task 01a0fe45): off until core's status or roster says the host
    // takes it. The forwarder writes only through the router.
    this.touchCfg = normalizeTouch(null)
    this.touchOn = false
    this.touchClickUntil = 0
    this.touches = new TouchForwarder({
      isEnabled: () => this.touchOn,
      send: m => this.router.touch(m),
      rect: () => this.touchRect(),
      now: () => performance.now(),
      slopPx: this.touchCfg.slopPx,
      moveHz: this.touchCfg.moveHz,
    })
  },

  // The displayed frame's box, recomputed per event from the element's rect
  // and the decoded size, so rotation, resize, fullscreen and a resolution
  // change mid-stream all map right. CSS px throughout: no devicePixelRatio.
  touchRect() {
    const v = this.video
    if (!v || typeof v.getBoundingClientRect !== "function") return null
    return contentRect(v.getBoundingClientRect(), v.videoWidth, v.videoHeight)
  },

  setTouch(raw) {
    this.touchCfg = normalizeTouch(raw)
    this.touches.configure({ slopPx: this.touchCfg.slopPx, moveHz: this.touchCfg.moveHz })
    this.renderCapture()
  },

  // Touch goes to the game only from the copy holding the stream (not a
  // hidden twin), for a player, on a live frame, on a host that takes it.
  touchWanted() {
    return (
      !this.dead &&
      this.touchCfg.enabled &&
      this.active() &&
      !this.suspended &&
      this.router.player &&
      this.panel === "live"
    )
  },

  // A phone's taps go to the game, so its live frame has nothing to click.
  touchHidesPanel() {
    return this.coarse && this.touchWanted()
  },

  renderTouch() {
    const on = this.touchWanted()
    if (on !== this.touchOn) {
      if (!on) this.touches.releaseAll()
      this.touchOn = on
    }
    if (!this.well) return
    if (on) this.well.setAttribute("data-gs-touch", "on")
    else this.well.removeAttribute("data-gs-touch")
  },

  onPointer(e) {
    // A control on the frame (a panel's button) stays a control.
    if (e.type === "pointerdown" && e.target && e.target.closest && e.target.closest("button")) return
    if (!this.touches[e.type].call(this.touches, e)) return
    e.preventDefault()
    this.touchClickUntil = Date.now() + TOUCH_CLICK_SWALLOW_MS
    if (e.type !== "pointerdown") return
    this.audio.gesture()
    this.lastInputAt = Date.now()
    try {
      if (this.well && this.well.setPointerCapture) this.well.setPointerCapture(e.pointerId)
    } catch (_) {}
  },

  // A portrait stream's well takes the frame's aspect ratio (capped in CSS at
  // 80svh); a 16:9-or-wider one keeps aspect-video.
  renderAspect() {
    if (!this.well || !this.video || !this.well.style) return
    const aspect = tallAspect(this.video.videoWidth, this.video.videoHeight)
    if (aspect) {
      this.well.style.setProperty("--gs-aspect", aspect)
      this.well.setAttribute("data-gs-tall", "")
    } else {
      this.well.style.removeProperty("--gs-aspect")
      this.well.removeAttribute("data-gs-tall")
    }
  },

  // Takes the stream back when this copy is on screen and the twin holding
  // it is not (see lib/game_stream_attach_state.js `reclaim`).
  maybeReclaim() {
    if (this.dead || !this.sessionId) return
    const holder = claims.get(this.sessionId)
    const holderOnScreen = holder && holder !== this ? onScreen(holder.el) : null
    const mine = this.heldAt || 0
    const outranked = Array.from(copies.get(this.sessionId) || []).some(
      c => c !== this && c !== holder && !c.dead && c.suspended && (c.heldAt || 0) > mine && onScreen(c.el),
    )
    if (reclaim({ onScreen: onScreen(this.el), active: this.active(), suspended: this.suspended, holderOnScreen, outranked })) {
      this.attach()
    }
  },

  // A suspended copy while a twin in this page holds the session shows where
  // the stream is ("elsewhere", with Play here), not its mount-time
  // Connecting: it has no pc (task 01a0ee4f stage 3, `twinHeldPanel`). Runs
  // when a copy mounts hidden (a twin already holds) and on every twin's
  // attach (a twin holds from now on). In this hook those are the moments a
  // suspended copy's running panel can meet a holder, so the panel is set
  // BEFORE a breakpoint crossing renders the copy: it never shows Connecting
  // first, and the resize itself changes nothing (maybeReclaim still takes
  // the stream only from a holder that is off screen).
  showTwinHeld() {
    if (this.dead || !this.sessionId) return
    const holder = claims.get(this.sessionId)
    const panel = twinHeldPanel({
      active: this.active(),
      suspended: this.suspended,
      twinHolds: !!holder && holder !== this && !holder.dead,
      serverState: this.serverState,
      panel: this.panel,
    })
    if (panel && panel !== this.panel) this.show(panel)
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
    if (this.touches) this.touches.releaseAll()
    clearInterval(this.timer)
    clearTimeout(this.stuckTimer)
    for (const t of this.blinkTimers.values()) clearTimeout(t)
    if (this.sheet && this.sheet.open && this.sheet.close) this.sheet.close()
    if (this.observer) this.observer.disconnect()
    this.stopPadLoop()
    this.unlisten()
    this.closePeer()
    if (claims.get(this.sessionId) === this) claims.delete(this.sessionId)
    this.untrack(this.sessionId)
  },

  track(sessionId) {
    if (!sessionId) return
    if (!copies.has(sessionId)) copies.set(sessionId, new Set())
    copies.get(sessionId).add(this)
  },

  untrack(sessionId) {
    const set = sessionId && copies.get(sessionId)
    if (!set) return
    set.delete(this)
    if (set.size === 0) copies.delete(sessionId)
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
      this.audio.gesture()
      this.dispatch({ type: "click", live: this.canCapture() })
    })
    add(this.el.querySelector("[data-gs-well]"), "click", () => {
      // A forwarded touch's trailing compat click: the touch went to the game.
      if (Date.now() < this.touchClickUntil) {
        this.touchClickUntil = 0
        return
      }
      this.audio.gesture()
      if (this.canCapture()) this.dispatch({ type: "click", live: true })
    })
    if (this.well) for (const type of POINTER_EVENTS) add(this.well, type, e => this.onPointer(e))
    if (this.video) {
      add(this.video, "loadedmetadata", () => this.renderAspect())
      add(this.video, "resize", () => this.renderAspect())
    }
    click("[data-gs-end]", () => this.end())
    click("[data-gs-leave]", () => this.leave())
    click("[data-gs-join]", () => {
      this.audio.gesture()
      const slot = parseInt(this.joinBtn && this.joinBtn.dataset.gsJoinSlot, 10)
      this.join(Number.isInteger(slot) ? slot : null)
    })
    click("[data-gs-overflow-toggle]", e => {
      e.stopPropagation()
      this.toggleMenu()
    })
    click("[data-gs-end-session]", () => {
      this.closeMenu()
      this.end()
    })
    click("[data-gs-confirm-yes]", () => {
      const slot = this.confirming && this.confirming.slot
      this.closeMenu()
      if (Number.isInteger(slot)) this.takeOver(slot)
    })
    click("[data-gs-confirm-no]", () => this.showConfirm(null))
    click("[data-gs-roster-line]", () => {
      if (this.sheet && this.sheet.showModal && !this.sheet.open) this.sheet.showModal()
    })
    for (const box of [this.chipsEl, this.sheetChipsEl]) {
      if (!box) continue
      add(box, "click", e => {
        const chip = e.target.closest && e.target.closest("[data-gs-chip]")
        if (!chip || chip.dataset.gsChipState !== "open") return
        if (this.sheet && this.sheet.open) this.sheet.close()
        this.join(parseInt(chip.dataset.gsChip, 10))
      })
    }
    if (this.takeItemsEl) {
      add(this.takeItemsEl, "click", e => {
        const item = e.target.closest && e.target.closest("[data-gs-take-over]")
        if (!item) return
        e.stopPropagation()
        this.showConfirm({ slot: parseInt(item.dataset.gsTakeOver, 10), label: item.textContent.trim() })
      })
    }
    add(document, "click", e => {
      if (this.overflowMenu && !this.overflowMenu.hidden && !this.overflowEl.contains(e.target)) this.closeMenu()
    })
    click("[data-gs-restart]", () => {
      this.audio.gesture()
      this.restart()
    })
    click("[data-gs-play-here]", () => {
      this.audio.gesture()
      this.playHere()
    })
    click("[data-gs-mute]", e => {
      e.stopPropagation()
      this.audio.action()
    })
    // Play here on "elsewhere" (task 01a0ee4f stage 2): a twin in THIS page
    // holds the stream, so take it back in the page. Never playHere(): that
    // pushes game_stream_take_over for slot 0, a window-level take-over that
    // on a multi host would take P1 from another person.
    click("[data-gs-play-here-twin]", () => {
      this.audio.gesture()
      this.attach("take")
    })
    click("[data-gs-reload]", () => window.location.reload())
    click("[data-gs-fullscreen]", () => this.toggleFullscreen())

    add(window, "keydown", e => this.keys.keydown(e), { capture: true })
    add(window, "keyup", e => this.keys.keyup(e), { capture: true })
    add(window, "blur", () => {
      this.touches.releaseAll()
      this.dispatch({ type: "blur" })
    })
    add(document, "visibilitychange", () => {
      if (document.visibilityState !== "hidden") return
      this.touches.releaseAll()
      this.dispatch({ type: "hidden" })
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

  // A copy on screen attaches now; one that is not waits, suspended, until it
  // is. Every copy keeps watching its size, so a copy that comes back on
  // screen (a breakpoint crossed and crossed back) takes the stream back from
  // a twin that went off screen. `tick` re-checks once a second as well.
  whenRendered(fn) {
    if (rendered(this.el)) fn()
    else {
      this.suspended = true
      this.showTwinHeld()
    }
    if (typeof ResizeObserver === "undefined") return
    this.observer = new ResizeObserver(() => this.maybeReclaim())
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
    this.suspended = false
    this.heldAt = performance.now()
    // The 10 s "Still connecting" clock starts at this attach, not at an
    // earlier suspension.
    this.connectingSince = Date.now()
    memo.attached(this.canvasId, this.nodeId, this.sessionId)
    const twin = claims.get(this.sessionId)
    if (twin && twin !== this) twin.suspend()
    claims.set(this.sessionId, this)
    // Every other suspended copy (one that mounted hidden and never held the
    // stream) now has a twin holding it: it shows elsewhere, not Connecting.
    for (const c of copies.get(this.sessionId) || []) if (c !== this) c.showTwinHeld()

    const reply = await this.push("game_stream_attach", { ...this.ids(), mode: attachMode })
    if (this.dead || !this.active()) return
    const outcome = attachOutcome(reply)
    if (outcome.kind === "refused") return this.refused(reply.error)

    this.iceServers = reply.ice_servers || []
    this.iceTransportPolicy = reply.ice_transport_policy
    this.viewerToken = outcome.token
    this.peerId = outcome.peerId
    this.applyPeer(reply)
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

  // A twin handing over to the copy that attached after it. This copy takes
  // the stream back if it is on screen when the twin is not (maybeReclaim),
  // or when the person clicks its Play here ([data-gs-play-here-twin]).
  // It has closed its pc, so a running session shows "elsewhere", never
  // Connecting (task 01a0ee4f stage 2, `suspendedPanel`). The panel is
  // sticky: renderAttach leaves a non-running panel alone and onServer
  // ignores a copy that is not the claimant.
  suspend() {
    this.suspended = true
    this.dispatch({ type: "not_live" })
    this.closePeer()
    this.show(suspendedPanel({ serverState: this.serverState }))
  },

  onServer(msg) {
    if (!msg || msg.session_id !== this.sessionId || !this.active()) return
    // A window that was taken over answers nothing until "Play here": an
    // offer now belongs to the window that took over.
    if (this.panel === "takeover" && msg.type !== "moved") return
    if (msg.type === "status") this.applyStatus(msg.status || {})
    else if (msg.type === "signal" && msg.kind === "offer") this.answer(msg.data)
    else if (msg.type === "moved") this.movedAway()
    else if (msg.type === "roster") this.setRoster(msg.roster)
    else if (msg.type === "displaced") this.onDisplaced(msg)
    else if (msg.type === "slot_activity") this.blink(msg.slots)
  },

  // ── Roster, slots and moves (stage 4) ─────────────────────────────────

  // A join / leave / take-over / attach reply: this peer's id, token, its
  // {src: slot} and (on attach) the roster.
  applyPeer(reply) {
    if (!reply) return
    if (reply.peer_id != null) this.peerId = reply.peer_id
    if (reply.viewer_token != null) this.viewerToken = reply.viewer_token
    if (reply.roster) this.setRoster(reply.roster, { reconcile: false })
    if (reply.slots) this.setMine(normalizeSlots(reply.slots))
  },

  setRoster(raw, { reconcile = true } = {}) {
    if (raw && raw.touch) this.setTouch(raw.touch)
    this.roster = normalizeRoster(raw)
    this.multi = this.roster.multi
    this.rosterKnown = true
    if (reconcile && this.multi) {
      const kept = reconcileSlots(this.mine, this.roster, this.peerId)
      if (kept.size !== this.mine.size) return this.setMine(kept)
    }
    this.renderRoster()
  },

  setMine(mine) {
    const before = mySlotList(this.mine).join(",")
    // Cancel touches while src 0 still holds its slot, so the cancel goes out.
    if (this.mine.has(0) && !mine.has(0)) this.touches.releaseAll()
    this.mine = mine
    this.router.setSlots(mine)
    for (const [src, differ] of this.padDiffers) {
      if (mine.has(src)) differ.slot = mine.get(src)
      else this.padDiffers.delete(src)
    }
    if (mySlotList(mine).join(",") !== before) {
      // A probe in flight carries the old slot's code.
      this.pending.clear()
      this.probeSlot = null
    }
    if (this.router.player) this.displaced = null
    // A spectator holds no capture. The release_all it would send goes
    // nowhere (the router has no slot for it); the host released the lost
    // slot itself on play_slots.
    else if (this.capture.captured) this.dispatch({ type: "not_live" })
    this.renderRoster()
    this.renderCapture()
    this.updatePadLoop()
  },

  onDisplaced(msg) {
    if (!this.multi) return
    const slot = Number(msg.slot)
    this.displaced = { slot, by: msg.by || null }
    const kept = new Map(Array.from(this.mine).filter(([, s]) => s !== slot))
    this.setMine(kept)
  },

  // Explicit moves. Each reply carries this peer's slots; the roster that
  // every copy renders arrives on the topic.
  async join(slot, src = 0) {
    if (this.dead || !this.multi) return null
    const payload = { ...this.ids(), src }
    if (Number.isInteger(slot)) payload.slot = slot
    const reply = await this.push("game_stream_join", payload)
    if (this.dead) return null
    if (reply.ok) {
      this.displaced = null
      this.applyPeer(reply)
    } else {
      this.renderRoster()
    }
    return reply
  },

  async leave() {
    if (this.dead) return
    // Release first, while this peer still holds its slots.
    this.dispatch({ type: "not_live" })
    const reply = await this.push("game_stream_leave", this.ids())
    if (this.dead || !reply.ok) return
    this.displaced = null
    this.applyPeer(reply)
  },

  async takeOver(slot) {
    if (this.dead) return
    const reply = await this.push("game_stream_take_over", { ...this.ids(), slot, src: 0 })
    if (this.dead || !reply.ok) return
    this.displaced = null
    this.applyPeer(reply)
  },

  async padJoin(src) {
    const reply = await this.join(null, src)
    if (reply && reply.ok && this.padDiffers.has(src)) this.padDiffers.get(src).reset()
  },

  toggleMenu() {
    if (!this.overflowMenu) return
    if (this.overflowMenu.hidden) {
      this.renderRoster()
      this.showConfirm(null)
      this.overflowMenu.hidden = false
      this.overflowToggle.setAttribute("aria-expanded", "true")
    } else {
      this.closeMenu()
    }
  },

  closeMenu() {
    if (!this.overflowMenu) return
    this.overflowMenu.hidden = true
    this.overflowToggle.setAttribute("aria-expanded", "false")
    this.showConfirm(null)
  },

  // The one-line take-over confirm, or (null) the item list again.
  showConfirm(item) {
    this.confirming = item
    if (this.confirmEl) this.confirmEl.hidden = !item
    if (this.takeItemsEl) this.takeItemsEl.hidden = !!item
    if (item && this.confirmLineEl) this.confirmLineEl.textContent = confirmLine(item)
  },

  blink(slots) {
    for (const slot of Array.isArray(slots) ? slots : []) {
      const dots = this.el.querySelectorAll(`[data-gs-chip="${Number(slot)}"] [data-gs-chip-dot]`)
      dots.forEach(dot => {
        dot.classList.remove("opacity-20")
        dot.classList.add("opacity-100")
      })
      clearTimeout(this.blinkTimers.get(slot))
      this.blinkTimers.set(
        slot,
        setTimeout(() => {
          dots.forEach(dot => {
            dot.classList.remove("opacity-100")
            dot.classList.add("opacity-20")
          })
        }, BLINK_MS),
      )
    }
  },

  applyStatus(status) {
    const state = status.state || "unavailable"
    this.serverState = state
    if (status.touch) this.setTouch(status.touch)
    if (typeof status.elapsed_ms === "number") this.buildStartedAt = Date.now() - status.elapsed_ms

    if (state === "ended" || state === "failed") {
      this.setReason(state, status.ended_reason || status.detail)
      this.dispatch({ type: "not_live" })
      if (state === "ended") this.freezeFrame()
      this.closePeer()
      this.show(state)
    } else if (state === "live" || state === "connecting") {
      // A status message never demotes a frame that is decoding: the panel
      // follows the current pc's frames (renderAttach).
      if (!["building", "connecting", "live"].includes(this.panel)) this.show("connecting")
      this.renderAttach()
    } else {
      this.show(state)
    }
  },

  refused(error) {
    if (error === "disabled") return this.show("unavailable")
    const line =
      error === "spectators_full"
        ? "This session is full. Try again when someone leaves"
        : error === "forbidden"
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

  canCapture() {
    return this.isLive() && this.router.player
  },

  movedAway() {
    this.suspended = false
    this.dispatch({ type: "not_live" })
    this.closePeer()
    // A session that has already ended is shown as ended (with Start again),
    // not as continued somewhere else.
    this.show(RUNNING.includes(this.serverState) ? "takeover" : this.serverState)
  },

  // "Play here" (task 01a0dbd6): opening only ever watches, so taking the
  // stream is an explicit take-over of P1 for this LiveView's peer. The
  // attach after it re-subscribes (a moved window unsubscribed) and hands
  // back the token and any pending offer. A refused take-over still
  // attaches, and the attach reply says what this window may show.
  async playHere() {
    if (this.dead) return
    await this.push("game_stream_take_over", { ...this.ids(), slot: 0, src: 0 })
    if (this.dead) return
    this.attach()
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
    this.untrack(this.sessionId)
    this.sessionId = reply.session_id
    this.track(this.sessionId)
    this.el.dataset.sessionId = reply.session_id
    this.hasFrames = false
    this.lastFrame = null
    this.rtt = new RollingStats(60)
    this.displaced = null
    this.setMine(new Map())
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
    const pcId = ++this.pcSeq
    this.pc = pc
    this.pcId = pcId
    this.statFrames = null

    pc.ontrack = e => {
      try {
        e.receiver.jitterBufferTarget = 0
      } catch (_) {}
      routeInboundTrack(e, {
        video: this.video,
        audio: this.audio,
        onVideo: () => this.watchFrames(pcId),
      })
    }
    pc.ondatachannel = e => {
      const ch = e.channel
      if (ch.label === "input-events") this.events = ch
      if (ch.label === "input-state") this.stateCh = ch
      if (typeof ch.addEventListener === "function") {
        ch.addEventListener("close", () => {
          if (this.events === ch || this.stateCh === ch) this.touches.releaseAll()
        })
      }
    }
    // A failed or closed peer decodes nothing more: drop its frames now. A
    // disconnected one may recover (ICE, TURN); its frames simply stop
    // counting 2 s after the last one if it does not.
    pc.onconnectionstatechange = () => {
      if (this.pc !== pc) return
      if (["failed", "closed"].includes(pc.connectionState)) {
        this.touches.releaseAll()
        this.hasFrames = false
        this.lastFrame = null
      }
      this.renderAttach()
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
        peer_id: this.peerId,
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
    // Before the channels go, so the cancels can still be sent.
    if (this.touches) this.touches.releaseAll()
    const pc = this.pc
    this.pc = null
    this.pcId = null
    this.statFrames = null
    this.events = null
    this.stateCh = null
    this.hasFrames = false
    if (this.audio) this.audio.detach()
    if (pc) {
      try {
        pc.close()
      } catch (_) {}
    }
  },

  // One frame loop per peer connection: it ends when `pcId` is no longer the
  // current pc, and the next pc starts its own. There is no hook-wide latch
  // to leave set, so a callback Chrome drops on a srcObject swap cannot stop
  // the next pc's frames from counting.
  watchFrames(pcId) {
    const v = this.video
    if (!v || typeof v.requestVideoFrameCallback !== "function") return
    const onFrame = (now, meta) => {
      if (this.dead || this.pcId !== pcId) return
      this.frames++
      this.frameSeen(pcId)
      if (meta && meta.width) {
        const changed = !this.size || this.size.width !== meta.width || this.size.height !== meta.height
        this.size = { width: meta.width, height: meta.height }
        if (changed) this.renderAspect()
      }
      if (this.pending.size) this.decodeProbe(now)
      v.requestVideoFrameCallback(onFrame)
    }
    v.requestVideoFrameCallback(onFrame)
  },

  frameSeen(pcId) {
    if (this.pcId !== pcId) return
    this.lastFrame = { pcId, at: Date.now() }
    this.hasFrames = true
    if (this.panel !== "live") this.renderAttach()
  },

  // The running panel (Connecting or live) from the current pc's frames, plus
  // the "Still connecting" line. Leaves every other panel alone: ended and
  // failed win, and building / takeover / unavailable are set elsewhere.
  renderAttach() {
    if (!["building", "connecting", "live"].includes(this.panel)) return
    if (!["connecting", "live"].includes(this.serverState)) return
    const now = Date.now()
    const panel = panelFor({ serverState: this.serverState, pcId: this.pcId, lastFrame: this.lastFrame, now })
    if (panel !== this.panel) this.show(panel)
    this.renderStuck(now)
  },

  renderStuck(now = Date.now()) {
    if (!this.stuckEl) return
    clearTimeout(this.stuckTimer)
    const clock = {
      serverState: this.serverState,
      pcId: this.pcId,
      lastFrame: this.lastFrame,
      connectingSince: this.connectingSince,
      now,
    }
    const connecting = this.panel === "connecting" && this.active()
    const on = connecting && stuck(clock)
    this.stuckEl.hidden = !on
    if (this.connectingLineEl) this.connectingLineEl.hidden = on
    // Stage 6: re-check exactly when the clock runs out rather than on the
    // next 1 s tick, so "Still connecting" shows 10 s after the last frame.
    if (connecting && !on) {
      this.stuckTimer = setTimeout(() => {
        if (!this.dead) this.renderAttach()
      }, Math.max(0, stuckAt(clock) - now) + 5)
    }
  },

  decodeProbe(now) {
    try {
      this.cornerCtx.drawImage(this.video, 0, 0, CORNER_PX, CORNER_PX, 0, 0, CORNER_PX, CORNER_PX)
      const data = this.cornerCtx.getImageData(0, 0, CORNER_PX, CORNER_PX).data
      // 0 is "no code in the corner", never a seq: it must not be looked up,
      // or an idle corner would read as a sample of `now - undefined`. The
      // code's top 2 bits are the slot that probed (stage 3): another
      // player's probe is not ours.
      const seq = probeSeqFor(decode(readCorner(data, CORNER_PX)), this.probeSlot)
      if (seq && this.pending.has(seq)) {
        this.rtt.push(now - this.pending.get(seq))
        this.pending.delete(seq)
      }
    } catch (_) {}
  },

  async readStats() {
    const pc = this.pc
    const pcId = this.pcId
    if (!pc) return
    const report = await pc.getStats()
    let pairId = null
    report.forEach(s => {
      if (s.type === "transport" && s.selectedCandidatePairId) pairId = s.selectedCandidatePairId
    })
    report.forEach(s => {
      if (s.type === "inbound-rtp" && s.kind === "video" && s.frameWidth) {
        this.size = { width: s.frameWidth, height: s.frameHeight }
      }
      // Decoded frames from the stats as well: requestVideoFrameCallback
      // only fires for frames that are painted.
      if (s.type === "inbound-rtp" && s.kind === "video" && typeof s.framesDecoded === "number") {
        if (this.pcId === pcId && this.statFrames != null && s.framesDecoded > this.statFrames) {
          this.frameSeen(pcId)
        }
        if (this.pcId === pcId) this.statFrames = s.framesDecoded
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
    return this.active() && this.panel === "live"
  },

  dispatch(event) {
    const { state, actions } = captureReduce(this.capture, event)
    this.capture = state
    for (const action of actions) {
      if (action === "capture") {
        this.keys.blurActive()
        this.lastInputAt = Date.now()
        for (const differ of this.padDiffers.values()) differ.reset()
        this.updatePadLoop()
      } else if (action === "release") {
        this.updatePadLoop()
      } else if (action === "release_all") {
        this.router.releaseAll()
      } else if (action === "exit_fullscreen") {
        if (document.fullscreenElement && document.exitFullscreen) document.exitFullscreen().catch(() => {})
      }
    }
    this.renderCapture()
  },

  // The pad loop runs while this copy holds capture, and, for a player on a
  // multi host, while it is live, so a second pad's press can claim a slot
  // before anyone clicks. A spectator never runs it.
  padLoopWanted() {
    if (this.dead || !this.active() || !this.router.player) return false
    return this.capture.captured || (this.multi && this.panel === "live")
  },

  updatePadLoop() {
    if (!this.padLoopWanted()) return this.stopPadLoop()
    if (this.raf) return
    const loop = () => {
      this.raf = null
      if (!this.padLoopWanted()) return
      this.padStep(navigator.getGamepads ? navigator.getGamepads() : [])
      this.raf = requestAnimationFrame(loop)
    }
    this.raf = requestAnimationFrame(loop)
  },

  // One read of every pad: a src per pad, a snapshot per slotted src while
  // captured (through the router), and a claim for an unslotted pad's press.
  padStep(rawPads) {
    const { assigned, gone } = this.padSources.assign(pickGamepads(rawPads))
    const captured = this.capture.captured
    for (const src of gone) {
      const differ = this.padDiffers.get(src)
      const msg = differ && differ.next(null)
      if (msg && captured) this.router.pad(msg)
      this.padDiffers.delete(src)
      this.padWasPressed.delete(src)
    }
    for (const { src, pad } of assigned) {
      const slot = this.router.slotFor(src)
      const pressed = padPressed(pad)
      const was = this.padWasPressed.get(src)
      this.padWasPressed.set(src, pressed)
      if (slot == null) {
        if (this.multi && this.router.player && pressed && !was) this.padJoin(src)
        continue
      }
      if (!captured) continue
      let differ = this.padDiffers.get(src)
      if (!differ) {
        differ = new PadDiffer(slot, src)
        this.padDiffers.set(src, differ)
      }
      differ.slot = slot
      const msg = differ.next(pad)
      if (msg && this.router.pad(msg) && msg.connected) this.lastInputAt = Date.now()
    }
    this.pad = assigned.length ? assigned[0].pad : null
    this.pads = assigned
    const sig = assigned.map(a => a.src).join(",")
    if (sig !== this.padSig) {
      this.padSig = sig
      this.renderPads()
      this.renderFooter()
    }
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
    if (panel === "connecting" && this.panel !== "connecting") this.connectingSince = Date.now()
    this.panel = panel
    // A spectator's live frame is just the video: nothing to click to play.
    // Nor is a phone's whose taps go to the game.
    const shown =
      panel === "live" && (this.capture.captured || !this.router.player || this.touchHidesPanel()) ? null : panel
    for (const p of this.panels) p.hidden = p.dataset.gsPanel !== shown
    this.el.dataset.state = panel
    const live = panel === "live"
    this.dot.classList.toggle("bg-success", live)
    this.dot.classList.toggle("bg-base-content/20", !live)
    this.video.classList.toggle("opacity-40", panel === "ended")
    if (this.endBtn) this.endBtn.hidden = !RUNNING.includes(this.serverState) || playingElsewhere(panel) || this.multi
    if (panel === "building" && this.elapsedEl) {
      this.elapsedEl.textContent = formatElapsed(Date.now() - this.buildStartedAt)
    }
    this.renderStuck()
    this.renderRoster()
    this.renderCapture()
    this.updatePadLoop()
  },

  renderCapture() {
    const captured = this.capture.captured
    if (this.ring) this.ring.hidden = !captured
    if (this.panel === "live") {
      const hide = captured || !this.router.player || this.touchHidesPanel()
      for (const p of this.panels) p.hidden = hide || p.dataset.gsPanel !== "live"
    }
    this.renderFooter()
  },

  // Everything the roster drives. Visibility follows `multi`, the running
  // state and whether this peer holds a slot; the chips, lines and menu are
  // rebuilt only once a roster has arrived (the first frame is the server's).
  renderRoster() {
    if (!this.rosterEl) return
    const multi = this.multi
    const running = RUNNING.includes(this.serverState) && !playingElsewhere(this.panel)
    const player = this.router.player
    this.rosterEl.hidden = !multi
    if (this.overflowEl) this.overflowEl.hidden = !(multi && running)
    if (this.leaveBtn) this.leaveBtn.hidden = !(multi && running && player)
    if (!multi || !running) {
      if (this.watchEl) this.watchEl.hidden = true
      if (this.overflowMenu && !this.overflowMenu.hidden) this.closeMenu()
    }
    if (!multi) {
      if (this.padsEl) this.padsEl.hidden = true
      return
    }
    if (!this.rosterKnown) return

    const roster = this.roster
    const peerId = this.peerId
    const mine = this.mine
    const cs = chips(roster, peerId)
    this.fill(this.chipsEl, cs.map(c => this.chipNode(c)))
    this.fill(this.sheetChipsEl, cs.map(c => this.chipNode(c)))
    if (this.watchingEl) {
      this.watchingEl.textContent = watchingText(roster)
      this.watchingEl.title = watchingTitle(roster)
    }
    if (this.sheetWatchingEl) this.sheetWatchingEl.textContent = sheetWatchingText(roster)
    if (this.rosterLineText) this.rosterLineText.textContent = phoneLine({ roster, peerId, mine })

    if (this.takeItemsEl && this.takeTemplate) {
      const nodes = takeOverItems(roster, peerId).map(item => {
        const node = this.takeTemplate.content.firstElementChild.cloneNode(true)
        node.dataset.gsTakeOver = String(item.slot)
        node.textContent = item.label
        return node
      })
      this.fill(this.takeItemsEl, nodes)
    }
    if (this.endLineEl) this.endLineEl.textContent = endLine(roster)

    const watch = watchView({ roster, mine, displaced: this.displaced })
    if (this.watchEl) this.watchEl.hidden = !(running && watch)
    if (watch && this.watchLineEl) this.watchLineEl.textContent = watch.line
    if (this.joinBtn) {
      this.joinBtn.hidden = !(watch && watch.join)
      if (watch && watch.join) {
        this.joinBtn.textContent = watch.join.label
        this.joinBtn.dataset.gsJoinSlot = String(watch.join.slot)
      }
    }
    this.renderPads()
  },

  fill(box, nodes) {
    if (!box) return
    box.replaceChildren(...nodes)
  },

  chipNode(chip) {
    const node = this.chipTemplate.content.firstElementChild.cloneNode(true)
    const base = this.chipTemplate.content.firstElementChild.getAttribute("class") || ""
    const key = { you: "gsChipYou", other: "gsChipOther", open: "gsChipOpen" }[chip.state]
    node.setAttribute("class", `${base} ${this.rosterEl.dataset[key] || ""}`.trim())
    node.dataset.gsChip = String(chip.slot)
    node.dataset.gsChipState = chip.state
    node.title = chip.title
    if (chip.state === "open") node.removeAttribute("aria-disabled")
    else node.setAttribute("aria-disabled", "true")
    node.querySelector("[data-gs-chip-label]").textContent = chip.label
    node.querySelector("[data-gs-chip-name]").textContent = chip.name
    node.querySelector("[data-gs-chip-dot]").hidden = chip.state === "open"
    return node
  },

  // The footer's pad rows, for a player on a multi host with pads detected.
  renderPads() {
    if (!this.padsEl) return
    const rows =
      this.multi && this.rosterKnown && this.router.player
        ? padRows({ pads: this.pads || [], mine: this.mine, roster: this.roster })
        : []
    this.padsEl.hidden = rows.length === 0
    if (!this.padTemplate) return
    this.fill(
      this.padsEl,
      rows.map(row => {
        const node = this.padTemplate.content.firstElementChild.cloneNode(true)
        node.dataset.gsPad = String(row.src)
        node.textContent = row.text
        return node
      }),
    )
  },

  renderFooter() {
    this.renderTouch()
    if (!this.controllerEl) return
    const pads = navigator.getGamepads ? navigator.getGamepads() : []
    const pad = this.pad || pickGamepad(pads)
    const playing = RUNNING.includes(this.serverState) && !playingElsewhere(this.panel)
    // On a multi host the pad rows name each pad's slot; a spectator has
    // nothing to play with, so neither line shows.
    const padRowsShown = this.multi && this.router.player && (this.pads || []).length > 0
    const spectating = this.multi && !this.router.player
    const touchPlay = this.touchOn && this.coarse
    const label =
      playing && !padRowsShown && !spectating ? controllerLabel({ pad, coarse: this.coarse, touch: touchPlay }) : ""
    this.controllerEl.textContent = label
    // Hidden when empty, so an ended frame does not keep a blank row on a phone.
    this.controllerEl.hidden = label === ""
    // A spectator has nothing to click to play.
    this.hintEl.textContent = hintText({
      live: this.panel === "live" && this.router.player,
      captured: this.capture.captured,
      touch: touchPlay,
    })
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
    this.statsEl.classList.toggle("text-subtle", !warn)
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

    // Probes run only while this peer holds a slot (the router sends none
    // otherwise), from slots 0-3, whose number the code's top 2 bits carry.
    if (
      this.capture.captured &&
      this.hasFrames &&
      this.router.player &&
      now - this.lastInputAt < PROBE_IDLE_STOP_MS &&
      now - this.lastProbeAt >= PROBE_EVERY_MS
    ) {
      this.lastProbeAt = now
      const seq = nextSeq(this.seq)
      const slot = this.router.probe(seq, PROBE_MAX_SLOT)
      if (slot != null) {
        this.seq = seq
        if (slot !== this.probeSlot) {
          this.pending.clear()
          this.probeSlot = slot
        }
        this.pending.set(seq, performance.now())
      }
    }

    if (this.pc) this.readStats().catch(() => {})
    this.maybeReclaim()
    if (this.active()) this.renderAttach()

    if (
      this.active() &&
      this.pc &&
      this.hasFrames &&
      this.router.player &&
      now - this.lastStatsPushAt >= STATS_PUSH_EVERY_MS
    ) {
      this.lastStatsPushAt = now
      const stats = {}
      if (this.rtt.count) {
        stats.rtt_p50_ms = this.rtt.p50()
        stats.rtt_p95_ms = this.rtt.p95()
      }
      if (this.fps != null) stats.fps_avg = this.fps
      if (this.path) stats.connection_path = this.path.toLowerCase()
      const slot = this.probeSlot != null ? this.probeSlot : mySlotList(this.mine)[0]
      this.push("game_stream_stats", { session_id: this.sessionId, stats, slot })
    }

    this.renderFooter()
  },
}

export default GameStream
