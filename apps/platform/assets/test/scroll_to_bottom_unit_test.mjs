// Node-runnable unit tests for the pure DOM-mutating logic of the
// `ScrollToBottom` hook (`assets/js/hooks/scroll_to_bottom.js`).
//
// As of task 019e21c7 Stage 5 the hook no longer manages date
// separators — those moved into the LV row template (see
// chat_message.ex `:day_label` + MessagesHooks.stream_insert_with_day_label/2)
// because `phx-update="stream"` reconciliation strips any non-stream
// child of the message-list container, which destroyed the JS-injected
// separators on every patch.
//
// What's left to cover here is `applyGrouping` — the Slack-style
// avatar/header collapse for consecutive same-author rows.
//
// Why a hand-rolled DOM shim instead of jsdom: the platform/assets
// tree intentionally has zero npm dependencies. Pulling jsdom in for
// these assertions would balloon the asset toolchain and force a
// network install on the test-host dev container. The hook uses a small,
// well-bounded slice of the DOM API (querySelectorAll, dataset,
// classList, style.visibility/display/paddingTop), so an inline shim
// is sufficient and keeps the test deps at zero.
//
// Run from the assets dir:
//
//     node --test test/scroll_to_bottom_unit_test.mjs

import test from "node:test";
import assert from "node:assert/strict";

// ---------------------------------------------------------------------------
// Minimal DOM shim
// ---------------------------------------------------------------------------

class ClassList {
  constructor(initial = "") {
    this._set = new Set(
      initial
        .split(/\s+/)
        .map((s) => s.trim())
        .filter(Boolean),
    );
  }
  add(...names) {
    for (const n of names) this._set.add(n);
  }
  remove(...names) {
    for (const n of names) this._set.delete(n);
  }
  contains(name) {
    return this._set.has(name);
  }
  // Two-argument form only — `applyGrouping` always passes an explicit
  // force flag, and the one-argument flip is deliberately not implemented
  // so a future caller relying on it fails loudly here rather than
  // silently no-op'ing.
  toggle(name, force) {
    if (force === undefined) {
      throw new Error("ClassList.toggle shim requires an explicit force flag");
    }
    if (force) this._set.add(name);
    else this._set.delete(name);
    return Boolean(force);
  }
  toString() {
    return Array.from(this._set).join(" ");
  }
}

class FakeElement {
  constructor(tagName) {
    this.tagName = tagName.toUpperCase();
    this.children = [];
    this.parentNode = null;
    this.dataset = {};
    this.classList = new ClassList();
    this._innerHTML = "";
    this._style = {};
    this._textContent = "";
  }

  set className(value) {
    this.classList = new ClassList(value || "");
  }
  get className() {
    return this.classList.toString();
  }

  set innerHTML(value) {
    this._innerHTML = String(value);
  }
  get innerHTML() {
    return this._innerHTML;
  }

  get textContent() {
    if (this._textContent) return this._textContent;
    return this._innerHTML.replace(/<[^>]*>/g, "");
  }
  set textContent(value) {
    this._textContent = String(value);
  }

  get style() {
    return this._style;
  }

  appendChild(child) {
    child.parentNode = this;
    this.children.push(child);
    return child;
  }

  // Recursive querySelectorAll across the tree, matching either
  // `[data-foo]`, `[data-foo][data-bar]`, or `.cls`.
  querySelectorAll(selector) {
    const matchers = parseSelector(selector);
    const out = [];
    const walk = (node) => {
      for (const child of node.children) {
        if (matchers.every((m) => m(child))) out.push(child);
        walk(child);
      }
    };
    walk(this);
    return out;
  }

  // Single-result variant
  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }
}

function parseSelector(selector) {
  const matchers = [];
  // Match attribute selectors like [data-participant-id] or
  // [data-role="message-context-trigger"]. An unparsed selector would leave
  // zero matchers and match EVERY node, so the value form must be handled.
  for (const m of selector.matchAll(/\[([a-z0-9-]+)(?:="([^"]*)")?\]/gi)) {
    const attr = m[1];
    const value = m[2];
    matchers.push((el) => {
      if (attr.startsWith("data-")) {
        const key = attr
          .slice(5)
          .replace(/-([a-z])/g, (_, c) => c.toUpperCase());
        if (value !== undefined) return el.dataset[key] === value;
        return el.dataset[key] !== undefined;
      }
      return false;
    });
  }
  // Match class selectors like .message-avatar
  for (const m of selector.matchAll(/\.([a-z0-9_-]+)/gi)) {
    const cls = m[1];
    matchers.push((el) => el.classList.contains(cls));
  }
  return matchers;
}

const fakeDocument = {
  createElement(tagName) {
    return new FakeElement(tagName);
  },
};
globalThis.document = fakeDocument;

// ---------------------------------------------------------------------------
// Hook under test (loaded via Function() to avoid Node ESM .js dance — see
// the prior version's commentary; the constraint hasn't changed).
// ---------------------------------------------------------------------------
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const hookSource = readFileSync(
  resolve(__dirname, "../js/hooks/scroll_to_bottom.js"),
  "utf8",
);
const hookBody = hookSource
  .replace(/^\s*export\s+default\s+ScrollToBottom\s*;?\s*$/m, "")
  .concat("\nreturn ScrollToBottom;\n");
// eslint-disable-next-line no-new-func
const ScrollToBottom = new Function(hookBody)();

// ---------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------

function makeContainer() {
  const el = new FakeElement("div");
  el.id = "message-list";
  return el;
}

function makeMessageRow({ participantId, id }) {
  const row = new FakeElement("div");
  row.dataset.participantId = participantId;
  if (id) row.dataset.messageId = id;
  const avatar = new FakeElement("div");
  avatar.className = "message-avatar";
  row.appendChild(avatar);
  const header = new FakeElement("div");
  header.className = "message-header";
  row.appendChild(header);
  return row;
}

// ---------------------------------------------------------------------------
// applyGrouping — consecutive same-author rows are marked as continuations
//
// The hook used to write inline styles (`visibility: hidden` on the avatar,
// `display: none` on the header, a 1px top padding on the row) and these
// tests asserted on those styles. It now sets a single
// `message-row--grouped` class and app.css owns the collapsed geometry.
//
// That move was the fix, not a tidy-up: `visibility: hidden` concealed the
// avatar while it went on reserving its full height, so a grouped one-line
// message stayed 66px tall to show 20px of text. Reclaiming that space
// needs rules an inline style cannot express, so the contract these tests
// guard is now "which rows are continuations", and the stylesheet answers
// "what a continuation looks like".
// ---------------------------------------------------------------------------

const isGrouped = (row) => row.classList.contains("message-row--grouped");
const isRunEnd = (row) => row.classList.contains("message-row--run-end");

test("applyGrouping marks consecutive same-author rows as continuations", () => {
  const el = makeContainer();
  const r1 = makeMessageRow({ participantId: "p1" });
  const r2 = makeMessageRow({ participantId: "p1" });
  const r3 = makeMessageRow({ participantId: "p2" });
  const r4 = makeMessageRow({ participantId: "p2" });
  el.appendChild(r1);
  el.appendChild(r2);
  el.appendChild(r3);
  el.appendChild(r4);

  ScrollToBottom.applyGrouping.call({ el });

  // r1 opens its group — full avatar + header.
  assert.equal(isGrouped(r1), false);
  // r2 follows the same author — collapsed.
  assert.equal(isGrouped(r2), true);
  // r3 starts a NEW author group even though it directly follows a
  // grouped row — a different author always opens a group.
  assert.equal(isGrouped(r3), false);
  // r4 continues r3.
  assert.equal(isGrouped(r4), true);
});

test("applyGrouping never groups a row missing its participant id", () => {
  // A row whose `data-participant-id` is absent must not inherit the
  // previous row's identity, and must not lend its own (undefined) one to
  // the row after it — otherwise two unrelated authors either side of a
  // system row would collapse into one visual group.
  const el = makeContainer();
  const r1 = makeMessageRow({ participantId: "p1" });
  const r2 = makeMessageRow({ participantId: undefined });
  const r3 = makeMessageRow({ participantId: undefined });
  el.appendChild(r1);
  el.appendChild(r2);
  el.appendChild(r3);

  ScrollToBottom.applyGrouping.call({ el });

  assert.equal(isGrouped(r1), false);
  assert.equal(isGrouped(r2), false);
  assert.equal(isGrouped(r3), false);
});

test("applyGrouping is idempotent across consecutive calls", () => {
  const el = makeContainer();
  el.appendChild(makeMessageRow({ participantId: "p1" }));
  el.appendChild(makeMessageRow({ participantId: "p1" }));
  el.appendChild(makeMessageRow({ participantId: "p2" }));

  ScrollToBottom.applyGrouping.call({ el });
  const after1 = el.children.map(isGrouped);

  ScrollToBottom.applyGrouping.call({ el });
  const after2 = el.children.map(isGrouped);

  assert.deepStrictEqual(after2, after1);
  assert.deepStrictEqual(after1, [false, true, false]);
});

test("applyGrouping resets a previously-collapsed row when its predecessor changes author", () => {
  // Simulate a row's data-participant-id flipping due to a server
  // re-render: the hook must UNgroup the no-longer-grouped row. This is
  // the case a plain `classList.add` would get wrong.
  const el = makeContainer();
  const r1 = makeMessageRow({ participantId: "p1" });
  const r2 = makeMessageRow({ participantId: "p1" });
  el.appendChild(r1);
  el.appendChild(r2);

  ScrollToBottom.applyGrouping.call({ el });
  assert.equal(isGrouped(r2), true);

  // Server re-renders r2 with a new author.
  r2.dataset.participantId = "p2";
  ScrollToBottom.applyGrouping.call({ el });

  assert.equal(isGrouped(r2), false);
});

// ---------------------------------------------------------------------------
// applyGrouping — run boundaries
//
// `--grouped` alone says "this row continues the one above", which is enough
// to collapse an avatar but not enough to round a run as one block: that needs
// to know which row is LAST in its run, and a single continuation flag cannot
// express it. `message-row--run-end` marks any row the next row does not
// continue.
//
// A first-in-run row stays implicit — it is just a row without `--grouped` —
// so a lone message carries no `--grouped` and does carry `--run-end`, and
// keeps full rounding without a special case.
// ---------------------------------------------------------------------------

test("applyGrouping marks the last row of each run as a run end", () => {
  const el = makeContainer();
  const r1 = makeMessageRow({ participantId: "p1" });
  const r2 = makeMessageRow({ participantId: "p1" });
  const r3 = makeMessageRow({ participantId: "p2" });
  const r4 = makeMessageRow({ participantId: "p2" });
  el.appendChild(r1);
  el.appendChild(r2);
  el.appendChild(r3);
  el.appendChild(r4);

  ScrollToBottom.applyGrouping.call({ el });

  // r1 opens p1's run and something follows it from p1, so it is not the end.
  assert.equal(isRunEnd(r1), false);
  // r2 is the last p1 row — the next row switches author.
  assert.equal(isRunEnd(r2), true);
  // r3 opens p2's run, r4 continues it.
  assert.equal(isRunEnd(r3), false);
  // r4 is last in the container, so nothing can continue it.
  assert.equal(isRunEnd(r4), true);

  // Boundaries are orthogonal to continuations: r2 and r4 are BOTH a
  // continuation and a run end, which is the whole point of the second class.
  assert.deepStrictEqual(el.children.map(isGrouped), [
    false,
    true,
    false,
    true,
  ]);
});

test("applyGrouping leaves the middle of a run unmarked as a run end", () => {
  // The discriminating case: a run of three. Only the third row ends it —
  // marking every row, or every grouped row, would be wrong here.
  const el = makeContainer();
  const r1 = makeMessageRow({ participantId: "p1" });
  const r2 = makeMessageRow({ participantId: "p1" });
  const r3 = makeMessageRow({ participantId: "p1" });
  const r4 = makeMessageRow({ participantId: "p2" });
  el.appendChild(r1);
  el.appendChild(r2);
  el.appendChild(r3);
  el.appendChild(r4);

  ScrollToBottom.applyGrouping.call({ el });

  assert.deepStrictEqual(el.children.map(isRunEnd), [
    false,
    false,
    true,
    true,
  ]);
});

test("applyGrouping marks a lone row as a run end and never as a continuation", () => {
  // A single-message run is the case the implicit first-in-run scheme has to
  // get right: no `--grouped`, but still `--run-end`, so it renders as a
  // fully-rounded standalone bubble.
  const el = makeContainer();
  const only = makeMessageRow({ participantId: "p1" });
  el.appendChild(only);

  ScrollToBottom.applyGrouping.call({ el });

  assert.equal(isGrouped(only), false);
  assert.equal(isRunEnd(only), true);
});

test("applyGrouping marks every row a run end when no two neighbours share an author", () => {
  const el = makeContainer();
  el.appendChild(makeMessageRow({ participantId: "p1" }));
  el.appendChild(makeMessageRow({ participantId: "p2" }));
  el.appendChild(makeMessageRow({ participantId: "p3" }));

  ScrollToBottom.applyGrouping.call({ el });

  assert.deepStrictEqual(el.children.map(isRunEnd), [true, true, true]);
  assert.deepStrictEqual(el.children.map(isGrouped), [false, false, false]);
});

test("applyGrouping clears a stale run-end when a later row joins the run", () => {
  // The `toggle` half of the contract, for the new class. A row that WAS the
  // end of its run stops being one as soon as the server re-renders the row
  // after it with the same author. A plain `classList.add` would leave the
  // stale marker and the run would render with a seam in the middle.
  const el = makeContainer();
  const r1 = makeMessageRow({ participantId: "p1" });
  const r2 = makeMessageRow({ participantId: "p2" });
  el.appendChild(r1);
  el.appendChild(r2);

  ScrollToBottom.applyGrouping.call({ el });
  assert.equal(isRunEnd(r1), true);

  // Server re-renders r2 as the same author as r1, joining them into one run.
  r2.dataset.participantId = "p1";
  ScrollToBottom.applyGrouping.call({ el });

  assert.equal(isRunEnd(r1), false);
  assert.equal(isRunEnd(r2), true);
  assert.equal(isGrouped(r2), true);
});

test("applyGrouping run-end marking is idempotent across consecutive calls", () => {
  const el = makeContainer();
  el.appendChild(makeMessageRow({ participantId: "p1" }));
  el.appendChild(makeMessageRow({ participantId: "p1" }));
  el.appendChild(makeMessageRow({ participantId: "p2" }));

  ScrollToBottom.applyGrouping.call({ el });
  const after1 = el.children.map(isRunEnd);

  ScrollToBottom.applyGrouping.call({ el });
  const after2 = el.children.map(isRunEnd);

  assert.deepStrictEqual(after2, after1);
  assert.deepStrictEqual(after1, [false, true, true]);
});
