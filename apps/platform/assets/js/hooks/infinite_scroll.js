// InfiniteScroll hook — fires a load-older or load-newer event whenever a
// sentinel element scrolls into view, with scroll-anchor preservation so
// the user's visual position doesn't jump after a prepend.
//
// Mounted on TWO sentinel elements per chat space (task 019e18fc Stage 3):
//
//   <div :if={@has_more_older}
//        id="chat-scroll-sentinel-top"
//        phx-hook="InfiniteScroll"
//        data-direction="older"
//        data-loading={...}>
//
//   <div :if={@newest_evicted?}
//        id="chat-scroll-sentinel-bottom"
//        phx-hook="InfiniteScroll"
//        data-direction="newer"
//        data-loading={...}>
//
// The sentinels are RENDERED OUTSIDE the `phx-update="stream"` message
// list (Stage 2's `#message-list`), so they stay anchored across stream
// reconciles. Their `:if={…}` LV-side gating is what controls visibility:
// once :has_more_older is false the top sentinel disappears entirely
// (and so does the observer instance via destroyed()); same on the
// bottom for :newest_evicted?.
//
// Scroll-anchor preservation (older only):
// - Before the LV push, capture scrollContainer.scrollHeight and
//   scrollContainer.scrollTop.
// - After the LV reply re-renders the message list, restore
//   scrollContainer.scrollTop = preTop + (newHeight - preHeight).
// - Without this the prepend grows scrollHeight while scrollTop stays
//   constant → the user's anchor visually jumps upward.
// - For load-newer (appends to bottom), no anchor preservation is
//   required — the user is scrolling toward the new content anyway.

const InfiniteScroll = {
  mounted() {
    this.direction = this.el.dataset.direction;
    this.scrollEl =
      this.el.closest("[data-scroll-container]") ||
      this.el.closest("main") ||
      document.documentElement;

    // Guard so we don't fire multiple concurrent pushes while one is in
    // flight. The LV side toggles :loading_older / :loading_newer which
    // re-renders the sentinel's data-loading attr; we additionally
    // guard client-side because the LV update is async.
    this._inflight = false;

    // The realign-guard memory (see `_trigger`): every scroll event carries
    // the offset the reader actually moved to, so the last observed value
    // survives a patch that destroys the offset silently. Passive: this
    // listener never calls preventDefault.
    this._scrollObservedTop = this.scrollEl.scrollTop;
    this._onScrollObserved = () => {
      this._scrollObservedTop = this.scrollEl.scrollTop;
    };
    this.scrollEl.addEventListener("scroll", this._onScrollObserved, {
      passive: true,
    });

    this._observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          if (this._inflight) continue;
          if (this.el.dataset.loading === "true") continue;
          // A failed load waits for the reader's Retry (below) rather than
          // re-firing on the next intersection (task 01a13884 stage 4).
          if (this.el.dataset.failed === "true") continue;
          this._trigger();
        }
      },
      {
        root: this.scrollEl,
        // A small positive margin so we start fetching a touch before
        // the sentinel is fully visible — feels more responsive without
        // being overeager.
        rootMargin: "200px",
        threshold: 0,
      },
    );

    this._observer.observe(this.el);

    // "Couldn't load earlier messages. Retry" (task 01a13884 stage 4). The
    // retry goes through `_trigger` — not a bare phx-click — so it captures
    // and restores the reading position exactly like a scroll-fired load.
    this._onRetryClick = (event) => {
      const retry = event.target && event.target.closest
        ? event.target.closest('[data-role="load-older-retry"]')
        : null;
      if (!retry) return;
      event.preventDefault();
      if (!this._inflight) this._trigger();
    };
    if (this.el.addEventListener) {
      this.el.addEventListener("click", this._onRetryClick);
    }
  },

  destroyed() {
    if (this._onRetryClick && this.el.removeEventListener) {
      this.el.removeEventListener("click", this._onRetryClick);
      this._onRetryClick = null;
    }
    if (this._observer) {
      this._observer.disconnect();
      this._observer = null;
    }
    if (this._onScrollObserved) {
      this.scrollEl.removeEventListener("scroll", this._onScrollObserved);
      this._onScrollObserved = null;
    }
  },

  _trigger() {
    this._inflight = true;

    if (this.direction === "older") {
      // Capture pre-prepend scroll geometry so we can restore after the
      // LV update lands. The LV reply triggers a stream_insert which
      // grows scrollHeight; we add the delta back to scrollTop to keep
      // the user pinned on the previously-earliest visible message.
      //
      // ── The destructive-move capture guard (task 01a05873) ──────────
      // The live offset is not always the reader's offset. A LiveView
      // patch can RELOCATE the scroller (morphdom realigns a child list
      // that grew ahead of it by removing and re-inserting the keyed
      // nodes — measured on the canvases-drawer toggle), and a detached
      // scroller forgets its scroll offset: it re-inserts reading 0,
      // with NO scroll event. Capturing here would record 0 for a reader
      // parked thousands of pixels deep, and `_afterOlder`'s
      // compensation would then throw them to `0 + Δ`. So: if the live
      // offset is 0 while the last scroll-observed offset was not, the
      // offset was destroyed under the reader rather than scrolled away
      // — a genuine scroll to the top delivers scroll events, and with
      // rootMargin 200px this hook fires long before the live offset
      // could reach 0 on its own — and the memory is the only surviving
      // record of where the reader was. (The ScrollToBottom hook
      // repairs the offset itself when it is mounted; this guard covers
      // the capture when it is not.)
      const live = this.scrollEl.scrollTop;
      const preTop =
        live === 0 && this._scrollObservedTop > 0
          ? this._scrollObservedTop
          : live;
      this._preHeight = this.scrollEl.scrollHeight;
      this._preTop = preTop;
      this.pushEvent("load_older_messages", {}, () => this._afterOlder());
    } else if (this.direction === "newer") {
      // Appends to the bottom — no anchor preservation needed. The
      // ScrollToBottom hook handles snap-to-bottom when appropriate.
      this.pushEvent("load_newer_messages", {}, () => {
        this._inflight = false;
      });
    } else {
      // Unknown direction — log and bail. data-direction is set in the
      // .heex template; this branch only fires if the template wires
      // something unexpected.
      // eslint-disable-next-line no-console
      console.warn(
        "[InfiniteScroll] unknown data-direction:",
        this.direction,
      );
      this._inflight = false;
    }
  },

  _afterOlder() {
    // requestAnimationFrame lets morphdom finish committing the
    // stream-insert DOM mutations before we read scrollHeight. Without
    // this we read stale geometry and the user's anchor still jumps.
    requestAnimationFrame(() => {
      const newHeight = this.scrollEl.scrollHeight;
      const delta = newHeight - (this._preHeight || newHeight);
      if (delta > 0) {
        this.scrollEl.scrollTop = (this._preTop || 0) + delta;
      }
      this._inflight = false;
    });
  },
};

export default InfiniteScroll;
