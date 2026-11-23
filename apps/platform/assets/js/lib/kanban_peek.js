/**
 * Kanban peek on the OPEN iPhone Duo (task 01a20937 stage 2, direction canvas
 * 01a2093b-50df).
 *
 * The open board is a row of fixed lanes (288px, 12px gaps, 16px lead; see
 * app.css). The peek is the affordance that says the row continues: at rest
 * the lane at the inline-end edge must show at least 32px AND hide at least
 * 32px. With a 16px lead that holds at 669 (53px shown) and 951 (35px shown),
 * but many widths between 640 and 1024 leave a sliver under 32px (any content
 * width whose remainder after whole lane+gap steps is under 32, e.g. 930).
 * The width the board gets is not knowable in CSS (open-landscape side
 * insets are unverified), so it is computed here.
 *
 * The canvas rule: when the remainder is under 32px, WIDEN THE LEADING
 * PADDING until the last full lane is pushed over the edge by at least 32px.
 * Never narrow the gaps (that recovers at most a few px per gap). When every
 * lane fits there is no scroll and no peek, so the lead stays at its base.
 * When the remainder already shows most of a lane, nothing changes.
 *
 * `installKanbanPeek` wires it to a board element: a ResizeObserver plus the
 * native posture event. It writes `--kanban-lead` on the board only while
 * the Duo is open (`openDuo`), and removes it otherwise, so phones, the
 * folded front screen and desktop never see it.
 */

import { openDuo } from "./duo_more_page.js"
import { DUO_POSTURE_EVENT } from "../hooks/native_back.js"

export const DEFAULTS = Object.freeze({ lane: 288, gap: 12, base: 16, minPeek: 32, lanes: Infinity })
export const LEAD_VAR = "--kanban-lead"

/**
 * Leading padding (px) for a board whose scrollport is `contentWidth` px.
 */
export function leadPadding(contentWidth, opts = {}) {
  const { lane, gap, base, minPeek, lanes } = { ...DEFAULTS, ...opts }
  const step = lane + gap
  const width = Math.floor(contentWidth)
  if (!(width > 0)) return base

  // Every lane fits with base padding at both ends: no scroll, no peek.
  if (lanes * lane + Math.max(lanes - 1, 0) * gap + 2 * base <= width) return base

  const usable = width - base
  const fullSteps = Math.floor(usable / step)
  // How much of the next lane shows at the inline end with the base lead.
  const shown = usable - fullSteps * step

  // Fewer than one whole lane on screen, or the next lane shows between
  // minPeek and its full width: leave the lead alone. (Between lane-minPeek
  // and lane it hides under minPeek; the canvas leaves that unchanged, since
  // it already shows most of another lane.)
  if (fullSteps < 1 || (shown >= minPeek && shown < lane)) return base

  // Otherwise nothing is cut, or only a sliver under minPeek shows. Push the
  // last FULLY visible lane over the edge so it hides exactly minPeek px.
  // With a sliver, that lane is the one before the sliver; when the next
  // lane fits whole (shown >= lane, only a gap after it), it is that lane.
  const lastFull = shown >= lane ? fullSteps : fullSteps - 1
  const lastFullEnd = base + lastFull * step + lane
  return base + (width + minPeek - lastFullEnd)
}

/**
 * The lane cut by the inline-end edge at rest, for a given lead:
 * { index, shown, hidden } (index is 0-based), or null when none is cut.
 */
export function cutLane(contentWidth, lead, opts = {}) {
  const { lane, gap, lanes } = { ...DEFAULTS, ...opts }
  const width = Math.floor(contentWidth)
  const count = Number.isFinite(lanes) ? lanes : Math.ceil(width / (lane + gap)) + 1
  for (let i = 0; i < count; i++) {
    const start = lead + i * (lane + gap)
    const end = start + lane
    if (end > width) {
      if (start >= width) return null
      return { index: i, shown: width - start, hidden: end - width }
    }
  }
  return null
}

/**
 * Wire the peek to `board`. Returns an uninstall function. `win` and `doc`
 * are injected for tests.
 */
export function installKanbanPeek(board, win = window, doc = document) {
  const lanesOf = () => Array.from(board.querySelectorAll(":scope > [data-column]"))
  let leftLane = 0

  // The left-most visible lane (the first with more than half of it on
  // screen, so a sliver left by a slow drag does not count), tracked while
  // scrolling so a rotation can put the same lane back at the inline start.
  // Rects, not offsetLeft: the board is not the lanes' offsetParent.
  const onScroll = () => {
    const box = board.getBoundingClientRect()
    const rtl = win.getComputedStyle?.(board)?.direction === "rtl"
    const i = lanesOf().findIndex((l) => {
      const r = l.getBoundingClientRect()
      const onScreen = rtl ? box.right - r.left : r.right - box.left
      return onScreen > r.width / 2
    })
    leftLane = i < 0 ? 0 : i
  }

  const apply = () => {
    if (!openDuo(doc)) {
      board.style.removeProperty(LEAD_VAR)
      return
    }
    const lanes = lanesOf()
    const lead = leadPadding(board.clientWidth, { lanes: lanes.length })
    board.style.setProperty(LEAD_VAR, `${lead}px`)

    // Keep the left-most lane left-most; when the board fits, the browser
    // clamps the scroll to 0 and the clamp wins.
    const target = lanes[leftLane]
    if (leftLane === 0 || !target) {
      board.scrollLeft = 0
    } else if (typeof target.scrollIntoView === "function") {
      target.scrollIntoView({ block: "nearest", inline: "start" })
    }
  }

  const RO = win.ResizeObserver
  const observer = RO ? new RO(() => apply()) : null
  if (observer) observer.observe(board)
  win.addEventListener(DUO_POSTURE_EVENT, apply)
  board.addEventListener("scroll", onScroll, { passive: true })
  apply()

  return () => {
    if (observer) observer.disconnect()
    win.removeEventListener(DUO_POSTURE_EVENT, apply)
    board.removeEventListener("scroll", onScroll)
    board.style.removeProperty(LEAD_VAR)
  }
}
