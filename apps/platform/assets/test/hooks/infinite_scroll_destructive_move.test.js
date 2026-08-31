import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import ScrollToBottom from "../../js/hooks/scroll_to_bottom.js";
import InfiniteScroll from "../../js/hooks/infinite_scroll.js";

/**
 * A LiveView patch can DESTROY the scroller's scroll offset instead of
 * scrolling it.
 *
 * Measured in the real app (task 01a05873, zero-hunt CDP trace in
 * `priv/measurements/01a05873-desktop-follow/`): opening the canvases
 * drawer inserts a node ahead of the keyed siblings of
 * `#chat-message-scroller`, and morphdom realigns the child list by
 * REMOVING the scroller and re-inserting the same node into the same
 * parent. `Node.insertBefore` of an attached node detaches it first, and a
 * detached scroller forgets its offset: it re-inserts at scrollTop 0 with
 * NO scroll event and scrollHeight still full. The patch never touches
 * `#message-list`, so no hook callback runs either.
 *
 * Two consumers then read the wrecked offset as if it were the reader's:
 *
 *   * InfiniteScroll's top sentinel intersects at scrollTop 0 and captures
 *     `_preTop = 0`; the post-prepend compensation lands the reader at
 *     `0 + Δ` — thousands of pixels away with the jump chip raised. THE
 *     REPORTED DEFECT.
 *   * ScrollToBottom's #848 viewport observer reconstructs the pre-resize
 *     distance from the zeroed offset, concludes the reader was deep in
 *     history, and declines the snap it exists to run.
 *
 * The fix has two halves, each covered here:
 *
 *   A. InfiniteScroll captures `_preTop` from the last scroll-observed
 *      offset when the live offset was silently zeroed (a real scroll to
 *      the top delivers scroll events; a silent zeroing delivers none).
 *   B. ScrollToBottom repairs the destroyed offset in the MutationObserver
 *      microtask — before paint, before ResizeObserver/IntersectionObserver
 *      delivery — so the reader never leaves the edge and #848 works again.
 *
 * The "destructive move" in these fixtures is a RAW write of the fake
 * scroller's backing field with no scroll-event dispatch: that is exactly
 * what the real DOM does (no event) and what a programmatic write does NOT
 * do (a write always delivers a scroll event).
 */

const NEAR_BOTTOM_PX = 150;

function fakeScroller({
  scrollTop = 0,
  scrollHeight = 3995,
  clientHeight = 495,
  clientWidth = 992,
} = {}) {
  return {
    scrollHeight,
    clientHeight,
    clientWidth,
    _scrollTop: scrollTop,
    scrollTopWrites: [],
    listeners: [],
    get scrollTop() {
      return this._scrollTop;
    },
    set scrollTop(v) {
      // Clamp like a real scroller: a write past the content bounds parks at
      // the bottom edge, it does not overshoot.
      const clamped = Math.max(0, Math.min(v, this.scrollHeight - this.clientHeight));
      if (clamped === this._scrollTop) return;
      this._scrollTop = clamped;
      this.scrollTopWrites.push(clamped);
    },
    // A genuine scroll (user, snap, clamp) delivers scroll events; the fake
    // requires the test to dispatch them explicitly so a silent zeroing is
    // expressible as "no dispatch".
    fireScroll() {
      this.listeners
        .filter((l) => l.type === "scroll")
        .forEach((l) => l.fn());
    },
    addEventListener(type, fn) {
      this.listeners.push({ type, fn });
    },
    removeEventListener(type, fn) {
      this.listeners = this.listeners.filter((l) => !(l.type === type && l.fn === fn));
    },
  };
}

function fakeSentinel(scroller) {
  return {
    dataset: { direction: "older" },
    closest(sel) {
      return sel === "[data-scroll-container]" ? scroller : null;
    },
  };
}

// Mount the InfiniteScroll hook on a fake sentinel whose scroller is parked
// `parkTop` px into `scrollHeight` of content. Returns the hook, the
// scroller, and a `sentinelIntersects()` trigger wired to the captured
// IntersectionObserver callback.
function mountInfiniteScroll({ parkTop, scrollHeight, clientHeight }) {
  const scroller = fakeScroller({
    scrollTop: parkTop,
    scrollHeight,
    clientHeight,
  });
  const el = fakeSentinel(scroller);
  const hook = Object.create(InfiniteScroll);
  hook.el = el;
  hook.pushEvent = vi.fn((name, _payload, reply) => {
    hook.pushReply = reply;
  });
  hook.mounted();
  const observer = hook._observer;
  return {
    hook,
    scroller,
    el,
    // The real IntersectionObserver invokes its callback with `this` bound
    // to the observer instance; mirror that.
    sentinelIntersects: () =>
      observer.cb.call(observer, [{ isIntersecting: true }]),
    loadOlderReply: () => hook.pushReply(),
  };
}

function fakeList({
  scrollTop,
  scrollHeight = 3995,
  clientHeight = 722,
  clientWidth = 992,
} = {}) {
  return {
    dataset: { spaceId: "space-fixture-1" },
    scrollHeight,
    clientHeight,
    clientWidth,
    // A stable parent, so the realign observer has something to observe.
    parentElement: { id: "chat-drop-zone" },
    _scrollTop: scrollTop,
    scrollTopWrites: [],
    get scrollTop() {
      return this._scrollTop;
    },
    set scrollTop(v) {
      // Clamp like a real scroller (see fakeScroller).
      const clamped = Math.max(0, Math.min(v, this.scrollHeight - this.clientHeight));
      if (clamped === this._scrollTop) return;
      this._scrollTop = clamped;
      this.scrollTopWrites.push(clamped);
    },
    fireScroll() {
      this.listeners.filter((l) => l.type === "scroll").forEach((l) => l.fn());
    },
    listeners: [],
    addEventListener(type, fn) {
      this.listeners.push({ type, fn });
    },
    removeEventListener(type, fn) {
      this.listeners = this.listeners.filter((l) => !(l.type === type && l.fn === fn));
    },
    closest() {
      return null;
    },
    querySelectorAll() {
      return [];
    },
    querySelector() {
      return null;
    },
  };
}

function buildScrollHook(el) {
  const hook = Object.create(ScrollToBottom);
  hook.el = el;
  hook.handleEvent = vi.fn();
  hook.pushEvent = vi.fn();
  return hook;
}

// The realign observer shim: capture the callback the hook registers so the
// test can deliver the exact MutationObserver records the drawer patch
// produces (the scroller appearing among removedNodes — it is already
// re-attached by the time the microtask runs, as in the real DOM).
function capturedMutationCallbacks(hook) {
  return hook._realignObserver.cb;
}

describe("InfiniteScroll — capturing _preTop across a destructive DOM move", () => {
  let priorIO, priorRAF, pendingFrames;

  beforeEach(() => {
    priorIO = globalThis.IntersectionObserver;
    globalThis.IntersectionObserver = class {
      constructor(cb) {
        this.cb = cb;
      }
      observe() {}
      disconnect() {}
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
    if (priorIO !== undefined) globalThis.IntersectionObserver = priorIO;
    else delete globalThis.IntersectionObserver;
    if (priorRAF !== undefined) globalThis.requestAnimationFrame = priorRAF;
    else delete globalThis.requestAnimationFrame;
  });

  it("FIXTURE GUARD: the parked reader is deep enough that _preTop=0 strands them", () => {
    // The strand is 0 + Δ. This fixture must keep Δ (the prepend) far larger
    // than the drawer shrink, so "reader thrown to 0+Δ" and "reader held at
    // their pixel" are distinguishable by more than the drawer's height.
    expect(3960).toBeGreaterThan(NEAR_BOTTOM_PX * 2);
  });

  it("(a) captures the pre-reset offset when the patch zeroes scrollTop silently", () => {
    const { hook, scroller, sentinelIntersects } = mountInfiniteScroll({
      parkTop: 3273,
      scrollHeight: 3995,
      clientHeight: 495,
    });

    // THE DEFECTIVE PATCH: the scroller is detached and re-inserted. The
    // offset is destroyed with no scroll event — a raw backing-field write.
    scroller._scrollTop = 0;
    expect(scroller.scrollTopWrites).toEqual([]);

    sentinelIntersects();

    // Pre-fix this captured 0, and the compensation threw the reader to
    // 0 + Δ (measured 3960) with the jump chip raised.
    expect(hook._preTop).toBe(3273);
  });

  it("(a2) compensates from the pre-reset offset, leaving the reader where they were", async () => {
    const { hook, scroller, sentinelIntersects, loadOlderReply } =
      mountInfiniteScroll({
        parkTop: 3273,
        scrollHeight: 3995,
        clientHeight: 495,
      });

    scroller._scrollTop = 0; // the destructive move: silent
    sentinelIntersects();
    // 50 older rows prepend: 3995 -> 7955.
    scroller.scrollHeight = 7955;
    loadOlderReply();
    await new Promise((r) => setTimeout(r, 0));

    // Reader compensated from where they actually were (3273), not from the
    // wrecked 0. Pre-fix: scrollTop became 0 + 3960 = 3960.
    expect(scroller.scrollTop).toBe(3273 + 3960);
    // Distance from the live edge equals exactly the drawer's shrink — the
    // reader was thrown away by NOTHING except the height change (which the
    // #848 viewport path then absorbs). Pre-fix: 7955 - 3960 - 495 = 3500.
    expect(scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight).toBe(227);
  });

  it("(b) CONTROL: a reader who genuinely scrolled to the top still captures 0", () => {
    // The deliberate-top load-older contract: scrolling to the top fires
    // scroll events, the memory reads 0, and the capture stays 0. A guard
    // that always substituted the memory would break prepend anchoring for
    // real top-readers.
    const { hook, scroller, sentinelIntersects } = mountInfiniteScroll({
      parkTop: 3273,
      scrollHeight: 3995,
      clientHeight: 495,
    });

    scroller._scrollTop = 900;
    scroller.fireScroll();
    scroller._scrollTop = 0;
    scroller.fireScroll();

    sentinelIntersects();
    expect(hook._preTop).toBe(0);
  });

  it("(b2) CONTROL: a reader parked at a nonzero offset captures it unchanged", () => {
    const { hook, sentinelIntersects } = mountInfiniteScroll({
      parkTop: 2500,
      scrollHeight: 3995,
      clientHeight: 495,
    });
    sentinelIntersects();
    expect(hook._preTop).toBe(2500);
  });
});

describe("ScrollToBottom — repairing the offset a destructive move destroyed", () => {
  let priorMO, priorRO, priorRAF, pendingFrames;

  beforeEach(() => {
    priorMO = globalThis.MutationObserver;
    globalThis.MutationObserver = class {
      constructor(cb) {
        this.cb = cb;
      }
      observe() {}
      disconnect() {}
    };
    priorRO = globalThis.ResizeObserver;
    globalThis.ResizeObserver = class {
      constructor(cb) {
        this.cb = cb;
      }
      observe() {}
      disconnect() {}
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
    if (priorMO !== undefined) globalThis.MutationObserver = priorMO;
    else delete globalThis.MutationObserver;
    if (priorRO !== undefined) globalThis.ResizeObserver = priorRO;
    else delete globalThis.ResizeObserver;
    if (priorRAF !== undefined) globalThis.requestAnimationFrame = priorRAF;
    else delete globalThis.requestAnimationFrame;
  });

  // Mount, end the arrival phase, and park the reader at the bottom edge the
  // way the gate-5 harness does. mounted()'s synchronous initial snap has
  // already written scrollHeight by the time this returns, so the park is
  // applied AFTER mount (bottom edge = scrollHeight - clientHeight) and the
  // park's scroll events are dispatched so the realign memory holds it.
  function settledAtBottom() {
    const el = fakeList({ scrollHeight: 3995, clientHeight: 722 });
    const hook = buildScrollHook(el);
    hook.mounted();
    hook._initialScroll = false;
    hook._clearSettleTimers();
    hook._disconnectResizeObserver();
    el._scrollTop = 3273; // scrollHeight - clientHeight: parked at the edge
    el.fireScroll();
    el.scrollTopWrites = [];
    return { el, hook };
  }

  it("(c) restores the destroyed offset when the scroller is detached and re-inserted", () => {
    const { el, hook } = settledAtBottom();

    // The destructive move zeroes the offset silently — no scroll event.
    el._scrollTop = 0;
    expect(el.scrollTopWrites).toEqual([]);

    // The drawer patch, as recorded: the scroller among removedNodes (the
    // same node is re-added into the same parent within the same batch).
    capturedMutationCallbacks(hook)([
      { type: "childList", removedNodes: [el], addedNodes: [] },
    ]);

    // Pre-fix: no repair exists — the reader sits at 0 and every downstream
    // consumer reads 0.
    expect(el.scrollTop).toBe(3273);
  });

  it("(c2) end-to-end: repair, then the drawer shrink, holds the reader at the edge", () => {
    const { el, hook } = settledAtBottom();

    // 1. The destructive move zeroes the offset silently…
    el._scrollTop = 0;
    // …and the observer microtask repairs it before anything observes.
    capturedMutationCallbacks(hook)([
      { type: "childList", removedNodes: [el], addedNodes: [] },
    ]);

    // 2. The drawer's height shrink the patch also produced.
    el.clientHeight = 495;
    hook._onViewportResize();

    // Pre-fix the reconstruction read the zeroed offset (pre-resize distance
    // 3273 > NEAR_BOTTOM_PX) and declined — the exact reader #848 exists to
    // hold was stranded. With the repair the path sees the true pre-resize
    // distance (0) and snaps.
    expect(el.scrollTop).toBe(el.scrollHeight - el.clientHeight);
    expect(el.scrollHeight - el.scrollTop - el.clientHeight).toBe(0);
  });

  it("(c3) CONTROL: a real scroll away from the park is not undone by the guard", () => {
    const { el, hook } = settledAtBottom();

    // The reader scrolls up by hand: scroll events fire, the memory follows.
    el._scrollTop = 2000;
    el.fireScroll();

    capturedMutationCallbacks(hook)([
      { type: "childList", removedNodes: [el], addedNodes: [] },
    ]);

    expect(el.scrollTop).toBe(2000);
  });
});
