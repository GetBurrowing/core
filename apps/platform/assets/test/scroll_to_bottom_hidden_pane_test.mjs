// Regression guard for the reader's scroll position across a call-rail TAB
// ROUND TRIP (task 01a084bf stage 5).
//
// ── WHAT THE BEHAVIOURAL GATE REPORTED ─────────────────────────────────────
//
// A reader on `/meetings`, parked mid-history in the call rail's Chat tab,
// switched to People, then Transcript, then back to Chat:
//
//     P1 Chat        scrollTop 354   max 614
//     P2 People      scrollTop 0  scrollHeight 0  clientHeight 0
//     P3 Transcript  scrollTop 0  scrollHeight 0  clientHeight 0
//     P4 Chat        scrollTop 614  scrollHeight 1107  clientHeight 493
//
// Reproduced twice, once via `el.click()` and once with real CDP mouse input.
// The gate's diagnosis was that `[data-role="call-rail-chat-wrap"]`'s `hidden`
// attribute takes the scroller to `display: none`, the browser discards the
// offset, and the list "lands at the bottom" on return.
//
// ── WHY THAT DIAGNOSIS IS WRONG, AND WHAT REPLACES IT ──────────────────────
//
// The gate's own numbers refute it. A discarded offset lands at 0 — the TOP.
// 614 is exactly `scrollHeight - clientHeight`, the clamped result of a
// `scrollTop = scrollHeight` WRITE. Something actively scrolled to the bottom.
//
// Measured in Chrome 152.0.7977.83 over CDP, on a static page carrying
// Tailwind v4.1.12's preflight rule verbatim —
// `[hidden]:where(:not([hidden='until-found'])) { display: none !important }`,
// which is why the `hidden` attribute beats the wrap's own `.flex` and the
// pane really is box-less — the browser RETAINS the offset and hands it back:
//
//     parked                          scrollTop 354  sh 1220  ch 300
//     hidden                          scrollTop   0  sh    0  ch   0
//     shown again                     scrollTop 354  sh 1220  ch 300
//     hidden, 5 rows appended, shown  scrollTop 354  sh 1525  ch 300
//     hidden, scrollTop=scrollHeight
//       attempted, shown              scrollTop 354  (the write is discarded)
//     hidden for 60 frames, shown     scrollTop 300  (a 300 parking)
//
// So the markup is not the defect and `hidden` does not need replacing. The
// destroyer is `_onViewportResize` in the hook: the ResizeObserver delivers
// the 0x0 box, the old code RECORDED it into `_lastClientWidth`,
// `_lastClientHeight` and `_lastScrollHeight`, and on the way back the WIDTH
// path reconstructed the reader's pre-resize distance from those zeroes,
// concluded they had been following the live edge, and snapped.
//
// ── WHERE THE BROWSER FACT ENTERS THIS FILE, STATED SO IT IS NOT MISREAD ────
//
// These are NODE tests. They cannot observe a browser. The retention measured
// above is modelled by `makeScroller` below and is an INPUT to these tests,
// not something they verify. What they verify is the hook's ARITHMETIC given
// that input — which is where the defect lives and the whole of what the fix
// changes. The behavioural proof that a real reader keeps their place is the
// e2e re-run of the gate, not this file and not any ExUnit test.
//
// ── A WARNING FOR ANYONE RE-RUNNING THE GATE ───────────────────────────────
//
// Clause 2 of the gate asks that a held DOM reference is still `isConnected`
// AND still `matches()` its selector. `matches()` is NON-DISCRIMINATING here:
// a DETACHED node still matches `[data-pane="meeting-chat-panel"]`, because
// the selector only tests the node's own attributes. The reviewer measured
// `heldMatches == true` at all four positions INCLUDING the three where the
// node was detached. Only `isConnected` separates a preserved node from a
// replaced one. An assertion written in the `matches()` shape is vacuous.
//
// Run from the assets dir:
//
//     node --test test/scroll_to_bottom_hidden_pane_test.mjs

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

// Load the REAL hook source rather than a copy, so this test cannot drift from
// the implementation it guards. Same approach as the two sibling scroll tests.
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
// Models the four browser behaviours MEASURED above, and nothing else:
//
//   1. inside a `display: none` subtree clientWidth, clientHeight AND
//      scrollHeight all read 0,
//   2. so does scrollTop,
//   3. a scrollTop WRITE while box-less is discarded,
//   4. and the offset comes back when the box does.
//
// The clamp is modelled too, as in scroll_to_bottom_arrival_test.mjs: the hook
// assigns `scrollTop = scrollHeight` and relies on the browser to clamp to the
// true bottom. Without it these tests would be measuring a fiction.
function makeScroller({ clientWidth, clientHeight, scrollHeight }) {
  return {
    _w: clientWidth,
    _h: clientHeight,
    _sh: scrollHeight,
    _retained: 0,
    rendered: true,
    get clientWidth() {
      return this.rendered ? this._w : 0;
    },
    get clientHeight() {
      return this.rendered ? this._h : 0;
    },
    get scrollHeight() {
      return this.rendered ? this._sh : 0;
    },
    get scrollTop() {
      return this.rendered ? this._retained : 0;
    },
    set scrollTop(v) {
      if (!this.rendered) return;
      const max = Math.max(0, this._sh - this._h);
      this._retained = Math.min(Math.max(0, v), max);
    },
    hide() {
      this.rendered = false;
    },
    show() {
      this.rendered = true;
    },
    grow(px) {
      this._sh += px;
    },
    bottom() {
      return Math.max(0, this._sh - this._h);
    },
  };
}

// The gate's own three numbers, so the trace this file reproduces is the trace
// the gate recorded rather than a convenient one.
const GATE = { clientWidth: 370, clientHeight: 493, scrollHeight: 1107 };
const GATE_PARKED = 354;
const GATE_BOTTOM = 614; // 1107 - 493, and the value the gate measured at P4

// A post-arrival context whose remembered dimensions were seeded from a
// RENDERED box, i.e. a reader who has already been reading in the Chat tab.
//
// `guarded: false` performs the MUTATION these tests need in order to mean
// anything: it disables `_hasMeasurableBox` and nothing else, so the shipped
// arithmetic runs exactly as it did before the fix. It is not a copy of the
// old code — there is nothing to drift.
function makeCtx(scrollEl, { guarded = true } = {}) {
  const ctx = {
    scrollEl,
    _initialScroll: false,
    _lastClientWidth: scrollEl.clientWidth,
    _lastClientHeight: scrollEl.clientHeight,
    _lastScrollHeight: scrollEl.scrollHeight,
    reported: 0,
    _reportDistance() {
      this.reported += 1;
    },
    _onViewportResize: ScrollToBottom._onViewportResize,
    // The realign-restore collaborator (task 01a084bf stage 5, second round).
    // `_onViewportResize` pays back an offset that was held because the pane had
    // no box when its RELOCATION was detected. Nothing in this file relocates
    // anything, so `_pendingRealignTop` stays null and every case below is
    // unaffected — but the method has to be the REAL one, or these tests would
    // pass over a hook that never restores anyone. See
    // `scroll_to_bottom_relocation_test.mjs` for what it does.
    _pendingRealignTop: null,
    _applyPendingRealign: ScrollToBottom._applyPendingRealign,
    _hasMeasurableBox: guarded
      ? ScrollToBottom._hasMeasurableBox
      : () => true,
  };
  return ctx;
}

// ---------------------------------------------------------------------------

test("a tab round trip leaves a reader parked mid-history exactly where they were", () => {
  const el = makeScroller(GATE);
  el.scrollTop = GATE_PARKED;
  const ctx = makeCtx(el);

  // The assertion below is only discriminating if "parked" and "the bottom"
  // are different places. Pin that before relying on it, or `354` passing
  // would prove nothing about whether a snap happened.
  assert.equal(el.bottom(), GATE_BOTTOM, "the gate's own max scrollTop");
  assert.notEqual(
    GATE_PARKED,
    GATE_BOTTOM,
    "the reader must be measurably away from the live edge for this test to " +
      "be able to fail",
  );

  // P2/P3: the wrap takes `hidden`, the ResizeObserver delivers the 0x0 box.
  // P4: back on the Chat tab.
  //
  // NOTHING is asserted about the hook's internals before the round trip
  // finishes, deliberately. This test's whole claim is about where the READER
  // ends up, so that is the assertion a reverted fix has to reach — an earlier
  // assertion on a remembered dimension would redden first and leave the
  // user-visible claim unexercised. The internals get their own case below.
  el.hide();
  ctx._onViewportResize();
  el.show();
  ctx._onViewportResize();

  assert.equal(
    el.scrollTop,
    GATE_PARKED,
    "the reader keeps their place across the round trip",
  );
  assert.equal(ctx.reported, 0, "and no snap was reported to the server");
});

test("the box-less frame leaves no trace in the remembered geometry", () => {
  // The mechanism behind the previous test, asserted separately so that one
  // fails on the reader's position rather than here. Each of the three is a
  // term the WIDTH path reconstructs the reader's distance from; a zero in any
  // of them is what produced the gate's 614.
  const el = makeScroller(GATE);
  el.scrollTop = GATE_PARKED;
  const ctx = makeCtx(el);

  el.hide();
  assert.equal(el.scrollTop, 0, "a box-less element reports scrollTop 0");
  assert.equal(el.scrollHeight, 0, "and scrollHeight 0 — the value at risk");

  ctx._onViewportResize();

  assert.equal(ctx._lastClientWidth, GATE.clientWidth);
  assert.equal(ctx._lastClientHeight, GATE.clientHeight);
  assert.equal(ctx._lastScrollHeight, GATE.scrollHeight);

  // And the guard must be a guard, not a blanket refusal: a real resize of a
  // real box is still recorded. Without this the three assertions above would
  // also pass for an `_onViewportResize` that had been deleted outright.
  el.show();
  el._h = GATE.clientHeight - 100;
  el._sh = GATE.scrollHeight + 40;
  ctx._onViewportResize();
  assert.equal(ctx._lastClientHeight, GATE.clientHeight - 100);
  assert.equal(ctx._lastScrollHeight, GATE.scrollHeight + 40);
});

test("MUTATION: with the box-less guard disabled the same trip reproduces the gate's 354 -> 0 -> 614", () => {
  const el = makeScroller(GATE);
  el.scrollTop = GATE_PARKED;
  const ctx = makeCtx(el, { guarded: false });

  const trace = [el.scrollTop];
  el.hide();
  ctx._onViewportResize();
  trace.push(el.scrollTop);
  el.show();
  ctx._onViewportResize();
  trace.push(el.scrollTop);

  // This is the defect, and it is what makes the previous test's pass mean
  // something: the fix is the ONLY reason the reader keeps 354.
  assert.deepEqual(
    trace,
    [GATE_PARKED, 0, GATE_BOTTOM],
    "the pre-fix arithmetic must still reproduce the gate's measured trace",
  );
});

test("the FIRST arrival on the Chat tab still lands on the newest message", () => {
  // `/meetings` opens on the People tab, so the chat pane mounts box-less and
  // `mounted()` seeds all three dimensions from a `display: none` scroller.
  // The reader's first visit to the Chat tab is therefore the one case where
  // the zeroes are not a lie, and the width path's `0 - 0 - 0 = 0` correctly
  // reads as "following the live edge" and snaps.
  //
  // This case exists because the guard above now DEPENDS on that: anyone who
  // "tidies" the mount seed, or widens the guard to cover the first delivery,
  // drops a first-time reader at the top of a long history instead of at the
  // newest message. That regression is silent and this is what catches it.
  const el = makeScroller(GATE);
  el.hide();
  const ctx = {
    scrollEl: el,
    _initialScroll: false,
    _lastClientWidth: el.clientWidth, // 0 — seeded while box-less
    _lastClientHeight: el.clientHeight, // 0
    _lastScrollHeight: el.scrollHeight, // 0
    reported: 0,
    _reportDistance() {
      this.reported += 1;
    },
    _onViewportResize: ScrollToBottom._onViewportResize,
    _pendingRealignTop: null,
    _applyPendingRealign: ScrollToBottom._applyPendingRealign,
    _hasMeasurableBox: ScrollToBottom._hasMeasurableBox,
  };

  assert.equal(ctx._lastScrollHeight, 0, "the mount seed is genuinely zero");

  el.show();
  assert.equal(el.scrollTop, 0, "and the reader starts at the top");

  ctx._onViewportResize();

  assert.equal(
    el.scrollTop,
    GATE_BOTTOM,
    "a first arrival snaps to the newest message",
  );
  assert.equal(ctx.reported, 1, "and that snap is reported to the server");
});

test("a message arriving while the pane is box-less does not poison the remembered scrollHeight", () => {
  const el = makeScroller(GATE);
  el.scrollTop = GATE_PARKED;

  // The real `_safeUpdate`, with only its collaborators stubbed — the line
  // under test is the trailing `_lastScrollHeight` refresh, and it must be the
  // shipped one.
  const base = (guarded) => ({
    scrollEl: el,
    _preUpdateDistance: null,
    _observer: null,
    grouped: 0,
    applyGrouping() {
      this.grouped += 1;
    },
    scrollToBottom() {},
    _reportDistance() {},
    _lastScrollHeight: GATE.scrollHeight,
    _safeUpdate: ScrollToBottom._safeUpdate,
    _pendingRealignTop: null,
    _applyPendingRealign: ScrollToBottom._applyPendingRealign,
    _hasMeasurableBox: guarded ? ScrollToBottom._hasMeasurableBox : () => true,
  });

  // The chat LiveView keeps streaming while the reader is on People, so
  // `updated()` -> `_safeUpdate()` runs on a `display: none` scroller.
  el.hide();

  const guarded = base(true);
  guarded._safeUpdate();
  assert.equal(guarded.grouped, 1, "_safeUpdate really ran");
  assert.equal(
    guarded._lastScrollHeight,
    GATE.scrollHeight,
    "the last RENDERED scrollHeight survives a box-less patch",
  );

  // Same call, guard disabled: the value the fix exists to keep out.
  const unguarded = base(false);
  unguarded._safeUpdate();
  assert.equal(unguarded.grouped, 1, "_safeUpdate really ran");
  assert.equal(
    unguarded._lastScrollHeight,
    0,
    "and without the guard it records the box-less zero",
  );

  // WHY THAT ZERO MATTERS, rather than being untidy. It is not read on the way
  // back to the Chat tab — the guard above handles that — but it survives, and
  // the next genuine WIDTH change reconstructs the reader's distance from it.
  el.show();
  const drag = {
    scrollEl: el,
    _initialScroll: false,
    _lastClientWidth: GATE.clientWidth,
    _lastClientHeight: GATE.clientHeight,
    _lastScrollHeight: unguarded._lastScrollHeight, // the poisoned 0
    _reportDistance() {},
    _onViewportResize: ScrollToBottom._onViewportResize,
    _pendingRealignTop: null,
    _applyPendingRealign: ScrollToBottom._applyPendingRealign,
    _hasMeasurableBox: ScrollToBottom._hasMeasurableBox,
  };
  el._w = GATE.clientWidth - 168; // the sidebar's own width change
  drag._onViewportResize();
  assert.equal(
    el.scrollTop,
    GATE_BOTTOM,
    "a poisoned scrollHeight yanks a parked reader to the bottom on the next " +
      "sidebar drag — the defect the guard prevents, one interaction later",
  );
});
