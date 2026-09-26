/**
 * Keyboard and gamepad input for the `game_stream` canvas (task 01a0db5f
 * stage 4). Pure apart from the `doc` handed to `KeyForwarder`, so vitest can
 * drive it with fakes.
 *
 * Wire shapes, as the play host reads them (Startup-Suite/play-host
 * `internal/input`):
 *
 *   input-events (reliable, ordered)
 *     {t: "key", code, down, repeat, slot}   code is KeyboardEvent.code
 *     {t: "release_all"}
 *     {t: "probe", seq}
 *   input-state (unordered, no retransmits; each message a full snapshot)
 *     {t: "pad", slot, seq, connected, buttons: [17], axes: [4]}
 *
 * `slot` is the player slot and becomes the Godot device index. v1 sends
 * slot 0 only; the multi-player follow-on (task 01a0dbd6) widens this by
 * sending more slots, and the host ignores keys it does not know, so nothing
 * here needs a new shape for it.
 */

import { ESCAPE, forwardable } from "./game_stream_capture.js"

export const SLOT = 0
export const STD_BUTTONS = 17
export const STD_AXES = 4
// The host's axisEpsilon: a change smaller than this is not a change.
export const EPSILON = 1 / 512

export function keyMessage(event, down, slot = SLOT) {
  const code = event && event.code
  if (!forwardable(code)) return null
  return { t: "key", code, down: !!down, repeat: !!(down && event.repeat), slot }
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

/** The pad to play with: the first connected one, preferring standard mapping. */
export function pickGamepad(pads) {
  const list = Array.from(pads || []).filter(p => p && p.connected !== false)
  return list.find(p => p.mapping === "standard") || list[0] || null
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
  constructor(slot = SLOT) {
    this.slot = slot
    this.seq = 0
    this.last = null
  }

  next(pad) {
    if (!pad) {
      if (!this.last) return null
      this.last = null
      return { t: "pad", slot: this.slot, seq: ++this.seq, connected: false }
    }
    const snap = values(pad)
    if (this.last && !differs(snap.buttons, this.last.buttons) && !differs(snap.axes, this.last.axes)) {
      return null
    }
    this.last = snap
    return { t: "pad", slot: this.slot, seq: ++this.seq, connected: true, ...snap }
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
