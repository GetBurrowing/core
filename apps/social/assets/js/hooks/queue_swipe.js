/**
 * QueueSwipe hook: the Queue's version strip (Social authoring 5/11, task
 * 01a16c50). Mounted on each idea card's `[data-role="queue-versions"]`
 * (`PlatformWeb.SocialIdeaCard`), whose `phx-target` is the card.
 *
 * On a phone (< 640px) every version is a full-width, scroll-snapped
 * column, so a swipe is the browser's own scroll; this hook only reads
 * which column landed and pushes `q_version` {index} to the card, so the
 * sticky bar acts on the version on screen. ArrowLeft / ArrowRight (focus
 * on the strip, not while typing, no modifier) move one version on any
 * width. When the server moves `data-current` (opening Reject on a version,
 * say), the strip scrolls to it.
 *
 * Nothing here decides anything: Approve, Revise and Reject are ordinary
 * phx-clicks on the card, re-checked on the server.
 *
 * On a desktop deep link (`data-deep-link="true"` on the card) the card is
 * scrolled into view once.
 */

const TYPING_TAGS = new Set(["INPUT", "TEXTAREA", "SELECT"])
const PHONE_QUERY = "(max-width: 639px)"
export const SETTLE_MS = 90

/** True when the event target is somewhere the user types. */
export function typingTarget(t) {
  if (!t) return false
  return TYPING_TAGS.has(t.tagName) || t.isContentEditable === true
}

/** `i` clamped into 0..count-1 (0 for an empty strip). */
export function clampIndex(i, count) {
  const n = Number(count)
  if (!Number.isFinite(n) || n <= 0) return 0
  const x = Math.round(Number(i))
  if (!Number.isFinite(x)) return 0
  return Math.min(n - 1, Math.max(0, x))
}

/** The full-width column under a scroll offset: round(left / width). */
export function indexAt(scrollLeft, width, count) {
  const w = Number(width)
  if (!Number.isFinite(w) || w <= 0) return 0
  return clampIndex(Number(scrollLeft) / w, count)
}

/**
 * The column whose centre is nearest `target` (the strip's centre), from
 * each column's centre x. -1 for no columns.
 */
export function nearestIndex(centers, target) {
  let best = -1
  let bestDist = Infinity
  centers.forEach((c, i) => {
    const d = Math.abs(Number(c) - Number(target))
    if (d < bestDist) {
      best = i
      bestDist = d
    }
  })
  return best
}

/**
 * The version a key moves to, or null for a key that does nothing here:
 * ArrowRight / ArrowLeft only, never while typing or with a modifier, and
 * never past either end.
 */
export function keyIndex(key, index, count, target, mods = {}) {
  if (typingTarget(target)) return null
  if (mods.metaKey || mods.ctrlKey || mods.altKey || mods.shiftKey) return null
  let next
  if (key === "ArrowRight") next = index + 1
  else if (key === "ArrowLeft") next = index - 1
  else return null
  const clamped = clampIndex(next, count)
  return clamped === index ? null : clamped
}

function isPhone() {
  return typeof window !== "undefined" && typeof window.matchMedia === "function"
    ? window.matchMedia(PHONE_QUERY).matches
    : false
}

const QueueSwipe = {
  mounted() {
    this.index = clampIndex(this.el.dataset.current, this.el.dataset.count)
    this.timer = null

    this.onScroll = () => {
      if (!isPhone()) return
      clearTimeout(this.timer)
      this.timer = setTimeout(() => this.settle(), SETTLE_MS)
    }

    this.onKey = (e) => {
      const next = keyIndex(e.key, this.index, this.el.dataset.count, e.target, e)
      if (next === null) return
      e.preventDefault()
      this.go(next)
      this.push(next)
    }

    this.el.addEventListener("scroll", this.onScroll, { passive: true })
    this.el.addEventListener("keydown", this.onKey)

    const card = this.el.closest && this.el.closest("[data-deep-link='true']")
    if (card && !isPhone() && typeof card.scrollIntoView === "function") {
      card.scrollIntoView({ block: "start" })
    }
  },

  updated() {
    const server = clampIndex(this.el.dataset.current, this.el.dataset.count)
    if (server !== this.index) {
      this.index = server
      this.go(server)
    }
  },

  destroyed() {
    clearTimeout(this.timer)
    this.el.removeEventListener("scroll", this.onScroll)
    this.el.removeEventListener("keydown", this.onKey)
  },

  // Which column the swipe landed on: the one centred in the strip, or
  // (no layout boxes) the full-width column under the scroll offset.
  settle() {
    const cols = Array.from(this.el.children || [])
    let i
    if (cols.length && typeof this.el.getBoundingClientRect === "function") {
      const box = this.el.getBoundingClientRect()
      const centers = cols.map((c) => {
        const r = c.getBoundingClientRect()
        return r.left + r.width / 2
      })
      i = clampIndex(nearestIndex(centers, box.left + box.width / 2), this.el.dataset.count)
    } else {
      i = indexAt(this.el.scrollLeft, this.el.clientWidth, this.el.dataset.count)
    }
    if (i !== this.index) this.push(i)
  },

  push(i) {
    this.index = i
    this.pushEventTo(this.el, "q_version", { index: i })
  },

  go(i) {
    const col = this.el.children && this.el.children[i]
    if (col && typeof col.scrollIntoView === "function") {
      col.scrollIntoView({ behavior: "smooth", block: "nearest", inline: "start" })
    } else if (typeof this.el.scrollTo === "function") {
      this.el.scrollTo({ left: i * this.el.clientWidth, behavior: "smooth" })
    }
  },
}

export default QueueSwipe
