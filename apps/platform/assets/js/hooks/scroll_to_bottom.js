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

// 5. Jump-to-latest distance is EDGE-triggered (task 01a03c76). The server
//    owns the chip's visibility, so it needs to know where the reader is —
//    but a round trip per scroll event is the wrong shape. `_reportDistance()`
//    pushes only when one of the reported booleans flips.
//
//    It reports TWO of them (task 01a0419a stage 4), because visibility is no
//    longer the same question as auto-scroll. See the constants below.

// ── The two scroll thresholds ───────────────────────────────────────────────
//
// These two are ORDERED, NOT INDEPENDENT: `DEEP_HISTORY_PX` must be strictly
// greater than `NEAR_BOTTOM_PX`, and the module refuses to load otherwise (see
// the check below the declarations). They are tuned by different methods —
// one is the follow rule's boundary, the other was measured in a browser — so
// nothing about how they are chosen keeps them in order.
//
// PROVENANCE — do not "simplify" this back to one threshold.
// The two-threshold rule was PROPOSED, then WITHDRAWN by Saru in revision 3 of
// the design canvas, and then REINSTATED BY ROWAN DIRECTLY when he said the
// deep case is not the same as reading a few messages up. That is the
// decision-maker overruling a withdrawal, not a withdrawn proposal drifting
// back in through a side door. Collapsing the two constants into one is a
// one-line change that restores behaviour Rowan explicitly rejected, and it
// looks like tidying. It is not.
//
// `NEAR_BOTTOM_PX` is the FOLLOW boundary: at or under it, an arriving message
// scrolls into view and the reader is treated as watching the live edge.
// It is deliberately unchanged; raising it to fix a visibility complaint would
// silently move the auto-scroll decision, which is the class of bug task
// 01a0419a stage 1 just removed.
const NEAR_BOTTOM_PX = 150;

// `DEEP_HISTORY_PX` is the VISIBILITY boundary for a reader with nothing new
// waiting, and it exists so "scrolled up a bit" and "lost in history" stop
// being the same state.
//
// TUNED IN-BROWSER, at 390x844 against a seeded conversation of 146 real
// messages (mixed one-liners and multi-paragraph bodies; median row 83px,
// mean 84px, tallest 132px) with the message pane measuring 564px tall.
// WHAT WAS ACTUALLY OBSERVED, at that fixture's row heights:
//
//     150px  = 0.27 screens,  ~2 messages below the fold   (the follow edge)
//     900px  = 1.60 screens, ~11 messages below the fold
//    1800px  = 3.19 screens, ~22 messages below the fold
//    2400px  = 4.26 screens, ~29 messages below the fold
//
// At 1800px the tip sits a little over THREE screens and about twenty-two
// messages below the viewport — that reads as "deep in history", where getting
// back to the live edge is a deliberate flick-flick-flick rather than a
// glance. At 900px it is one and a half screens and eleven messages, which is
// still recognisably "I scrolled up to re-read something" — exactly the state
// Rowan said must NOT raise the pill on its own. 2400px was rejected the other
// way: by four screens the reader is deep enough that the pill has stopped
// being an offer and started being late.
//
// The desktop pane measures 730px on the same box, so 1800px is ~2.5 screens
// there — still comfortably past "a few messages up", which is why one
// constant serves both widths.
const DEEP_HISTORY_PX = 1800;

// The middle band — past NEAR_BOTTOM_PX, short of DEEP_HISTORY_PX — is the
// whole visibility half of this change: there the pill appears ONLY when
// something actually arrived. If a later edit lands DEEP_HISTORY_PX at or
// below NEAR_BOTTOM_PX that band collapses to zero width SILENTLY: no error,
// no failing assertion, just the pill reappearing on every scroll-up, which is
// the behaviour the ticket exists to remove. So it is a load-time throw rather
// than a test — a test can be deleted, this binds the edit itself.
//
// WHAT THIS DOES AND DOES NOT COVER: it throws when the module is EXECUTED, so
// a developer running the app meets it on the first page load. It is NOT a
// pipeline guarantee — CI runs no JavaScript at all, and a bundle containing
// an inverted pair builds perfectly clean. The exposure is small because you
// cannot tune DEEP_HISTORY_PX without running the app, and whoever does meets
// the throw immediately; that is why this is the right mechanism and why no
// build-time check is warranted for a constant only a human can set.
if (DEEP_HISTORY_PX <= NEAR_BOTTOM_PX) {
  throw new Error(
    `scroll_to_bottom: DEEP_HISTORY_PX (${DEEP_HISTORY_PX}) must be strictly ` +
      `greater than NEAR_BOTTOM_PX (${NEAR_BOTTOM_PX}); at or below it the ` +
      `middle visibility band collapses and the jump pill reappears on every ` +
      `scroll-up.`,
  );
}
// The initial-arrival phase ends when layout has been quiet for this long.
// Fonts, images, tables and code-block scrollers all settle within a few
// frames of each other; 250ms of no size change means the conversation has
// finished arriving. See `_endInitialPhase`.
const SETTLE_QUIET_MS = 250;
// Absolute ceiling on the arrival phase, so a container that never stops
// resizing (a live-updating embed, a pathological image) cannot hold the
// reader pinned forever.
const SETTLE_MAX_MS = 3000;
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
    this._holdFrame = null;
    // Seeds `_spaceId`, `_initialScroll` and `_anchoredFor`, and arms the
    // ResizeObserver. `updated()` calls the SAME method when the rendered
    // conversation changes, so there is exactly one definition of what
    // "entering a conversation" means and the two entry paths cannot drift.
    this._beginConversation(this.el.dataset.spaceId ?? null);

    this.handleEvent("sidebar_collapsed_changed", () =>
      this.holdAnchorThroughReflow(),
    );

    // A reader who takes control during the arrival phase must keep it.
    // Deliberately NOT the "scroll" event: our own `scrollTop` assignments
    // fire that too, so it cannot distinguish the reader from the hook and
    // would end the phase on the very first snap. These three are only ever
    // produced by a person.
    this._onUserIntent = () => this._endInitialPhase("user gesture");
    for (const evt of ["wheel", "touchmove", "keydown"]) {
      this.scrollEl.addEventListener(evt, this._onUserIntent, {
        passive: true,
      });
    }

    // The chip's own click round-trips through the server, which pushes this
    // back down. Re-reporting immediately means the server learns `away:
    // false` in the SAME interaction, so the chip leaves without waiting for
    // a scroll event that a programmatic scrollTop write may never produce.
    this.handleEvent("chat:scroll-to-latest", () => {
      this.scrollEl.scrollTop = this.scrollEl.scrollHeight;
      this._reportDistance();
    });

    // Passive: this listener never calls preventDefault, and a non-passive
    // scroll listener blocks the compositor. rAF-coalesced so a flung
    // scroller evaluates the predicate at most once per frame.
    this._scrollFrame = null;
    this._onScroll = () => {
      if (this._scrollFrame) return;
      this._scrollFrame = requestAnimationFrame(() => {
        this._scrollFrame = null;
        this._reportDistance();
      });
    };
    this.scrollEl.addEventListener("scroll", this._onScroll, { passive: true });

    // Defined so the first `updated()` and every non-patch caller
    // (ResizeObserver, settle timer, mount) read a defined value. `null`
    // means "no pre-patch capture" and selects the live measurement.
    this._preUpdateDistance = null;

    // MutationObserver fires when stream inserts new message rows
    this._observer = new MutationObserver(() => {
      this._safeUpdate();
    });

    // iOS PWA cold-launch fix (task 019ff6c9):
    // On iOS Safari in standalone (PWA) mode, mounted() fires before the
    // browser has completed its initial layout pass. scrollHeight is
    // inaccurate at this point, so the view lands mid-conversation.
    // The MutationObserver only catches new childList additions, but on
    // cold launch the nodes are already present — just not laid out yet.
    //
    // ResizeObserver detects when the container's dimensions stabilize
    // after fonts, images, and layout settle. We keep snapping to bottom
    // during the initial phase, then disconnect once stable.
    // Wrap the first scrollToBottom in rAF so the browser has done at
    // least one layout pass before we read scrollHeight.
    requestAnimationFrame(() => {
      this._safeUpdate();
      this._reportDistance();
    });

    // One-shot fallback for iOS Safari standalone mode: it sometimes
    // reports incorrect scrollHeight before the first paint completes.
    this._iosFallbackTimer = setTimeout(() => {
      this._iosFallbackTimer = null;
      if (this._initialScroll) {
        this.scrollEl.scrollTop = this.scrollEl.scrollHeight;
      }
    }, 100);

    this._safeUpdate();
    this._observer.observe(this.el, { childList: true, subtree: false });
  },
  // Entering a conversation — on mount, and again whenever `updated()`
  // observes `data-space-id` take a NEW value. Both callers get the same
  // state, including a freshly armed ResizeObserver: the observer is
  // disconnected the moment the initial phase ends (`honourAnchor`,
  // `scrollToBottom`), so flipping `_initialScroll` alone would leave the
  // iOS / late-layout re-snap protection dead from conversation two on.
  // Captured BEFORE LiveView patches the DOM. See `beforeUpdate`.
  //
  // "At the bottom" and "scrolled up by hand" are different states even at
  // the same pixel offset. At the bottom you are following the conversation
  // and a new message should simply arrive — you should never have to scroll
  // to see the thing you were already watching for. Scrolling up is an act of
  // intent: you are reading history and must not be yanked down. The
  // jump-to-latest pill serves that second case and only that one.
  //
  // Measured after the patch, the two states are indistinguishable: the
  // arriving message has already grown the scroller, so a reader who was at
  // distance 0 measures at the new message's HEIGHT. Short message, under
  // NEAR_BOTTOM_PX: follows (the only case any pre-existing fixture built).
  // Tall message, over NEAR_BOTTOM_PX: declines to follow AND raises the
  // pill — the exact defect this capture exists to remove. Raising
  // NEAR_BOTTOM_PX is not a fix; it only moves the message height at which
  // the bug returns, and that constant is simultaneously the pill's
  // visibility boundary.
  beforeUpdate() {
    this._preUpdateDistance = this.distanceFromBottom();
  },
  _beginConversation(spaceId) {
    this._spaceId = spaceId;
    this._initialScroll = true;
    // Message id whose arrival position has already been honoured, so a
    // later stream batch doesn't re-centre a reader who has since
    // scrolled away. Cleared here so a deep link into a DIFFERENT space is
    // honoured on arrival.
    this._anchoredFor = null;
    this._clearSettleTimers();
    this._settleCeiling = setTimeout(
      () => this._endInitialPhase("ceiling"),
      SETTLE_MAX_MS,
    );

    // Forget what the server was last told. A `patch=` switch re-renders the
    // list in place and the server's per-conversation state starts fresh, so
    // the first evaluation after a switch must always push rather than being
    // suppressed by the previous conversation's boolean.
    this._lastAway = null;
    this._lastDeep = null;
    this._connectResizeObserver();
  },
  // iOS PWA cold-launch fix (task 019ff6c9): ResizeObserver detects when the
  // container's dimensions stabilize after fonts, images and layout settle.
  // Keep snapping during the initial phase, then disconnect once stable.
  _connectResizeObserver() {
    if (typeof ResizeObserver === "undefined") return;
    this._disconnectResizeObserver();
    this._resizeObserver = new ResizeObserver(() => {
      if (this._initialScroll) {
        // Still arriving: hold the reader at the live edge as content grows
        // underneath, and treat the resize as evidence that layout has not
        // settled yet.
        this.scrollEl.scrollTop = this.scrollEl.scrollHeight;
        this._armSettleTimer();
      } else {
        // Initial phase ended — no longer needed
        this._disconnectResizeObserver();
      }
    });
    this._resizeObserver.observe(this.scrollEl);
  },
  // Restart the quiet-period countdown. Called on every snap and every
  // observed resize during the arrival phase, so the phase ends only once
  // layout has genuinely stopped moving.
  _armSettleTimer() {
    if (!this._initialScroll) return;
    if (this._settleTimer) clearTimeout(this._settleTimer);
    this._settleTimer = setTimeout(
      () => this._endInitialPhase("settled"),
      SETTLE_QUIET_MS,
    );
  },
  // End the arrival phase exactly once, from whichever of the three reasons
  // gets there first: layout went quiet, the ceiling expired, or the reader
  // took control with a real gesture. Idempotent — `honourAnchor` and
  // `destroyed` both call it.
  _endInitialPhase(_reason) {
    if (!this._initialScroll) return;
    this._initialScroll = false;
    this._clearSettleTimers();
    this._disconnectResizeObserver();
  },
  _clearSettleTimers() {
    if (this._settleTimer) {
      clearTimeout(this._settleTimer);
      this._settleTimer = null;
    }
    if (this._settleCeiling) {
      clearTimeout(this._settleCeiling);
      this._settleCeiling = null;
    }
  },
  _disconnectResizeObserver() {
    if (this._resizeObserver) {
      this._resizeObserver.disconnect();
      this._resizeObserver = null;
    }
  },
  _safeUpdate() {
    // One reading for BOTH decisions. The follow rule and the pill predicate
    // must not disagree in the very frame this capture exists to correct.
    const preDistance = this._preUpdateDistance;
    // Disconnect observer to prevent infinite loop from our own DOM changes
    if (this._observer) this._observer.disconnect();
    this.applyGrouping();
    this.scrollToBottom(preDistance);
    // Reconnect after our changes are done
    if (this._observer) {
      this._observer.observe(this.el, { childList: true, subtree: false });
    }
    // An arriving message grows the scroller, which moves the reader further
    // from the bottom without any scroll event firing. Re-evaluate here or
    // the chip never appears for a stationary reader.
    this._reportDistance(preDistance);
  },
  updated() {
    // A `patch=` navigation to another channel/DM re-renders `#message-list`
    // in place: same DOM id, same hook instance, so `mounted()` does NOT
    // re-run and the initial-snap phase would stay spent from page load. Only
    // an ACTUAL change of value resets — `updated()` fires on every stream
    // batch within one conversation, and resetting there would reinstate the
    // unconditional yank-to-bottom that task 019f51d1 removed (see header).
    const spaceId = this.el.dataset.spaceId ?? null;
    if (spaceId !== this._spaceId) this._beginConversation(spaceId);

    this._safeUpdate();
    // Release the capture once this patch is fully serviced. Queued as a
    // microtask so a MutationObserver callback for the same patch still sees
    // it, while later rAF / timer / ResizeObserver paths — which are not
    // DOM-patch-driven and whose live measurement IS the reader's position —
    // fall back to measuring.
    queueMicrotask(() => {
      this._preUpdateDistance = null;
    });
  },
  destroyed() {
    if (this._onUserIntent) {
      for (const evt of ["wheel", "touchmove", "keydown"]) {
        this.scrollEl.removeEventListener(evt, this._onUserIntent);
      }
      this._onUserIntent = null;
    }
    this._clearSettleTimers();
    if (this._observer) this._observer.disconnect();
    if (this._onScroll) {
      this.scrollEl.removeEventListener("scroll", this._onScroll);
      this._onScroll = null;
    }
    if (this._scrollFrame) {
      cancelAnimationFrame(this._scrollFrame);
      this._scrollFrame = null;
    }
    if (this._holdFrame) cancelAnimationFrame(this._holdFrame);
    this._disconnectResizeObserver();
    if (this._iosFallbackTimer) {
      clearTimeout(this._iosFallbackTimer);
      this._iosFallbackTimer = null;
    }
  },
  // Edge-triggered report of the reader's position, as TWO booleans.
  // Deliberately NOT a per-scroll-event push: the server only cares about the
  // transitions, and the `_lastAway` / `_lastDeep` pair makes a
  // stationary reader silent.
  //
  // WHY TWO. `away` answers the FOLLOW question — is the reader watching the
  // live edge? It stays pinned to NEAR_BOTTOM_PX, the same constant
  // `scrollToBottom()` thresholds against and read from the same captured
  // distance, so the follow rule and the count rule cannot disagree in the one
  // frame that matters. `deep` answers a genuinely different question — is the
  // reader far enough into history that the way back is worth offering
  // unprompted? Overloading NEAR_BOTTOM_PX for both is what would let
  // visibility and auto-scroll drift apart again.
  //
  // The server composes the five bands from these two plus its own unread
  // count (see `MessagesHooks.jump_chip_visible?/3`):
  //
  //   at the bottom              → follow the message, never a pill
  //   shallow, nothing new       → NOTHING
  //   shallow, message arrived   → pill WITH badge
  //   deep, nothing new          → pill, no badge
  //   deep, message arrived      → pill WITH badge
  //
  // `preDistance` is the pre-patch capture on the DOM-patch path, and
  // null/undefined everywhere else (scroll events, the chip's own click),
  // where the live measurement already is the reader's position.
  _reportDistance(preDistance) {
    const distance = preDistance ?? this.distanceFromBottom();
    const away = distance > NEAR_BOTTOM_PX;
    const deep = distance > DEEP_HISTORY_PX;
    // Edge-triggered on the PAIR. Either flipping is a real transition: a
    // reader crossing out of the deep band changes what the server renders
    // even though `away` never moved.
    if (away === this._lastAway && deep === this._lastDeep) return;
    const hadPrevious = this._lastAway !== null;
    this._lastAway = away;
    this._lastDeep = deep;
    this.pushEvent("jump_to_latest_distance", { away, deep });
    // KEEP-OR-DROP DECISION on `holdAnchorThroughReflow()` (task 01a0419a
    // stage 4, and the reason is narrower than it was): KEPT, for DESKTOP.
    //
    // Stage 2 lifted the control out of the flow, so on mobile the wrappers
    // are a zero-height overlay and the pill appearing changes no geometry at
    // all — there this call absorbs nothing. But the overlay is gated behind
    // `@media (max-width: 1023.98px)`; at desktop widths the wrappers are
    // `display: contents` and the button is still a flex SIBLING of the
    // scroller, so it appearing and disappearing still shrinks and grows the
    // scroller's clientHeight and the browser still re-clamps scrollTop under
    // the reader's eyes. The reason has narrowed from "both platforms" to
    // "desktop only"; it has not evaporated, so the call stays. It is a no-op
    // on mobile (the pin re-writes the distance it just read), which is the
    // cheap half of the trade. Drop it only together with the desktop in-flow
    // path.
    //
    // Skipped on the very first report, where nothing was rendered before and
    // there is no height change to absorb.
    if (hadPrevious) this.holdAnchorThroughReflow();
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
    this._endInitialPhase("anchored");
    return true;
  },
  scrollToBottom(preDistance) {
    if (this.honourAnchor()) return;

    if (this._initialScroll) {
      this.scrollEl.scrollTop = this.scrollEl.scrollHeight;
      // The phase deliberately does NOT end here (task 01a03f3a). It used to
      // end the first time the container merely overflowed, which is a proxy
      // for "the conversation has arrived" and a bad one: a single tall
      // message overflows the box on frame one, long before fonts, images and
      // tables have settled. Ending here also tore down the ResizeObserver
      // added by 019ff6c9 for exactly that late layout, on the same frame —
      // so on a channel of tall messages both protections were dead before
      // any of the growth they guard against had happened, stranding the
      // reader thousands of pixels above the newest message.
      //
      // The phase now ends on arrival rather than on overflow: quiet layout,
      // a hard ceiling, or a real scroll gesture. See `_endInitialPhase`.
      this._armSettleTimer();
      return;
    }
    // After initial load, only auto-scroll if the user is near the bottom —
    // where they were BEFORE this patch grew the scroller, not after. Falls
    // back to the live measurement only when there is no capture.
    const distance = preDistance ?? this.distanceFromBottom();
    if (distance <= NEAR_BOTTOM_PX) {
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
  // Walk visible message rows and mark where each author's RUN starts and
  // ends. A run is a maximal block of consecutive rows from one participant.
  //
  // Two classes, both driven off the same single pass:
  //
  //   `message-row--grouped`  this row continues the author above it, so its
  //                           avatar + header collapse for a compact look.
  //   `message-row--run-end`  nothing after this row continues it — the next
  //                           row is a different author, or there is no next
  //                           row at all.
  //
  // There is deliberately no third class for "first in run": that is simply a
  // row WITHOUT `--grouped`. A single-message run therefore carries no
  // `--grouped` and does carry `--run-end`, which is exactly what lets it keep
  // full rounding with no special case.
  //
  // Both are set with `classList.toggle(name, bool)` rather than `add`. When
  // the server re-renders a row with a new author, a row that has stopped
  // being a continuation — or stopped being a run end — has to be UNmarked;
  // a bare `add` leaves the stale class behind and the row keeps rendering as
  // something it no longer is.
  //
  // This only decides WHICH rows are continuations and boundaries. What those
  // rows look like lives in app.css, because the previous inline-style version
  // could only hide things, and hiding is not the same as reclaiming the
  // space:
  //
  //   `avatar.style.visibility = "hidden"` made the avatar invisible while it
  //   went on reserving its full 47px of row height. A one-line follow-up
  //   message was 66px tall to hold 20px of text, and no amount of padding
  //   tuning could get under that floor while a 47px ghost held the row open.
  //
  // Anything that needs to reclaim layout — not just conceal it — belongs in
  // the stylesheet where the collapsed geometry is written down once.
  applyGrouping() {
    const rows = Array.from(this.el.querySelectorAll("[data-participant-id]"));
    let prevParticipantId = null;

    rows.forEach((row, i) => {
      const pid = row.dataset.participantId;
      const grouped = Boolean(pid) && pid === prevParticipantId;

      // Look one row ahead rather than back-patching the previous row, so
      // this stays a single forward pass. A row with no participant id is
      // its own run of one: it never continues anything and nothing
      // continues it, so it always ends a run.
      const nextPid = rows[i + 1]?.dataset.participantId;
      const runEnd = !(Boolean(pid) && nextPid === pid);

      row.classList.toggle("message-row--grouped", grouped);
      row.classList.toggle("message-row--run-end", runEnd);

      prevParticipantId = pid || null;
    });
  },
};

export default ScrollToBottom;
