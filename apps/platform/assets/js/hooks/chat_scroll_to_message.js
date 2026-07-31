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
