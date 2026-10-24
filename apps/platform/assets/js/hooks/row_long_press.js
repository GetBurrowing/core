/**
 * RowLongPress hook: a long-press shortcut on any row of any list.
 *
 * Generic on purpose (task 01a1557a-8562 stage 4). The Chat list is its first
 * user and the Inbox list (task 01a1557a-ad2d) its second; nothing here knows
 * which list it is on. Everything comes from data attributes on the element
 * the hook is mounted on:
 *
 *   data-long-press-event   the event pushed when the hold completes
 *                           (the Chat list uses "open_list_sheet")
 *   data-long-press-*       every other `data-long-press-<name>` attribute
 *                           becomes one payload key, kebab-case turned into
 *                           snake_case: `data-long-press-space-id="x"` is
 *                           `{space_id: "x"}`
 *   data-editing="true"     the hook is inert (an arranging mode, where the
 *                           row's gestures belong to something else)
 *
 * The gesture, shared with the masters prototype (`longPress`, :1409) and
 * Saru's rulings on both list canvases:
 *
 *   - a hold of HOLD_MS (450ms) pushes the event once, and buzzes where the
 *     platform supports it;
 *   - more than MOVE_CANCEL_PX (10px) of movement cancels it, because that is
 *     a scroll;
 *   - `contextmenu` is prevented, so the platform's own callout does not open
 *     on top of the sheet the hold opens;
 *   - the ONE click that follows a completed hold is swallowed in the capture
 *     phase (`preventDefault` and `stopPropagation`), so a row that is also a
 *     link does not navigate when the finger lifts. The swallow listens on the
 *     DOCUMENT, not the row: whatever the hold opened (a bottom sheet, say)
 *     is often under the finger by the time it lifts, and the browser sends
 *     that click to the new element. Measured on the Chat list under CDP
 *     touch: a row-scoped swallow let the release click land on the sheet's
 *     backdrop and close the sheet it had just opened. The swallow clears
 *     on that click, or RELEASE_GRACE_MS (250ms) after the finger or mouse
 *     button is released, or after SWALLOW_MS (1200ms), whichever comes
 *     first. The grace matters when a release produces NO click (the finger
 *     slid off, or the browser suppressed it): without it the swallow stayed
 *     armed and ate the next real tap (measured in vitest: a tap 300ms after
 *     such a release was prevented). 250ms clears that tap, and the release
 *     click itself arrives right after touchend because the viewport
 *     (`width=device-width`, root.html.heex) has no 300ms click delay.
 *     `pointerleave` is not a release and does not start the grace.
 *
 * Why a hook and not a `phx-click`: a row that is a LiveView patch/navigate
 * link cannot carry a bare `phx-click` (it throws in the client), and a
 * `JS.push` on a navigating click never reaches the server because the
 * channel leaves first. A push from a timer is not tied to the click, so it
 * arrives; the swallowed click is what keeps the link from firing.
 *
 * Touch listeners are passive (scrolling stays native). Pointer events drive
 * the same gesture for a mouse, so the shortcut also works under device
 * emulation; touch pointers are ignored there because the touch listeners
 * already own them.
 */

export const HOLD_MS = 450
export const MOVE_CANCEL_PX = 10
export const SWALLOW_MS = 1200
export const RELEASE_GRACE_MS = 250

const PREFIX = "longPress"

/** The pushed payload: every `data-long-press-*` attribute but the event. */
export function longPressPayload(dataset) {
  const payload = {}

  for (const [key, value] of Object.entries(dataset || {})) {
    if (!key.startsWith(PREFIX) || key === `${PREFIX}Event`) continue
    const rest = key.slice(PREFIX.length)
    if (rest === "") continue
    const snake = rest
      .replace(/^[A-Z]/, (c) => c.toLowerCase())
      .replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`)
    payload[snake] = value
  }

  return payload
}

const RowLongPress = {
  mounted() {
    this._timer = null
    this._swallowTimer = null
    this._swallow = false
    this._origin = null

    this._onTouchStart = (e) => {
      const t = e.touches && e.touches[0]
      if (t) this._begin(t.clientX, t.clientY)
    }
    this._onTouchMove = (e) => {
      const t = e.touches && e.touches[0]
      if (t) this._move(t.clientX, t.clientY)
    }
    this._onPointerDown = (e) => {
      if (e.pointerType === "touch") return
      if (e.button !== undefined && e.button !== 0) return
      this._begin(e.clientX, e.clientY)
    }
    this._onPointerMove = (e) => {
      if (e.pointerType === "touch") return
      this._move(e.clientX, e.clientY)
    }
    this._onEnd = () => this._cancel()
    this._onRelease = () => {
      this._cancel()
      this._graceSwallow()
    }
    this._onContextMenu = (e) => e.preventDefault()
    this._onClickCapture = (e) => {
      if (!this._swallow) return
      e.preventDefault()
      e.stopPropagation()
      this._clearSwallow()
    }

    const passive = { passive: true }
    this.el.addEventListener("touchstart", this._onTouchStart, passive)
    this.el.addEventListener("touchmove", this._onTouchMove, passive)
    this.el.addEventListener("touchend", this._onRelease, passive)
    this.el.addEventListener("touchcancel", this._onRelease, passive)
    this.el.addEventListener("pointerdown", this._onPointerDown)
    this.el.addEventListener("pointermove", this._onPointerMove)
    this.el.addEventListener("pointerup", this._onRelease)
    this.el.addEventListener("pointercancel", this._onRelease)
    this.el.addEventListener("pointerleave", this._onEnd)
    this.el.addEventListener("contextmenu", this._onContextMenu)
  },

  destroyed() {
    this._cancel()
    this._clearSwallow()
    this.el.removeEventListener("touchstart", this._onTouchStart)
    this.el.removeEventListener("touchmove", this._onTouchMove)
    this.el.removeEventListener("touchend", this._onRelease)
    this.el.removeEventListener("touchcancel", this._onRelease)
    this.el.removeEventListener("pointerdown", this._onPointerDown)
    this.el.removeEventListener("pointermove", this._onPointerMove)
    this.el.removeEventListener("pointerup", this._onRelease)
    this.el.removeEventListener("pointercancel", this._onRelease)
    this.el.removeEventListener("pointerleave", this._onEnd)
    this.el.removeEventListener("contextmenu", this._onContextMenu)
  },

  _editing() {
    return this.el.dataset.editing === "true"
  },

  _begin(x, y) {
    this._cancel()
    if (this._editing()) return
    this._origin = { x, y }
    this._timer = setTimeout(() => {
      this._timer = null
      this._fire()
    }, HOLD_MS)
  },

  _move(x, y) {
    if (!this._timer || !this._origin) return
    const dx = x - this._origin.x
    const dy = y - this._origin.y
    if (Math.hypot(dx, dy) > MOVE_CANCEL_PX) this._cancel()
  },

  _cancel() {
    if (this._timer) clearTimeout(this._timer)
    this._timer = null
    this._origin = null
  },

  _fire() {
    this._origin = null
    if (this._editing()) return
    const event = this.el.dataset.longPressEvent
    if (!event) return

    this.pushEvent(event, longPressPayload(this.el.dataset))

    if (typeof navigator !== "undefined" && typeof navigator.vibrate === "function") {
      try {
        navigator.vibrate(20)
      } catch (_e) {
        // Some browsers refuse vibration outside a user gesture; the push
        // already happened, the buzz is decoration.
      }
    }

    this._swallow = true
    document.addEventListener("click", this._onClickCapture, true)
    this._swallowTimer = setTimeout(() => this._clearSwallow(), SWALLOW_MS)
  },

  // A release while the swallow is armed: the release click, if there is
  // one, arrives at once, so shorten the window to RELEASE_GRACE_MS.
  _graceSwallow() {
    if (!this._swallow) return
    if (this._swallowTimer) clearTimeout(this._swallowTimer)
    this._swallowTimer = setTimeout(() => this._clearSwallow(), RELEASE_GRACE_MS)
  },

  _clearSwallow() {
    if (this._swallowTimer) clearTimeout(this._swallowTimer)
    this._swallowTimer = null
    if (this._swallow) document.removeEventListener("click", this._onClickCapture, true)
    this._swallow = false
  },
}

export default RowLongPress
