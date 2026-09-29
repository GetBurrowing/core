/**
 * Keyboard and gamepad input for the `game_stream` canvas (task 01a0db5f
 * stage 4). Pure apart from the `doc` handed to `KeyForwarder`, so vitest can
 * drive it with fakes.
 *
 * Wire shapes, as the play host reads them (Startup-Suite/play-host
 * `internal/input`):
 *
 *   input-events (reliable, ordered)
 *     {t: "key", code, down, repeat, src, slot}   code is KeyboardEvent.code
 *     {t: "release_all"}
 *     {t: "probe", seq, src}
 *   input-state (unordered, no retransmits; each message a full snapshot)
 *     {t: "pad", src, slot, seq, connected, buttons: [17], axes: [4]}
 *
 * ## Sources and slots (task 01a0dbd6)
 *
 * `src` is this browser's local controller ordinal: 0 is the keyboard plus
 * the first pad, 1 the second pad, and so on (`PadSources`). Core maps each
 * (peer, src) to a player slot and tells the host; the host takes the slot
 * from that table and IGNORES the message's `slot` (play-host
 * `internal/input` Binding). `slot` is still sent, as the slot core gave this
 * src, because a v1 host reads it (and knows only slot 0).
 *
 * Every data-channel write goes through ONE `InputRouter`. It sends a key,
 * pad, probe or release_all only for a src that holds a slot, so a spectator
 * (no slots) writes nothing to either channel, whatever the capture machine
 * or a stray key does. The host drops a slotless peer's input anyway
 * (stage 3); the router means it never has to.
 */

import { ESCAPE, forwardable } from "./game_stream_capture.js"

export const SLOT = 0
export const STD_BUTTONS = 17
export const STD_AXES = 4
// The host's axisEpsilon: a change smaller than this is not a change.
export const EPSILON = 1 / 512

export function keyMessage(event, down, slot = SLOT, src = 0) {
  const code = event && event.code
  if (!forwardable(code)) return null
  return { t: "key", code, down: !!down, repeat: !!(down && event.repeat), src, slot }
}

function editable(el) {
  if (!el || el.nodeType !== 1) return false
  if (el.isContentEditable) return true
  const tag = (el.tagName || "").toUpperCase()
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT"
}

/**
 * Handles keydown/keyup while the frame holds capture.
 *
 * While captured, EVERY key event is `preventDefault`ed and stopped (so the
 * chat composer and LiveView's window key bindings see nothing), and the
 * focused element is blurred at capture time so a later key cannot land in
 * it. Esc is prevented too but never sent: it goes to `onEscape` so the
 * capture machine can release. While not captured the forwarder does
 * nothing at all and the page behaves as if the canvas were not there.
 */
export class KeyForwarder {
  constructor({ isCaptured, send, onEscape, onInput, doc }) {
    this.isCaptured = isCaptured
    this.send = send
    this.onEscape = onEscape || (() => {})
    this.onInput = onInput || (() => {})
    this.doc = doc
  }

  /** Called on capture: blur whatever has focus (the chat composer). */
  blurActive() {
    const active = this.doc && this.doc.activeElement
    if (active && active !== this.doc.body && typeof active.blur === "function") active.blur()
  }

  /** Returns true when the event was consumed. */
  handle(event, down) {
    if (!this.isCaptured()) return false
    event.preventDefault()
    if (typeof event.stopImmediatePropagation === "function") event.stopImmediatePropagation()

    if (event.code === ESCAPE || event.key === ESCAPE) {
      if (down) this.onEscape()
      return true
    }

    const message = keyMessage(event, down)
    if (message) {
      this.send(message)
      this.onInput()
    }
    return true
  }

  keydown(event) {
    return this.handle(event, true)
  }

  keyup(event) {
    return this.handle(event, false)
  }

  /** focusin while captured: an editable element took focus, so release. */
  focusMovedToEditable(target) {
    return this.isCaptured() && editable(target)
  }
}

/**
 * The pads to play with: every connected one, standard-mapped pads first,
 * each group in browser index order. The first of them is src 0's pad.
 */
export function pickGamepads(pads) {
  const list = Array.from(pads || []).filter(p => p && p.connected !== false)
  const std = list.filter(p => p.mapping === "standard")
  const other = list.filter(p => p.mapping !== "standard")
  return [...std, ...other]
}

/** The first pad `pickGamepads` returns, or null (the v1 footer's one pad). */
export function pickGamepad(pads) {
  return pickGamepads(pads)[0] || null
}

function padKey(pad, i) {
  return pad && pad.index != null ? `i${pad.index}` : `n${i}`
}

/**
 * Gives each connected pad a src and keeps it while the pad stays connected,
 * so a second pad unplugging does not move the first pad's slot, and a pad
 * that comes back takes the lowest free src. The first pad seen is src 0,
 * which it shares with the keyboard.
 */
export class PadSources {
  constructor() {
    this.bySrc = new Map() // src -> pad key
  }

  /**
   * `pads` as `pickGamepads` returns them. Returns `{assigned: [{src, pad}],
   * gone: [src]}`: the pads with their srcs (in src order) and the srcs whose
   * pad disconnected since the last call.
   */
  assign(pads) {
    const list = Array.from(pads || [])
    const keys = list.map(padKey)
    const gone = []
    for (const [src, key] of this.bySrc) {
      if (!keys.includes(key)) {
        this.bySrc.delete(src)
        gone.push(src)
      }
    }
    const held = new Map(Array.from(this.bySrc, ([src, key]) => [key, src]))
    list.forEach((pad, i) => {
      const key = keys[i]
      if (held.has(key)) return
      let src = 0
      while (this.bySrc.has(src)) src++
      this.bySrc.set(src, key)
      held.set(key, src)
    })
    const assigned = list
      .map((pad, i) => ({ src: held.get(keys[i]), pad }))
      .sort((a, b) => a.src - b.src)
    return { assigned, gone: gone.sort((a, b) => a - b) }
  }
}

/** Is any button on `pad` pressed? (A pad with no slot claims one on a press.) */
export function padPressed(pad) {
  return !!pad && Array.from(pad.buttons || []).some(b => {
    if (b == null) return false
    if (typeof b === "number") return b > 0.5
    return !!b.pressed || (typeof b.value === "number" && b.value > 0.5)
  })
}

/**
 * The only writer to the host's two data channels. `slots` is this peer's
 * `{src: slot}` from core; a message goes out only for a src in it.
 */
export class InputRouter {
  constructor({ sendEvent, sendState }) {
    this.sendEvent = sendEvent
    this.sendState = sendState
    this.slots = new Map()
  }

  /** Replaces the table with core's `{src: slot}` (object or Map). */
  setSlots(table) {
    const next = new Map()
    const entries = table instanceof Map ? table.entries() : Object.entries(table || {})
    for (const [k, v] of entries) {
      const src = Number(k)
      const slot = Number(v)
      if (Number.isInteger(src) && src >= 0 && Number.isInteger(slot) && slot >= 0) next.set(src, slot)
    }
    this.slots = next
  }

  slotFor(src) {
    return this.slots.has(src) ? this.slots.get(src) : null
  }

  /** True while this peer holds at least one slot. */
  get player() {
    return this.slots.size > 0
  }

  /** A key (from `keyMessage`), always src 0. False when not sent. */
  key(message) {
    const slot = this.slotFor(0)
    if (!message || slot == null) return false
    this.sendEvent({ ...message, src: 0, slot })
    return true
  }

  /** A pad snapshot (from a `PadDiffer`), on its own src. */
  pad(message) {
    const slot = message ? this.slotFor(message.src) : null
    if (slot == null) return false
    this.sendState({ ...message, slot })
    return true
  }

  releaseAll() {
    if (!this.player) return false
    this.sendEvent({ t: "release_all" })
    return true
  }

  /** The src and slot a probe goes out on: src 0's, else the lowest slotted src. */
  probeSource(maxSlot) {
    const srcs = Array.from(this.slots.keys()).sort((a, b) => a - b)
    const src = this.slots.has(0) ? 0 : srcs[0]
    if (src == null) return null
    const slot = this.slots.get(src)
    return slot <= maxSlot ? { src, slot } : null
  }

  /** Sends a probe; returns the slot its code will carry, or null when not sent. */
  probe(seq, maxSlot) {
    const source = this.probeSource(maxSlot)
    if (!source) return null
    this.sendEvent({ t: "probe", seq, src: source.src })
    return source.slot
  }
}

function values(pad) {
  const buttons = []
  for (let i = 0; i < STD_BUTTONS; i++) {
    const b = pad.buttons && pad.buttons[i]
    const v = b == null ? 0 : typeof b === "number" ? b : b.value != null ? b.value : b.pressed ? 1 : 0
    buttons.push(Math.max(0, Math.min(1, Number(v) || 0)))
  }
  const axes = []
  for (let i = 0; i < STD_AXES; i++) {
    const v = pad.axes && pad.axes[i]
    axes.push(Math.max(-1, Math.min(1, Number(v) || 0)))
  }
  return { buttons, axes }
}

function differs(a, b) {
  for (let i = 0; i < a.length; i++) {
    if (Math.abs(a[i] - b[i]) >= EPSILON) return true
    if (a[i] === 0 && b[i] !== 0) return true
  }
  return false
}

/**
 * Turns a stream of `navigator.getGamepads()` reads into snapshots, sending
 * one only when something changed. A pad that disappears is reported once
 * as `connected: false`, which the host turns into a release of everything
 * that pad held.
 */
export class PadDiffer {
  constructor(slot = SLOT, src = 0) {
    this.slot = slot
    this.src = src
    this.seq = 0
    this.last = null
  }

  next(pad) {
    if (!pad) {
      if (!this.last) return null
      this.last = null
      return { t: "pad", src: this.src, slot: this.slot, seq: ++this.seq, connected: false }
    }
    const snap = values(pad)
    if (this.last && !differs(snap.buttons, this.last.buttons) && !differs(snap.axes, this.last.axes)) {
      return null
    }
    this.last = snap
    return { t: "pad", src: this.src, slot: this.slot, seq: ++this.seq, connected: true, ...snap }
  }

  reset() {
    this.last = null
  }
}

/** A readable name for a Gamepad.id ("Xbox Wireless Controller (STANDARD ...)"). */
export function padName(pad) {
  const id = (pad && pad.id) || ""
  const name = id.replace(/\s*\(.*$/, "").trim()
  return name || "Controller"
}

/**
 * The footer's controller line. The browser hides a pad until one of its
 * buttons is pressed, so "no pad" on a desktop is an instruction, and on a
 * touch-only device it says what v1 needs (there are no touch controls).
 */
export function controllerLabel({ pad, coarse }) {
  if (pad) return padName(pad)
  if (coarse) return "Connect a controller to play on this device"
  return "Press any button on your controller"
}

/** The footer hint: where the keys are going right now. */
export function hintText({ live, captured }) {
  if (captured) return "Esc to release"
  if (live) return "Click to play"
  return ""
}
