/**
 * MessageContextPopover — the desktop frame of the "What this message is
 * answering" panel (task 01a0d8de stage 3).
 *
 * The panel is rendered once at the template root (`position: fixed`), so
 * this hook anchors it under the header of the message it describes, found
 * by the row's `data-message-id`. It re-anchors after every patch, because
 * a LiveView patch resets the inline style this hook writes, and on scroll
 * and resize so it travels with the row.
 *
 * Non-modal: no focus trap, no scrim. It closes on Escape (the element's
 * `phx-window-keydown`) and on a click outside it. A click on the actions
 * sheet's context row is not "outside": that click opens a panel itself, and
 * closing first would race it.
 */
const GAP = 4
const MARGIN = 8

const MessageContextPopover = {
  mounted() {
    this.returnFocus = document.activeElement

    this.onOutside = (e) => {
      if (this.el.contains(e.target)) return
      if (e.target.closest('[data-role="message-actions-context"]')) return
      this.pushEvent("close_message_context", {})
    }
    this.onMove = () => this.position()

    document.addEventListener("pointerdown", this.onOutside, true)
    window.addEventListener("scroll", this.onMove, true)
    window.addEventListener("resize", this.onMove)

    this.position()
    this.el.focus({ preventScroll: true })
  },

  updated() {
    this.position()
  },

  destroyed() {
    document.removeEventListener("pointerdown", this.onOutside, true)
    window.removeEventListener("scroll", this.onMove, true)
    window.removeEventListener("resize", this.onMove)

    const back = this.returnFocus
    if (back && document.contains(back) && document.activeElement === document.body) {
      try { back.focus({ preventScroll: true }) } catch (_e) { /* gone */ }
    }
  },

  position() {
    const id = this.el.dataset.anchorMessageId
    const row = id && document.querySelector(`[data-message-id="${id}"]`)
    const header = row && (row.querySelector(".message-header") || row)
    if (!header) return

    const rect = header.getBoundingClientRect()
    const width = this.el.offsetWidth
    const height = this.el.offsetHeight
    const maxLeft = window.innerWidth - width - MARGIN
    const left = Math.max(MARGIN, Math.min(rect.left, maxLeft))

    // Under the header when it fits, above it when it does not.
    let top = rect.bottom + GAP
    if (top + height > window.innerHeight - MARGIN) {
      top = Math.max(MARGIN, rect.top - height - GAP)
    }

    // Tailwind v4 translate utilities set `translate`, not `transform`.
    this.el.style.translate = "none"
    this.el.style.transform = "none"
    this.el.style.left = `${left}px`
    this.el.style.top = `${top}px`
  },
}

export default MessageContextPopover
