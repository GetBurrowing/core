// The thread-activity rows (task 01a174f5 stage 3) render in
// `#thread-activity`, a SIBLING of `#message-list` inside the scroller. The
// hook's MutationObserver used to watch only `#message-list`'s childList, so
// a row appearing below the fold never ran the follow rule and a reader
// pinned to the bottom silently stopped being at the bottom.
//
// Pinned here:
//   * `_observeLog()` watches BOTH `#message-list` (childList) and
//     `#thread-activity` (childList, subtree), and `_safeUpdate()` re-arms
//     both after its own DOM work;
//   * a row arriving goes through the shipped `_safeUpdate()`: a reader at
//     the bottom stays at the bottom, a reader scrolled up is not moved.
//
// Run from the assets dir:
//
//     node --test test/scroll_to_bottom_thread_activity_test.mjs

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

const hookBody = readFileSync(
  resolve(__dirname, "../js/hooks/scroll_to_bottom.js"),
  "utf8",
)
  .replace(/^\s*export\s+default\s+ScrollToBottom\s*;?\s*$/m, "")
  .concat("\nreturn ScrollToBottom;\n");

const ScrollToBottom = new Function(hookBody)();

// The three numbers the hook reads, with the browser's scrollTop clamp.
function makeScroller({ clientHeight, scrollHeight }) {
  return {
    clientHeight,
    clientWidth: 1000,
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
    grow(px) {
      this._scrollHeight += px;
    },
    bottom() {
      return this._scrollHeight - this.clientHeight;
    },
  };
}

// Records what is observed, with which options, and disconnects.
function makeObserver() {
  return {
    targets: [],
    observe(node, opts) {
      this.targets.push({ node, opts });
    },
    disconnect() {
      this.targets = [];
    },
  };
}

const ROWS = { id: "thread-activity" };

function makeCtx(scrollEl, { withRows = true } = {}) {
  const parent = {
    querySelector(sel) {
      return sel === "#thread-activity" && withRows ? ROWS : null;
    },
  };
  return {
    el: { id: "message-list", dataset: {}, parentElement: parent },
    scrollEl,
    _observer: makeObserver(),
    _initialScroll: false,
    _anchoredFor: null,
    _preUpdateDistance: null,
    _pendingRealignTop: null,
    grouped: 0,
    applyGrouping() {
      this.grouped += 1;
    },
    _reportDistance() {},
    // Shipped methods.
    _observeLog: ScrollToBottom._observeLog,
    _safeUpdate: ScrollToBottom._safeUpdate,
    _applyPendingRealign: ScrollToBottom._applyPendingRealign,
    _hasMeasurableBox: ScrollToBottom._hasMeasurableBox,
    scrollToBottom: ScrollToBottom.scrollToBottom,
    distanceFromBottom: ScrollToBottom.distanceFromBottom,
    honourAnchor: ScrollToBottom.honourAnchor,
  };
}

const ROW_PX = 44;

test("_observeLog watches #message-list and the #thread-activity rows", () => {
  const ctx = makeCtx(makeScroller({ clientHeight: 800, scrollHeight: 3000 }));
  ctx._observeLog();

  const byId = Object.fromEntries(
    ctx._observer.targets.map((t) => [t.node.id, t.opts]),
  );
  assert.deepEqual(byId["message-list"], { childList: true, subtree: false });
  assert.deepEqual(byId["thread-activity"], { childList: true, subtree: true });
});

test("_safeUpdate re-arms the #thread-activity observation after its own DOM work", () => {
  const ctx = makeCtx(makeScroller({ clientHeight: 800, scrollHeight: 3000 }));
  ctx._observeLog();
  ctx._safeUpdate();

  const ids = ctx._observer.targets.map((t) => t.node.id).sort();
  assert.deepEqual(ids, ["message-list", "thread-activity"]);
  assert.equal(ctx.grouped, 1, "the shipped _safeUpdate really ran");
});

test("no #thread-activity (embedded chat) still observes the log alone", () => {
  const ctx = makeCtx(makeScroller({ clientHeight: 800, scrollHeight: 3000 }), {
    withRows: false,
  });
  ctx._observeLog();
  assert.deepEqual(
    ctx._observer.targets.map((t) => t.node.id),
    ["message-list"],
  );
});

test("a reader pinned to the bottom stays pinned when a row appears", () => {
  const el = makeScroller({ clientHeight: 800, scrollHeight: 3000 });
  el.scrollTop = el.bottom();
  const ctx = makeCtx(el);
  ctx._observeLog();

  // A row lands in #thread-activity: the scroller grows below the reader and
  // the observer's callback runs `_safeUpdate()`.
  el.grow(ROW_PX);
  ctx._safeUpdate();

  assert.equal(el.scrollTop, el.bottom(), "still at the bottom, row in view");
});

test("a reader scrolled up into history is not moved when a row appears", () => {
  const el = makeScroller({ clientHeight: 800, scrollHeight: 3000 });
  el.scrollTop = 600; // 1600px above the bottom
  const ctx = makeCtx(el);
  ctx._observeLog();

  el.grow(ROW_PX);
  ctx._safeUpdate();

  assert.equal(
    el.scrollTop,
    600,
    "the reader's pixel is left exactly where it was",
  );
});
