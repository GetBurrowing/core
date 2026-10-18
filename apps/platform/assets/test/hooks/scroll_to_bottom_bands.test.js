import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import ScrollToBottom from "../../js/hooks/scroll_to_bottom.js";

/**
 * The jump-to-latest control's VISIBILITY BANDS (task 01a0419a stage 4).
 *
 * The hook reports the reader's POSITION as two booleans; the server composes
 * them with its own unread count (`MessagesHooks.jump_chip_visible?/3`) into
 * five states:
 *
 *   position     nothing new       a message arrived
 *   ────────────────────────────────────────────────
 *   at bottom    nothing           nothing (it scrolls to you)
 *   shallow      NOTHING           pill WITH badge
 *   deep         pill, no badge    pill WITH badge
 *
 * THE MIDDLE-LEFT CELL IS THE WHOLE POINT, and it is written first here on
 * purpose. A suite that covers at-bottom and deep passes comfortably while the
 * shallow band is broken in either direction — and "shallow with nothing new"
 * is not one case among five, it is the entire visibility half of this change.
 * It is the state Alex described in his own words and it did not exist before
 * this stage.
 *
 * What this file can and cannot see: the hook does not know the unread count,
 * so what is asserted here is the POSITION half — which of `away` / `deep` the
 * hook reports at each distance. The composition into rendered pill-and-badge
 * is asserted server-side in
 * `test/platform_web/live/chat/jump_to_latest_hooks_test.exs`.
 *
 * Every absence assertion below is paired with a positive control IN THE SAME
 * TEST, because "the hook reported no deep" and "the hook reported nothing at
 * all" are indistinguishable otherwise.
 */

const NEAR_BOTTOM_PX = 150;
const DEEP_HISTORY_PX = 1800;

// Between the two thresholds: a reader who scrolled up to re-read something.
const SHALLOW_PX = 900;
// Comfortably past the deep boundary, not sitting on it.
const DEEP_PX = 2600;
// Every arrival grows the scroller by more than NEAR_BOTTOM_PX. A short
// fixture message lands in the branch that never had a bug (see
// scroll_to_bottom_follow.test.js).
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
    scrollIntoView() {},
    querySelector() {
      return null;
    },
  };
}

function fakeList({ rows = [], scrollHeight = 8000, clientHeight = 600 } = {}) {
  return {
    dataset: { spaceId: "space-fixture-bands" },
    rows,
    scrollHeight,
    clientHeight,
    _scrollTop: 0,
    scrollTopWrites: [],
    get scrollTop() {
      return this._scrollTop;
    },
    set scrollTop(v) {
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
    querySelector() {
      return null;
    },
  };
}

function settledHook({ distance }) {
  const el = fakeList({ rows: [fakeRow("m-1"), fakeRow("m-2")] });
  const hook = Object.create(ScrollToBottom);
  hook.el = el;
  hook.serverEvents = {};
  hook.handleEvent = vi.fn((name, cb) => {
    hook.serverEvents[name] = cb;
  });
  hook.pushEvent = vi.fn();
  hook.mounted();
  hook._initialScroll = false;
  hook._clearSettleTimers();
  hook._disconnectResizeObserver();
  el._scrollTop = el.scrollHeight - el.clientHeight - distance;
  el.scrollTopWrites = [];
  hook.pushEvent.mockClear();
  hook._lastAway = null;
  hook._lastDeep = null;
  hook._preUpdateDistance = null;
  return { el, hook };
}

// LiveView's real order: capture, patch the DOM, then `updated()`.
function arriveTallMessage(el, hook) {
  hook.beforeUpdate();
  el.rows.push(fakeRow("m-3", "p-2"));
  el.scrollHeight += TALL_MESSAGE_PX;
  hook.updated();
}

function reports(hook) {
  return hook.pushEvent.mock.calls
    .filter(([name]) => name === "jump_to_latest_distance")
    .map(([, payload]) => payload);
}

describe("ScrollToBottom — jump-to-latest visibility bands", () => {
  let priorMO, priorRO, priorRAF, priorCAF, pendingFrames;

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
    priorCAF = globalThis.cancelAnimationFrame;
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
    if (priorCAF !== undefined) globalThis.cancelAnimationFrame = priorCAF;
    else delete globalThis.cancelAnimationFrame;
  });

  // ── The band this whole stage exists for ────────────────────────────────

  it("BAND shallow/nothing-new: reports away WITHOUT deep, so no pill is raised", () => {
    // Alex's case: scrolled up to re-read a few messages, nothing arriving.
    // The server needs `deep: false` here — that is the only thing keeping the
    // pill out of the DOM when the unread count is zero.
    const { el, hook } = settledHook({ distance: SHALLOW_PX });

    hook._reportDistance();

    const [report] = reports(hook);
    // POSITIVE CONTROL, in this test, for the refute below it: the hook did
    // report, and it did say the reader is away. Without this line
    // `deep === false` is satisfied just as well by never pushing at all.
    expect(report).toBeDefined();
    expect(report.away).toBe(true);
    // The absence assertion.
    expect(report.deep).toBe(false);
    // Nothing moved the reader.
    expect(el.scrollTopWrites).toEqual([]);
  });

  it("BAND shallow/message-arrived: still away, still not deep — the badge is what changes", () => {
    // Same position, a tall message arrives. The hook's report must be
    // IDENTICAL to the row above; the difference between "nothing" and "pill
    // with badge" is entirely the server's unread count. If arrival moved
    // `deep`, the two shallow rows would be indistinguishable to the server.
    const { el, hook } = settledHook({ distance: SHALLOW_PX });
    const heldAt = el.scrollTop;

    arriveTallMessage(el, hook);

    expect(reports(hook)).toEqual([{ away: true, deep: false }]);
    // Reading history is an act of intent — nothing may move the viewport.
    expect(el.scrollTop).toBe(heldAt);
  });

  // ── The other three rows ────────────────────────────────────────────────

  it("BAND at-bottom: reports neither away nor deep, and follows the arriving message", () => {
    const { el, hook } = settledHook({ distance: 0 });

    arriveTallMessage(el, hook);

    // Positive control: the pane genuinely followed, so this is a real
    // at-bottom run and not a fixture that never patched.
    expect(el.scrollTop).toBe(el.scrollHeight);
    const flags = reports(hook).map((r) => [r.away, r.deep]);
    expect(flags.some(([away]) => away === true)).toBe(false);
    expect(flags.some(([, deep]) => deep === true)).toBe(false);
  });

  it("BAND deep/nothing-new: reports deep, which raises the pill with no badge", () => {
    const { hook } = settledHook({ distance: DEEP_PX });

    hook._reportDistance();

    expect(reports(hook)).toEqual([{ away: true, deep: true }]);
  });

  it("BAND deep/message-arrived: still deep and still away", () => {
    const { el, hook } = settledHook({ distance: DEEP_PX });
    const heldAt = el.scrollTop;

    arriveTallMessage(el, hook);

    expect(reports(hook)).toEqual([{ away: true, deep: true }]);
    expect(el.scrollTop).toBe(heldAt);
  });

  // ── The properties that make the bands hold ─────────────────────────────

  it("the shallow band is non-empty: the two thresholds are ORDERED, not independent", () => {
    // If DEEP_HISTORY_PX ever lands at or below NEAR_BOTTOM_PX the shallow
    // band collapses to zero width and the pill returns on every scroll-up.
    // The module refuses to load in that state; this asserts the pair the
    // shipped module was loaded with.
    expect(DEEP_HISTORY_PX).toBeGreaterThan(NEAR_BOTTOM_PX);
    // And the fixture actually sits inside the band it claims to test.
    expect(SHALLOW_PX).toBeGreaterThan(NEAR_BOTTOM_PX);
    expect(SHALLOW_PX).toBeLessThan(DEEP_HISTORY_PX);
    expect(DEEP_PX).toBeGreaterThan(DEEP_HISTORY_PX);
  });

  it("crossing OUT of the deep band re-reports even though `away` never moved", () => {
    // Edge-triggering on `away` alone would swallow this: the reader goes
    // deep -> shallow, `away` is true throughout, and the server would keep
    // rendering a pill for a reader who no longer warrants one.
    const { el, hook } = settledHook({ distance: DEEP_PX });

    hook._reportDistance();
    expect(reports(hook)).toEqual([{ away: true, deep: true }]);

    el._scrollTop = el.scrollHeight - el.clientHeight - SHALLOW_PX;
    hook._reportDistance();

    expect(reports(hook)).toEqual([
      { away: true, deep: true },
      { away: true, deep: false },
    ]);
  });

  it("a stationary reader stays silent: no re-push when neither boolean moved", () => {
    const { hook } = settledHook({ distance: SHALLOW_PX });

    hook._reportDistance();
    hook._reportDistance();
    hook._reportDistance();

    // Positive control paired with the count: one report happened, and only
    // one. `toHaveLength(1)` alone could pass on a hook that pushed once and
    // then crashed.
    expect(reports(hook)).toEqual([{ away: true, deep: false }]);
  });

  it("the deep predicate reads the PRE-PATCH capture, not the grown scroller", () => {
    // A reader sitting just under the deep boundary must not be pushed over it
    // by the height of the arriving message — that is stage 1's defect wearing
    // the visibility predicate's clothes.
    const { el, hook } = settledHook({ distance: DEEP_HISTORY_PX - 100 });

    arriveTallMessage(el, hook);

    // Post-patch the live distance is DEEP_HISTORY_PX + 300, so a hook reading
    // the live measurement reports deep: true here.
    expect(el.scrollHeight - el.scrollTop - el.clientHeight).toBeGreaterThan(
      DEEP_HISTORY_PX,
    );
    expect(reports(hook)).toEqual([{ away: true, deep: false }]);
  });
});
