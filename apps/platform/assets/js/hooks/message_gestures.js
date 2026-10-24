// MessageGestures: the touch gestures on a chat message (redesign rung 9,
// task 01a1557a-9406; direction canvas 01a1666e node m3, rules 1-3).
//
//   * TAP (released before 450ms, moved 10px or less) on the message's own
//     area or text reveals the 4-glyph pill (`[data-role="message-pill"]`)
//     by setting `data-pill-open` on the message root IN THE SAME HANDLER.
//     No timer and no server round trip: the pill is the answer to the tap,
//     so it shows the frame the finger lifts. One pill is open at a time.
//   * DOUBLE-TAP (a second tap within 300ms and 12px) pushes
//     `open_message_actions` {id}. The pill is already showing; the sheet is
//     the upgrade.
//   * LONG-PRESS (held 450ms, moved 10px or less) pushes
//     `open_message_actions`. A move past 10px, a pointerup or a
//     pointercancel before 450ms cancels it, and the click a fired
//     long-press leaves behind is swallowed. That click is swallowed at
//     the WINDOW, not on this message: the sheet the press opened is under
//     the finger by the time it lifts, and the click lands on whatever the
//     sheet put there (measured in e2e: a quick-react emoji, which reacted
//     and closed the sheet).
//
// Long-press was dropped once before because it competed with the browser's
// native text-selection menu on the same gesture. It is back because this
// hook now owns that gesture outright: `contextmenu` is prevented on a
// touch, and below lg app.css sets `-webkit-touch-callout: none` and
// `user-select: none` on message bodies. On a phone, Copy in the pill and
// in the actions sheet replaces native text selection.
//
// A tap on something inside the message that does its own thing (a link,
// an image, a video, a button, a field, a reaction pill, the thread
// indicator, the inline thread, anything with phx-click) never opens the
// pill (direction rule 2). A mouse is not a gesture source: on desktop the
// pill shows on hover and focus in plain CSS, and a double-click selects a
// word as it always has.
//
// The pill closes on a tap anywhere outside its message, on Esc, and when
// the message scroller (`#chat-message-scroller`, found as an ancestor)
// scrolls more than 10px.
//
// The press-and-hold itself is `createLongPress/2`, exported so a reaction
// pill's long-press (ReactorPopover, stage 3) runs the SAME timing, move
// cancel and click swallow rather than a second implementation.
//
// Copy (`[data-role="message-pill-copy"]`) is client-side: it copies the
// button's `data-clipboard-text`, shows the "Copied" toast for 2s, marks the
// message root `data-copied="true"` for 2s (so e2e can assert it without a
// clipboard permission) and swaps the glyph to a check for 1.5s, which
// app.css shows on desktop only.

import { toast } from "../attach_stage"

export const LONG_PRESS_MS = 450
export const MOVE_CANCEL_PX = 10
export const DOUBLE_TAP_MS = 300
export const DOUBLE_TAP_MAX_MOVE_PX = 12
export const SCROLL_DISMISS_PX = 10
const HAPTIC_MS = 20
const COPIED_MS = 2000
const COPY_CHECK_MS = 1500
const FULLSCREEN_PROTOTYPE = '[data-role="prototype-canvas"][data-fullscreen="true"]'
const SCROLLER = "#chat-message-scroller"
export const OWN_TAP_TARGETS = [
  "a",
  "img",
  "video",
  "button",
  "input",
  "textarea",
  "select",
  "[contenteditable]",
  '[data-role="reaction-pill"]',
  ".reaction-pill",
  ".thread-indicator",
  ".thread-replies",
  "[phx-click]",
].join(", ")

// The hook whose pill is open, or null. Module scope, because "one pill at
// a time" is a rule across every message on the page.
let openHook = null

function closest(target, selector) {
  return target && target.closest ? target.closest(selector) : null
}

function onDocPointerDown(e) {
  if (openHook && !openHook.el.contains(e.target)) closePill()
}

function onDocKeyDown(e) {
  if (e.key === "Escape") closePill()
}

function onScroll() {
  if (!openHook || !openHook._scroller) return
  if (Math.abs(openHook._scroller.scrollTop - openHook._scrollStart) > SCROLL_DISMISS_PX) {
    closePill()
  }
}

export function openPill(hook) {
  if (openHook && openHook !== hook) closePill()
  hook.el.setAttribute("data-pill-open", "true")
  if (openHook === hook) return
  openHook = hook
  document.addEventListener("pointerdown", onDocPointerDown, true)
  document.addEventListener("keydown", onDocKeyDown)
  hook._scroller = closest(hook.el, SCROLLER)
  if (hook._scroller) {
    hook._scrollStart = hook._scroller.scrollTop
    hook._scroller.addEventListener("scroll", onScroll, { passive: true })
  }
}

export function closePill() {
  const hook = openHook
  if (!hook) return
  openHook = null
  hook.el.removeAttribute("data-pill-open")
  document.removeEventListener("pointerdown", onDocPointerDown, true)
  document.removeEventListener("keydown", onDocKeyDown)
  if (hook._scroller) hook._scroller.removeEventListener("scroll", onScroll)
  hook._scroller = null
}

// The click that follows a fired long-press, wherever it lands. Window
// capture runs before LiveView's own (bubbling, window) click binding. The
// next pointerdown clears it, in case the browser sends no click at all.
function swallowNextClick() {
  const swallow = (e) => {
    e.preventDefault()
    e.stopPropagation()
    clear()
  }
  const clear = () => {
    window.removeEventListener("click", swallow, true)
    window.removeEventListener("pointerdown", clearOnDown, true)
  }
  const clearOnDown = () => clear()
  window.addEventListener("click", swallow, true)
  // Registered after the current pointerdown has already dispatched, so
  // only the NEXT gesture's pointerdown clears it.
  window.addEventListener("pointerdown", clearOnDown, true)
}

// Press-and-hold detection, shared by the message and the reaction pills.
// `start(e)` arms a press; it fires `onFire()` after `LONG_PRESS_MS` unless
// the pointer moves more than `MOVE_CANCEL_PX`, lifts or is cancelled first.
// A fired press swallows the click that follows it. `end(e)` reports what
// the release was: "tap" (lifted early, inside the move limit), "fired"
// (after a fired press) or null (no press, another pointer, or moved).
export function createLongPress(onFire) {
  let press = null
  let timer = null

  const cancel = () => {
    clearTimeout(timer)
    timer = null
    press = null
  }

  const movedTooFar = (p, e) => {
    const dx = e.clientX - p.x
    const dy = e.clientY - p.y
    return dx * dx + dy * dy > MOVE_CANCEL_PX ** 2
  }

  return {
    start(e) {
      cancel()
      press = { id: e.pointerId, x: e.clientX, y: e.clientY, fired: false }
      timer = setTimeout(() => {
        if (!press) return
        press.fired = true
        swallowNextClick()
        onFire()
      }, LONG_PRESS_MS)
    },

    move(e) {
      if (!press || press.fired || e.pointerId !== press.id) return
      if (movedTooFar(press, e)) cancel()
    },

    end(e) {
      if (!press || e.pointerId !== press.id) return null
      const p = press
      clearTimeout(timer)
      timer = null
      press = null
      if (p.fired) return "fired"
      return movedTooFar(p, e) ? null : "tap"
    },

    cancel,
  }
}

function legacyCopy(text) {
  try {
    const area = document.createElement("textarea")
    area.value = text
    area.setAttribute("readonly", "")
    area.style.position = "fixed"
    area.style.opacity = "0"
    document.body.appendChild(area)
    area.select()
    const ok = document.execCommand("copy")
    area.remove()
    return ok
  } catch (_e) {
    return false
  }
}

// Copy `text`, then call `done` once it is on the clipboard. Shared with the
// actions sheet's Copy text / Copy link rows (hooks/message_actions_copy.js).
export function copyText(text, done) {
  const fallback = () => {
    if (legacyCopy(text)) done()
  }
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(done, fallback)
  } else {
    fallback()
  }
}

// The confirmation every copy shows: the toast for 2s, and the message root
// marked `data-copied="true"` for 2s so e2e can assert without a clipboard
// permission.
export function showCopied(messageEl, text = "Copied") {
  toast(text, { id: "copy-toast", role: "copy-toast", ms: COPIED_MS })
  if (!messageEl) return
  messageEl.setAttribute("data-copied", "true")
  clearTimeout(messageEl._copiedTimer)
  messageEl._copiedTimer = setTimeout(() => messageEl.removeAttribute("data-copied"), COPIED_MS)
}

const MessageGestures = {
  mounted() {
    this._lastTapAt = 0
    this._lastTapX = 0
    this._lastTapY = 0
    this._longPress = createLongPress(() => this.fireLongPress())
    this._lastPointerType = null

    this._onDown = (e) => this.pointerDown(e)
    this._onMove = (e) => this.pointerMove(e)
    this._onUp = (e) => this.pointerUp(e)
    this._onCancel = () => this.cancelPress()
    this._onClick = (e) => this.click(e)
    this._onContextMenu = (e) => {
      if (this._keyMenu) {
        this._keyMenu = false
        e.preventDefault()
        return
      }
      if (this._lastPointerType && this._lastPointerType !== "mouse") e.preventDefault()
    }
    this._onKeyDown = (e) => this.keyDown(e)

    this.el.addEventListener("pointerdown", this._onDown)
    this.el.addEventListener("pointermove", this._onMove)
    this.el.addEventListener("pointerup", this._onUp)
    this.el.addEventListener("pointercancel", this._onCancel)
    this.el.addEventListener("click", this._onClick, true)
    this.el.addEventListener("contextmenu", this._onContextMenu)
    this.el.addEventListener("keydown", this._onKeyDown)
  },

  // A patch of this row drops attributes the server did not render, so put
  // the open state back.
  updated() {
    if (openHook === this) this.el.setAttribute("data-pill-open", "true")
  },

  destroyed() {
    this.cancelPress()
    if (openHook === this) closePill()
    clearTimeout(this.el._copiedTimer)
    clearTimeout(this._checkTimer)
    this.el.removeEventListener("pointerdown", this._onDown)
    this.el.removeEventListener("pointermove", this._onMove)
    this.el.removeEventListener("pointerup", this._onUp)
    this.el.removeEventListener("pointercancel", this._onCancel)
    this.el.removeEventListener("click", this._onClick, true)
    this.el.removeEventListener("contextmenu", this._onContextMenu)
    this.el.removeEventListener("keydown", this._onKeyDown)
  },

  // Keyboard entry (direction canvas 01a1666e node m3 rule 10), on the
  // focused message itself, never on a control inside it: Shift+F10 or the
  // ContextMenu key opens the actions (the sheet below lg, the popover at
  // lg), and Enter reveals the pill. Esc closes the pill (onDocKeyDown) and
  // the sheet or popover (their own Esc bindings); either frame returns
  // focus to the message when it closes. The ContextMenu key also fires a
  // native contextmenu event after keydown, which is swallowed once.
  keyDown(e) {
    if (e.target !== this.el) return
    const menuKey = e.key === "ContextMenu" || (e.key === "F10" && e.shiftKey)
    if (menuKey) {
      e.preventDefault()
      this._keyMenu = true
      this.openActions()
    } else if (e.key === "Enter" && !e.shiftKey && !e.metaKey && !e.ctrlKey && !e.altKey) {
      e.preventDefault()
      openPill(this)
    }
  },

  pointerDown(e) {
    this._lastPointerType = e.pointerType
    this.cancelPress()
    if (e.pointerType === "mouse" || e.isPrimary === false) return
    // A prototype in fullscreen is promoted to the browser top layer
    // (prototype_fullscreen.js, task 01a1389f) but still sits inside this
    // message in the DOM, so its taps bubble here. The pill and the sheet
    // would open UNDER the top layer, unreachable, so nothing there counts,
    // and a pending first tap is forgotten.
    if (closest(e.target, FULLSCREEN_PROTOTYPE)) {
      this._lastTapAt = 0
      return
    }
    if (closest(e.target, OWN_TAP_TARGETS)) return

    this._longPress.start(e)
  },

  pointerMove(e) {
    this._longPress.move(e)
  },

  pointerUp(e) {
    if (this._longPress.end(e) === "tap") this.tap(e.clientX, e.clientY)
  },

  cancelPress() {
    if (this._longPress) this._longPress.cancel()
  },

  fireLongPress() {
    this._lastTapAt = 0
    this.openActions()
  },

  tap(x, y) {
    const now = Date.now()
    const dx = x - this._lastTapX
    const dy = y - this._lastTapY
    const withinTime = now - this._lastTapAt < DOUBLE_TAP_MS
    const withinMove = dx * dx + dy * dy < DOUBLE_TAP_MAX_MOVE_PX ** 2

    // Synchronous, before anything else: the no-tap-delay rule.
    openPill(this)

    if (this._lastTapAt && withinTime && withinMove) {
      this._lastTapAt = 0
      this.openActions()
    } else {
      this._lastTapAt = now
      this._lastTapX = x
      this._lastTapY = y
    }
  },

  click(e) {
    const btn = closest(e.target, '[data-role="message-pill-copy"]')
    if (btn && this.el.contains(btn)) {
      e.preventDefault()
      this.copy(btn)
    }
  },

  copy(btn) {
    copyText(btn.dataset.clipboardText || "", () => this.copied(btn))
  },

  copied(btn) {
    showCopied(this.el)
    btn.setAttribute("data-copy-check", "true")
    clearTimeout(this._checkTimer)
    this._checkTimer = setTimeout(() => btn.removeAttribute("data-copy-check"), COPY_CHECK_MS)
  },

  openActions() {
    const messageId = this.el.dataset.messageId
    if (!messageId) return
    if (navigator.vibrate) navigator.vibrate(HAPTIC_MS)
    this.pushEvent("open_message_actions", { id: messageId })
  },
}

export default MessageGestures
