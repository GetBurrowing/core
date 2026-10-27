import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import ScrollToBottom from "../../js/hooks/scroll_to_bottom.js";

/**
 * A SERVER-initiated prepend keeps the reading position (task 01a17bf4
 * stage 2).
 *
 * Chat's join reply carries only the newest N messages and the server
 * prepends the rest of the 50-message window right after connect. No client
 * request starts that load, so InfiniteScroll's own anchor compensation never
 * runs for it. Two readers matter:
 *
 *   (a) bottom-pinned: stays at the bottom (within 2 px);
 *   (b) scrolled up before the backfill lands: the topmost visible message
 *       keeps its on-screen offset (within 2 px).
 *
 * (c) covers a reader scrolled up by LESS than NEAR_BOTTOM_PX (150): the
 * follow rule alone would snap them to the bottom, because it treats any
 * patch that grows the scroller as an arrival.
 *
 * The geometry is a model, not jsdom (which does no layout): each row has a
 * height, rows stack from the top of the scroller, and a row's
 * getBoundingClientRect().top is its offset minus scrollTop. The prepended
 * batch is far taller than the viewport, so an implementation that does
 * nothing moves the reader by thousands of pixels, not by a rounding error.
 */

const CLIENT_HEIGHT = 666;
const BATCH_HEIGHT = 40 * 110;

function fakeRow(id, height) {
  const classes = new Set();
  const row = {
    id,
    height,
    parent: null,
    dataset: { messageId: id, participantId: `p-${id}` },
    style: {},
    classList: {
      toggle(name, force) {
        if (force) classes.add(name);
        else classes.delete(name);
        return Boolean(force);
      },
      contains: (name) => classes.has(name),
    },
    getBoundingClientRect() {
      const list = row.parent;
      let top = 0;
      for (const r of list.rows) {
        if (r === row) break;
        top += r.height;
      }
      const t = top - list.scrollTop;
      return { top: t, bottom: t + row.height, height: row.height };
    },
  };
  return row;
}

function fakeList(rows) {
  const list = {
    dataset: { spaceId: "space-prepend-1" },
    rows: [],
    clientHeight: CLIENT_HEIGHT,
    clientWidth: 800,
    _scrollTop: 0,
    get scrollHeight() {
      return this.rows.reduce((a, r) => a + r.height, 0);
    },
    get scrollTop() {
      return this._scrollTop;
    },
    set scrollTop(v) {
      // A real scroller clamps.
      this._scrollTop = Math.max(0, Math.min(v, this.scrollHeight - this.clientHeight));
    },
    get firstElementChild() {
      return this.rows[0] || null;
    },
    contains(node) {
      return this.rows.includes(node);
    },
    getClientRects() {
      return [{}];
    },
    closest() {
      return null;
    },
    parentElement: null,
    addEventListener() {},
    removeEventListener() {},
    querySelectorAll(sel) {
      if (sel === "[data-participant-id]") return this.rows;
      return [];
    },
    querySelector() {
      return null;
    },
    setRows(next) {
      for (const r of next) r.parent = this;
      this.rows = next;
    },
  };
  list.setRows(rows);
  return list;
}

function buildHook(el) {
  const hook = Object.create(ScrollToBottom);
  hook.el = el;
  hook.handleEvent = vi.fn();
  hook.pushEvent = vi.fn();
  return hook;
}

// The first frame: N = 10 rows, settled (arrival phase over), the reader
// parked `distance` px above the bottom.
function settled({ distance }) {
  const first = Array.from({ length: 10 }, (_, i) => fakeRow(`new-${i}`, 90 + (i % 3) * 20));
  const el = fakeList(first);
  const hook = buildHook(el);
  hook.mounted();
  hook._initialScroll = false;
  hook._clearSettleTimers();
  hook._disconnectResizeObserver();
  el.scrollTop = el.scrollHeight - el.clientHeight - distance;
  hook._preUpdateDistance = null;
  return { el, hook };
}

// LiveView's order for the backfill diff: capture, patch (40 rows inserted
// in front of the first one), then updated(). No pushEvent precedes it.
function serverPrepend(el, hook) {
  hook.beforeUpdate();
  const older = Array.from({ length: 40 }, (_, i) => fakeRow(`old-${i}`, 110));
  el.setRows([...older, ...el.rows]);
  hook.updated();
}

function distanceFromBottom(el) {
  return el.scrollHeight - el.scrollTop - el.clientHeight;
}

function topmostVisible(el) {
  return el.rows.find((r) => {
    const { top, bottom } = r.getBoundingClientRect();
    return bottom > 0 && top < el.clientHeight;
  });
}

describe("ScrollToBottom: a server-initiated prepend", () => {
  let priorMO, priorRO, priorRAF, timers;

  beforeEach(() => {
    priorMO = globalThis.MutationObserver;
    globalThis.MutationObserver = class {
      observe() {}
      disconnect() {}
    };
    priorRO = globalThis.ResizeObserver;
    globalThis.ResizeObserver = class {
      observe() {}
      disconnect() {}
    };
    priorRAF = globalThis.requestAnimationFrame;
    timers = new Set();
    globalThis.requestAnimationFrame = (cb) => {
      const id = setTimeout(() => {
        timers.delete(id);
        cb();
      }, 0);
      timers.add(id);
      return id;
    };
    globalThis.cancelAnimationFrame = (id) => clearTimeout(id);
  });

  afterEach(() => {
    timers.forEach((id) => clearTimeout(id));
    globalThis.MutationObserver = priorMO;
    if (priorRO !== undefined) globalThis.ResizeObserver = priorRO;
    else delete globalThis.ResizeObserver;
    if (priorRAF !== undefined) globalThis.requestAnimationFrame = priorRAF;
    else delete globalThis.requestAnimationFrame;
  });

  it("FIXTURE GUARD: the batch is much taller than the viewport and the follow edge", () => {
    expect(BATCH_HEIGHT).toBeGreaterThan(CLIENT_HEIGHT * 4);
    expect(BATCH_HEIGHT).toBeGreaterThan(150 * 10);
  });

  it("(a) a bottom-pinned reader stays at the bottom", () => {
    const { el, hook } = settled({ distance: 0 });
    expect(distanceFromBottom(el)).toBe(0);

    serverPrepend(el, hook);

    expect(Math.abs(distanceFromBottom(el))).toBeLessThanOrEqual(2);
  });

  it("(b) a reader scrolled up 300 px keeps the topmost visible message at its offset", () => {
    const { el, hook } = settled({ distance: 300 });
    const row = topmostVisible(el);
    const before = row.getBoundingClientRect().top;

    serverPrepend(el, hook);

    expect(topmostVisible(el)).toBe(row);
    expect(Math.abs(row.getBoundingClientRect().top - before)).toBeLessThanOrEqual(2);
  });

  it("(c) a reader scrolled up 100 px (inside the follow edge) is not snapped to the bottom", () => {
    const { el, hook } = settled({ distance: 100 });
    const row = topmostVisible(el);
    const before = row.getBoundingClientRect().top;

    serverPrepend(el, hook);

    expect(Math.abs(row.getBoundingClientRect().top - before)).toBeLessThanOrEqual(2);
    expect(Math.abs(distanceFromBottom(el) - 100)).toBeLessThanOrEqual(2);
  });

  it("an ordinary arrival at the bottom still follows (the prepend rule does not swallow it)", () => {
    const { el, hook } = settled({ distance: 0 });

    hook.beforeUpdate();
    el.setRows([...el.rows, fakeRow("arrived", 400)]);
    hook.updated();

    expect(distanceFromBottom(el)).toBe(0);
  });

  it("pushes through #message-list-push-proxy, so #message-list is never the locked element", () => {
    const { hook } = settled({ distance: 0 });
    // This suite runs without a DOM; a stand-in document holds the proxy.
    const proxy = { id: "message-list-push-proxy" };
    const priorDocument = globalThis.document;
    globalThis.document = { getElementById: (id) => (id === proxy.id ? proxy : null) };
    hook.liveSocket = { execJS: vi.fn() };
    hook.pushEvent.mockClear();
    try {
      hook._lastAway = null;
      hook._reportDistance();

      expect(hook.pushEvent).not.toHaveBeenCalled();
      expect(hook.liveSocket.execJS).toHaveBeenCalledTimes(1);
      const [el, js, type] = hook.liveSocket.execJS.mock.calls[0];
      expect(el).toBe(proxy);
      expect(type).toBe("hook");
      expect(JSON.parse(js)).toEqual([
        ["push", { event: "jump_to_latest_distance", value: { away: false, deep: false } }],
      ]);
    } finally {
      if (priorDocument === undefined) delete globalThis.document;
      else globalThis.document = priorDocument;
    }
  });
});
