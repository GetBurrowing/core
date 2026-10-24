// MessageActionsPopover: the desktop frame of the per-message actions
// (redesign rung 9 stage 2, task 01a1557a-9406; masters MD `openPop`).
//
// The popover is rendered once at the template root (`position: fixed`,
// `hidden lg:block`), from the same assign as the phone sheet, so this hook
// anchors it under the message's tap pill (or the row's top-right corner),
// flipping above when it does not fit. It re-anchors after every patch and
// on scroll and resize.
//
// Focus: on open it moves into the first row when the popover is visible
// (it is `display: none` below lg, where the Sheet hook owns focus). On
// close, in either frame, focus goes back to the message, which carries
// `tabindex="0"`, unless something else already took it.

const GAP = 6
const MARGIN = 8

// `offsetParent` is always null for a `position: fixed` element, so
// visibility is read from the layout boxes instead.
const visible = (el) => el.getClientRects().length > 0

export function place(anchorRect, size, viewport) {
  const maxLeft = viewport.width - size.width - MARGIN
  const left = Math.max(MARGIN, Math.min(anchorRect.right - size.width, maxLeft))
  let top = anchorRect.bottom + GAP
  if (top + size.height > viewport.height - MARGIN) {
    top = Math.max(MARGIN, anchorRect.top - size.height - GAP)
  }
  return { left, top }
}

const MessageActionsPopover = {
  mounted() {
    this.messageId = this.el.dataset.anchorMessageId
    this.onMove = () => this.position()
    window.addEventListener("scroll", this.onMove, true)
    window.addEventListener("resize", this.onMove)
    this.position()
    if (visible(this.el)) {
      const first = this.el.querySelector("button")
      if (first) first.focus({ preventScroll: true })
    }
  },

  updated() {
    this.messageId = this.el.dataset.anchorMessageId
    this.position()
  },

  destroyed() {
    window.removeEventListener("scroll", this.onMove, true)
    window.removeEventListener("resize", this.onMove)
    const row = this.row()
    const active = document.activeElement
    if (row && (!active || active === document.body || !document.contains(active))) {
      try { row.focus({ preventScroll: true }) } catch (_e) { /* gone */ }
    }
  },

  row() {
    const id = this.messageId
    return id ? document.querySelector(`[data-message-id="${id}"][phx-hook="MessageGestures"]`) : null
  },

  position() {
    const row = this.row()
    if (!row || !visible(this.el)) return
    const anchor = row.querySelector('[data-role="message-pill"]')
    const anchorRect = (anchor && visible(anchor) ? anchor : row).getBoundingClientRect()
    const { left, top } = place(
      anchorRect,
      { width: this.el.offsetWidth, height: this.el.offsetHeight },
      { width: window.innerWidth, height: window.innerHeight }
    )
    // Tailwind v4 translate utilities set `translate`, not `transform`.
    this.el.style.translate = "none"
    this.el.style.transform = "none"
    this.el.style.left = `${left}px`
    this.el.style.top = `${top}px`
  },
}

export default MessageActionsPopover
