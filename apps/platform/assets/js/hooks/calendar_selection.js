// Calendar range gestures (task 01a1b8a5 stage 2; prototype 01a178d2 v7
// `.drag-selection`). Press on an empty part of a day column and drag to
// select a time range; on release the server opens the ONE event editor on
// that range (`select_range`). The gesture never saves: Create event in the
// editor is the only write.
//
// Rules, each pinned by assets/test/hooks/calendar_selection.test.js:
//   * one pointer at a time, identified by pointerId; a second pointer is
//     ignored;
//   * only mouse and pen drag. Touch never starts a gesture, so touch
//     scrolling and the phone's tap-to-create (the slot's phx-click) are
//     untouched;
//   * below a 4px movement threshold it is a click, and the slot's own
//     phx-click (`new_at`) handles it as it always has;
//   * past the threshold the pointer is captured, the range snaps to 15
//     minutes, is bounded to the column's 07:00-21:00 window and to the day
//     it started on, and a reverse drag is normalized (start < end);
//   * pointercancel, lost capture, Escape, a scroll of the grid, LiveView
//     navigation and the hook going away all ABORT: no event is pushed;
//   * a completed drag suppresses the trailing click, so it cannot also
//     open a 30-minute draft;
//   * Escape during a drag is consumed (stopImmediatePropagation) so the
//     page-level Escape does not ALSO close the open details.
//
// Minutes are local wall-clock minutes in the grid's own zone (the viewer's
// zone, which the server rendered the columns in); the server turns
// date + minutes into instants.

export const HOUR_PX = 48
export const FIRST_HOUR = 7
export const LAST_HOUR = 21
export const SNAP_MIN = 15
export const THRESHOLD_PX = 4

const clamp = (n, lo, hi) => Math.min(hi, Math.max(lo, n))

// The snapped minute under a y offset (px from the column's top).
export function minuteAt(y, o = {}) {
  const hourPx = o.hourPx ?? HOUR_PX
  const first = (o.firstHour ?? FIRST_HOUR) * 60
  const last = (o.lastHour ?? LAST_HOUR) * 60
  const snap = o.snap ?? SNAP_MIN
  const raw = first + (y / hourPx) * 60
  return clamp(Math.floor(raw / snap) * snap, first, last)
}

// The range between an anchor and a current minute, in either order: the
// slot under each end is included, so it is never empty, and it stays
// inside the window.
export function rangeOf(anchor, current, o = {}) {
  const snap = o.snap ?? SNAP_MIN
  const first = (o.firstHour ?? FIRST_HOUR) * 60
  const last = (o.lastHour ?? LAST_HOUR) * 60
  const start = clamp(Math.min(anchor, current), first, last - snap)
  const end = clamp(Math.max(anchor, current) + snap, start + snap, last)
  return { start, end }
}

// The gesture as a state machine over plain inputs, so it is testable
// without a DOM. `y` is px from the column's top.
export function createGesture(o = {}) {
  const threshold = o.threshold ?? THRESHOLD_PX
  let g = null

  return {
    get state() {
      return g ? (g.active ? "dragging" : "pressed") : "idle"
    },

    down({ pointerId, pointerType, button, y, date }) {
      if (g) return false
      if (button !== 0 || pointerType === "touch" || !date) return false
      g = { pointerId, date, startY: y, anchor: minuteAt(y, o), active: false, range: null }
      return true
    },

    move({ pointerId, y }) {
      if (!g || pointerId !== g.pointerId) return { type: "none" }
      if (!g.active && Math.abs(y - g.startY) < threshold) return { type: "none" }
      const first = !g.active
      g.active = true
      g.range = rangeOf(g.anchor, minuteAt(y, o), o)
      return { type: first ? "start" : "update", range: g.range }
    },

    up({ pointerId, y }) {
      if (!g || pointerId !== g.pointerId) return { type: "none" }
      const done = g
      g = null
      if (!done.active) return { type: "click" }
      const range = rangeOf(done.anchor, minuteAt(y, o), o)
      return { type: "select", date: done.date, start: range.start, end: range.end }
    },

    // pointercancel, lost capture, Escape, scroll, navigation.
    abort() {
      const was = g
      g = null
      return was ? { type: "abort", wasActive: was.active } : { type: "none" }
    },
  }
}

const topPx = (minute, o = {}) =>
  ((minute - (o.firstHour ?? FIRST_HOUR) * 60) / 60) * (o.hourPx ?? HOUR_PX)

const CalendarSelection = {
  mounted() {
    this.gesture = createGesture()
    this.column = null
    this.overlay = null
    this.suppressClick = false

    this.onDown = (e) => {
      // A drag whose release produced no click must not swallow the next one.
      this.suppressClick = false
      if (e.target.closest && e.target.closest(".cal-ev")) return
      const column = e.target.closest && e.target.closest("[data-role=calendar-day-column]")
      if (!column || !this.el.contains(column)) return
      const started = this.gesture.down({
        pointerId: e.pointerId,
        pointerType: e.pointerType,
        button: e.button,
        y: e.clientY - column.getBoundingClientRect().top,
        date: column.dataset.date,
      })
      if (started) this.column = column
    }

    this.onMove = (e) => {
      if (!this.column) return
      const y = e.clientY - this.column.getBoundingClientRect().top
      const step = this.gesture.move({ pointerId: e.pointerId, y })
      if (step.type === "start") {
        try {
          this.column.setPointerCapture(e.pointerId)
        } catch (_) {
          // A pointer that is already gone cannot be captured; the next
          // pointerup or cancel ends the gesture either way.
        }
        this.drawOverlay(step.range)
      } else if (step.type === "update") {
        this.drawOverlay(step.range)
      }
      if (step.type !== "none") e.preventDefault()
    }

    this.onUp = (e) => {
      if (!this.column) return
      const y = e.clientY - this.column.getBoundingClientRect().top
      const step = this.gesture.up({ pointerId: e.pointerId, y })
      if (step.type === "none") return
      const column = this.column
      this.finish()
      if (step.type === "select") {
        try {
          column.releasePointerCapture(e.pointerId)
        } catch (_) {}
        this.suppressClick = true
        this.pushEvent("select_range", { date: step.date, start: step.start, end: step.end })
      }
    }

    this.onAbort = () => this.abort()

    this.onLostCapture = () => {
      if (this.gesture.state === "dragging") this.abort()
    }

    // Capture phase, before LiveView's phx-click on the slot.
    this.onClick = (e) => {
      if (!this.suppressClick) return
      this.suppressClick = false
      e.preventDefault()
      e.stopImmediatePropagation()
    }

    // Capture phase on window, before phx-window-keydown="escape".
    this.onKey = (e) => {
      if (e.key !== "Escape" || this.gesture.state === "idle") return
      this.abort()
      e.preventDefault()
      e.stopImmediatePropagation()
    }

    this.scroller = this.el.closest("#calendar-body") || this.el.parentElement

    this.el.addEventListener("pointerdown", this.onDown)
    this.el.addEventListener("pointermove", this.onMove)
    this.el.addEventListener("pointerup", this.onUp)
    this.el.addEventListener("pointercancel", this.onAbort)
    this.el.addEventListener("lostpointercapture", this.onLostCapture)
    this.el.addEventListener("click", this.onClick, true)
    window.addEventListener("keydown", this.onKey, true)
    window.addEventListener("phx:page-loading-start", this.onAbort)
    if (this.scroller) this.scroller.addEventListener("scroll", this.onAbort, { passive: true })
  },

  drawOverlay(range) {
    if (!this.overlay) {
      this.overlay = document.createElement("div")
      this.overlay.className = "cal-drag-selection"
      this.overlay.setAttribute("data-role", "calendar-drag-selection")
      this.overlay.setAttribute("aria-hidden", "true")
      this.column.appendChild(this.overlay)
    }
    const top = topPx(range.start)
    this.overlay.style.top = `${top}px`
    this.overlay.style.height = `${topPx(range.end) - top}px`
  },

  abort() {
    this.gesture.abort()
    this.finish()
  },

  finish() {
    if (this.overlay) this.overlay.remove()
    this.overlay = null
    this.column = null
  },

  destroyed() {
    this.abort()
    window.removeEventListener("keydown", this.onKey, true)
    window.removeEventListener("phx:page-loading-start", this.onAbort)
    if (this.scroller) this.scroller.removeEventListener("scroll", this.onAbort)
  },
}

// Focus return for the event editor: whatever had focus when the editor
// opened (the chip, the slot, + New) gets it back when the editor closes,
// whichever way it closes (X, Cancel, Escape, backdrop, Save). The editor's
// focus trap is Phoenix's `focus_wrap`.
let lastFocus = null

if (typeof document !== "undefined" && document.addEventListener) {
  document.addEventListener(
    "focusin",
    (e) => {
      if (!(e.target.closest && e.target.closest("#calendar-editor-scrim"))) lastFocus = e.target
    },
    true,
  )
}

export const CalendarEditorFocus = {
  mounted() {
    this.returnTo = lastFocus
  },

  destroyed() {
    const target = this.returnTo
    if (target && target.isConnected && typeof target.focus === "function") target.focus()
  },
}

export default CalendarSelection
