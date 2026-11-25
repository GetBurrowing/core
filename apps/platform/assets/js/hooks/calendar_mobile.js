// The phone calendar's hooks (canvas 01a2111c, "Calendar on a phone"),
// bundled as the `calendar_mobile` island (js/calendar_mobile_island.js) and
// loaded on demand by js/lib/load_calendar_mobile.js, so app.js, which every
// page loads, carries only the loader:
//
// - CalendarAgenda: the agenda opens on today, reports the day at the top
//   (the week strip follows it) and whether today is on screen (the Today
//   button), and loads more days at either end without the list jumping.
// - CalendarDay: the Day view opens at now (or the first event, or 08:00)
//   and a sideways swipe changes day.
// - CalendarSwipe: a sideways swipe on the week strip moves a week.
//
// Every offset is measured from the DOM (the sticky day header, the pinned
// all-day row, the hour row), never a constant, so it holds at 200% text
// and in landscape. Swipes that start within EDGE_PX of either screen edge
// are ignored so the iOS Back swipe keeps working.

export const EDGE_PX = 20
export const MIN_SWIPE_PX = 48

/**
 * "next", "previous" or null for a touch from `start` to `end` ({x, y}) on
 * a screen `width` wide. A swipe left is "next". Starts inside the edge
 * guard, short moves and mostly-vertical moves are not swipes.
 */
export function swipeDirection(start, end, width, { edge = EDGE_PX, min = MIN_SWIPE_PX } = {}) {
  if (!start || !end) return null
  if (start.x < edge || start.x > width - edge) return null
  const dx = end.x - start.x
  const dy = end.y - start.y
  if (Math.abs(dx) < min || Math.abs(dx) < 1.5 * Math.abs(dy)) return null
  return dx < 0 ? "next" : "previous"
}

/** The row ({from, to, top, bottom}) under the line `y`, or the first one below it. */
export function rowAt(rows, y) {
  return rows.find((r) => r.bottom > y) || rows[rows.length - 1] || null
}

/**
 * The row to hold still while rows land above it: the first day row (its id
 * is its date, so it survives the patch) at or below the line `y`. An empty
 * run's id can change when it merges with the days loaded before it.
 */
export function anchorRow(rows, y) {
  return rows.find((r) => r.bottom > y && r.type === "day") || rowAt(rows, y)
}

/** The row whose `from..to` (ISO dates) covers `iso`, or the nearest later one. */
export function rowForDate(rows, iso) {
  return rows.find((r) => r.from <= iso && iso <= r.to) || rows.find((r) => r.from > iso) || null
}

/**
 * Whether a row (viewport rect) shows more than its header: some of it is
 * below the sticky header line and above the bottom of the list.
 */
export function rowVisible(rect, viewTop, viewBottom, headerPx) {
  if (!rect) return false
  return rect.bottom > viewTop + headerPx && rect.top < viewBottom
}

/** scrollTop that puts `targetTop` `offset + context` px below the container's top. */
export function scrollTarget({ targetTop, containerTop, scrollTop, offset = 0, context = 0 }) {
  return Math.max(0, Math.round(targetTop - containerTop + scrollTop - offset - context))
}

/**
 * Whether a sentinel (viewport rect) is within `margin` px of the list
 * (viewport rect `view`) at its end of the list.
 */
export function nearEdge(direction, rect, view, margin = 240) {
  if (!rect || !view) return false
  return direction === "later" ? rect.top < view.bottom + margin : rect.bottom > view.top - margin
}

/** Whether the server marked that end of the agenda reached (`data-end-*`). */
export function endReached(dataset, direction) {
  return (direction === "later" ? dataset.endLater : dataset.endEarlier) === "true"
}

/** The tail's min height: one list height less a day header. */
export function tailPx(listHeight, headerPx) {
  return Math.max(0, Math.round(listHeight - headerPx))
}

/** The scroll change that puts an anchor back where it was after a patch. */
export function anchorShift(before, after) {
  return typeof before === "number" && typeof after === "number" ? after - before : 0
}

// A scroll the code made (a jump, an anchor kept after a load) is not the
// reader's: the strip must not hide or come back for it.
function programmaticScroll(el, top) {
  if (Math.round(el.scrollTop) === Math.round(top)) return
  el._mProgrammatic = true
  el.scrollTop = top
}

function attachSwipe(hook, el) {
  hook.onTouchStart = (e) => {
    const t = e.touches && e.touches[0]
    hook.touchStart = t ? { x: t.clientX, y: t.clientY } : null
  }
  hook.onTouchEnd = (e) => {
    const t = e.changedTouches && e.changedTouches[0]
    const dir = swipeDirection(hook.touchStart, t && { x: t.clientX, y: t.clientY }, window.innerWidth)
    hook.touchStart = null
    if (dir) hook.pushEvent(el.dataset.swipeEvent, { direction: dir })
  }
  el.addEventListener("touchstart", hook.onTouchStart, { passive: true })
  el.addEventListener("touchend", hook.onTouchEnd, { passive: true })
}

function detachSwipe(hook, el) {
  el.removeEventListener("touchstart", hook.onTouchStart)
  el.removeEventListener("touchend", hook.onTouchEnd)
}

export const CalendarSwipe = {
  mounted() {
    attachSwipe(this, this.el)
  },
  destroyed() {
    detachSwipe(this, this.el)
  },
}

export const CalendarAgenda = {
  mounted() {
    this.ready = false
    this.loading = false
    this.lastReport = null
    this.handleEvent("m-agenda-scroll", ({ date }) => this.scrollToDate(date))
    this.onScroll = () => {
      if (this.raf) return
      this.raf = requestAnimationFrame(() => {
        this.raf = null
        this.report()
        this.checkEdges()
      })
    }
    this.el.addEventListener("scroll", this.onScroll, { passive: true })
    this.fitTail()
    if (typeof ResizeObserver !== "undefined") {
      this.ro = new ResizeObserver(() => this.fitTail())
      this.ro.observe(this.el)
    }
    this.scrollToDate(this.el.dataset.focus || this.el.dataset.today)
    // Rows stay hidden (app.css) until they are scrolled to the right day,
    // so the first open shows the loading lines, never the wrong fortnight.
    this.js().setAttribute(this.el, "data-ready", "")

    if (typeof IntersectionObserver !== "undefined") {
      this.io = new IntersectionObserver(
        (entries) => {
          for (const entry of entries) {
            if (!entry.isIntersecting) continue
            const dir = entry.target.dataset.role === "m-agenda-earlier" ? "earlier" : "later"
            this.loadMore(dir)
          }
        },
        { root: this.el, rootMargin: "240px 0px" },
      )
      // Only after the first scroll to today, or the top sentinel fires at once.
      requestAnimationFrame(() => {
        this.ready = true
        for (const role of ["m-agenda-earlier", "m-agenda-later"]) {
          const s = this.el.querySelector(`[data-role="${role}"]`)
          if (s) this.io.observe(s)
        }
      })
    }
  },

  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll)
    if (this.io) this.io.disconnect()
    if (this.ro) this.ro.disconnect()
    if (this.raf) cancelAnimationFrame(this.raf)
  },

  // The list's tail is at least one screen tall, so any day, even the last
  // one loaded, can be scrolled to the top (a jump, the strip following).
  fitTail() {
    const tail = this.el.querySelector('[data-role="m-agenda-later"]')
    if (tail && this.el.clientHeight) tail.style.minHeight = `${tailPx(this.el.clientHeight, this.headerPx())}px`
  },

  rowEls() {
    return Array.from(this.el.querySelectorAll('[data-role="m-agenda-row"]'))
  },

  rows() {
    return this.rowEls().map((el) => {
      const r = el.getBoundingClientRect()
      return { el, type: el.dataset.type, from: el.dataset.from, to: el.dataset.to, top: r.top, bottom: r.bottom }
    })
  },

  headerPx() {
    const h = this.el.querySelector('[data-role="m-agenda-day-header"]')
    return h ? h.getBoundingClientRect().height : 0
  },

  scrollToDate(iso) {
    const row = rowForDate(this.rows(), iso)
    if (!row) return
    programmaticScroll(
      this.el,
      scrollTarget({
        targetTop: row.top,
        containerTop: this.el.getBoundingClientRect().top,
        scrollTop: this.el.scrollTop,
      }),
    )
    this.report(true)
  },

  // Near either end, load more that way. Driven by scrolling as well as
  // the observer: the tail is a screen tall, so it stays "intersecting"
  // and the observer alone would fire once and never again (review G).
  checkEdges() {
    if (this.el.offsetParent === null) return
    const view = this.el.getBoundingClientRect()
    const later = this.el.querySelector('[data-role="m-agenda-later"]')
    const earlier = this.el.querySelector('[data-role="m-agenda-earlier"]')
    // A direction whose last load added nothing waits for the list to change.
    const dry = (dir) => this.dry && this.dry[dir] === this.el.scrollHeight
    if (later && !dry("later") && nearEdge("later", later.getBoundingClientRect(), view)) this.loadMore("later")
    else if (earlier && !dry("earlier") && nearEdge("earlier", earlier.getBoundingClientRect(), view))
      this.loadMore("earlier")
  },

  // Earlier days land above: keep the first visible row where it was.
  loadMore(direction) {
    if (!this.ready || this.loading || this.el.offsetParent === null) return
    // The server found nothing in two years that way: the agenda ends there.
    if (endReached(this.el.dataset || {}, direction)) return
    this.loading = true
    const view = this.el.getBoundingClientRect()
    const anchor = direction === "earlier" ? anchorRow(this.rows(), view.top) : null
    const anchorId = anchor && anchor.el.id
    const before = anchor && anchor.top

    const height = this.el.scrollHeight

    this.pushEvent("m_agenda_more", { direction }, () => {
      const el = anchorId && document.getElementById(anchorId)
      if (el) programmaticScroll(this.el, this.el.scrollTop + anchorShift(before, el.getBoundingClientRect().top))
      this.loading = false
      // The list grew and its end is still near: keep going. It stops when
      // a load adds nothing (no event within two years that way).
      this.dry = this.dry || {}
      if (this.el.scrollHeight > height) {
        this.dry[direction] = null
        requestAnimationFrame(() => this.checkEdges())
      } else {
        this.dry[direction] = this.el.scrollHeight
      }
      this.report(true)
    })
  },

  report(force = false) {
    if (this.el.offsetParent === null) return
    const view = this.el.getBoundingClientRect()
    const header = this.headerPx()
    const rows = this.rows()
    const top = rowAt(rows, view.top + 1)
    if (!top) return
    const today = rows.find((r) => r.el.dataset.today === "true")
    const todayVisible = rowVisible(today, view.top, view.bottom, header)
    const key = `${top.from}|${todayVisible}`
    if (!force && key === this.lastReport) return
    this.lastReport = key
    this.pushEvent("m_agenda_focus", { date: top.from, today_visible: todayVisible })
  },
}

export const CalendarDay = {
  mounted() {
    this.day = this.el.dataset.day
    attachSwipe(this, this.el)
    this.scrollToStart()
  },

  updated() {
    if (this.el.dataset.day !== this.day) {
      this.day = this.el.dataset.day
      this.scrollToStart()
    }
  },

  destroyed() {
    detachSwipe(this, this.el)
  },

  // Today: the now line a quarter of the way down. Another day: its first
  // event with half an hour above it, or 08:00. Both below the pinned row.
  scrollToStart() {
    const pinned = this.el.querySelector('[data-role="m-day-pinned"]')
    const offset = pinned ? pinned.getBoundingClientRect().height : 0
    const hour = this.el.querySelector('[data-hour="0"]')
    const hourPx = hour ? hour.getBoundingClientRect().height : 0
    const now = this.el.querySelector('[data-role="m-now"]')
    const first = this.el.querySelector('[data-role="m-day-column"] .cal-ev')
    const target = now || first || this.el.querySelector('[data-hour="8"]')
    if (!target) return
    const context = now ? (this.el.clientHeight - offset) * 0.25 : first ? hourPx / 2 : 0

    programmaticScroll(
      this.el,
      scrollTarget({
        targetTop: target.getBoundingClientRect().top,
        containerTop: this.el.getBoundingClientRect().top,
        scrollTop: this.el.scrollTop,
        offset,
        context,
      }),
    )
  },
}

// Week start lives in lib/week_start.js: app.js needs it for the connect
// params, and this module is an island (calendar_mobile_island.js).
export { weekStart } from "../lib/week_start.js"

// ── the phone layout marks (review A, B, C) ───────────────────────────

/** Rows of a wrapped flex line: tops within `tol` px are one line. */
export function lineCount(tops, tol = 8) {
  const sorted = [...tops].sort((a, b) => a - b)
  let lines = 0
  let last = -Infinity
  for (const top of sorted) {
    if (top - last > tol) lines += 1
    last = top
  }
  return lines
}

/** The month opens as a bottom sheet in landscape or at 150%+ text. */
export function monthAsSheet({ width, height, rootPx }) {
  return width > height || rootPx / 16 >= 1.5
}

/**
 * The low-space rule: the visible list, with the strip shown and less the
 * sticky day header over it, would be under 40% of the viewport height.
 */
export function lowSpace({ listPx, stripPx, stripHidden, headerPx, viewportPx }) {
  const withStrip = listPx - (stripHidden ? stripPx : 0) - headerPx
  return withStrip < 0.4 * viewportPx
}

/**
 * Whether the strip should hide after a scroll by `dy` px in low space:
 * down hides, up shows, small moves keep it as it is.
 */
export function stripHiddenAfter(hidden, dy, low, threshold = 4) {
  if (!low) return false
  if (dy > threshold) return true
  if (dy < -threshold) return false
  return hidden
}

export const CalendarPhoneLayout = {
  mounted() {
    this.stripHidden = false
    this.lastTop = new WeakMap()
    this.onResize = () => this.measure()
    this.onScroll = (e) => this.follow(e.target)
    window.addEventListener("resize", this.onResize)
    this.el.addEventListener("scroll", this.onScroll, { capture: true, passive: true })
    if (typeof ResizeObserver !== "undefined") {
      this.ro = new ResizeObserver(() => this.measureRow1())
      const row1 = this.el.querySelector('[data-role="m-row1"]')
      if (row1) this.ro.observe(row1)
    }
    requestAnimationFrame(() => this.measure())
  },

  updated() {
    if (!this.phone()) return
    this.measureRow1()
    this.measureSpace()
  },

  destroyed() {
    window.removeEventListener("resize", this.onResize)
    this.el.removeEventListener("scroll", this.onScroll, { capture: true })
    if (this.ro) this.ro.disconnect()
  },

  rootPx() {
    return parseFloat(getComputedStyle(document.documentElement).fontSize) || 16
  },

  phone() {
    const c = this.el.querySelector('[data-role="m-controls"]')
    return !!(c && c.offsetParent !== null)
  },

  measure() {
    if (!this.phone()) return
    const sheet = monthAsSheet({ width: window.innerWidth, height: window.innerHeight, rootPx: this.rootPx() })
    if (sheet) this.js().setAttribute(this.el, "data-month-sheet", "")
    else this.js().removeAttribute(this.el, "data-month-sheet")
    this.measureRow1()
    this.measureSpace()
  },

  // Row 1 may wrap to two lines; if it would need three, Agenda | Day goes
  // into the title menu (review B).
  measureRow1() {
    const row1 = this.el.querySelector('[data-role="m-row1"]')
    if (!row1 || row1.offsetParent === null) return
    const tops = () =>
      Array.from(row1.querySelectorAll('[data-role="m-date-group"], .ms-auto > *'))
        .filter((el) => getComputedStyle(el).display !== "none")
        .map((el) => el.getBoundingClientRect().top)
    this.el.removeAttribute("data-row1-compact")
    const compact = lineCount(tops()) > 2
    if (compact) this.js().setAttribute(this.el, "data-row1-compact", "")
    else this.js().removeAttribute(this.el, "data-row1-compact")
  },

  scroller() {
    return Array.from(this.el.querySelectorAll("#m-agenda, #m-day")).find((el) => el.offsetParent !== null)
  },

  strip() {
    return this.el.querySelector('[data-role="calendar-day-strip"]')
  },

  measureSpace() {
    const list = this.scroller()
    const strip = this.strip()
    if (!list || !strip) return
    const nav = document.getElementById("bottom-nav")
    const controls = this.el.querySelector('[data-role="m-controls"]')
    const row1 = this.el.querySelector('[data-role="m-row1"]')
    const r = list.getBoundingClientRect()
    // The bottom nav is position: fixed (no offsetParent): ask its display.
    const navShown = nav && getComputedStyle(nav).display !== "none"
    const bottom = navShown ? Math.min(r.bottom, nav.getBoundingClientRect().top) : r.bottom
    const header = list.querySelector('[data-role="m-agenda-day-header"], [data-role="m-day-pinned"]')
    this.stripPx = strip.offsetHeight
    // The list as it is with the strip shown, from the controls' top: not
    // from the list's own top, which moves while the strip slides.
    const border = controls.offsetHeight - controls.clientHeight
    this.low = lowSpace({
      listPx: bottom - controls.getBoundingClientRect().top - row1.offsetHeight - this.stripPx - border,
      stripPx: this.stripPx,
      stripHidden: false,
      headerPx: header ? header.getBoundingClientRect().height : 0,
      viewportPx: window.innerHeight,
    })
    this.el.setAttribute("data-low-space", this.low ? "true" : "false")
    // In low space the strip starts tucked away; it comes back on scroll-up.
    this.setStrip(this.low ? (this.lowSeen ? this.stripHidden : true) : false)
    this.lowSeen = this.low
  },

  follow(target) {
    if (!target || (target.id !== "m-agenda" && target.id !== "m-day")) return
    const last = this.lastTop.get(target)
    this.lastTop.set(target, target.scrollTop)
    if (target._mProgrammatic) {
      target._mProgrammatic = false
      return
    }
    if (last === undefined || !this.low) return
    this.setStrip(stripHiddenAfter(this.stripHidden, target.scrollTop - last, this.low))
  },

  setStrip(hidden) {
    const strip = this.strip()
    if (!strip || hidden === this.stripHidden) return
    this.stripHidden = hidden
    if (hidden) {
      this.js().setAttribute(strip, "style", `margin-top: -${this.stripPx || strip.offsetHeight}px`)
      this.js().setAttribute(strip, "inert", "")
      this.js().setAttribute(strip, "data-hidden", "true")
    } else {
      this.js().removeAttribute(strip, "style")
      this.js().removeAttribute(strip, "inert")
      this.js().removeAttribute(strip, "data-hidden")
    }
  },
}
