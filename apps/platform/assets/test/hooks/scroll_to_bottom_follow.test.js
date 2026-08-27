import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import ScrollToBottom from "../../js/hooks/scroll_to_bottom.js";

/**
 * The follow rule must decide from the reader's position BEFORE the patch.
 *
 * "At the bottom" and "scrolled up by hand" are different states even at the
 * same pixel offset. At the bottom you are following the conversation and a
 * new message should simply arrive. Scrolling up is an act of intent — you
 * are reading history and must not be yanked down. The jump-to-latest pill
 * serves that second case and only that one.
 *
 * Measured AFTER the patch, the two are indistinguishable: a reader at
 * distance 0 measures at the arriving message's height. Every pre-existing
 * fixture in this directory builds SHORT messages, so every one of them lands
 * in the branch that already worked — which is precisely how the defect
 * passed both gates. EVERY test here therefore grows the scroller by more
 * than NEAR_BOTTOM_PX (150). A fixture under that height cannot fail for any
 * implementation and is vacuous by construction.
 *
 * Case (a) is the defect. Case (b) is its anti-vacuity control: an
 * implementation that simply always follows passes (a) and fails (b).
 */

const NEAR_BOTTOM_PX = 150;
// Comfortably over the threshold: a paragraph or a code block, not an edge
// case sitting one pixel the far side of the boundary.
const TALL_MESSAGE_PX = 400;

function fakeRow(messageId, participantId = "p-1") {
  const classes = new Set();
  return {
    dataset: { messageId, participantId },
    style: {},
    classList: {
      toggle(name, force) {
        if (force) classes.add(name);
        else classes.delete(name);
        return Boolean(force);
      },
      contains: (name) => classes.has(name),
    },
    scrollIntoViewCalls: [],
    scrollIntoView(opts) {
      this.scrollIntoViewCalls.push(opts);
    },
    querySelector() {
      return null;
    },
  };
}

function fakeList({
  rows = [],
  scrollHeight = 4000,
  clientHeight = 600,
  scrollTop = 0,
} = {}) {
  return {
    dataset: { spaceId: "space-fixture-1" },
    rows,
    scrollHeight,
    clientHeight,
    _scrollTop: scrollTop,
    scrollTopWrites: [],
    get scrollTop() {
      return this._scrollTop;
    },
    set scrollTop(v) {
      // A write of the current value is a no-op in a real scroller; the
      // reflow hold performs exactly that every frame when nothing moved.
      if (v === this._scrollTop) return;
      this._scrollTop = v;
      this.scrollTopWrites.push(v);
    },
    closest() {
      return null;
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
    querySelectorAll(sel) {
      if (sel === "[data-participant-id]") {
        return this.rows.filter((r) => r.dataset.participantId);
      }
      return [];
    },
    querySelector(sel) {
      const match = /^\[data-message-id="(.+)"\]$/.exec(sel);
      if (!match) return null;
      return this.rows.find((r) => r.dataset.messageId === match[1]) || null;
    },
  };
}

function buildHook(el) {
  const hook = Object.create(ScrollToBottom);
  hook.el = el;
  hook.serverEvents = {};
  hook.handleEvent = vi.fn((name, cb) => {
    hook.serverEvents[name] = cb;
  });
  hook.pushEvent = vi.fn();
  return hook;
}

// Mount, then put the hook in the state a settled conversation is actually
// in: initial-snap phase spent, nothing reported to the server yet, the
// reader parked wherever `distance` says.
function settledHook({ distance }) {
  const el = fakeList({ rows: [fakeRow("m-1"), fakeRow("m-2")] });
  const hook = buildHook(el);
  hook.mounted();
  hook._initialScroll = false;
  hook._clearSettleTimers();
  hook._disconnectResizeObserver();
  el._scrollTop = el.scrollHeight - el.clientHeight - distance;
  el.scrollTopWrites = [];
  hook.pushEvent.mockClear();
  hook._lastAway = null;
  hook._preUpdateDistance = null;
  return { el, hook };
}

// LiveView's real order: capture, patch the DOM, then `updated()`. The
// scroller has ALREADY grown by the time the hook's decision runs.
function arriveTallMessage(el, hook) {
  hook.beforeUpdate();
  el.rows.push(fakeRow("m-3", "p-2"));
  el.scrollHeight += TALL_MESSAGE_PX;
  hook.updated();
}

function pushedAway(hook) {
  return hook.pushEvent.mock.calls
    .filter(([name]) => name === "jump_to_latest_distance")
    .map(([, payload]) => payload.away);
}

describe("ScrollToBottom — a tall message arriving at a bottom-parked reader", () => {
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

  it("FIXTURE GUARD: the arriving message is taller than the follow threshold", () => {
    // Without this the whole file could quietly shrink into the branch that
    // never had a bug.
    expect(TALL_MESSAGE_PX).toBeGreaterThan(NEAR_BOTTOM_PX);
  });

  it("(a) follows a reader who was AT the bottom, and raises no pill", () => {
    const { el, hook } = settledHook({ distance: 0 });

    arriveTallMessage(el, hook);

    // The reader was watching the bottom of the conversation; the new
    // message must simply be there.
    expect(el.scrollTop).toBe(el.scrollHeight);
    expect(el.scrollTopWrites).toEqual([el.scrollHeight]);
    // And the pill must not appear. Post-patch measurement reported 400px of
    // distance here and flipped `away: true` — the user-visible symptom.
    expect(pushedAway(hook)).not.toContain(true);
  });

  it("(a2) follows a bottom-parked reader even at the threshold's far edge", () => {
    // distance 150 is still "following" by the hook's own boundary; a
    // post-patch reading would put this reader at 550.
    const { el, hook } = settledHook({ distance: NEAR_BOTTOM_PX });

    arriveTallMessage(el, hook);

    expect(el.scrollTop).toBe(el.scrollHeight);
    expect(pushedAway(hook)).not.toContain(true);
  });

  it("(b) CONTROL: holds a reader who scrolled up by hand, and raises the pill", () => {
    const { el, hook } = settledHook({ distance: 900 });
    const heldAt = el.scrollTop;

    arriveTallMessage(el, hook);

    // Reading history is an act of intent. Nothing may move the viewport.
    expect(el.scrollTop).toBe(heldAt);
    expect(el.scrollTopWrites).toEqual([]);
    // The pill exists for exactly this reader.
    expect(pushedAway(hook)).toEqual([true]);
  });

  it("(b2) CONTROL: holds a reader just past the threshold", () => {
    const { el, hook } = settledHook({ distance: NEAR_BOTTOM_PX + 1 });
    const heldAt = el.scrollTop;

    arriveTallMessage(el, hook);

    expect(el.scrollTop).toBe(heldAt);
    expect(pushedAway(hook)).toEqual([true]);
  });

  it("falls back to live measurement when no patch capture exists", () => {
    // Mount, ResizeObserver and the settle timer are not DOM-patch-driven:
    // there, the live reading IS the reader's position. A capture that
    // outlived its patch would freeze the follow rule on a stale number.
    const { el, hook } = settledHook({ distance: 0 });

    arriveTallMessage(el, hook);
    // Drain the microtask the hook uses to release its capture.
    return Promise.resolve().then(() => {
      expect(hook._preUpdateDistance).toBe(null);

      // Reader now scrolls up by hand; a non-patch re-evaluation must see
      // that, not the captured 0.
      el._scrollTop = el.scrollHeight - el.clientHeight - 900;
      el.scrollTopWrites = [];
      hook._safeUpdate();

      expect(el.scrollTopWrites).toEqual([]);
      expect(pushedAway(hook)).toContain(true);
    });
  });
});
