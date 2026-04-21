// Companion hook to `LongpressMenu`. When the server-side
// `:longpress_menu_for` assign flips to a message id, the menu fragment
// renders and this hook mounts on it. The hook:
//
//   1. Finds the target message bubble via `data-target-message-id`.
//   2. Clones the target DOM, positions the clone at the original rect
//      via `position: fixed`, and appends it to `document.body`. Inline
//      styles and Tailwind classes are preserved by `cloneNode(true)`.
//   3. Dims the original in place so the clone looks like "the" message
//      has been lifted out of the chat flow.
//   4. On the next animation frame, adds a `.lifted` class that applies
//      a CSS transition to translate the clone to the viewport center
//      and scale up slightly (~1.02).
//
// On destruction (scrim tap or action click closes the menu), we reverse
// the animation, restore the original's opacity, and remove the clone
// after the CSS transition completes.
//
// Scrim blur + emoji pill render through regular LV in the menu
// fragment — see chat_live.html.heex.

const MessageLift = {
  mounted() {
    const targetId = this.el.dataset.targetMessageId
    if (!targetId) return

    const target = document.querySelector(`[data-message-id="${targetId}"]`)
    if (!target) return

    const rect = target.getBoundingClientRect()

    // Dim the original immediately to prevent a double-render flash.
    target.dataset.messageLiftOrigOpacity = target.style.opacity || ""
    target.dataset.messageLiftOrigPointerEvents = target.style.pointerEvents || ""
    target.style.opacity = "0.25"
    target.style.pointerEvents = "none"

    const clone = target.cloneNode(true)
    clone.classList.add("message-lift")
    // Strip the hook attribute so the clone doesn't get mounted as a
    // LongpressMenu hook by LiveView.
    clone.removeAttribute("phx-hook")
    clone.removeAttribute("id")
    clone.style.position = "fixed"
    clone.style.left = `${rect.left}px`
    clone.style.top = `${rect.top}px`
    clone.style.width = `${rect.width}px`
    clone.style.margin = "0"
    clone.style.zIndex = "60"
    clone.style.pointerEvents = "none"

    const centerX = window.innerWidth / 2
    const centerY = window.innerHeight / 2
    const targetCenterX = rect.left + rect.width / 2
    const targetCenterY = rect.top + rect.height / 2
    const dx = centerX - targetCenterX
    const dy = centerY - targetCenterY

    clone.style.setProperty("--lift-dx", `${dx}px`)
    clone.style.setProperty("--lift-dy", `${dy}px`)

    // Expose the clone's post-lift half-height to the LV menu fragment so
    // the emoji pill (above the clone) can position itself relative to
    // where the clone lands. 1.02 matches the CSS scale on
    // .message-lift.lifted. The action card below the clone was removed
    // when long-press became double-tap — see longpress_menu.js.
    this.el.style.setProperty("--clone-half-h", `${(rect.height * 1.02) / 2}px`)

    document.body.appendChild(clone)

    // Lock background scroll while the menu is open. Restored in destroyed().
    this._prevBodyOverflow = document.body.style.overflow
    document.body.style.overflow = "hidden"

    // Close on ESC (desktop/tablet keyboard) and on any viewport geometry
    // change — orientation flip, window resize, or the iOS visualViewport
    // changing. Positions are stale once the viewport has shifted; safer
    // to dismiss than to try to re-measure mid-animation.
    this._onKey = (e) => {
      if (e.key === "Escape") this.pushEvent("close_longpress_menu", {})
    }
    this._onViewport = () => this.pushEvent("close_longpress_menu", {})

    window.addEventListener("keydown", this._onKey)
    window.addEventListener("resize", this._onViewport)
    window.addEventListener("orientationchange", this._onViewport)

    // Force a reflow, then add the class so the transition fires.
    void clone.offsetWidth
    requestAnimationFrame(() => clone.classList.add("lifted"))

    this._clone = clone
    this._target = target
  },

  destroyed() {
    if (this._onKey) window.removeEventListener("keydown", this._onKey)
    if (this._onViewport) {
      window.removeEventListener("resize", this._onViewport)
      window.removeEventListener("orientationchange", this._onViewport)
    }

    if (this._prevBodyOverflow !== undefined) {
      document.body.style.overflow = this._prevBodyOverflow
      this._prevBodyOverflow = undefined
    }

    const clone = this._clone
    const target = this._target
    if (!clone || !target) return

    const cleanup = () => {
      if (clone.parentNode) clone.remove()
    }

    clone.addEventListener("transitionend", cleanup, { once: true })
    // Safety: even if transitionend doesn't fire (user navigates mid-animation),
    // force-remove after 400ms.
    setTimeout(cleanup, 400)

    clone.classList.remove("lifted")

    target.style.opacity = target.dataset.messageLiftOrigOpacity || ""
    target.style.pointerEvents = target.dataset.messageLiftOrigPointerEvents || ""
    delete target.dataset.messageLiftOrigOpacity
    delete target.dataset.messageLiftOrigPointerEvents

    this._clone = null
    this._target = null
  },
}

export default MessageLift
