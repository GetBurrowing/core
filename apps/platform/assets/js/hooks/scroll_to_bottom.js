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
//
// Scroll preservation (task 019f51d1) — two protections against silently
// discarding the user's reading position:
//
// 1. Snaps are gated. The initial-load phase hard-snaps to bottom and ends
//    the first time the container actually overflows; from then on a snap
//    only fires when the user is already within NEAR_BOTTOM_PX of the
//    bottom. (Previously the initial phase persisted until the user
//    scrolled >300px up, which made every later update an unconditional
//    yank-to-bottom for anyone who hadn't.)
//
// 3. Deep-link arrival is held (task 019fabe8 stage 3). When
//    `handle_params/3` accepts a `?message=<id>` link it renders
//    `data-anchor-message-id` on `#message-list`, in the SAME diff as
//    the anchored window. While that attribute names a row we have not
//    yet honoured, `scrollToBottom()` centres that row and returns
//    without snapping — otherwise the initial-scroll phase above would
//    yank the reader to the bottom on every async stream batch, after
//    `chat:scroll-to-message` has already run. Honoured once per id;
//    an absent attribute or an unresolvable row leaves the existing
//    behaviour exactly as it was.
//
// 4. Rail collapse is reflow-anchored. Toggling the sidebar animates a
//    168px width change; chat text rewraps, scrollHeight changes, and the
//    browser clamps/re-anchors scrollTop — observed in prod as the pane
//    snapping to bottom. On `sidebar_collapsed_changed` this hook holds the
//    user's distance-from-bottom constant on every animation frame for the
//    duration of the width transition. The scroller also carries
//    `[overflow-anchor:none]` (chat_live.html.heex) so native anchoring
//    doesn't fight this hook or InfiniteScroll's manual prepend anchoring.

const NEAR_BOTTOM_PX = 150;
// The rail width transition is 200ms (icon_rail.ex). Hold a little past it
// to cover post-transition layout settle; also covers reduced-motion (0ms).
const REFLOW_HOLD_MS = 400;

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
    this._holdFrame = null;
    // Message id whose arrival position has already been honoured, so a
    // later stream batch doesn't re-centre a reader who has since
    // scrolled away.
    this._anchoredFor = null;

    this.handleEvent("sidebar_collapsed_changed", () =>
      this.holdAnchorThroughReflow(),
    );

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
    if (this._holdFrame) cancelAnimationFrame(this._holdFrame);
  },
  distanceFromBottom() {
    return (
      this.scrollEl.scrollHeight -
      this.scrollEl.scrollTop -
      this.scrollEl.clientHeight
    );
  },
  // Centre the deep-link target instead of snapping, at most once per
  // id. Returns true when the arrival position was taken, i.e. when the
  // caller must NOT snap. Every early return leaves the pre-existing
  // scroll behaviour untouched.
  honourAnchor() {
    const id = this.el.dataset.anchorMessageId;
    if (!id || this._anchoredFor === id) return false;

    // The row may not be in the DOM yet — stream batches land async
    // after mount. Falling through means today's bottom snap runs, and
    // the next mutation gets another chance to anchor.
    const target = this.el.querySelector(`[data-message-id="${id}"]`);
    if (!target) return false;

    target.scrollIntoView({ block: "center" });
    this._anchoredFor = id;
    // End the initial-snap phase explicitly. It normally ends only once
    // the container overflows; leaving it open would re-snap on the
    // very next stream batch and undo the arrival.
    this._initialScroll = false;
    return true;
  },
  scrollToBottom() {
    if (this.honourAnchor()) return;

    if (this._initialScroll) {
      this.scrollEl.scrollTop = this.scrollEl.scrollHeight;
      // The initial phase ends once the container actually overflows —
      // stream batches land async after mount, and each gets the hard
      // snap until there is real scrollable content to anchor against.
      if (this.scrollEl.scrollHeight > this.scrollEl.clientHeight) {
        this._initialScroll = false;
      }
      return;
    }
    // After initial load, only auto-scroll if the user is near the bottom
    if (this.distanceFromBottom() <= NEAR_BOTTOM_PX) {
      this.scrollEl.scrollTop = this.scrollEl.scrollHeight;
    }
  },
  // Pin the user's distance-from-bottom through the rail width transition.
  // At the bottom the pin degenerates to bottom-stick (dist 0), which is
  // what a bottom-anchored reader expects during a reflow.
  holdAnchorThroughReflow() {
    const dist = this.distanceFromBottom();
    const deadline = performance.now() + REFLOW_HOLD_MS;
    if (this._holdFrame) cancelAnimationFrame(this._holdFrame);

    const hold = () => {
      this.scrollEl.scrollTop =
        this.scrollEl.scrollHeight - this.scrollEl.clientHeight - dist;
      if (performance.now() < deadline) {
        this._holdFrame = requestAnimationFrame(hold);
      } else {
        this._holdFrame = null;
      }
    };
    hold();
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
