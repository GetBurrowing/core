// Regression guard for the arrival scroll position of the `ScrollToBottom`
// hook (task 01a03f3a).
//
// THE DEFECT THIS PINS. `scrollToBottom()` ends its initial hard-snap phase
// the first time the container merely OVERFLOWS:
//
//     if (this._initialScroll) {
//       this.scrollEl.scrollTop = this.scrollEl.scrollHeight;
//       if (this.scrollEl.scrollHeight > this.scrollEl.clientHeight) {
//         this._initialScroll = false;
//         this._disconnectResizeObserver();
//       }
//       return;
//     }
//
// Overflow is a proxy for "the conversation has finished arriving", and it is
// a bad one: a single tall message overflows the box on the first frame, long
// before fonts, images, tables and code blocks have settled. The phase ends
// immediately, the ResizeObserver added for exactly this (task 019ff6c9) is
// torn down on that same frame, and every later call is gated on the reader
// already being within NEAR_BOTTOM_PX (150) of the bottom.
//
// So any late growth larger than 150px strands the reader permanently, with
// the newest message present in the DOM but far below the fold. That is the
// reported symptom: "you are dropped right into the middle of it instead of
// the most recent message", reproducibly in the same spot, because the
// content — and therefore the growth — is deterministic.
//
// Run from the assets dir:
//
//     node --test test/scroll_to_bottom_arrival_test.mjs

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

// Load the REAL hook source rather than a copy, so this test cannot drift
// from the implementation it guards. Same approach as
// scroll_to_bottom_unit_test.mjs.
const hookBody = readFileSync(
  resolve(__dirname, "../js/hooks/scroll_to_bottom.js"),
  "utf8",
)
  .replace(/^\s*export\s+default\s+ScrollToBottom\s*;?\s*$/m, "")
  .concat("\nreturn ScrollToBottom;\n");

const ScrollToBottom = new Function(hookBody)();

// ---------------------------------------------------------------------------
// Scroll-container shim
// ---------------------------------------------------------------------------
// Models the only three numbers the hook reads, plus the browser's clamping
// of scrollTop to [0, scrollHeight - clientHeight]. The clamp is load-bearing:
// the hook assigns `scrollTop = scrollHeight` and relies on the browser to
// clamp it to the true bottom. Without modelling it the tests would be
// measuring a fiction.
function makeScroller({ clientHeight, scrollHeight }) {
  return {
    clientHeight,
    _scrollHeight: scrollHeight,
    _scrollTop: 0,
    get scrollHeight() {
      return this._scrollHeight;
    },
    get scrollTop() {
      return this._scrollTop;
    },
    set scrollTop(v) {
      const max = Math.max(0, this._scrollHeight - this.clientHeight);
      this._scrollTop = Math.min(Math.max(0, v), max);
    },
    // Late layout: fonts load, images decode, tables reflow. Content below the
    // viewport grows and scrollTop is NOT adjusted — exactly what a browser
    // does when the growth is below the current scroll position.
    grow(px) {
      this._scrollHeight += px;
    },
    atBottom() {
      return this._scrollTop === this._scrollHeight - this.clientHeight;
    },
    distanceFromBottom() {
      return this._scrollHeight - this._scrollTop - this.clientHeight;
    },
  };
}

// A hook context with no anchor and a ResizeObserver we can observe the
// teardown of. `el.dataset` is read by honourAnchor(); an empty dataset means
// "no deep link", which is the sidebar-click path this bug lives on.
function makeCtx(scrollEl) {
  const ctx = {
    el: { dataset: {} },
    scrollEl,
    _initialScroll: true,
    _anchoredFor: null,
    _settleTimer: null,
    _settleCeiling: null,
    _resizeObserver: { disconnect() {} },
    resizeObserverLive: true,
    // Real methods off the loaded hook — the point is to exercise the
    // shipped logic, not a restatement of it.
    distanceFromBottom: ScrollToBottom.distanceFromBottom,
    honourAnchor: ScrollToBottom.honourAnchor,
    scrollToBottom: ScrollToBottom.scrollToBottom,
    _armSettleTimer: ScrollToBottom._armSettleTimer,
    _endInitialPhase: ScrollToBottom._endInitialPhase,
    _clearSettleTimers: ScrollToBottom._clearSettleTimers,
  };
  // Only the observer teardown is shimmed, so a test can see whether it
  // happened without needing a real ResizeObserver.
  ctx._disconnectResizeObserver = function () {
    this.resizeObserverLive = false;
    this._resizeObserver = null;
  };
  return ctx;
}

// The arrival phase ends after SETTLE_QUIET_MS of no resize. Tests that care
// about the post-arrival regime wait past it rather than reaching into the
// hook's internals.
const settle = () => new Promise((r) => setTimeout(r, 350));

// ---------------------------------------------------------------------------

test("a tall channel lands at the newest message even when layout settles after the first frame", () => {
  // 50 agent reports. At first paint the text is laid out but images, web
  // fonts and code-block scrollers have not settled: 6000px measured.
  const el = makeScroller({ clientHeight: 800, scrollHeight: 6000 });
  const ctx = makeCtx(el);

  // First frame: mounted() -> _safeUpdate() -> scrollToBottom()
  ctx.scrollToBottom();

  assert.equal(el.atBottom(), true, "the first snap should reach the bottom");
  assert.equal(
    ctx._initialScroll,
    true,
    "mere overflow must NOT end the arrival phase — a single tall message " +
      "overflows on frame one, long before layout has settled",
  );
  assert.equal(
    ctx.resizeObserverLive,
    true,
    "and the ResizeObserver (019ff6c9) must survive to catch that late layout",
  );

  // Late layout settles. On a channel of tall messages this is thousands of
  // pixels, all of it below the reader.
  el.grow(6000);

  // A later stream batch / updated() fires.
  ctx.scrollToBottom();

  assert.equal(
    el.atBottom(),
    true,
    `the reader is stranded ${el.distanceFromBottom()}px above the newest ` +
      `message: the initial phase ended on frame one, the ResizeObserver was ` +
      `disconnected, and ${el.distanceFromBottom()}px exceeds the 150px ` +
      `near-bottom gate, so nothing will ever snap again`,
  );
  ctx._endInitialPhase("test cleanup");
});

test("growth under the near-bottom gate is absorbed — why short channels look fine", () => {
  // Same structure, but the late growth is small: a channel of short text
  // messages with no images shifts by a few px at most.
  const el = makeScroller({ clientHeight: 800, scrollHeight: 6000 });
  const ctx = makeCtx(el);

  ctx.scrollToBottom();
  el.grow(120); // < NEAR_BOTTOM_PX
  ctx.scrollToBottom();

  assert.equal(
    el.atBottom(),
    true,
    "growth inside the 150px gate is still corrected, which is why this " +
      "defect is invisible in chatty short-message channels",
  );
  ctx._endInitialPhase("test cleanup");
});

test("the ResizeObserver survives frame one, so late layout can still be caught", () => {
  // Task 019ff6c9 added the ResizeObserver specifically so that late layout
  // re-snaps. This asserts the teardown races ahead of the growth it was
  // added to catch — the reason that fix does not hold.
  const el = makeScroller({ clientHeight: 800, scrollHeight: 6000 });
  const ctx = makeCtx(el);

  ctx.scrollToBottom();

  assert.equal(
    ctx.resizeObserverLive,
    true,
    "the ResizeObserver must survive the first frame — it was added to catch " +
      "layout that settles AFTER the container first overflows, and a channel " +
      "of tall messages overflows on frame one",
  );
  ctx._endInitialPhase("test cleanup");
});

// ---------------------------------------------------------------------------
// The other half: the arrival phase must actually END. Pinning the reader to
// the bottom forever would fix this bug by reintroducing the unconditional
// yank-to-bottom that task 019f51d1 removed. These two guard that direction.
// ---------------------------------------------------------------------------

test("once layout goes quiet the phase ends and a scrolled-up reader is left alone", async () => {
  const el = makeScroller({ clientHeight: 800, scrollHeight: 6000 });
  const ctx = makeCtx(el);

  ctx.scrollToBottom();
  await settle();

  assert.equal(
    ctx._initialScroll,
    false,
    "quiet layout must end the arrival phase, or every later stream batch " +
      "would yank the reader to the bottom (the 019f51d1 regression)",
  );

  // The reader deliberately scrolls up to read history.
  el.scrollTop = 1000;
  const parked = el.scrollTop;

  // A new message arrives.
  el.grow(400);
  ctx.scrollToBottom();

  assert.equal(
    el.scrollTop,
    parked,
    "a reader who has scrolled away from the bottom must not be moved",
  );
});

test("a container that never stops resizing still releases the reader at the ceiling", async () => {
  // Pathological case: something keeps resizing forever. Without a ceiling the
  // arrival phase would never end and the reader could never scroll up.
  const el = makeScroller({ clientHeight: 800, scrollHeight: 6000 });
  const ctx = makeCtx(el);

  ctx.scrollToBottom();
  // Keep layout "noisy" for longer than the quiet window by re-arming.
  for (let i = 0; i < 4; i++) {
    await new Promise((r) => setTimeout(r, 120));
    el.grow(50);
    ctx._armSettleTimer();
  }
  assert.equal(
    ctx._initialScroll,
    true,
    "continuous resizing keeps the phase open (precondition for this test)",
  );

  ctx._endInitialPhase("ceiling");
  assert.equal(
    ctx._initialScroll,
    false,
    "the ceiling exit must be able to end a phase that quiet-settling never " +
      "will — otherwise a permanently-resizing container pins the reader",
  );
  assert.equal(ctx._settleTimer, null, "and it clears its timers");
});

// Drive the REAL mounted() so the listener wiring itself is under test.
// The previous version of this guard called _endInitialPhase() by hand: it
// proved the method worked and proved nothing about whether mounted() ever
// attaches it. A mutation blanking the handler survived that version.
function mountHook(scrollEl) {
  const listeners = {};
  scrollEl.addEventListener = (evt, fn) => {
    (listeners[evt] ||= []).push(fn);
  };
  scrollEl.removeEventListener = (evt, fn) => {
    listeners[evt] = (listeners[evt] || []).filter((f) => f !== fn);
  };

  const el = {
    dataset: {},
    closest: (sel) => (sel === "[data-scroll-container]" ? scrollEl : null),
    querySelectorAll: () => [],
  };

  const prev = {
    MutationObserver: globalThis.MutationObserver,
    ResizeObserver: globalThis.ResizeObserver,
    requestAnimationFrame: globalThis.requestAnimationFrame,
  };
  globalThis.MutationObserver = class {
    observe() {}
    disconnect() {}
  };
  globalThis.ResizeObserver = class {
    constructor(cb) {
      this.cb = cb;
    }
    observe() {}
    disconnect() {}
  };
  globalThis.requestAnimationFrame = () => 0;

  const ctx = Object.create(ScrollToBottom);
  ctx.el = el;
  ctx.handleEvent = () => {};
  ScrollToBottom.mounted.call(ctx);

  Object.assign(globalThis, prev);
  return { ctx, listeners, fire: (evt) => (listeners[evt] || []).forEach((f) => f()) };
}

test("mounted() attaches the gesture listeners that end the arrival phase", () => {
  const el = makeScroller({ clientHeight: 800, scrollHeight: 6000 });
  const { ctx, listeners, fire } = mountHook(el);

  for (const evt of ["wheel", "touchmove", "keydown"]) {
    assert.ok(
      (listeners[evt] || []).length > 0,
      `mounted() must attach a ${evt} listener — without it a reader who ` +
        `scrolls during the arrival window gets yanked back by the observer`,
    );
  }
  assert.equal(ctx._initialScroll, true, "still arriving after mount");

  fire("wheel");

  assert.equal(
    ctx._initialScroll,
    false,
    "the attached handler must end the arrival phase, not merely exist",
  );

  ScrollToBottom.destroyed.call(ctx);
  for (const evt of ["wheel", "touchmove", "keydown"]) {
    assert.equal(
      (listeners[evt] || []).length,
      0,
      `destroyed() must remove the ${evt} listener`,
    );
  }
});

test("a reader who scrolls during the arrival phase keeps control", () => {
  // The window between mount and settle is short but real. If the reader
  // scrolls up inside it, the ResizeObserver would otherwise keep yanking
  // them back to the live edge as late layout lands — the 019f51d1
  // regression, reintroduced through a side door.
  const el = makeScroller({ clientHeight: 800, scrollHeight: 6000 });
  const ctx = makeCtx(el);

  ctx.scrollToBottom();
  assert.equal(ctx._initialScroll, true, "still arriving (precondition)");

  // The gesture handler mounted() installs, invoked as the listener would.
  ctx._endInitialPhase("user gesture");

  assert.equal(
    ctx._initialScroll,
    false,
    "a real gesture must end the arrival phase immediately",
  );
  assert.equal(
    ctx.resizeObserverLive,
    false,
    "and stop the observer re-snapping the reader who just scrolled away",
  );

  el.scrollTop = 1000;
  const parked = el.scrollTop;
  el.grow(5000);
  ctx.scrollToBottom();

  assert.equal(el.scrollTop, parked, "late layout must not move them back");
});
