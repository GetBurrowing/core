/**
 * ChatScrollToMessage — listens for `chat:scroll-to-message` push events
 * (task 019e0f29 Stage 6, contract Section D.4) and scrolls the message
 * stream to the target message id, then applies a brief 1.5s pulse so
 * the user can locate it.
 *
 * Mounted on a hidden `<div id="chat-scroll-to-message-listener">`
 * placed once in `chat_live.html.heex`. The LV's
 * `scroll_to_message` handle_event pushes the event with the target
 * message id; this hook handles client-side scroll + pulse.
 */
const ChatScrollToMessage = {
  mounted() {
    this.handleEvent("chat:scroll-to-message", ({ id }) =>
      this.scrollToMessage(id, true),
    )
    // "Jump to message" from the Context panel (task 01a0d8de stage 3). The
    // server patches to `?message=<id>`, whose anchored window and
    // `chat:scroll-to-message` put the row on screen; this marks it with the
    // jump highlight and moves focus to it for keyboard and screen-reader
    // users. The row may land a few frames after this event when the window
    // is reloaded around it, so the lookup retries, bounded.
    this.handleEvent("chat:message-jump", ({ id }) => this.markJump(id, 10))
  },

  markJump(id, framesLeft) {
    const target = document.querySelector(`[data-message-id="${id}"]`)
    if (!target) {
      if (framesLeft > 0) requestAnimationFrame(() => this.markJump(id, framesLeft - 1))
      return
    }

    target.classList.remove("chat-message-jump")
    // Restart the fade when the same row is jumped to twice in a row.
    void target.offsetWidth
    target.classList.add("chat-message-jump")
    if (!target.hasAttribute("tabindex")) target.setAttribute("tabindex", "-1")
    try { target.focus({ preventScroll: true }) } catch (_e) { /* detached */ }
    clearTimeout(this._jumpTimer)
    this._jumpTimer = setTimeout(() => target.classList.remove("chat-message-jump"), 2200)
  },
  // `retry` covers the deep-link race (task 019fabe8 stage 3): the LV
  // pushes this event in the same reply as the anchored window, so the
  // event can be handled a frame before morphdom has patched the target
  // row in. Previously that meant the pulse was silently dropped. One
  // retry on the next animation frame is enough — the stream patch and
  // the event ride the same message — and bounding it at one keeps a
  // genuinely absent target (deleted, evicted) from looping.
  scrollToMessage(id, retry) {
    const target = document.querySelector(`[data-message-id="${id}"]`)
    if (!target) {
      if (retry) requestAnimationFrame(() => this.scrollToMessage(id, false))
      return
    }

    target.scrollIntoView({ behavior: "smooth", block: "center" })
    target.classList.add("chat-message-pulse")
    setTimeout(() => target.classList.remove("chat-message-pulse"), 1500)
  }
}

export default ChatScrollToMessage
