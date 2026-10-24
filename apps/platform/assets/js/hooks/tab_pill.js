// TabPill: the sliding pill behind the phone tab bar's current tab.
//
// The product lead picked prototype t1 ("Sliding pill") of ten. A soft primary-tinted
// pill sits behind the current tab. When the current tab changes it springs
// across (transform .45s cubic-bezier(.3,1.5,.5,1), width .45s), and a tab
// scales to .92 while pressed (80ms).
//
// WHICH TAB. The pill follows the tab that LOOKS current: the one
// `lib/nav_pending.js` marked `data-nav-pending` on tap (the optimistic
// swap), or else `.bottom-nav-tab--active`. The pill moves on the tap, the
// same frame the ink moves, and it comes back if nav_pending rolls the tap
// back. A MutationObserver on the bar watches those attributes, so the hook
// never has to know who changed them.
//
// NO SLIDE-IN ON LOAD. On mount the pill is placed on the current tab with
// no transition. A tab link's `navigate` remounts the LiveView, and that
// replaces this bar, so the pill would otherwise snap to tab 0 or replay
// the slide on every page. A tap therefore records {from, to, at} in
// sessionStorage. The next mount, if it lands on `to` within SLIDE_MS of
// the tap, carries on from where the old bar's slide had got to (Web
// Animations, currentTime = elapsed). Otherwise it just places the pill.
// A More open/close is a patch of the same bar and animates in place.
//
// Reduced motion: the pill is always placed, never slid. Resizing re-places
// it with no transition.

export const STORAGE_KEY = "suite:tab-pill:last-tap"
export const SLIDE_MS = 450
export const SLIDE_EASE = "cubic-bezier(.3,1.5,.5,1)"
export const PRESS_CLASS = "is-pressed"
// Horizontal inset of the pill inside its tab cell, px.
export const PILL_INSET_X = 4

const TAB_SELECTOR = ".bottom-nav-tab"

export function tabsOf(nav) {
  return Array.from(nav.querySelectorAll(TAB_SELECTOR))
}

// The index of the tab that currently LOOKS current, or -1.
export function targetIndex(tabs) {
  const pending = tabs.findIndex((t) => t.hasAttribute("data-nav-pending"))
  if (pending >= 0) return pending

  return tabs.findIndex(
    (t) => t.classList.contains("bottom-nav-tab--active") && !t.hasAttribute("data-nav-yielded"),
  )
}

// The pill's box for a tab, relative to the bar (the tab's offsetParent).
export function geometryFor(tab) {
  if (!tab) return null
  const w = Math.max(tab.offsetWidth - 2 * PILL_INSET_X, 0)
  return { x: tab.offsetLeft + PILL_INSET_X, w }
}

// Where a remount should start, given the stored tap. Returns
// {from, elapsed} to continue a slide, or null to place instantly.
export function resumeFrom(stored, index, now) {
  if (!stored || typeof stored !== "object") return null
  const { from, to, at } = stored
  if (!Number.isInteger(from) || !Number.isInteger(to) || typeof at !== "number") return null
  if (to !== index || from === index || from < 0) return null
  const elapsed = now - at
  if (!(elapsed >= 0) || elapsed >= SLIDE_MS) return null
  return { from, elapsed }
}

function storage(win) {
  try {
    return win.sessionStorage || null
  } catch (_e) {
    return null
  }
}

export function readTap(win) {
  const s = storage(win)
  if (!s) return null
  try {
    const raw = s.getItem(STORAGE_KEY)
    s.removeItem(STORAGE_KEY)
    return raw ? JSON.parse(raw) : null
  } catch (_e) {
    return null
  }
}

export function writeTap(win, tap) {
  const s = storage(win)
  if (!s) return
  try {
    s.setItem(STORAGE_KEY, JSON.stringify(tap))
  } catch (_e) {
    // Quota or private mode: the next mount just places the pill.
  }
}

function reducedMotion(win) {
  return !!(win.matchMedia && win.matchMedia("(prefers-reduced-motion: reduce)").matches)
}

const TabPill = {
  mounted() {
    this.win = this.win || window
    this.pill = this.el.querySelector("[data-tab-pill]")
    if (!this.pill) return

    this.index = targetIndex(tabsOf(this.el))
    const resume = reducedMotion(this.win)
      ? null
      : resumeFrom(readTap(this.win), this.index, Date.now())

    this.place(this.index, false)
    if (resume) this.continueSlide(resume.from, resume.elapsed)

    this.onPointerDown = (e) => {
      const tab = e.target.closest && e.target.closest(TAB_SELECTOR)
      if (!tab || !this.el.contains(tab)) return
      this.release()
      this.pressed = tab
      tab.classList.add(PRESS_CLASS)
    }
    this.release = () => {
      if (this.pressed) this.pressed.classList.remove(PRESS_CLASS)
      this.pressed = null
    }
    // pointerleave does not bubble; a capturing listener still sees it.
    this.onPointerLeave = (e) => {
      if (e.target === this.pressed) this.release()
    }
    // Capture, so the tap is recorded before LiveView navigates. `from` is
    // the server's current tab (the --active one), not wherever the pill is
    // heading: nav_pending may already have marked the tapped tab.
    this.onClick = (e) => {
      const tab = e.target.closest && e.target.closest(TAB_SELECTOR)
      if (!tab || !tab.hasAttribute("href")) return
      const tabs = tabsOf(this.el)
      const to = tabs.indexOf(tab)
      const from = tabs.findIndex((t) => t.classList.contains("bottom-nav-tab--active"))
      if (to >= 0 && from >= 0 && to !== from) writeTap(this.win, { from, to, at: Date.now() })
    }
    this.el.addEventListener("pointerdown", this.onPointerDown)
    this.el.addEventListener("pointerleave", this.onPointerLeave, true)
    this.win.addEventListener("pointerup", this.release)
    this.win.addEventListener("pointercancel", this.release)
    this.el.addEventListener("click", this.onClick, true)

    this.observer = new MutationObserver(() => this.sync())
    this.observer.observe(this.el, {
      subtree: true,
      attributes: true,
      attributeFilter: ["class", "data-nav-pending", "data-nav-yielded"],
    })

    this.onResize = () => this.place(this.index, false)
    if (typeof ResizeObserver === "function") {
      this.resizeObserver = new ResizeObserver(this.onResize)
      this.resizeObserver.observe(this.el)
    }
    this.win.addEventListener("resize", this.onResize)
  },

  updated() {
    this.sync()
  },

  destroyed() {
    if (this.observer) this.observer.disconnect()
    if (this.resizeObserver) this.resizeObserver.disconnect()
    if (this.onResize) this.win.removeEventListener("resize", this.onResize)
    if (this.release) {
      this.win.removeEventListener("pointerup", this.release)
      this.win.removeEventListener("pointercancel", this.release)
    }
  },

  sync() {
    if (!this.pill) return
    const index = targetIndex(tabsOf(this.el))
    if (index === this.index) return
    this.index = index
    this.place(index, !reducedMotion(this.win))
  },

  // Put the pill on tab `index`, sliding when `animate`.
  place(index, animate) {
    const pill = this.pill
    const geo = geometryFor(tabsOf(this.el)[index])

    if (!geo || geo.w === 0) {
      pill.style.opacity = "0"
      return
    }

    if (!animate) pill.style.transition = "none"
    pill.style.setProperty("--pill-x", `${geo.x}px`)
    pill.style.setProperty("--pill-w", `${geo.w}px`)
    pill.style.opacity = "1"

    if (!animate) {
      // Commit the jump before the transition comes back.
      void pill.offsetWidth
      pill.style.transition = ""
    }
  },

  // A remount mid-slide: replay the slide from tab `from` to where the pill
  // now sits, already `elapsed` ms in, so the new bar picks up the old
  // bar's motion instead of restarting it.
  continueSlide(from, elapsed) {
    const pill = this.pill
    const start = geometryFor(tabsOf(this.el)[from])
    const end = geometryFor(tabsOf(this.el)[this.index])
    if (!start || !end || typeof pill.animate !== "function") return

    const slides = [
      pill.animate(
        [{ transform: `translateX(${start.x}px)` }, { transform: `translateX(${end.x}px)` }],
        { duration: SLIDE_MS, easing: SLIDE_EASE },
      ),
      pill.animate([{ width: `${start.w}px` }, { width: `${end.w}px` }], {
        duration: SLIDE_MS,
        easing: "ease",
      }),
    ]
    for (const a of slides) a.currentTime = elapsed
  },
}

export default TabPill
