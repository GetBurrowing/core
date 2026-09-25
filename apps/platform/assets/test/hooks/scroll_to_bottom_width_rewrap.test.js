import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import ScrollToBottom from "../../js/hooks/scroll_to_bottom.js";

/**
 * WIDTH-CHANGE REWRAP STRANDING (task 01a05873).
 *
 * A width change rewraps every message body, so `scrollHeight` moves in the
 * same ResizeObserver frame. Before 01a05873 the viewport observer bailed
 * on width changes entirely (`if (width !== prevWidth) return;`) with a
 * comment pointing at `holdAnchorThroughReflow` as "the owner" of the width
 * case — but that pin is armed ONLY by `sidebar_collapsed_changed`. The
 * two desktop width resizes with no owner were the window resize and the
 * sidebar drag, and both STRANDED a bottom-parked reader:
 *
 *   window 1440 → 1200   rewrap grew scrollHeight +800px under an
 *                        unchanged scrollTop (measured on the real app)
 *   sidebar drag +200px  rewrap grew scrollHeight +400px
 *
 * after which the follow rule correctly declined — the reader was no
 * longer near the bottom — and the jump pill appeared for a reader who
 * never scrolled. Mobile has neither a resizable sidebar nor a window,
 * which is why the same code was never suspected on phones.
 *
 * The fix reconstructs the PRE-RESIZE distance from `_lastScrollHeight`
 * (tracked across patches by `_safeUpdate`) against the pre-resize
 * clientHeight, and re-anchors the same way the height path does: snap
 * when that distance was within NEAR_BOTTOM_PX, preserve the pixel
 * otherwise. It does NOT re-arm `holdAnchorThroughReflow` — pinning a
 * moving reader for 400ms is the stutter task 01a0419a stage 2 measured
 * and stage 3 removed; see the KEEP-OR-DROP note in `_reportDistance`.
 *
 * WHY THE REWRAP DELTAS ARE THE SIZES THEY ARE: every growth here is
 * larger than NEAR_BOTTOM_PX (150) because a smaller one lands in the
 * branch that already worked (the reader stays inside the follow band
 * and the next message brings them back) — the same vacuity trap the
 * viewport suite's header documents for sibling resizes.
 */

const NEAR_BOTTOM_PX = 150;

// Models the four numbers the hook reads off the scroller, plus the
// browser's clamp of scrollTop to [0, scrollHeight - clientHeight] and
// the two width-change mechanics the real browser exhibits:
//
//   rewrapGrow   narrower pane → more lines per body → scrollHeight grows,
//                scrollTop untouched (the STRANDING mechanism)
//   rewrapShrink wider pane → fewer lines → scrollHeight shrinks, and the
//                browser CLAMPS scrollTop down to the new max
function fakeScroller({
  clientHeight = 722,
  clientWidth = 992,
  scrollHeight = 5148,
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
      this._scrollTop = Math.max(
        0,
        this.scrollHeight - this.clientHeight - distance,
      );
      this.scrollTopWrites = [];
    },
    // Narrower pane: bodies rewrap taller. The browser does NOT move
    // scrollTop — that is the whole stranding mechanism.
    rewrapGrow(newWidth, newScrollHeight) {
      this.clientWidth = newWidth;
      this.scrollHeight = newScrollHeight;
    },
    // Wider pane: bodies rewrap shorter. The browser CLAMPS scrollTop to
    // the new maximum, exactly as it does for any content shrink.
    rewrapShrink(newWidth, newScrollHeight) {
      this.clientWidth = newWidth;
      this.scrollHeight = newScrollHeight;
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

function fakeList(scrollEl, rows) {
  return {
    dataset: { spaceId: "space-fixture-1" },
    closest: (sel) => (sel === "[data-scroll-container]" ? scrollEl : null),
    querySelectorAll: (sel) =>
      sel === "[data-participant-id]" ? rows : [],
    querySelector: () => null,
  };
}

describe("ScrollToBottom — a width change rewraps the conversation", () => {
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
    globalThis.MutationObserver = priorMO;
    if (priorRO !== undefined) globalThis.ResizeObserver = priorRO;
    else delete globalThis.ResizeObserver;
    if (priorRAF !== undefined) globalThis.requestAnimationFrame = priorRAF;
    else delete globalThis.requestAnimationFrame;
  });

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
    // `_lastScrollHeight` was seeded at mount; keep it in step with the
    // parked geometry exactly as `_safeUpdate` does on every real patch.
    hook._lastScrollHeight = scrollEl.scrollHeight;
    hook.pushEvent.mockClear();
    hook._lastAway = null;
    hook._lastDeep = null;
    hook._preUpdateDistance = null;
    return { el, scrollEl, hook };
  }

  it("snaps a bottom-parked reader through a window-resize rewrap", () => {
    // THE REPORTED STRANDING, in its purest form. Parked at distance 0,
    // pane narrows 992 → 752, bodies rewrap +800px. Before 01a05873 the
    // observer returned early and the reader sat 800px from the new
    // bottom with no snap and no follow on the next message.
    const { scrollEl, hook } = settledHook({ distance: 0 });
    scrollEl.rewrapGrow(752, 5148 + 800);

    hook._onViewportResize();

    expect(scrollEl.distanceFromBottom()).toBe(0);
    expect(scrollEl.scrollTopWrites.length).toBeGreaterThan(0);
  });

  it("snaps a reader who was inside the follow band (distance 100)", () => {
    const { scrollEl, hook } = settledHook({ distance: 100 });
    scrollEl.rewrapGrow(752, 5148 + 800);

    hook._onViewportResize();

    expect(scrollEl.distanceFromBottom()).toBe(0);
  });

  it("does NOT snap a reader who was deliberately scrolled up", () => {
    // THE ACCEPTED COST, mirrored from the height path: a reader who was
    // 600px up (past NEAR_BOTTOM_PX) keeps the pixel they were looking
    // at. Restoring their distance would drag text out from under them;
    // the pill is the correct affordance for this reader.
    const { scrollEl, hook } = settledHook({
      distance: 600,
      scrollHeight: 6000,
    });
    const before = scrollEl.scrollTop;
    scrollEl.rewrapGrow(752, 6000 + 300);

    hook._onViewportResize();

    expect(scrollEl.scrollTop).toBe(before);
    expect(scrollEl.scrollTopWrites).toEqual([]);
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("keeps a bottom-parked reader at the bottom through a WIDER rewrap", () => {
    // Sidebar drag wider: bodies rewrap shorter, the browser clamps
    // scrollTop down to the new max — the reader stays AT the bottom via
    // the clamp even if the reconstructed pre-distance declines to snap.
    // What must NOT happen is a snap-then-report cycle, and what MUST
    // hold is the bottom itself.
    const { scrollEl, hook } = settledHook({ distance: 0 });
    scrollEl.rewrapShrink(1192, 5148 - 400);

    hook._onViewportResize();

    expect(scrollEl.distanceFromBottom()).toBe(0);
  });

  it("uses the POST-message scrollHeight after a patch, not the mount-time one", () => {
    // `_lastScrollHeight` freshness. A message arrives (patch grows the
    // scroller; `_safeUpdate` refreshes the tracking), and only THEN the
    // user resizes the window. The pre-resize distance must be computed
    // against the post-patch scrollHeight — a stale mount-time value
    // would report a bottom-parked reader as stranded and decline.
    const { scrollEl, hook } = settledHook({ distance: 0 });

    // A patch lands: content grows 120px, hook services it, reader
    // follows to the new bottom. Same paths the real `updated()` runs.
    scrollEl.scrollHeight += 120;
    hook._safeUpdate();
    scrollEl.parkAt(0);

    scrollEl.rewrapGrow(752, scrollEl.scrollHeight + 800);
    hook._onViewportResize();

    expect(scrollEl.distanceFromBottom()).toBe(0);
  });

  it("reports the snap to the server (pill latch follows the reader)", () => {
    // The snap must re-report so the server's chip predicate agrees the
    // reader is back at the live edge — one reading, both decisions.
    const { scrollEl, hook } = settledHook({ distance: 0 });
    scrollEl.rewrapGrow(752, 5148 + 800);

    hook._onViewportResize();

    expect(hook._lastAway).toBe(false);
    expect(hook._lastDeep).toBe(false);
  });

  it("survives a clamp-only rewrap before the resize (webfont swap)", () => {
    // THE STALENESS CASE the real app produced. The webfont lands after
    // arrival, reflowing every body with NO LiveView patch; the content
    // SHRINKS, the browser clamps scrollTop to the new bottom, and the
    // clamp fires a real scroll event. If the pre-resize scrollHeight
    // tracker only refreshed on patches, it would still hold the
    // pre-font height at resize time and misclassify this reader (still
    // parked, distance 0) as mid-band — observed stale by 192px. The
    // refresh in `_reportDistance` is what keeps the tracker in step:
    // the clamp's scroll event runs through it.
    const { scrollEl, hook } = settledHook({ distance: 0, scrollHeight: 4403 });

    // Webfont swap: content shrinks 192px, browser clamps the parked
    // reader to the new bottom, clamp fires a scroll event — which is
    // exactly the report path the listener takes.
    scrollEl.scrollHeight = 4211;
    scrollEl.parkAt(0); // models the browser's clamp to the new max
    hook._reportDistance();

    // Now the window resize.
    scrollEl.rewrapGrow(752, 4211 + 520);
    hook._onViewportResize();

    expect(scrollEl.distanceFromBottom()).toBe(0);
  });

  it("a height-only change still runs the height path unchanged", () => {
    // Regression guard for the sibling-resize behavior this task must
    // not disturb: a pure clientHeight change (drawer opening) with the
    // reader parked follows through to the bottom via the EXISTING
    // height logic.
    const { scrollEl, hook } = settledHook({ distance: 0, clientWidth: 992 });
    scrollEl.clientHeight -= 300; // canvases drawer opens

    hook._onViewportResize();

    expect(scrollEl.distanceFromBottom()).toBe(0);
  });
});
