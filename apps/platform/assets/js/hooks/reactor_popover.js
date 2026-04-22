// Reactor popover for a reaction pill (desktop only).
//
// On hover or focus of a reaction pill, render a small floating popover
// near it showing who reacted with that emoji. List is provided
// server-side via `data-reactors` JSON on the pill — no server
// round-trip per hover, and no eager DOM for every reactor (50
// reactors × many messages is hostile).
//
// Rendered as a portal to `document.body` so Phoenix LV's
// `stream_insert` replacing the message row does not tear down an
// open popover mid-interaction (matters for active surveys where
// reactions are arriving in real time).
//
// Mobile is intentionally no-op per product decision — touch users
// don't need reactor metadata, and the hover affordance is desktop-
// native. Screen reader accessibility is handled by `aria-label` on
// the pill itself, which carries the full reactor list as a string
// and works the same on every device.

const MOBILE_MATCH = "(hover: none)"
const CLOSE_DELAY_MS = 100

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[c])
}

const ReactorPopover = {
  mounted() {
    // Touch devices: skip entirely. Reactor metadata is desktop-only.
    if (window.matchMedia && window.matchMedia(MOBILE_MATCH).matches) return

    this._popover = null
    this._closeTimer = null

    this._onEnter = () => this.open()
    this._onLeave = () => this.scheduleClose()
    this._onFocus = () => this.open()
    this._onBlur = () => this.scheduleClose()
    this._onEsc = (e) => {
      if (e.key === "Escape") this.close()
    }

    this.el.addEventListener("mouseenter", this._onEnter)
    this.el.addEventListener("mouseleave", this._onLeave)
    this.el.addEventListener("focus", this._onFocus)
    this.el.addEventListener("blur", this._onBlur)
  },

  updated() {
    // When LiveView re-renders the pill (e.g. a reaction was added
    // and the stream re-inserted the message), refresh the popover
    // contents in place so an open popover stays accurate instead of
    // flickering or showing stale state.
    if (!this._popover) return
    this.renderInto(this._popover)
  },

  destroyed() {
    this.close({immediate: true})
    if (this._onEnter) {
      this.el.removeEventListener("mouseenter", this._onEnter)
      this.el.removeEventListener("mouseleave", this._onLeave)
      this.el.removeEventListener("focus", this._onFocus)
      this.el.removeEventListener("blur", this._onBlur)
    }
  },

  open() {
    this.cancelClose()
    if (this._popover) return

    const pop = document.createElement("div")
    pop.className = "reactor-popover"
    pop.setAttribute("role", "dialog")
    pop.setAttribute("aria-modal", "false")
    // Keep the popover out of hover-leave race: hovering the popover
    // itself cancels the close timer, so users can read/copy the list.
    pop.addEventListener("mouseenter", () => this.cancelClose())
    pop.addEventListener("mouseleave", () => this.scheduleClose())

    document.body.appendChild(pop)
    this._popover = pop

    this.renderInto(pop)
    this.position(pop)

    document.addEventListener("keydown", this._onEsc)
  },

  scheduleClose() {
    this.cancelClose()
    this._closeTimer = setTimeout(() => this.close(), CLOSE_DELAY_MS)
  },

  cancelClose() {
    if (this._closeTimer) {
      clearTimeout(this._closeTimer)
      this._closeTimer = null
    }
  },

  close({immediate = false} = {}) {
    this.cancelClose()
    if (!this._popover) return
    document.removeEventListener("keydown", this._onEsc)

    const pop = this._popover
    this._popover = null

    if (immediate) {
      if (pop.parentNode) pop.remove()
      return
    }

    pop.classList.add("reactor-popover-out")
    setTimeout(() => {
      if (pop.parentNode) pop.remove()
    }, 120)
  },

  renderInto(pop) {
    const emoji = this.el.dataset.emoji || ""
    const extra = parseInt(this.el.dataset.extraCount || "0", 10)
    let reactors = []
    try {
      reactors = JSON.parse(this.el.dataset.reactors || "[]")
    } catch {
      reactors = []
    }

    pop.setAttribute("aria-label", `Reactors for ${emoji}`)

    const rows = reactors.map((r) => {
      const agentBadge = r.is_agent
        ? `<span class="reactor-popover-agent" title="AI agent">AI</span>`
        : ""
      return `<li class="reactor-popover-row">${escapeHtml(r.name || "Someone")}${agentBadge}</li>`
    }).join("")

    const overflow = extra > 0
      ? `<li class="reactor-popover-overflow">and ${extra} other${extra === 1 ? "" : "s"}</li>`
      : ""

    pop.innerHTML =
      `<div class="reactor-popover-head">Reacted with ${escapeHtml(emoji)}</div>` +
      `<ul class="reactor-popover-list">${rows}${overflow}</ul>`
  },

  position(pop) {
    const rect = this.el.getBoundingClientRect()
    const popRect = pop.getBoundingClientRect()

    const gap = 8
    const maxLeft = window.innerWidth - popRect.width - gap
    const left = Math.max(
      gap,
      Math.min(maxLeft, rect.left + rect.width / 2 - popRect.width / 2),
    )

    // Prefer above the pill; flip below if not enough room.
    const above = rect.top - popRect.height - gap
    const below = rect.bottom + gap
    const top = above >= gap ? above : below

    pop.style.position = "fixed"
    pop.style.left = `${left}px`
    pop.style.top = `${top}px`
    pop.style.zIndex = "80"
  },
}

export default ReactorPopover
