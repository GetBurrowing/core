/**
 * PinnedReorder hook: mouse drag and Alt+arrow keys for the pinned
 * CONVERSATION rows of the desktop list pane (Burrow redesign 25 stage 3,
 * design direction canvas 01a17470).
 *
 * Mounted on `#chat-list-rows-pinned` only. Pinned follows the user's saved
 * order; every other section is recency-sorted and never reorders, so no
 * other container carries this hook.
 *
 * What it reads from the server's markup (`chat_list.ex`, `## Pinned
 * reorder`):
 *
 *   [data-reorder="true"]   a draggable row link (never a task, the Agents
 *                           row, a restricted row or an unpinned row)
 *   data-pinned-position    the row's 0-based place in the server's
 *                           conversation run. A RESTRICTED pinned row carries
 *                           it too (no link, no data-reorder), so a drop
 *                           counts it.
 *   data-pinned-count       the length of that run
 *
 * The gesture:
 *
 *   - Desktop only: `matchMedia(LG_QUERY)` is checked on EVERY pointerdown
 *     and keydown (no cached width), and only a "mouse" or "pen" pointer
 *     drags. Touch is ignored at every width, so the phone has no drag.
 *   - A primary-button press on a reorder row starts listening on the
 *     DOCUMENT (and the row takes pointer capture once the drag begins), so
 *     a release outside the container still ends the drag, clamped.
 *   - The drag begins once the pointer has moved DRAG_THRESHOLD_PX (4px,
 *     Euclidean) with the button held. Below that the release is an ordinary
 *     click and navigation is untouched.
 *   - The target comes from the POINTER's y against the vertical midpoints
 *     of the other conversation rows, translated into the server's indexing
 *     through the neighbouring row's data-pinned-position (never by counting
 *     nodes), and clamped to 0..count-1. Past the last row it parks at the
 *     end of Pinned; above the first conversation row it parks at 0.
 *   - The lifted row (base-100, shadow-md), the origin-slot outline
 *     (base-300 on the base-200 list ground) and the single 2px base-content
 *     drop line are drawn in an overlay child the server never patches
 *     (`phx-update="ignore"`). Nothing ever puts a transform on
 *     `[data-role=chat-list-row-wrap]`: ChatListSettle owns that.
 *   - Release pushes `move_pinned_row` only when the position changed, and
 *     the click that follows a completed drag is swallowed in the capture
 *     phase. Escape or pointercancel cancels with no push.
 *   - While the drag is live the row carries `data-editing="true"`, which
 *     keeps RowLongPress from opening the row sheet; a server patch strips
 *     JS-set attributes, so updated() and every move re-apply it.
 *   - A plain LiveView patch mid-drag (ChatListSettle's hold, a message
 *     arriving) keeps the drag alive: rows are re-read at every step and at
 *     the drop. The drag cancels only when the dragged row is gone.
 *   - Alt+ArrowUp / Alt+ArrowDown (no Ctrl, Meta or Shift) on a focused
 *     reorder row pushes `move_pinned_step`; focus returns to that row after
 *     the update.
 */

export const DRAG_THRESHOLD_PX = 4
export const LG_QUERY = "(min-width: 1024px)"
// The release click arrives right after pointerup; a drag that produced no
// click must not leave the swallow armed for the next real click.
export const SWALLOW_GRACE_MS = 250

export const ROW_SELECTOR = '[data-reorder="true"]'
export const SLOT_SELECTOR = "[data-pinned-position]"
export const OVERLAY_SELECTOR = '[data-role="pinned-reorder-overlay"]'
const NAME_SELECTOR = '[data-role="chat-list-row-name"]'

// Literal class strings, so Tailwind's source scan sees them. The origin
// slot is DELIBERATELY still on `border-base-300`: the design direction
// (canvas 01a17470) names a base-300 outline for it, and it is decorative
// (the drop line carries the position), so it is allowlisted in
// border_token_direction_test.exs rather than moved to `border-edge`.
const GHOST_CLASS = "absolute inset-x-0 overflow-hidden rounded-box bg-base-100 shadow-md"
const ORIGIN_CLASS = "absolute inset-x-0 rounded-box border border-base-300 bg-base-200"
const LINE_CLASS = "absolute right-0 h-0.5 bg-base-content"

export function desktop(win = globalThis.window) {
  return !!(win && typeof win.matchMedia === "function" && win.matchMedia(LG_QUERY).matches)
}

export const clamp = (value, lo, hi) => Math.min(hi, Math.max(lo, value))

const dragPointer = (e) => e.pointerType === "mouse" || e.pointerType === "pen"

const plainAlt = (e) => e.altKey && !e.ctrlKey && !e.metaKey && !e.shiftKey

const position = (node) => Number.parseInt(node.dataset.pinnedPosition, 10)

/**
 * The drop position. `slots` are the OTHER conversation rows in DOM order,
 * each `{position, top, bottom}`; `from` is the dragged row's position.
 * The slot is the number of midpoints above `y`; the neighbour before it
 * names the server position (removing the dragged row shifts the rows after
 * it up by one). Clamped to 0..count-1.
 */
export function dropPosition(slots, from, y, count) {
  let before = null
  for (const slot of slots) {
    if ((slot.top + slot.bottom) / 2 < y) before = slot
    else break
  }
  const raw = before === null ? 0 : before.position < from ? before.position + 1 : before.position
  return clamp(raw, 0, count - 1)
}

const PinnedReorder = {
  mounted() {
    this._drag = null
    this._swallow = false
    this._swallowTimer = null
    this._focusId = null

    this._onPointerDown = (e) => this._pointerDown(e)
    this._onDragStart = (e) => {
      if (e.target && typeof e.target.closest === "function" && e.target.closest(ROW_SELECTOR)) {
        e.preventDefault()
      }
    }
    this._onKeyDown = (e) => this._keyDown(e)

    this._onDocMove = (e) => this._move(e)
    this._onDocUp = (e) => this._up(e)
    this._onDocCancel = () => this._cancel()
    this._onDocKey = (e) => {
      if (e.key !== "Escape" || !this._drag) return
      if (this._drag.active) e.preventDefault()
      this._cancel()
    }
    this._onSelectStart = (e) => {
      if (this._drag && this._drag.active) e.preventDefault()
    }
    this._onClickCapture = (e) => {
      if (!this._swallow) return
      e.preventDefault()
      e.stopPropagation()
      this._clearSwallow()
    }

    this.el.addEventListener("pointerdown", this._onPointerDown)
    this.el.addEventListener("dragstart", this._onDragStart)
    this.el.addEventListener("keydown", this._onKeyDown)
  },

  updated() {
    if (this._focusId) this._restoreFocus()

    const drag = this._drag
    if (!drag) return

    const row = this._row(drag.spaceId)
    if (!row) {
      // Unpinned elsewhere mid-drag: nothing left to drop.
      this._cancel()
      return
    }

    if (drag.active) {
      row.setAttribute("data-editing", "true")
      this._render()
    }
  },

  destroyed() {
    this._cancel()
    this._clearSwallow()
    this.el.removeEventListener("pointerdown", this._onPointerDown)
    this.el.removeEventListener("dragstart", this._onDragStart)
    this.el.removeEventListener("keydown", this._onKeyDown)
  },

  // -- pointer --------------------------------------------------------------

  _pointerDown(e) {
    if (!desktop()) return
    if (!dragPointer(e)) return
    if (e.button !== undefined && e.button !== 0) return
    const row = e.target && typeof e.target.closest === "function" && e.target.closest(ROW_SELECTOR)
    if (!row) return

    this._cancel()
    this._drag = {
      spaceId: row.dataset.spaceId,
      pointerId: e.pointerId,
      startX: e.clientX,
      startY: e.clientY,
      y: e.clientY,
      active: false,
    }

    const doc = globalThis.document
    doc.addEventListener("pointermove", this._onDocMove)
    doc.addEventListener("pointerup", this._onDocUp)
    doc.addEventListener("pointercancel", this._onDocCancel)
    doc.addEventListener("keydown", this._onDocKey)
    doc.addEventListener("selectstart", this._onSelectStart)
  },

  _move(e) {
    const drag = this._drag
    if (!drag || !this._samePointer(e)) return
    drag.y = e.clientY

    if (!drag.active) {
      const dx = e.clientX - drag.startX
      const dy = e.clientY - drag.startY
      if (Math.hypot(dx, dy) < DRAG_THRESHOLD_PX) return
      if (!this._begin()) return
    }

    const row = this._row(drag.spaceId)
    if (!row) {
      this._cancel()
      return
    }
    row.setAttribute("data-editing", "true")
    this._render()
  },

  _up(e) {
    const drag = this._drag
    if (!drag || !this._samePointer(e)) return
    if (!drag.active) {
      // Under the threshold: an ordinary click, left alone.
      this._end()
      return
    }

    drag.y = e.clientY
    const target = this._target()
    this._end()
    this._armSwallow()

    if (target && target.to !== target.from) {
      this.pushEvent("move_pinned_row", { space_id: drag.spaceId, to_position: target.to })
    }
  },

  _samePointer(e) {
    const id = this._drag.pointerId
    return id === undefined || e.pointerId === undefined || e.pointerId === id
  },

  _begin() {
    const drag = this._drag
    const row = this._row(drag.spaceId)
    if (!row) {
      this._cancel()
      return false
    }

    const rect = row.getBoundingClientRect()
    drag.active = true
    drag.grab = drag.startY - rect.top
    drag.height = rect.bottom - rect.top
    row.setAttribute("data-editing", "true")

    try {
      if (drag.pointerId !== undefined && typeof row.setPointerCapture === "function") {
        row.setPointerCapture(drag.pointerId)
        drag.captured = row
      }
    } catch (_e) {
      // A synthetic or already-released pointer; the document listeners
      // still end the drag.
    }

    this._buildOverlay(row)
    return true
  },

  // Stop listening and clear the visuals, without pushing anything.
  _end() {
    const drag = this._drag
    this._drag = null
    if (!drag) return

    const doc = globalThis.document
    doc.removeEventListener("pointermove", this._onDocMove)
    doc.removeEventListener("pointerup", this._onDocUp)
    doc.removeEventListener("pointercancel", this._onDocCancel)
    doc.removeEventListener("keydown", this._onDocKey)
    doc.removeEventListener("selectstart", this._onSelectStart)

    if (drag.captured) {
      try {
        drag.captured.releasePointerCapture(drag.pointerId)
      } catch (_e) {
        // Already released by the browser on pointerup.
      }
    }

    if (drag.active) {
      const row = this._row(drag.spaceId)
      if (row) row.removeAttribute("data-editing")
      this._clearOverlay()
    }
  },

  _cancel() {
    this._end()
  },

  // -- geometry -------------------------------------------------------------

  _row(spaceId) {
    for (const row of this.el.querySelectorAll(ROW_SELECTOR)) {
      if (row.dataset.spaceId === spaceId) return row
    }
    return null
  },

  // Every conversation row the server rendered (draggable or restricted),
  // read fresh from the DOM, outside the overlay.
  _slotNodes() {
    const overlay = this._overlay()
    return [...this.el.querySelectorAll(SLOT_SELECTOR)].filter(
      (node) => !(overlay && overlay.contains(node))
    )
  },

  _target() {
    const drag = this._drag
    const row = this._row(drag.spaceId)
    if (!row) return null

    const from = position(row)
    const count = Number.parseInt(row.dataset.pinnedCount, 10)
    if (!Number.isInteger(from) || !Number.isInteger(count) || count < 1) return null

    const slots = this._slots(drag.spaceId)
    return { from, to: dropPosition(slots, from, drag.y, count), slots }
  },

  _slots(spaceId) {
    return this._slotNodes()
      .filter((node) => node.dataset.spaceId !== spaceId)
      .map((node) => {
        const rect = node.getBoundingClientRect()
        return { node, position: position(node), top: rect.top, bottom: rect.bottom }
      })
  },

  // -- overlay --------------------------------------------------------------

  _overlay() {
    return this.el.querySelector(OVERLAY_SELECTOR)
  },

  _buildOverlay(row) {
    const overlay = this._overlay()
    if (!overlay) return
    this._clearOverlay()
    const doc = globalThis.document

    const origin = doc.createElement("div")
    origin.className = ORIGIN_CLASS
    origin.setAttribute("data-role", "pinned-reorder-origin")

    const ghost = doc.createElement("div")
    ghost.className = GHOST_CLASS
    ghost.setAttribute("data-role", "pinned-reorder-ghost")
    ghost.appendChild(ghostCopy(row))

    const line = doc.createElement("div")
    line.className = LINE_CLASS
    line.setAttribute("data-role", "pinned-reorder-line")

    overlay.appendChild(origin)
    overlay.appendChild(ghost)
    overlay.appendChild(line)
    this._parts = { origin, ghost, line }
  },

  _clearOverlay() {
    const overlay = this._overlay()
    if (overlay) {
      while (overlay.firstChild) overlay.removeChild(overlay.firstChild)
    }
    this._parts = null
  },

  _render() {
    const drag = this._drag
    if (!drag || !drag.active) return
    const row = this._row(drag.spaceId)
    if (!row) return
    if (!this._parts || !this._parts.ghost.parentNode) this._buildOverlay(row)
    if (!this._parts) return

    const base = this.el.getBoundingClientRect().top
    const rowRect = row.getBoundingClientRect()
    const height = rowRect.bottom - rowRect.top
    const nodes = this._slotNodes()
    const tops = nodes.map((n) => n.getBoundingClientRect().top)
    const bottoms = nodes.map((n) => n.getBoundingClientRect().bottom)
    const bandTop = Math.min(...tops, rowRect.top)
    const bandBottom = Math.max(...bottoms, rowRect.bottom)

    const { origin, ghost, line } = this._parts

    origin.style.top = `${rowRect.top - base}px`
    origin.style.height = `${height}px`

    // The lifted row follows the pointer, and stays inside Pinned.
    const ghostTop = clamp(drag.y - drag.grab, bandTop, bandBottom - height)
    ghost.style.top = `${ghostTop - base}px`
    ghost.style.height = `${height}px`

    const target = this._target()
    if (!target) return
    const { slots, from } = target
    const before = slots.filter((s) => (s.top + s.bottom) / 2 < drag.y)
    const prev = before.length > 0 ? before[before.length - 1] : null
    const next = slots[before.length] || null
    // The gap between the neighbours; at the ends, the band's edge.
    const gapY = prev ? (next ? (prev.bottom + next.top) / 2 : prev.bottom) : next ? next.top : rowRect.top
    line.style.top = `${gapY - base - 1}px`
    line.style.left = `${textLeft(next ? next.node : prev ? prev.node : row, this.el)}px`
    line.setAttribute("data-to-position", String(target.to))
    line.setAttribute("data-from-position", String(from))
  },

  // -- click swallow --------------------------------------------------------

  _armSwallow() {
    this._clearSwallow()
    this._swallow = true
    globalThis.document.addEventListener("click", this._onClickCapture, true)
    this._swallowTimer = setTimeout(() => this._clearSwallow(), SWALLOW_GRACE_MS)
  },

  _clearSwallow() {
    if (this._swallowTimer) clearTimeout(this._swallowTimer)
    this._swallowTimer = null
    if (this._swallow) globalThis.document.removeEventListener("click", this._onClickCapture, true)
    this._swallow = false
  },

  // -- keyboard -------------------------------------------------------------

  _keyDown(e) {
    if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return
    if (!plainAlt(e)) return
    if (!desktop()) return
    if (this._drag && this._drag.active) return
    const row = e.target && typeof e.target.closest === "function" && e.target.closest(ROW_SELECTOR)
    if (!row) return

    e.preventDefault()
    const spaceId = row.dataset.spaceId
    this._focusId = spaceId
    this.pushEvent(
      "move_pinned_step",
      { space_id: spaceId, direction: e.key === "ArrowUp" ? "up" : "down" },
      () => this._restoreFocus()
    )
  },

  _restoreFocus() {
    const id = this._focusId
    this._focusId = null
    if (!id) return
    const row = this._row(id)
    if (row && globalThis.document.activeElement !== row && typeof row.focus === "function") {
      row.focus()
    }
  },
}

// The lifted copy: the row's look without its identity. No ids (they must
// stay unique), no data-* or hooks (nothing may mistake it for a row), and
// no fill classes (the ghost is base-100 whatever the row's state).
function ghostCopy(row) {
  const copy = row.cloneNode(true)
  scrub(copy)
  return copy
}

function scrub(node) {
  if (!node || node.nodeType !== 1) return
  for (const name of [...node.getAttributeNames()]) {
    if (name === "id" || name.startsWith("data-") || name.startsWith("phx-") || name === "href") {
      node.removeAttribute(name)
    }
  }
  if (node.tagName === "A" || node.tagName === "a") node.setAttribute("tabindex", "-1")
  const cls = node.getAttribute("class")
  if (cls) {
    const kept = cls.split(/\s+/).filter((c) => c && !/(^|:)bg-/.test(c))
    node.setAttribute("class", kept.join(" "))
  }
  for (const child of [...node.children]) scrub(child)
}

// The left edge of a row's text (its name), relative to the container.
function textLeft(node, container) {
  const name = node.querySelector ? node.querySelector(NAME_SELECTOR) : null
  const target = name || node
  return target.getBoundingClientRect().left - container.getBoundingClientRect().left
}

export default PinnedReorder
