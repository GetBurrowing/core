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
//    on ARRIVAL — 250ms of quiet layout, a 3s ceiling, or a real
//    wheel/touchmove/keydown gesture, whichever lands first (task
//    01a03f3a); from then on a snap only fires when the user is already
//    within NEAR_BOTTOM_PX of the bottom. (Previously the initial phase
//    persisted until the user scrolled >300px up, which made every later
//    update an unconditional yank-to-bottom for anyone who hadn't. The
//    exit was then moved to the first OVERFLOW, which is a bad proxy for
//    arrival — see the long note in `scrollToBottom` for why.)
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

// ── The hysteresis margin ───────────────────────────────────────────────────
//
// READ THIS BEFORE COUNTING THRESHOLDS. There are still exactly TWO
// thresholds, `NEAR_BOTTOM_PX` and `DEEP_HISTORY_PX`, and both keep the values
// and the provenance recorded above. `THRESHOLD_HYSTERESIS_PX` is NOT a third
// threshold and it is NOT a re-tune of either: it is ONE margin applied
// SYMMETRICALLY to BOTH of them, turning each single value into a BAND whose
// NOMINAL CROSSING POINT is still the constant above it. A reader arriving
// here and "simplifying" three numbers down to two would be deleting the
// mechanism, not a redundancy.
//
// WHY A BAND. Both reported booleans were derived from a single comparison, so
// a reader hovering at a boundary re-flipped one on every wheel tick and
// `_reportDistance()` pushed a server event each time — each of which is a
// LiveView render. Task 01a0419a stage 2 measured the resulting stutter and
// stage 3 removed its worst amplifier (the reflow-hold pin, see
// `_reportDistance`), but the churn is an INDEPENDENT defect and survives that
// removal: an oscillating boolean still round-trips to the server. This is the
// fix for that half, and it is justified on its own merits rather than as part
// of the stutter fix.
//
// THE RULE. To ENTER a state the reader must pass `nominal + margin`; to LEAVE
// it they must fall back past `nominal - margin`. In between, the previous
// answer stands. So a reader oscillating anywhere inside the band produces
// exactly ONE event, and a reader who genuinely commits past the far edge
// still flips.
//
// WHY 24. It has to exceed the incidental wobble at a boundary — sub-pixel
// scroll rounding, momentum settle, and the few-pixel rubber-band overshoot at
// the end of a flick — while staying far below any distance a person would
// call a scroll. 24px is under a third of the 83px median message row measured
// for `DEEP_HISTORY_PX` above, so no band edge can move past the message that
// defined it. It is deliberately NOT tuned per threshold: two margins would be
// two more numbers to keep in order, and nothing observed suggests the two
// boundaries wobble differently.
const THRESHOLD_HYSTERESIS_PX = 24;

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

// The SAME silent-collapse hazard, one level up: the margin widens both bands
// inward, so a large enough margin closes the gap between them even though the
// two constants themselves are still correctly ordered. At that point `away`
// and `deep` enter and leave together, the middle band — the entire visibility
// rule — is gone, and NOTHING reports it: no error, no failing assertion, just
// the pill behaving as if there were one threshold again. A negative margin is
// the same class of bug from the other direction: it would INVERT each band,
// making the exit point higher than the entry point, so a single boolean would
// chatter instead of latching.
//
// Both are bound at module load for the same reason the pair-ordering above
// is: a test can be deleted, and CI runs no JavaScript at all.
//
// The surviving middle band runs from `NEAR_BOTTOM_PX + margin` (where `away`
// latches on) to `DEEP_HISTORY_PX - margin` (where `deep` latches on), so that
// is the interval this asserts is non-empty.
if (THRESHOLD_HYSTERESIS_PX < 0) {
  throw new Error(
    `scroll_to_bottom: THRESHOLD_HYSTERESIS_PX (${THRESHOLD_HYSTERESIS_PX}) ` +
      `must not be negative; a negative margin inverts both bands, putting ` +
      `each exit point above its entry point so the boolean chatters instead ` +
      `of latching.`,
  );
}
if (
  DEEP_HISTORY_PX - THRESHOLD_HYSTERESIS_PX <=
  NEAR_BOTTOM_PX + THRESHOLD_HYSTERESIS_PX
) {
  throw new Error(
    `scroll_to_bottom: THRESHOLD_HYSTERESIS_PX (${THRESHOLD_HYSTERESIS_PX}) ` +
      `is too large for the gap between NEAR_BOTTOM_PX (${NEAR_BOTTOM_PX}) ` +
      `and DEEP_HISTORY_PX (${DEEP_HISTORY_PX}): the middle visibility band ` +
      `would run from ${NEAR_BOTTOM_PX + THRESHOLD_HYSTERESIS_PX}px to ` +
      `${DEEP_HISTORY_PX - THRESHOLD_HYSTERESIS_PX}px, i.e. be empty. The ` +
      `margin must stay under half their difference ` +
      `(${(DEEP_HISTORY_PX - NEAR_BOTTOM_PX) / 2}px).`,
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
    // Seed the viewport dimensions BEFORE arming the observer below. A
    // ResizeObserver delivers one callback for the CURRENT size the moment it
    // starts observing; with nothing seeded that first delivery would read as
    // a change from nothing and snap a reader who has not moved.
    this._lastClientHeight = this.scrollEl.clientHeight;
    this._lastClientWidth = this.scrollEl.clientWidth;
    // Pre-resize scrollHeight for the WIDTH path below. Seeded with the
    // other dimensions so the ResizeObserver's first (current-size)
    // delivery has all three to compare against.
    this._lastScrollHeight = this.scrollEl.scrollHeight;
    this._connectViewportObserver();
    // Seed the realign-guard memory (below) with the position the server
    // render landed the reader at, and arm its observer.
    this._scrollObservedTop = this.scrollEl.scrollTop;
    this._connectRealignObserver();
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
      // Realign-guard memory: EVERY scroll event carries the offset the
      // reader (or one of this hook's own snaps) actually moved to. Record
      // it BEFORE the rAF coalescing gate — a coalesced-away event must
      // still refresh the memory, because `_repairRealignedScroll` below
      // distinguishes "the reader moved" (an event delivered the new
      // offset) from "the offset was destroyed" (no event ever came).
      this._scrollObservedTop = this.scrollEl.scrollTop;
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
    // A deferred restore belongs to the conversation that was on screen when
    // the relocation happened. Applying it to a different space would drop the
    // reader at an offset that means nothing there.
    this._pendingRealignTop = null;
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
  // ── The reader is pinned to the BOTTOM, not to a scrollTop (task 01a04aec)
  //
  // `#chat-message-scroller` is `flex-1 min-h-0` inside a flex COLUMN, so its
  // viewport height is whatever its in-flow siblings leave it:
  //
  //   above it   the search / pins / canvases drawers and the archived banner
  //              (`chat_live.html.heex`)
  //   below it   the streaming-reply bubbles, the typing indicator and the
  //              composer, whose textarea grows from 33px to a 200px cap as
  //              you type (`compose_input.js` `_autoResize`)
  //
  // Any of those changing height changes the scroller's `clientHeight` while
  // `scrollTop` stays exactly where the browser left it. `distanceFromBottom()`
  // is `scrollHeight - scrollTop - clientHeight`, so the reader's distance
  // from the live edge moves by the FULL delta without the reader touching
  // anything. Open the canvases drawer and a reader parked at the bottom is
  // several hundred pixels above it; type a message that wraps the composer
  // past 150px and the composer ALONE carries them over NEAR_BOTTOM_PX — after
  // which `scrollToBottom()` correctly declines to follow, because by its own
  // rule this reader is no longer at the bottom. That is the reported
  // symptom, in both the shapes it was reported in: the pane stops keeping up
  // with the conversation, and the jump-to-latest chip appears for a reader
  // who never scrolled.
  //
  // NOTHING ELSE IN THIS HOOK CAN SEE IT, which is why four previous passes
  // over this file left it standing:
  //
  //   * `beforeUpdate` / `updated` fire only when LiveView patches
  //     `#message-list`. Every sibling named above is OUTSIDE that element, so
  //     a drawer opening or a streaming bubble growing is a patch somewhere
  //     else entirely and this hook is never called.
  //   * the arrival `ResizeObserver` does watch this same box, but it is torn
  //     down the moment the arrival phase ends (`_endInitialPhase`) — 250ms of
  //     quiet layout after the conversation lands, long before any of this.
  //   * `holdAnchorThroughReflow` is armed only by `sidebar_collapsed_changed`,
  //     a WIDTH change, and holds a distance rather than the bottom.
  //
  // So this is a SECOND, PERMANENT observer answering a different question:
  // not "has the content finished arriving" but "did the viewport itself
  // change size, and was the reader following the bottom when it did".
  _connectViewportObserver() {
    if (typeof ResizeObserver === "undefined") return;
    this._disconnectViewportObserver();
    this._viewportObserver = new ResizeObserver(() => this._onViewportResize());
    this._viewportObserver.observe(this.scrollEl);
  },
  _disconnectViewportObserver() {
    if (this._viewportObserver) {
      this._viewportObserver.disconnect();
      this._viewportObserver = null;
    }
  },
  // TRUE when the scroller currently has a layout box to measure.
  //
  // An element inside a `display: none` subtree reports clientWidth,
  // clientHeight AND scrollHeight as 0 — every input the resize paths below
  // read at once. The predicate cannot tell that apart from a genuinely
  // rendered 0x0 box, and deliberately does not try: in both cases the honest
  // answer is that this hook knows nothing about where the reader is and must
  // not decide anything.
  _hasMeasurableBox() {
    return this.scrollEl.clientWidth > 0 || this.scrollEl.clientHeight > 0;
  },
  _onViewportResize() {
    // ── The hidden-pane guard (task 01a084bf stage 5) ───────────────────────
    //
    // WHAT WAS MEASURED, and by whom. The behavioural gate on task 01a084bf
    // reported a reader parked at scrollTop 354 (max 614) on the call rail's
    // Chat tab, sent to 614 — the exact bottom — by a People/Transcript/Chat
    // tab round trip. The gate's own diagnosis was that `display: none`
    // discards the offset and the browser drops the reader at the bottom on
    // return. BOTH HALVES OF THAT ARE WRONG, and the numbers it recorded are
    // what refute it: a discarded offset lands at 0, the TOP; 614 is
    // `scrollHeight - clientHeight`, which only a write can reach.
    //
    // Measured in Chrome 152.0.7977.83 over CDP against a static page
    // carrying Tailwind v4.1.12's preflight rule verbatim
    // (`[hidden]:where(:not([hidden='until-found'])) { display: none
    // !important }`, so the `hidden` attribute really does beat the wrap's
    // own `.flex`): the browser RETAINS the offset across the round trip and
    // hands it back. 354 -> 0 while hidden -> 354 on return. It also retains
    // it when rows are appended to the hidden scroller, when a `scrollTop`
    // write is attempted on the box-less element (the write is discarded),
    // and across 60 hidden frames.
    //
    // So the destroyer is THIS FUNCTION. `[data-role="call-rail-chat-wrap"]`
    // in `call_shell.ex` flips `hidden`, the ResizeObserver above delivers
    // 0x0, and the old code recorded that: `_lastClientWidth`,
    // `_lastClientHeight` and `_lastScrollHeight` all became 0. On the way
    // back the WIDTH path then reconstructed the reader's pre-resize distance
    // from those zeroes — `0 - 354 - 0 = -354`, comfortably under
    // NEAR_BOTTOM_PX — concluded the reader had been following the live edge,
    // and snapped. Seeded with the gate's own three numbers the arithmetic
    // reproduces its trace exactly, 354 -> 0 -> 614; see
    // `assets/test/scroll_to_bottom_hidden_pane_test.mjs`.
    //
    // THE FIX IS TO RECORD NOTHING. Returning before the reads above leaves
    // all three remembered dimensions at their last RENDERED values, so the
    // re-show delivery compares like with like: same width, same height, no
    // change, no snap, and the offset the browser handed back stands. If the
    // pane's size genuinely changed while it was hidden — a window resize
    // while the reader was on People — the re-show delivery still sees a real
    // change against the real pre-hide geometry, which is the comparison the
    // width path was always trying to make.
    //
    // THE SIBLING PANE ALREADY DOES THIS, which is the strongest evidence
    // here and is not mine. `[data-role="meeting-transcript-wrap"]` sits
    // beside the chat wrap in the same rail, hides by the same `hidden`
    // attribute, and `hooks/meeting_transcript.js` gates its own
    // ResizeObserver on `this.el.clientHeight > 0` — with a comment stating
    // that a reader who had scrolled up "keeps their place" because the
    // browser restores the offset. That was written by another author, for
    // another pane, and it ships. The chat pane was the outlier, and the
    // measurement above and that precedent are independent of each other.
    //
    // WHAT THIS DELIBERATELY DOES NOT CHANGE, because it is load-bearing.
    // `/meetings` opens on the People tab (`meeting_live.ex`), so the chat
    // pane MOUNTS box-less and `mounted()` seeds all three dimensions from
    // that. The reader's FIRST arrival on the Chat tab therefore still runs
    // the width path against a 0 seed, still reconstructs `0 - 0 - 0 = 0`,
    // and still snaps to the newest message — which is the correct landing
    // for a first visit, and is the one case where the zeroes are not a lie.
    // That behaviour is accidental in shape but required in effect, so it is
    // pinned by its own case in the test file above. Do not "tidy" the mount
    // seed without reading it.
    if (!this._hasMeasurableBox()) return;

    // The box is back. If a relocation was detected while it was gone, the
    // reader's offset is owed to them before anything below reads `scrollTop`.
    this._applyPendingRealign();

    const width = this.scrollEl.clientWidth;
    const height = this.scrollEl.clientHeight;
    const prevWidth = this._lastClientWidth;
    const prevHeight = this._lastClientHeight;
    this._lastClientWidth = width;
    this._lastClientHeight = height;

    // The arrival phase already holds the reader at the live edge on every
    // resize and ends by its own rules. Two owners of `scrollTop` inside that
    // window is how earlier passes over this file undid each other.
    if (this._initialScroll) return;

    // A WIDTH change rewraps every message, so `scrollHeight` moved in the
    // same frame and the height path's substitution — NEW scrollHeight
    // against OLD height — is not comparable. The width case has TWO
    // owners now, answering different questions:
    //
    //   * `holdAnchorThroughReflow`, armed from `sidebar_collapsed_changed`,
    //     pins the reader's DISTANCE through the rail's 200ms width
    //     animation (task 019f51d1). Deliberately NOT re-armed broadly —
    //     pinning a moving reader for 400ms is the stutter task 01a0419a
    //     stage 2 measured and stage 3 removed; see the KEEP-OR-DROP note
    //     in `_reportDistance`.
    //   * THIS path, added by task 01a05873, owns the ONE-SHOT resizes the
    //     pin was never armed for: window resizes and the sidebar drag,
    //     both desktop-only (mobile has no resizable sidebar or window).
    //     It re-anchors the same way the height path does — snap when the
    //     PRE-resize distance was within NEAR_BOTTOM_PX, preserve the
    //     pixel otherwise — but the pre-resize distance must be
    //     reconstructed from the PRE-resize scrollHeight (`_lastScrollHeight`,
    //     refreshed on every layout-changing event below), because the
    //     live scrollHeight already includes the rewrap.
    //
    // Before 01a05873 this case fell through to a bare `return`, which
    // stranded a bottom-parked reader: rewrap grew `scrollHeight` under an
    // unchanged `scrollTop` (measured 800px stranded on a 1440→1200 window
    // resize, 400px on a sidebar drag), after which the follow rule
    // correctly declined — the reader was no longer near the bottom — and
    // the pill appeared for someone who never scrolled.
    if (width !== prevWidth) {
      const preDistance =
        this._lastScrollHeight - this.scrollEl.scrollTop - prevHeight;
      if (preDistance <= NEAR_BOTTOM_PX) {
        this.scrollEl.scrollTop = this.scrollEl.scrollHeight;
        this._reportDistance();
      }
      this._lastScrollHeight = this.scrollEl.scrollHeight;
      return;
    }
    if (height === prevHeight) return;

    // Where the reader WAS, in the instant before the box changed size. A
    // scroller merely getting shorter does not move `scrollTop`, so the old
    // height is the only term that has to be substituted back.
    const preDistance =
      this.scrollEl.scrollHeight - this.scrollEl.scrollTop - prevHeight;

    // THE ACCEPTED COST, stated here rather than left to be discovered. A
    // reader who had deliberately scrolled up to read history keeps the pixel
    // they were looking at and is NOT pulled to the bottom, even though the
    // resize has just changed their distance from it. Restoring THEIR distance
    // instead would drag the text out from under them on every composer
    // keystroke, which is the opposite defect and the more intrusive one. The
    // boundary is NEAR_BOTTOM_PX, the same constant the follow rule uses, so
    // "followed through a resize" and "followed a new message" cannot name
    // different readers.
    if (preDistance > NEAR_BOTTOM_PX) {
      this._lastScrollHeight = this.scrollEl.scrollHeight;
      return;
    }

    this.scrollEl.scrollTop = this.scrollEl.scrollHeight;
    this._reportDistance();
    this._lastScrollHeight = this.scrollEl.scrollHeight;
  },
  // ── The morphdom realignment guard (task 01a05873 stage 2) ─────────────────
  //
  // WHAT WAS MEASURED, in the real app over CDP
  // (priv/measurements/01a05873-desktop-follow/, gate-5 harness + zero-hunt
  // trace): a reader parked at the bottom clicks the canvases drawer toggle
  // and the `canvas_panel_toggle` patch — which only flips `@show_canvases`
  // and renders the drawer div into `#chat-drop-zone`, NEVER touching
  // `#message-list` — leaves the scroller at scrollTop 0. Not by any
  // `scrollTop = 0` write: the recorded DOM op is a REMOVE of
  // `#chat-message-scroller` from `#chat-drop-zone` followed immediately by
  // an ADD of the SAME node back into the SAME parent, ~25ms after the
  // patch, with no scroll event and scrollHeight still full.
  //
  // WHY morphdom does it. The patch grows `#chat-drop-zone`'s child list
  // ahead of the keyed siblings (`#inline-focus-listener`,
  // `#chat-message-scroller`), and LiveView's DOM patcher realigns a changed
  // child list by RELOCATING the existing keyed nodes
  // (`fromEl.insertBefore(matchingFromEl, …)` in the bundled morphdom).
  // Giving the new drawer an id does NOT avoid this — measured: the move
  // still happens, because the alignment walk starts from the insertion
  // point, not from the new node's key. `Node.insertBefore` of an attached
  // node removes it first, and a detached scroller forgets its scroll
  // offset: on re-insert scrollTop reads 0.
  //
  // WHY NOTHING ELSE SEES IT:
  //   * no scroll event — the offset was destroyed with the detached
  //     render box, not scrolled away; every scroll-event-driven path
  //     (including `_reportDistance` and the realign-guard memory below)
  //     is silent.
  //   * `beforeUpdate` / `updated` — they fire only when LiveView patches
  //     `#message-list`, and this patch does not.
  //   * the #848 viewport observer — it fires on the drawer's clientHeight
  //     shrink, but its pre-resize reconstruction
  //     (`scrollHeight - scrollTop - prevHeight`) reads the ALREADY-zeroed
  //     scrollTop: a bottom-parked reader at 3273px reconstructs as "was
  //     3273px away" and the path declines. The exact reader #848 exists
  //     to hold is the one it cannot see.
  //   * InfiniteScroll's top sentinel — at scrollTop 0 it intersects and
  //     fires `load_older_messages` with `_preTop` captured AFTER the
  //     reset (0); the post-prepend compensation then lands the reader at
  //     `0 + Δ` ≈ 3960px away with the jump chip raised. That is the
  //     reported defect.
  //
  // THE REPAIR. The parent-level childList observer below sees the scroller
  // (or an ancestor of it) among a batch's removedNodes, and the
  // `_scrollObservedTop` memory — refreshed on every scroll event, see
  // `_onScroll` — still holds the offset the reader actually had, because
  // the destruction produced no event. Restoring it in the observer
  // microtask puts the reader back before the browser paints, before any
  // ResizeObserver / IntersectionObserver delivery, so the #848 height
  // path then sees the true pre-resize distance and does its own job (snap
  // a bottom-parked reader to the drawer-shrunk edge), and the sentinel
  // never intersects. Nothing about the follow rule, the thresholds or the
  // capture contract changes: this only un-corrupts the input they read.
  //
  // The memory can only disagree with the live offset through a silent
  // destruction. A real move — user scroll, one of this hook's snaps, a
  // browser clamp of a rendered box — delivers a scroll event first, which
  // refreshes the memory to the live value and makes the repair a no-op.
  // A space switch re-renders the pane and snaps to bottom during arrival,
  // so a transient repair there is immediately overwritten by the arrival
  // snap.
  // ── WHY THE WHOLE ANCESTOR CHAIN, not just the parent (task 01a084bf
  // stage 5, second round) ───────────────────────────────────────────────────
  //
  // The drawer case above relocates the scroller ONE level up, so observing
  // `scrollEl.parentElement` was enough for it. The call rail's tab round trip
  // relocates it FOUR levels up, and the parent-only observer never saw it.
  //
  // MEASURED in the app, Chrome 152 over CDP, `/meetings` with the rail's Chat
  // tab, a `MutationObserver` on `document.body` across a real mouse click on
  // the People tab. Three childList records, one batch, t=19-20ms:
  //
  //   1. a NEW `[data-role="call-rail-chat-wrap"]` ADDED into
  //      `[data-role="call-rail-pane"]`
  //   2. `#meeting-chat-panel-<id>` REMOVED from `[data-pane=…chat-panel]`
  //   3. the SAME `#meeting-chat-panel-<id>` ADDED back into a
  //      `[data-pane=…chat-panel]`
  //
  // Measured node identity across that batch, from the scroller upward:
  // depths 0-4 are the SAME nodes, depths 5 and 6 are REPLACED, depth 7
  // (`call-rail-pane`) and everything above it is the same. So the subtree was
  // MOVED, not removed — which is why `isConnected` reads true at every one of
  // those records: the node never rests detached, and a hook watching for a
  // detached scroller sees nothing.
  //
  // Moving a scroll container is what loses the offset, and `display: none` is
  // not involved. Isolated on a static page reproducing this exact three-event
  // shape (priv/measurements/01a084bf-hidden-pane-scroll/reloc.html):
  //
  //   hide then show, NO relocation      354 -> 354   (offset retained)
  //   hide AND relocate, then show       354 ->   0   (offset lost)
  //   relocate while fully VISIBLE       354 ->   0   (offset lost)
  //
  // The third line is the one that settles it: no `hidden`, no `display: none`,
  // nothing but the move, and the reader is still lost.
  //
  // WHY THE CHAIN IS A PROOF RATHER THAN A TRACE. Relocating the scroller means
  // detaching it, or some ancestor of it, from wherever it currently sits. That
  // always produces a childList record whose target is a node in the scroller's
  // CURRENT ancestor chain. Observing every one of those nodes therefore cannot
  // miss a relocation, at any depth, from any future markup change — it does not
  // depend on the rail's shape, which is what the parent-only version did.
  //
  // WHY THIS DOES NOT OVER-FIRE, which `subtree: true` on a high ancestor would.
  // Arriving messages are inserted into `#message-list`, a DESCENDANT of the
  // scroller. A descendant's childList record has a descendant target, so no
  // observer here is armed on it and the callback does not run at all — not
  // "runs and declines". A subtree observer on `call-rail-pane` would run on
  // every message and have to be talked out of repairing; this cannot be asked.
  // Pinned by its own case in
  // `assets/test/scroll_to_bottom_hidden_pane_test.mjs`.
  _realignAncestorChain() {
    const chain = [];
    let n = this.scrollEl.parentElement;
    while (n) {
      chain.push(n);
      n = n.parentElement;
    }
    return chain;
  },
  // TRUE when the scroller's ancestors are not the ones this observer was armed
  // on. This is a relocation the `removedNodes` predicate below can MISS: the
  // callback runs after every mutation in the batch is applied, so a node the
  // scroller was moved OUT of no longer `contains` it by the time we look.
  // Identity, not shape — depths 5 and 6 above are new nodes carrying the same
  // attributes, and a selector or tag comparison would call them unchanged.
  _realignChainChanged() {
    const armed = this._realignChain;
    if (!armed) return false;
    const live = this._realignAncestorChain();
    if (live.length !== armed.length) return true;
    for (let i = 0; i < live.length; i++) {
      if (live[i] !== armed[i]) return true;
    }
    return false;
  },
  _connectRealignObserver() {
    if (typeof MutationObserver === "undefined") return;
    this._disconnectRealignObserver();
    const chain = this._realignAncestorChain();
    if (!chain.length) return;
    this._realignChain = chain;
    // ONE observer, many targets. `observe` is additive, and a single
    // disconnect drops all of them — so re-arming after a relocation cannot
    // leak the observers armed on the nodes that were replaced.
    this._realignObserver = new MutationObserver((muts) =>
      this._onRealignMutations(muts),
    );
    for (const node of chain) {
      this._realignObserver.observe(node, { childList: true });
    }
  },
  _onRealignMutations(muts) {
    let carriedScroller = false;
    for (const mut of muts) {
      for (const n of mut.removedNodes) {
        if (n === this.scrollEl || (n.contains && n.contains(this.scrollEl))) {
          carriedScroller = true;
          break;
        }
      }
      if (carriedScroller) break;
    }
    const chainChanged = this._realignChainChanged();
    if (carriedScroller || chainChanged) this._repairRealignedScroll();
    // Re-arm on the nodes that exist NOW. Two of the four ancestors between the
    // scroller and the rail pane are replaced by this patch, and an observer
    // armed on a node that has been thrown away observes nothing.
    if (chainChanged) this._connectRealignObserver();
  },
  _disconnectRealignObserver() {
    if (this._realignObserver) {
      this._realignObserver.disconnect();
      this._realignObserver = null;
      this._realignChain = null;
    }
  },
  _repairRealignedScroll() {
    const memory = this._scrollObservedTop;
    if (memory == null) return;
    // A `scrollTop` WRITE ON A BOX-LESS ELEMENT IS DISCARDED. Measured twice in
    // Chrome 152: on the static probe, and in the app — at the People tab the
    // hidden scroller was written 696, read back 0 in the same expression, and
    // returned to the Chat tab at 0. The tab patch relocates the scroller in
    // the SAME batch that takes the wrap to `display: none`, so this callback
    // always runs box-less and an immediate write here would be a silent no-op
    // that LOOKS like a fix. Hold the offset and apply it when there is a box.
    if (!this._hasMeasurableBox()) {
      this._pendingRealignTop = memory;
      return;
    }
    const live = this.scrollEl.scrollTop;
    if (live === memory) return;
    this.scrollEl.scrollTop = memory;
  },
  // Apply a restore that was deferred because the scroller had no box when its
  // relocation was detected. Called from the two paths that run with a box:
  // `_onViewportResize`, which the ResizeObserver delivers when the wrap loses
  // `hidden`, and `_safeUpdate`. Deliberately BEFORE either of them decides
  // anything, so the follow rule reads the reader's real position rather than
  // the 0 the relocation left behind.
  _applyPendingRealign() {
    const pending = this._pendingRealignTop;
    if (pending == null) return;
    if (!this._hasMeasurableBox()) return;
    this._pendingRealignTop = null;
    if (this.scrollEl.scrollTop === pending) return;
    this.scrollEl.scrollTop = pending;
    // The write fires a scroll event which would refresh this anyway; setting
    // it here means the memory is never momentarily older than the DOM.
    this._scrollObservedTop = pending;
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
    // A deferred realign restore is owed before `scrollToBottom` below reads
    // the reader's position: a patch can be what makes the pane measurable
    // again, and the ResizeObserver is not guaranteed to get there first.
    this._applyPendingRealign();
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
    // Keep the pre-resize scrollHeight fresh on every patch — it is the
    // ONLY term the WIDTH path of `_onViewportResize` cannot reconstruct
    // after a rewrap, and a stale value there strands a bottom-parked
    // reader on the next window resize / sidebar drag (task 01a05873).
    //
    // NOT WHILE THE PANE IS BOX-LESS (task 01a084bf stage 5). The chat pane
    // keeps streaming while the reader is on the People tab, so this line runs
    // on a `display: none` scroller and used to record `scrollHeight` 0. The
    // hidden-pane guard in `_onViewportResize` means that zero is no longer
    // read on the way back to the Chat tab, but it SURVIVES there until the
    // next patch, and the first genuine width change after it — a sidebar
    // drag, a window resize — reconstructs `0 - scrollTop - prevHeight`,
    // decides the reader was at the live edge, and yanks them to the bottom.
    // Same defect as the one above, one interaction later. Freshness is only
    // worth having if the value is real.
    if (this._hasMeasurableBox()) {
      this._lastScrollHeight = this.scrollEl.scrollHeight;
    }
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
    this._disconnectViewportObserver();
    this._disconnectRealignObserver();
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
  // Resolve one boolean against its NOMINAL threshold with the shared
  // hysteresis margin applied symmetrically, latching on the previous answer.
  //
  // `previous` is `null` only on the very first report of a conversation,
  // where there is no state to latch onto and no jitter to suppress yet; there
  // the nominal value is used bare, so the first answer is the same one the
  // un-banded code would have given. Every later call needs a margin's worth
  // of committed movement to change its mind.
  _latch(distance, nominal, previous) {
    if (previous === null || previous === undefined) return distance > nominal;
    return previous
      ? distance > nominal - THRESHOLD_HYSTERESIS_PX
      : distance > nominal + THRESHOLD_HYSTERESIS_PX;
  },
  _reportDistance(preDistance) {
    // Keep the pre-resize scrollHeight fresh on EVERY report path — not
    // just patches. A rewrap can happen with no LiveView patch at all
    // (webfont swap reflows every body once, mid-conversation), and when
    // it shrinks the content the browser CLAMPS scrollTop, which fires a
    // real scroll event that lands HERE. Without this refresh the width
    // path in `_onViewportResize` reads a stale pre-resize height and a
    // bottom-parked reader can be misclassified as mid-band on the next
    // window resize (observed stale by 192px in the real app, task
    // 01a05873).
    this._lastScrollHeight = this.scrollEl.scrollHeight;
    const distance = preDistance ?? this.distanceFromBottom();
    // Banded, not bare comparisons — see `THRESHOLD_HYSTERESIS_PX`. The
    // nominal crossing points are still NEAR_BOTTOM_PX and DEEP_HISTORY_PX.
    const away = this._latch(distance, NEAR_BOTTOM_PX, this._lastAway);
    const deep = this._latch(distance, DEEP_HISTORY_PX, this._lastDeep);
    // Edge-triggered on the PAIR. Either flipping is a real transition: a
    // reader crossing out of the deep band changes what the server renders
    // even though `away` never moved.
    if (away === this._lastAway && deep === this._lastDeep) return;
    this._lastAway = away;
    this._lastDeep = deep;
    this.pushEvent("jump_to_latest_distance", { away, deep });
    // KEEP-OR-DROP on `holdAnchorThroughReflow()`, REVISITED under task
    // 01a0419a v3. This SUPERSEDES the v2 stage 4 ruling that stood here.
    //
    // v2 stage 4 kept this call for ONE stated reason: at desktop widths the
    // jump-to-latest button was still an in-flow flex SIBLING of the scroller,
    // so it appearing changed the scroller's `clientHeight` and the browser
    // re-clamped `scrollTop`. Stage 1 of this task deleted that path — the
    // control is now a zero-height overlay at EVERY width. The justification
    // is not narrowed, it is false, so the call is DROPPED.
    //
    // It was also measured to be actively harmful, which the old comment got
    // backwards when it called the pin "a no-op on mobile". The pin captures
    // `distanceFromBottom()` once and writes it back every frame for 400ms:
    // that is a no-op for ABSORBING A REFLOW, and it is exactly what FREEZES a
    // reader who is moving. Task 01a0419a stage 2 measured 400ms windows after
    // an edge at -30px/-12px (1440x900) and -60px/-30px (390x844) against
    // equal-length mid-band control windows of -540px to -690px. The 390px
    // `away` window — where there is no reflow to absorb at all — was the
    // WORST in the table. Harness and captures:
    // `priv/measurements/01a0419a-scroll-stutter/`.
    //
    // THE METHOD IS RETAINED AND IS STILL LIVE. Its remaining caller is the
    // `handleEvent("sidebar_collapsed_changed", ...)` registration in
    // `mounted()` — the original task 019f51d1 reason, a 168px rail width
    // animation that rewraps text and makes the browser re-anchor scrollTop.
    // That caller is untouched by this task. Do not delete
    // `holdAnchorThroughReflow()` as dead code: dropping this call site leaves
    // exactly one caller, not zero, and `scroll_to_bottom.test.js` asserts it
    // still fires on the sidebar event for precisely that reason.
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
