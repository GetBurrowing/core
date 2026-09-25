import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import ScrollToBottom from "../../js/hooks/scroll_to_bottom.js";

/**
 * The reader is pinned to the BOTTOM of the conversation, not to a scrollTop.
 *
 * `#chat-message-scroller` is `flex-1 min-h-0` in a flex COLUMN, so its
 * viewport height is whatever its in-flow siblings leave it. Every one of
 * these siblings changes height at runtime, and none of them lives inside
 * `#message-list`:
 *
 *   above the scroller   the search / pins / canvases drawers, archived banner
 *   below the scroller   streaming-reply bubbles, typing indicator, composer
 *
 * When one of them resizes, the browser leaves `scrollTop` alone. Since
 * `distanceFromBottom()` is `scrollHeight - scrollTop - clientHeight`, the
 * reader's distance from the live edge moves by the FULL delta with no scroll
 * event, no `updated()` and no gesture. Past NEAR_BOTTOM_PX the follow rule
 * then correctly declines to follow — a reader who never scrolled has been
 * silently reclassified as reading history.
 *
 * WHY THE FIXTURES ARE THE SIZES THEY ARE. Every resize here is larger than
 * NEAR_BOTTOM_PX (150), because a smaller one lands in the branch that already
 * worked: the reader stays inside the follow band and the next message brings
 * them back. A fixture under the threshold cannot fail for any implementation
 * and is vacuous by construction — the same trap `scroll_to_bottom_follow`
 * documents for message heights. The guard test below pins that.
 *
 * The three shapes deliberately cover BOTH sides of the scroller and BOTH
 * report paths, because the defect was reported twice with different framings:
 * "chat opens mid-thread when the space has a live canvas" (a drawer ABOVE)
 * and "even at full screen with no canvas, whenever you send a new message I
 * have to scroll down" (the composer and the streaming bubble, BELOW). They
 * are one defect.
 */

const NEAR_BOTTOM_PX = 150;

// Measured off the reported screenshot's own numbers: the LIVE CANVASES panel
// with its create form is roughly 470px. Any value comfortably over
// NEAR_BOTTOM_PX exercises the same branch.
const CANVAS_DRAWER_PX = 470;
// `compose_input.js` `_autoResize` grows the textarea from 33px to a 200px
// cap. 167px is the full travel — and it is over NEAR_BOTTOM_PX on its own,
// which is why typing a long message was enough to break sending it.
const COMPOSER_GROWTH_PX = 167;
// A streaming agent reply of a few paragraphs, rendered by `streaming_replies`
// as a `flex-shrink-0` sibling BELOW the scroller.
const STREAMING_BUBBLE_PX = 300;

// Models the four numbers the hook reads off the scroller, plus the browser's
// clamp of scrollTop to [0, scrollHeight - clientHeight]. The clamp is
// load-bearing: the hook assigns `scrollTop = scrollHeight` and relies on it.
// `clientHeight` is a plain mutable field precisely because this suite is
// about it changing.
function fakeScroller({
  clientHeight = 1000,
  clientWidth = 900,
  scrollHeight = 8000,
} = {}) {
  return {
    clientHeight,
    clientWidth,
    scrollHeight,
    _scrollTop: 0,
    scrollTopWrites: [],
    get scrollTop() {
      return this._scrollTop;
    },
    set scrollTop(v) {
      const max = Math.max(0, this.scrollHeight - this.clientHeight);
      const clamped = Math.min(Math.max(0, v), max);
      if (clamped === this._scrollTop) return;
      this._scrollTop = clamped;
      this.scrollTopWrites.push(clamped);
    },
    distanceFromBottom() {
      return this.scrollHeight - this._scrollTop - this.clientHeight;
    },
    parkAt(distance) {
      this._scrollTop = this.scrollHeight - this.clientHeight - distance;
      this.scrollTopWrites = [];
    },
    // A sibling ABOVE or BELOW the scroller takes/returns vertical space. The
    // browser does NOT move scrollTop when a scroller merely gets shorter —
    // that is the whole mechanism — so this deliberately leaves it alone and
    // lets the getter clamp on read.
    resizeViewport(delta) {
      this.clientHeight += delta;
      const max = Math.max(0, this.scrollHeight - this.clientHeight);
      if (this._scrollTop > max) this._scrollTop = max;
    },
    listeners: [],
    addEventListener(type, fn, opts) {
      this.listeners.push({ type, fn, opts });
    },
    removeEventListener(type, fn) {
      this.listeners = this.listeners.filter(
        (l) => !(l.type === type && l.fn === fn),
      );
    },
  };
}

function fakeRow(participantId = "p-1") {
  const classes = new Set();
  return {
    dataset: { participantId },
    style: {},
    classList: {
      toggle(name, force) {
        if (force) classes.add(name);
        else classes.delete(name);
      },
      contains: (name) => classes.has(name),
    },
    // No Context trigger inside: grouping's opensRun probe (01a0d8de) finds nothing.
    querySelector: () => null,
  };
}

// `#message-list`, which is NOT the scroller: it resolves the real one
// through `closest("[data-scroll-container]")`, exactly as production does.
function fakeList(scrollEl, rows) {
  return {
    dataset: { spaceId: "space-fixture-1" },
    closest: (sel) => (sel === "[data-scroll-container]" ? scrollEl : null),
    querySelectorAll: (sel) =>
      sel === "[data-participant-id]" ? rows : [],
    querySelector: () => null,
  };
}

describe("ScrollToBottom — a sibling resizes the scroller's viewport", () => {
  let priorMO, priorRO, priorRAF, pendingFrames, observers;

  beforeEach(() => {
    priorMO = globalThis.MutationObserver;
    globalThis.MutationObserver = class {
      constructor(cb) {
        this.cb = cb;
      }
      observe() {}
      disconnect() {}
    };

    // Every constructed observer is recorded so a test can fire the one it
    // means and assert on teardown. A real ResizeObserver also delivers one
    // callback for the current size on `observe()`; `deliverInitial` below
    // reproduces that, because a fix that mistook it for a change would snap
    // a reader who had not moved.
    observers = [];
    priorRO = globalThis.ResizeObserver;
    globalThis.ResizeObserver = class {
      constructor(cb) {
        this.cb = cb;
        this.connected = false;
        this.target = null;
        observers.push(this);
      }
      observe(target) {
        this.connected = true;
        this.target = target;
      }
      disconnect() {
        this.connected = false;
      }
    };

    priorRAF = globalThis.requestAnimationFrame;
    pendingFrames = new Set();
    globalThis.requestAnimationFrame = (cb) => {
      const id = setTimeout(() => {
        pendingFrames.delete(id);
        cb();
      }, 0);
      pendingFrames.add(id);
      return id;
    };
    globalThis.cancelAnimationFrame = (id) => {
      pendingFrames.delete(id);
      clearTimeout(id);
    };
  });

  afterEach(() => {
    pendingFrames.forEach((id) => clearTimeout(id));
    pendingFrames.clear();
    globalThis.MutationObserver = priorMO;
    if (priorRO !== undefined) globalThis.ResizeObserver = priorRO;
    else delete globalThis.ResizeObserver;
    if (priorRAF !== undefined) globalThis.requestAnimationFrame = priorRAF;
    else delete globalThis.requestAnimationFrame;
  });

  // Mount, then put the hook in the state a settled conversation is actually
  // in: arrival phase spent and its observer torn down (which is what makes
  // this a test of the SECOND observer and not of the arrival one), nothing
  // reported to the server yet, the reader parked wherever `distance` says.
  function settledHook({ distance = 0, ...geometry } = {}) {
    const scrollEl = fakeScroller(geometry);
    const el = fakeList(scrollEl, [fakeRow(), fakeRow()]);
    const hook = Object.create(ScrollToBottom);
    hook.el = el;
    hook.handleEvent = vi.fn();
    hook.pushEvent = vi.fn();
    hook.mounted();

    hook._endInitialPhase("test setup");
    clearTimeout(hook._iosFallbackTimer);
    hook._iosFallbackTimer = null;
    pendingFrames.forEach((id) => clearTimeout(id));
    pendingFrames.clear();

    scrollEl.parkAt(distance);
    hook.pushEvent.mockClear();
    hook._lastAway = null;
    hook._lastDeep = null;
    hook._preUpdateDistance = null;
    return { el, scrollEl, hook };
  }

  // The live viewport observer: the one still connected after arrival.
  function viewportObserver(hook) {
    return observers.find((o) => o === hook._viewportObserver);
  }

  function resize(hook, scrollEl, delta) {
    scrollEl.resizeViewport(delta);
    viewportObserver(hook).cb();
  }

  function pushedAway(hook) {
    return hook.pushEvent.mock.calls
      .filter(([name]) => name === "jump_to_latest_distance")
      .map(([, payload]) => payload.away);
  }

  it("FIXTURE GUARD: every resize in this file exceeds the follow threshold", () => {
    // Under the threshold the reader never leaves the follow band and the
    // next message brings them back, so no implementation can fail. If these
    // shrink, the file has stopped testing anything.
    expect(CANVAS_DRAWER_PX).toBeGreaterThan(NEAR_BOTTOM_PX);
    expect(COMPOSER_GROWTH_PX).toBeGreaterThan(NEAR_BOTTOM_PX);
    expect(STREAMING_BUBBLE_PX).toBeGreaterThan(NEAR_BOTTOM_PX);
  });

  it("SETUP GUARD: the arrival observer is gone and a second one is still live", () => {
    // The whole point of the fix is that it outlives `_endInitialPhase`. If
    // these two ever collapse into one observer, every test below would be
    // re-testing the arrival snap that already existed.
    const { hook } = settledHook();

    expect(hook._resizeObserver).toBe(null);
    expect(hook._viewportObserver).not.toBe(null);
    expect(viewportObserver(hook).connected).toBe(true);
  });

  it("(a) the canvases drawer opening keeps a bottom-parked reader at the bottom", () => {
    const { scrollEl, hook } = settledHook({ distance: 0 });

    resize(hook, scrollEl, -CANVAS_DRAWER_PX);

    // Without the fix this reader is now CANVAS_DRAWER_PX above the newest
    // message — the reported "opens mid-thread with the jump chip showing".
    expect(scrollEl.distanceFromBottom()).toBe(0);
    expect(pushedAway(hook)).not.toContain(true);
  });

  it("(a2) the composer growing under the typist keeps them at the bottom", () => {
    const { scrollEl, hook } = settledHook({ distance: 0 });

    resize(hook, scrollEl, -COMPOSER_GROWTH_PX);

    // This is the "no canvas, full screen, I have to scroll down every time I
    // send a message" report: the composer alone carried the sender past
    // NEAR_BOTTOM_PX before the send, so the follow rule then declined to
    // follow their own message.
    expect(scrollEl.distanceFromBottom()).toBe(0);
    expect(pushedAway(hook)).not.toContain(true);
  });

  it("(a3) a streaming reply bubble growing BELOW the list keeps the reader at the bottom", () => {
    const { scrollEl, hook } = settledHook({ distance: 0 });

    // `streaming_replies` renders one `flex-shrink-0` block per in-flight
    // chunk, and it grows on every chunk.
    resize(hook, scrollEl, -STREAMING_BUBBLE_PX / 2);
    resize(hook, scrollEl, -STREAMING_BUBBLE_PX / 2);

    expect(scrollEl.distanceFromBottom()).toBe(0);
    expect(pushedAway(hook)).not.toContain(true);
  });

  it("(a4) follows a reader at the far edge of the follow band", () => {
    const { scrollEl, hook } = settledHook({ distance: NEAR_BOTTOM_PX });

    resize(hook, scrollEl, -CANVAS_DRAWER_PX);

    // NEAR_BOTTOM_PX is still "following" by the hook's own boundary, and it
    // is the SAME constant `scrollToBottom()` thresholds against — the two
    // rules must not name different readers.
    expect(scrollEl.distanceFromBottom()).toBe(0);
  });

  it("(b) COST: a reader who scrolled up to read history is NOT yanked down", () => {
    const { scrollEl, hook } = settledHook({ distance: 900 });
    const heldAt = scrollEl.scrollTop;

    resize(hook, scrollEl, -CANVAS_DRAWER_PX);

    // This is the accepted cost, pinned. Reading history is an act of intent:
    // the reader keeps the pixel they were looking at, even though the resize
    // has just changed their distance from the bottom. Restoring THAT distance
    // instead would drag the text out from under them on every keystroke.
    expect(scrollEl.scrollTop).toBe(heldAt);
    expect(scrollEl.scrollTopWrites).toEqual([]);
  });

  it("(b2) COST: holds a reader one pixel past the follow threshold", () => {
    const { scrollEl, hook } = settledHook({ distance: NEAR_BOTTOM_PX + 1 });
    const heldAt = scrollEl.scrollTop;

    resize(hook, scrollEl, -CANVAS_DRAWER_PX);

    expect(scrollEl.scrollTop).toBe(heldAt);
    expect(scrollEl.scrollTopWrites).toEqual([]);
  });

  it("ANTI-VACUITY: an observer callback with NO height change moves nothing", () => {
    // A space with no drawer, no streaming reply and an untouched composer
    // still gets ResizeObserver callbacks (scroll-driven relayouts, DPR
    // changes, the initial delivery). An implementation that simply slammed to
    // the bottom on every callback would pass every test above and fail this
    // one — including for the scrolled-up reader below.
    const { scrollEl, hook } = settledHook({ distance: 900 });
    const heldAt = scrollEl.scrollTop;

    viewportObserver(hook).cb();
    viewportObserver(hook).cb();

    expect(scrollEl.scrollTop).toBe(heldAt);
    expect(scrollEl.scrollTopWrites).toEqual([]);
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("ANTI-VACUITY: a reader INSIDE the follow band is not teleported by a bare callback", () => {
    // The reader above is far enough up that the pre-resize distance alone
    // declines to act, so they cannot tell "the viewport did not change size"
    // from "the reader is reading history". This one can: 50px up is squarely
    // inside the follow band, so ONLY the height-changed guard keeps them
    // where they parked. A reader who deliberately nudged up a few lines with
    // nothing resizing must stay there.
    const { scrollEl, hook } = settledHook({ distance: 50 });
    const heldAt = scrollEl.scrollTop;

    viewportObserver(hook).cb();

    expect(scrollEl.scrollTop).toBe(heldAt);
    expect(scrollEl.scrollTopWrites).toEqual([]);
  });

  it("ANTI-VACUITY: the observer's first delivery on observe() is not a change", () => {
    // A real ResizeObserver fires once for the CURRENT size the moment it
    // starts observing. Mount must seed the dimensions BEFORE observing, or
    // that delivery reads as a change from nothing.
    const scrollEl = fakeScroller();
    const el = fakeList(scrollEl, [fakeRow()]);
    const hook = Object.create(ScrollToBottom);
    hook.el = el;
    hook.handleEvent = vi.fn();
    hook.pushEvent = vi.fn();

    hook.mounted();
    hook._endInitialPhase("test setup");
    clearTimeout(hook._iosFallbackTimer);
    scrollEl.parkAt(900);

    viewportObserver(hook).cb();

    expect(scrollEl.scrollTopWrites).toEqual([]);
  });

  it("declines a WIDTH change — there the pre-resize substitution is a fiction", () => {
    // A width change rewraps every message, so `scrollHeight` moved in the
    // SAME frame and `scrollHeight_new - scrollTop - prevHeight` is no longer
    // the reader's old distance from anything. The rail transition is the
    // width case and it already has an owner: `holdAnchorThroughReflow`, armed
    // from `sidebar_collapsed_changed`.
    //
    // THE FIXTURE IS BUILT SO THE FICTION WOULD LIE IN THE DANGEROUS
    // DIRECTION. The reader has scrolled 1000px up to read history. The window
    // is then resized: it gets WIDER, so the text rewraps to fewer lines and
    // `scrollHeight` drops 8000 → 7000; and it gets SHORTER, so the scroller's
    // own box drops 1000 → 600. Both arrive in one callback, which is what a
    // window resize or a tablet rotation actually looks like.
    //
    // Substituting the old height into the new geometry yields 0 — "this
    // reader is glued to the bottom" — when they are in fact 400px above it
    // and were 1000px above it a frame ago. Acting on that number would yank
    // a reader who is reading, which is the one thing this hook must never do.
    const { scrollEl, hook } = settledHook({ distance: 1000 });
    const heldAt = scrollEl.scrollTop;
    expect(heldAt).toBe(6000);

    scrollEl.clientWidth += 300;
    scrollEl.scrollHeight = 7000;
    scrollEl.clientHeight = 600;
    viewportObserver(hook).cb();

    // The fiction the guard exists to reject, spelled out so a future edit
    // cannot quietly make this fixture vacuous.
    expect(scrollEl.scrollHeight - scrollEl.scrollTop - 1000).toBeLessThan(
      NEAR_BOTTOM_PX,
    );
    expect(scrollEl.distanceFromBottom()).toBe(400);

    expect(scrollEl.scrollTop).toBe(heldAt);
    expect(scrollEl.scrollTopWrites).toEqual([]);
  });

  it("defers to the arrival phase while the conversation is still landing", () => {
    // Inside the arrival phase the other observer is already pinning the
    // reader to the live edge on every resize. Two owners of scrollTop in the
    // same window is how earlier passes over this file undid each other.
    const scrollEl = fakeScroller();
    const el = fakeList(scrollEl, [fakeRow()]);
    const hook = Object.create(ScrollToBottom);
    hook.el = el;
    hook.handleEvent = vi.fn();
    hook.pushEvent = vi.fn();
    hook.mounted();
    clearTimeout(hook._iosFallbackTimer);
    pendingFrames.forEach((id) => clearTimeout(id));
    pendingFrames.clear();

    expect(hook._initialScroll).toBe(true);
    scrollEl.parkAt(0);

    scrollEl.resizeViewport(-CANVAS_DRAWER_PX);
    hook._viewportObserver.cb();

    expect(scrollEl.scrollTopWrites).toEqual([]);

    // …but it must still track the size, or the first post-arrival resize
    // would be measured against a stale height.
    expect(hook._lastClientHeight).toBe(scrollEl.clientHeight);
    hook._endInitialPhase("test cleanup");
  });

  it("reports the reader back as near the bottom after a resize re-pins them", () => {
    // The chip's visibility is server-owned. A re-pin that did not report
    // would leave a "Jump to latest" chip standing over a reader who is
    // already at the latest message.
    const { scrollEl, hook } = settledHook({ distance: 0 });
    hook._lastAway = true;

    resize(hook, scrollEl, -CANVAS_DRAWER_PX);

    expect(pushedAway(hook)).toEqual([false]);
  });

  it("disconnects the viewport observer on destroy", () => {
    const { hook } = settledHook();
    const observer = viewportObserver(hook);

    hook.destroyed();

    expect(observer.connected).toBe(false);
    expect(hook._viewportObserver).toBe(null);
  });
});
