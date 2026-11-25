// The phone calendar's hooks (canvas 01a2111c, "Calendar on a phone"):
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

/** The tail's min height: one list height less a day header. */
export function tailPx(listHeight, headerPx) {
  return Math.max(0, Math.round(listHeight - headerPx))
}

/** The scroll change that puts an anchor back where it was after a patch. */
export function anchorShift(before, after) {
  return typeof before === "number" && typeof after === "number" ? after - before : 0
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
      })
    }
    this.el.addEventListener("scroll", this.onScroll, { passive: true })
    this.fitTail()
    if (typeof ResizeObserver !== "undefined") {
      this.ro = new ResizeObserver(() => this.fitTail())
      this.ro.observe(this.el)
    }
    this.scrollToDate(this.el.dataset.today)

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
    this.el.scrollTop = scrollTarget({
      targetTop: row.top,
      containerTop: this.el.getBoundingClientRect().top,
      scrollTop: this.el.scrollTop,
    })
    this.report(true)
  },

  // Earlier days land above: keep the first visible row where it was.
  loadMore(direction) {
    if (!this.ready || this.loading || this.el.offsetParent === null) return
    this.loading = true
    const view = this.el.getBoundingClientRect()
    const anchor = direction === "earlier" ? anchorRow(this.rows(), view.top) : null
    const anchorId = anchor && anchor.el.id
    const before = anchor && anchor.top

    this.pushEvent("m_agenda_more", { direction }, () => {
      const el = anchorId && document.getElementById(anchorId)
      if (el) this.el.scrollTop += anchorShift(before, el.getBoundingClientRect().top)
      this.loading = false
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

    this.el.scrollTop = scrollTarget({
      targetTop: target.getBoundingClientRect().top,
      containerTop: this.el.getBoundingClientRect().top,
      scrollTop: this.el.scrollTop,
      offset,
      context,
    })
  },
}
