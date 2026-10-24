/**
 * ChatListSettle hook: the phone Chat list never moves a row while the
 * reader is touching or scrolling it (task 01a166bf stage 4; canvas
 * 01a16c80 node m2 rule 5, "hold the line").
 *
 * Mounted on `#chat-list-scroller`. It owns no DOM (no phx-update="ignore");
 * it only reports the gesture and animates the re-sort:
 *
 *   - HOLD starts on pointerdown or touchstart inside the scroller, or on any
 *     scroll of it. The first `chat_list_hold` of a hold makes the server
 *     snapshot the displayed order and render that order until release.
 *   - While held, continuing activity (scroll, touchmove, a pressed pointer
 *     moving, another press) re-pushes `chat_list_hold` at most once every
 *     REHOLD_MS (2.5s). The server keeps its snapshot and only re-arms its
 *     10s timer, so a reader scrolling non-stop for longer than 10s is never
 *     re-sorted under (stage 5).
 *   - RELEASE comes once no pointer is down AND no scroll has fired for
 *     SETTLE_MS (600ms). A scroll inside the window restarts it; a pointer
 *     going down cancels it. `chat_list_release` is pushed and the server
 *     re-sorts once.
 *   - On the update after a re-sort, rows that moved slide from their old
 *     place over FLIP_MS (200ms). Under prefers-reduced-motion they jump: no
 *     transform is ever applied.
 *
 * The server also auto-releases 10s after the latest hold, so a lost
 * pointerup cannot freeze the list forever (`ChatListHooks`). That timer only
 * fires with no activity for 10s: a stuck pointer, or a finger held
 * perfectly still that long, which the spec treats the same way.
 *
 * Every listener is passive: scrolling stays native. Release listeners are
 * on the scroller AND the document, because a mouse button can come up
 * outside the list. Touch is read from touch events only (see
 * `touchPointer`); pointer events drive a mouse or pen.
 */

export const SETTLE_MS = 600
export const FLIP_MS = 200
// Re-hold throttle while held: comfortably under the server's 10s timeout.
export const REHOLD_MS = 2500
export const ROW_SELECTOR = '[data-role="chat-list-row-wrap"]'

const PASSIVE = { passive: true }

export function prefersReducedMotion(win = globalThis.window) {
  return !!(win && win.matchMedia && win.matchMedia("(prefers-reduced-motion: reduce)").matches)
}

/** `{spaceId => top}` for every row in `root`. */
export function rowTops(root) {
  const tops = new Map()
  for (const row of root.querySelectorAll(ROW_SELECTOR)) {
    const id = row.dataset && row.dataset.spaceId
    if (id) tops.set(id, row.getBoundingClientRect().top)
  }
  return tops
}

// Whether the ids both snapshots hold appear in a different order: a
// re-sort, as opposed to rows only shifting (a fold, a banner).
function reordered(before, rows) {
  const was = [...before.keys()]
  const now = rows.map((r) => r.dataset.spaceId).filter((id) => before.has(id))
  const common = was.filter((id) => now.includes(id))
  return common.some((id, i) => now[i] !== id)
}

// A touch is tracked by the touch events alone. Its pointer events would
// lie: the browser fires `pointercancel` the moment it takes the gesture
// over as a pan, while the finger is still down (measured under CDP touch:
// the list released mid-drag and re-sorted under the finger).
const touchPointer = (e) => !!e && e.pointerType === "touch"

// A touchend that leaves another finger on the glass is not a release.
const fingersLeft = (e) => !!e && !!e.touches && e.touches.length > 0

const nextFrame = (fn) =>
  (globalThis.requestAnimationFrame || ((cb) => setTimeout(cb, 0)))(fn)

export default {
  mounted() {
    this.held = false
    this.heldAt = 0
    this.pointerDown = false
    this.timer = null
    this.before = null

    this.onDown = (e) => {
      if (touchPointer(e)) return
      this.pointerDown = true
      this.clearTimer()
      this.hold()
    }
    this.onUp = (e) => {
      if (touchPointer(e) || fingersLeft(e) || !this.pointerDown) return
      this.pointerDown = false
      this.arm()
    }
    this.onScroll = () => {
      this.hold()
      this.arm()
    }
    // Movement only refreshes an existing hold; it never starts one.
    this.onMove = (e) => {
      if (!this.held) return
      if (e && e.type === "pointermove" && (touchPointer(e) || !this.pointerDown)) return
      this.hold()
    }

    this.el.addEventListener("pointerdown", this.onDown, PASSIVE)
    this.el.addEventListener("touchstart", this.onDown, PASSIVE)
    this.el.addEventListener("scroll", this.onScroll, PASSIVE)
    this.el.addEventListener("touchmove", this.onMove, PASSIVE)
    this.el.addEventListener("pointermove", this.onMove, PASSIVE)
    this.upTargets = [this.el, globalThis.document].filter(Boolean)
    for (const target of this.upTargets) {
      for (const type of ["pointerup", "pointercancel", "touchend", "touchcancel"]) {
        target.addEventListener(type, this.onUp, PASSIVE)
      }
    }
  },

  destroyed() {
    this.clearTimer()
    this.el.removeEventListener("pointerdown", this.onDown, PASSIVE)
    this.el.removeEventListener("touchstart", this.onDown, PASSIVE)
    this.el.removeEventListener("scroll", this.onScroll, PASSIVE)
    this.el.removeEventListener("touchmove", this.onMove, PASSIVE)
    this.el.removeEventListener("pointermove", this.onMove, PASSIVE)
    for (const target of this.upTargets || []) {
      for (const type of ["pointerup", "pointercancel", "touchend", "touchcancel"]) {
        target.removeEventListener(type, this.onUp, PASSIVE)
      }
    }
  },

  // Start a hold, or refresh one at most every REHOLD_MS. The server keeps
  // the first snapshot on a refresh and only re-arms its expiry timer.
  hold() {
    const now = Date.now()
    if (this.held && now - this.heldAt < REHOLD_MS) return
    this.held = true
    this.heldAt = now
    this.pushEvent("chat_list_hold", {})
  },

  // (Re)start the settle window, unless a pointer is still down.
  arm() {
    this.clearTimer()
    if (this.pointerDown) return
    this.timer = setTimeout(() => this.release(), SETTLE_MS)
  },

  clearTimer() {
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
  },

  release() {
    this.timer = null
    if (!this.held || this.pointerDown) return
    this.held = false
    this.pushEvent("chat_list_release", {})
  },

  beforeUpdate() {
    this.before = rowTops(this.el)
  },

  updated() {
    const before = this.before
    this.before = null
    if (!before || prefersReducedMotion()) return

    const rows = [...this.el.querySelectorAll(ROW_SELECTOR)]
    if (!reordered(before, rows)) return

    const moved = []
    for (const row of rows) {
      const id = row.dataset.spaceId
      if (!before.has(id)) continue
      const delta = before.get(id) - row.getBoundingClientRect().top
      if (delta === 0) continue
      row.style.transition = "none"
      row.style.transform = `translateY(${delta}px)`
      moved.push(row)
    }
    if (moved.length === 0) return

    nextFrame(() => {
      for (const row of moved) {
        row.style.transition = `transform ${FLIP_MS}ms ease-out`
        row.style.transform = ""
      }
      setTimeout(() => {
        for (const row of moved) row.style.transition = ""
      }, FLIP_MS)
    })
  },
}
