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

// A grouped row (same author as the row above) collapses its header, as
// app.css does, so `applyGrouping` changes heights inside a patch.
const GROUPED_SAVES_PX = 40;

function fakeRow(id, baseHeight, participantId = `p-${id}`) {
  const classes = new Set();
  const row = {
    id,
    get height() {
      return baseHeight - (classes.has("message-row--grouped") ? GROUPED_SAVES_PX : 0);
    },
    set height(v) {
      baseHeight = v + (classes.has("message-row--grouped") ? GROUPED_SAVES_PX : 0);
    },
    parent: null,
    dataset: { messageId: id, participantId },
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
    // Content below the log inside the same scroller (the thread-activity
    // rows), which a backfill patch can grow.
    extraBottom: 0,
    get scrollHeight() {
      return this.rows.reduce((a, r) => a + r.height, 0) + this.extraBottom;
    },
    get children() {
      return this.rows;
    },
    getBoundingClientRect() {
      return { top: 0, bottom: this.clientHeight };
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
// `realistic`: what Chrome showed the backfill patch also doing. The old
// first row loses its 60 px day separator (the boundary label moves to the
// new oldest row) and the thread-activity rows under the log grow by 160 px.
function serverPrepend(el, hook, { realistic = false } = {}) {
  hook.beforeUpdate();
  const older = Array.from({ length: 40 }, (_, i) => fakeRow(`old-${i}`, 110));
  if (realistic) {
    el.rows[0].height -= 60;
    el.extraBottom += 160;
  }
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

  it("(a, realistic) a bottom-pinned reader stays at the bottom when the patch also grows the rows below", () => {
    const { el, hook } = settled({ distance: 0 });

    serverPrepend(el, hook, { realistic: true });

    expect(Math.abs(distanceFromBottom(el))).toBeLessThanOrEqual(2);
  });

  it("(b, realistic) the topmost visible message keeps its offset when the old first row shrinks", () => {
    // 300 px up from the bottom of 10 rows: the topmost visible row is NOT
    // the first row, which is the case an old-first-row anchor gets wrong.
    const { el, hook } = settled({ distance: 300 });
    const row = topmostVisible(el);
    expect(row).not.toBe(el.rows[0]);
    const before = row.getBoundingClientRect().top;

    serverPrepend(el, hook, { realistic: true });

    expect(topmostVisible(el)).toBe(row);
    expect(Math.abs(row.getBoundingClientRect().top - before)).toBeLessThanOrEqual(2);
  });

  it("compensates AFTER grouping: the old first row joining the batch's last author run", () => {
    // The batch's newest message is by the same author as the old first
    // row, so this patch's `applyGrouping` collapses the old first row's
    // header (-40 px) after the rows are inserted. Measuring the anchor
    // before grouping leaves the reader 40 px off.
    const { el, hook } = settled({ distance: 300 });
    const row = topmostVisible(el);
    const before = row.getBoundingClientRect().top;

    hook.beforeUpdate();
    const older = Array.from({ length: 40 }, (_, i) =>
      fakeRow(`old-${i}`, 110, i === 39 ? el.rows[0].dataset.participantId : undefined),
    );
    el.setRows([...older, ...el.rows]);
    hook.updated();

    expect(el.rows[40].classList.contains("message-row--grouped")).toBe(true);
    expect(Math.abs(row.getBoundingClientRect().top - before)).toBeLessThanOrEqual(2);
  });
});

