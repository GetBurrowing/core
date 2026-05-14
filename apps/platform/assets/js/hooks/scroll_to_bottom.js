// ScrollToBottom hook — scrolls a container to its bottom on mount and on
// each DOM update (i.e. when new messages arrive via phx-update="stream").
// Also applies Slack-style message grouping: consecutive messages from the
// same sender hide the avatar and sender name row.
//
// Date separators were previously injected here. They now live INSIDE
// each stream-managed message row (see chat_message.ex `:day_label`),
// because `#message-list` carries `phx-update="stream"` and morphdom
// strips any non-stream child nodes on each reconcile — defeating
// any JS-side incremental separator logic. The fix is structural:
// render the separator inside the row template so it inherits the
// row's stable phx-id.

const ScrollToBottom = {
  mounted() {
    // Resolve the real scroll container. The hook is sometimes mounted on a
    // wrapper element that is not itself the scroller (e.g. when the message
    // list is repositioned inside a layout that owns the `overflow-y-auto`).
    // Prefer an explicit `data-scroll-container` opt-in, fall back to the
    // shell `<main>`, and finally to `this.el` (preserves the current
    // chat_live.html.heex behaviour where #message-list is itself the
    // scroller).
    this.scrollEl =
      this.el.closest("[data-scroll-container]") ||
      this.el.closest("main") ||
      this.el;
    this._initialScroll = true;
    this._onUserScroll = () => {
      const distFromBottom =
        this.scrollEl.scrollHeight -
        this.scrollEl.scrollTop -
        this.scrollEl.clientHeight;
      if (distFromBottom > 300) {
        this._initialScroll = false;
      }
    };
    // MutationObserver fires when stream inserts new message rows
    this._observer = new MutationObserver(() => {
      this._safeUpdate();
    });
    this._safeUpdate();
    this._observer.observe(this.el, { childList: true, subtree: false });
  },
  _safeUpdate() {
    // Disconnect observer to prevent infinite loop from our own DOM changes
    if (this._observer) this._observer.disconnect();
    this.applyGrouping();
    this.scrollToBottom();
    // Reconnect after our changes are done
    if (this._observer) {
      this._observer.observe(this.el, { childList: true, subtree: false });
    }
  },
  updated() {
    this._safeUpdate();
  },
  destroyed() {
    if (this._observer) this._observer.disconnect();
    if (this._scrollListenerAdded && this.scrollEl && this._onUserScroll) {
      this.scrollEl.removeEventListener("scroll", this._onUserScroll);
      this._scrollListenerAdded = false;
    }
  },
  scrollToBottom() {
    // During initial load, always scroll to bottom. We keep _initialScroll true
    // until the user explicitly scrolls up, ensuring that late-arriving stream
    // content (messages rendered after mount) still triggers a snap to bottom.
    if (this._initialScroll) {
      this.scrollEl.scrollTop = this.scrollEl.scrollHeight;
      // Start listening for user scroll after first meaningful content
      if (
        this.scrollEl.scrollHeight > this.scrollEl.clientHeight &&
        !this._scrollListenerAdded
      ) {
        this._scrollListenerAdded = true;
        this.scrollEl.addEventListener("scroll", this._onUserScroll, {
          passive: true,
        });
      }
      return;
    }
    // After initial load, only auto-scroll if user is near the bottom
    const threshold = 150;
    const distanceFromBottom =
      this.scrollEl.scrollHeight -
      this.scrollEl.scrollTop -
      this.scrollEl.clientHeight;
    if (distanceFromBottom <= threshold) {
      this.scrollEl.scrollTop = this.scrollEl.scrollHeight;
    }
  },
  // Walk visible message rows; if the participant matches the previous row,
  // collapse the avatar + header for a compact grouped look.
  applyGrouping() {
    const rows = Array.from(this.el.querySelectorAll("[data-participant-id]"));
    let prevParticipantId = null;

    rows.forEach((row) => {
      const pid = row.dataset.participantId;
      const avatar = row.querySelector(".message-avatar");
      const header = row.querySelector(".message-header");

      if (pid && pid === prevParticipantId) {
        // Grouped — hide avatar and header, reduce top padding
        if (avatar) avatar.style.visibility = "hidden";
        if (header) header.style.display = "none";
        row.style.paddingTop = "1px";
      } else {
        // First in group — show avatar and header normally
        if (avatar) avatar.style.visibility = "";
        if (header) header.style.display = "";
        row.style.paddingTop = "";
      }

      prevParticipantId = pid || null;
    });
  },
};

export default ScrollToBottom;
