// Regression guard for the reader's scroll position across a morphdom
// RELOCATION of the chat scroller (task 01a084bf stage 5, second round).
//
// ── WHAT WAS MEASURED, AND WHERE ────────────────────────────────────────────
//
// The behavioural gate reported a reader parked mid-history in the call rail's
// Chat tab returning to the TOP after a People/Transcript/Chat round trip.
// Reproduced on this box in Chrome 152.0.7977.83 over CDP, 1280x800,
// `/meetings/<slug>` with 16 seeded messages, real `Input.dispatchMouseEvent`
// wheel and real mouse press/release on the tabs. Three runs, identical:
//
//     P1 Chat, parked      scrollTop  696   scrollHeight 1709  clientHeight 493
//     P2 People            scrollTop    0   scrollHeight    0  clientHeight   0
//     P3 Transcript        scrollTop    0   scrollHeight    0  clientHeight   0
//     P4 Chat, returned    scrollTop    0   scrollHeight 1709  clientHeight 493
//
// 696 of a 1216 maximum is genuinely mid-history, so the case can fail. First
// arrival on the Chat tab measures 1216/1216 — snapped to the newest message —
// which is the CORRECT first-visit landing and is not what any of this tests.
//
// A `MutationObserver` on `document.body` across the chat→people click recorded
// three childList records in one batch, t=15-20ms:
//
//   1. a NEW `[data-role="call-rail-chat-wrap"]` ADDED,
//      mutation target `[data-role="call-rail-pane"]`
//   2. `#meeting-chat-panel-<id>` REMOVED,
//      mutation target `[data-pane="meeting-chat-panel"]`
//   3. the SAME `#meeting-chat-panel-<id>` ADDED back,
//      mutation target `[data-pane="meeting-chat-panel"]`
//
// `isConnected` on the scroller read TRUE at every one of them: the subtree was
// MOVED, not removed, and never rests detached. Node identity from the scroller
// upward — depths 0-4 the SAME nodes, depths 5 and 6 REPLACED, depth 7
// (`call-rail-pane`) and above the same. The round trip back to Chat produced
// NO further relocation records: there is exactly one, on the way out.
//
// ── THE TWO BROWSER FACTS THIS FILE TAKES AS INPUT ──────────────────────────
//
// These are NODE tests. They cannot observe a browser, and they do not pretend
// to. Two measured facts are MODELLED by the shims below, as inputs:
//
//   (i) MOVING A SCROLL CONTAINER LOSES ITS OFFSET, and `display: none` has
//       nothing to do with it. Isolated on a static page reproducing the
//       three-event shape above
//       (priv/measurements/01a084bf-hidden-pane-scroll/reloc.html, Chrome 152):
//
//           hide then show, NO relocation    354 -> 354   retained
//           hide AND relocate, then show     354 ->   0   lost
//           relocate while fully VISIBLE     354 ->   0   lost
//
//       The third line settles it — no `hidden`, no `display: none`, just the
//       move. This also withdraws the previous round's mechanism claim and the
//       gate's original one: `display: none` was never the culprit either way.
//
//  (ii) A `scrollTop` WRITE ON A BOX-LESS ELEMENT IS DISCARDED. Measured on
//       that probe and again in the app: at the People tab the hidden scroller
//       was written 696 and read back 0 in the same expression, and the return
//       to Chat landed at 0. This is why the repair cannot happen in the
//       observer callback, which always runs box-less on this transition.
//
// What these tests verify is the hook's OBSERVER WIRING and its ARITHMETIC,
// which is the whole of what the fix changes. The behavioural proof that a real
// reader keeps their place is the e2e re-run of the gate; on this build that
// same rig measured P4 at 696 three times running, and 0 three times with the
// hook reverted. Nothing in this file is evidence for that.
//
// Run from the assets dir:
//
//     node --test test/scroll_to_bottom_relocation_test.mjs

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

// Load the REAL hook source rather than a copy, so this test cannot drift from
// the implementation it guards. Same approach as the sibling scroll tests.
const hookBody = readFileSync(
  resolve(__dirname, "../js/hooks/scroll_to_bottom.js"),
  "utf8",
)
  .replace(/^\s*export\s+default\s+ScrollToBottom\s*;?\s*$/m, "")
  .concat("\nreturn ScrollToBottom;\n");

const ScrollToBottom = new Function(hookBody)();

// ---------------------------------------------------------------------------
// Minimal element shim — parentage and `contains`, nothing else
// ---------------------------------------------------------------------------

function node(label) {
  return {
    label,
    parentElement: null,
    childNodes: [],
    contains(other) {
      let n = other;
      while (n) {
        if (n === this) return true;
        n = n.parentElement;
      }
      return false;
    },
  };
}

function attach(child, parent) {
  child.parentElement = parent;
  parent.childNodes.push(child);
  return child;
}

// The scroller: element shim plus the geometry model. Fact (i) is encoded in
// `loseOffsetToRelocation` and fact (ii) in the `scrollTop` setter — both
// stated above.
//
// Written as ONE object literal rather than `Object.assign(node(...), {...})`
// on purpose: `Object.assign` copies the VALUE a getter returns, not the
// accessor, which silently turns every measurement below into a frozen number
// and makes the whole file pass or fail for reasons that have nothing to do
// with the hook. That happened while writing this.
function makeScroller({ clientHeight, scrollHeight }) {
  return {
    label: "#chat-message-scroller",
    parentElement: null,
    childNodes: [],
    contains(other) {
      let n = other;
      while (n) {
        if (n === this) return true;
        n = n.parentElement;
      }
      return false;
    },
    _h: clientHeight,
    _sh: scrollHeight,
    _retained: 0,
    _writesAttemptedWhileBoxless: 0,
    rendered: true,
    get clientWidth() {
      return this.rendered ? 370 : 0;
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
      // FACT (ii), measured: the write is discarded, not clamped, not queued.
      if (!this.rendered) {
        this._writesAttemptedWhileBoxless += 1;
        return;
      }
      const max = Math.max(0, this._sh - this._h);
      this._retained = Math.min(Math.max(0, v), max);
    },
    hide() {
      this.rendered = false;
    },
    show() {
      this.rendered = true;
    },
    // FACT (i), measured: the move is what loses the offset.
    loseOffsetToRelocation() {
      this._retained = 0;
    },
    bottom() {
      return Math.max(0, this._sh - this._h);
    },
  };
}

// ---------------------------------------------------------------------------
// MutationObserver shim
// ---------------------------------------------------------------------------
// Records what the hook armed itself on. `deliver` applies the ONE rule that
// matters here and that the parent-only wiring fell foul of: an observer
// receives a childList record only if the record's TARGET is one of its own
// observed nodes. `subtree` is honoured too, so a test cannot accidentally
// prove something about a wiring the hook does not use.
class FakeMutationObserver {
  constructor(cb) {
    this.cb = cb;
    this.targets = [];
    this.disconnects = 0;
    FakeMutationObserver.live.push(this);
  }
  observe(target, opts) {
    this.targets.push({ target, opts: opts || {} });
  }
  disconnect() {
    this.targets = [];
    this.disconnects += 1;
  }
  observedNodes() {
    return this.targets.map((t) => t.target);
  }
  watches(target) {
    return this.targets.some(
      (t) =>
        t.target === target ||
        (t.opts.subtree && t.target.contains && t.target.contains(target)),
    );
  }
  // Deliver only the records this observer would actually have received.
  deliver(records) {
    const mine = records.filter((r) => this.watches(r.target));
    if (mine.length) this.cb(mine, this);
    return mine.length;
  }
}
FakeMutationObserver.live = [];

globalThis.MutationObserver = FakeMutationObserver;

// ---------------------------------------------------------------------------
// The rail, at the depths MEASURED in the app
// ---------------------------------------------------------------------------

const GATE = { clientHeight: 493, scrollHeight: 1709 };
const PARKED = 696;
const BOTTOM = 1216; // 1709 - 493

function buildRail() {
  const body = node("BODY");
  const railPane = attach(node('[data-role="call-rail-pane"]'), body); // depth 7
  const wrap = attach(node('[data-role="call-rail-chat-wrap"]'), railPane); // depth 6
  const pane = attach(node('[data-pane="meeting-chat-panel"]'), wrap); // depth 5
  const panel = attach(node("#meeting-chat-panel-<id>"), pane); // depth 4
  const d3 = attach(node("div(unnamed)"), panel); // depth 3
  const d2 = attach(node("div(unnamed)"), d3); // depth 2
  const dropZone = attach(node("#chat-drop-zone"), d2); // depth 1
  const scroller = makeScroller(GATE);
  attach(scroller, dropZone); // depth 0
  // Message rows live INSIDE the scroller. This is measured, not assumed:
  // `#chat-message-scroller.contains(#message-list)` read true in the app, with
  // 16 children for the 16 seeded messages.
  const messageList = attach(node("#message-list"), scroller);
  return { body, railPane, wrap, pane, panel, d3, d2, dropZone, scroller, messageList };
}

// The relocation, performed on the shim exactly as the app's three records
// describe it: a NEW wrap and a NEW pane, into which the SAME `panel` node is
// moved; the old wrap is dropped. Returns the records a body-level observer saw.
function relocate(rail, { hidden }) {
  const newWrap = node('[data-role="call-rail-chat-wrap"] (new)');
  const newPane = node('[data-pane="meeting-chat-panel"] (new)');
  const oldPane = rail.pane;
  attach(newWrap, rail.railPane);
  attach(newPane, newWrap);
  // The move. Old parentage is dropped first, as `insertBefore` does.
  oldPane.childNodes = oldPane.childNodes.filter((c) => c !== rail.panel);
  attach(rail.panel, newPane);
  rail.railPane.childNodes = rail.railPane.childNodes.filter(
    (c) => c !== rail.wrap,
  );
  rail.wrap.parentElement = null;
  rail.scroller.loseOffsetToRelocation();
  if (hidden) rail.scroller.hide();
  const records = [
    { type: "childList", target: rail.railPane, addedNodes: [newWrap], removedNodes: [] },
    { type: "childList", target: oldPane, addedNodes: [], removedNodes: [rail.panel] },
    { type: "childList", target: newPane, addedNodes: [rail.panel], removedNodes: [] },
  ];
  rail.wrap = newWrap;
  rail.pane = newPane;
  return records;
}

function makeCtx(scroller) {
  return {
    scrollEl: scroller,
    _initialScroll: false,
    _lastClientWidth: scroller.clientWidth,
    _lastClientHeight: scroller.clientHeight,
    _lastScrollHeight: scroller.scrollHeight,
    _scrollObservedTop: scroller.scrollTop,
    _pendingRealignTop: null,
    reported: 0,
    _reportDistance() {
      this.reported += 1;
    },
    _hasMeasurableBox: ScrollToBottom._hasMeasurableBox,
    _realignAncestorChain: ScrollToBottom._realignAncestorChain,
    _realignChainChanged: ScrollToBottom._realignChainChanged,
    _connectRealignObserver: ScrollToBottom._connectRealignObserver,
    _disconnectRealignObserver: ScrollToBottom._disconnectRealignObserver,
    _onRealignMutations: ScrollToBottom._onRealignMutations,
    _repairRealignedScroll: ScrollToBottom._repairRealignedScroll,
    _applyPendingRealign: ScrollToBottom._applyPendingRealign,
    _onViewportResize: ScrollToBottom._onViewportResize,
  };
}

function armed(rail) {
  const scroller = rail.scroller;
  const ctx = makeCtx(scroller);
  scroller.scrollTop = PARKED;
  ctx._scrollObservedTop = PARKED; // every scroll event refreshes this
  FakeMutationObserver.live = [];
  ctx._connectRealignObserver();
  return { ctx, mo: FakeMutationObserver.live[0] };
}

// ---------------------------------------------------------------------------

test("THE INSTRUMENT: the shim reproduces the two measured browser facts", () => {
  // Every case below is a claim about the hook GIVEN these behaviours. If the
  // shim stops modelling them the rest of this file measures nothing, and it
  // would still be green — the first draft used `Object.assign` over an object
  // with getters, which froze every measurement, and three cases passed anyway.
  const s = makeScroller(GATE);
  s.scrollTop = PARKED;
  assert.equal(s.scrollTop, PARKED, "a write with a box sticks");
  assert.equal(s.bottom(), BOTTOM, "and the maximum is the gate's own");

  s.hide();
  assert.equal(s.clientHeight, 0, "box-less: clientHeight reads 0");
  assert.equal(s.scrollHeight, 0, "box-less: scrollHeight reads 0");
  assert.equal(s.scrollTop, 0, "box-less: scrollTop reads 0");

  s.scrollTop = 42;
  s.show();
  assert.equal(s.scrollTop, PARKED, "FACT (ii): the box-less write was discarded");
  assert.equal(s._writesAttemptedWhileBoxless, 1, "and it was counted");

  s.loseOffsetToRelocation();
  assert.equal(s.scrollTop, 0, "FACT (i): the move loses the offset");
});

test("the observer is armed on every ancestor, and on nothing at or below the scroller", () => {
  const rail = buildRail();
  const { mo } = armed(rail);

  const observed = mo.observedNodes();
  assert.deepEqual(
    observed.map((n) => n.label),
    [
      "#chat-drop-zone",
      "div(unnamed)",
      "div(unnamed)",
      "#meeting-chat-panel-<id>",
      '[data-pane="meeting-chat-panel"]',
      '[data-role="call-rail-chat-wrap"]',
      '[data-role="call-rail-pane"]',
      "BODY",
    ],
    "every ancestor from the scroller's parent to the root, in order",
  );

  // THE HAZARD THIS ANSWERS. The mutation lands FOUR levels above the node the
  // old wiring watched. `#chat-drop-zone` alone — the whole of the pre-fix
  // observation set — is not among the three measured mutation targets.
  assert.ok(observed.includes(rail.railPane), "depth 7 is watched");
  assert.ok(observed.includes(rail.pane), "depth 5 is watched");

  // And nothing subtree-wide, at any target: a subtree observer on a rail
  // ancestor would run on every arriving message.
  for (const t of mo.targets) {
    assert.deepEqual(
      t.opts,
      { childList: true },
      `${t.target.label} is watched for its own child list only`,
    );
  }

  // The scroller and its descendants are deliberately NOT watched.
  assert.ok(!observed.includes(rail.scroller), "the scroller itself is not a target");
  assert.ok(!observed.includes(rail.messageList), "#message-list is not a target");
});

test("an arriving message cannot even reach the callback, and would be declined if it did", () => {
  const rail = buildRail();
  const { ctx, mo } = armed(rail);

  // A stream insert is a childList record whose TARGET is `#message-list`, a
  // descendant of the scroller. Two independent reasons it is harmless:
  const row = node("#chat-message-999");
  const insert = [
    { type: "childList", target: rail.messageList, addedNodes: [row], removedNodes: [] },
  ];

  // ONE — the observer is not armed on that target, so the callback never runs.
  assert.equal(mo.deliver(insert), 0, "no record is delivered for a message insert");

  // TWO — force it through anyway. Even delivered, nothing about the scroller
  // moved, so the predicate must say NOTHING. A detector that fires here would
  // fight the follow-the-live-edge behaviour on every message.
  ctx._onRealignMutations(insert);
  assert.equal(ctx._pendingRealignTop, null, "no restore is queued");
  assert.equal(rail.scroller.scrollTop, PARKED, "and the reader is not moved");

  // Also with a REMOVAL in the batch — a stream reset drops rows — which is the
  // shape closest to the one the predicate does fire on.
  ctx._onRealignMutations([
    { type: "childList", target: rail.messageList, addedNodes: [], removedNodes: [row] },
  ]);
  assert.equal(ctx._pendingRealignTop, null, "a removed message row is not a relocation");
  assert.equal(rail.scroller.scrollTop, PARKED);
});

test("a tab round trip leaves a reader parked mid-history exactly where they were", () => {
  const rail = buildRail();
  const { ctx, mo } = armed(rail);

  // The fixture has to be able to fail before anything below means a thing:
  // "parked", "the top" and "the bottom" must be three different places.
  assert.equal(rail.scroller.bottom(), BOTTOM, "the gate's own max scrollTop");
  assert.notEqual(PARKED, BOTTOM, "the reader is measurably away from the live edge");
  assert.notEqual(PARKED, 0, "and away from the top");

  // NOTHING is asserted about the hook's internals here, deliberately. This
  // test's whole claim is where the READER ends up, so that is the assertion a
  // reverted fix has to reach — an earlier assertion on a delivery count or a
  // held offset would redden first and leave the user-visible claim unexercised.
  // The internals get their own cases below.
  mo.deliver(relocate(rail, { hidden: true }));
  rail.scroller.show();
  ctx._onViewportResize();

  assert.equal(
    rail.scroller.scrollTop,
    PARKED,
    "the reader keeps their place across the round trip",
  );
  assert.equal(ctx.reported, 0, "and no snap was reported to the server");
});

test("the measured batch is caught four levels up, and the restore is DEFERRED because there is no box", () => {
  // The mechanism behind the previous test, asserted separately so that one
  // fails on the reader's position rather than here.
  const rail = buildRail();
  const { ctx, mo } = armed(rail);

  const records = relocate(rail, { hidden: true });

  // TWO of the three reach it, not three, and the reason matters: record 3's
  // target is the NEW `[data-pane="meeting-chat-panel"]`, a node that did not
  // exist when the observer armed, so nothing could have been watching it. The
  // one that carries the claim is record 2 — the removal of the still-scroller-
  // containing panel from the OLD pane, which is an armed ancestor. A wiring
  // that needed the additions would be relying on a node it cannot know about.
  assert.equal(mo.deliver(records), 2, "the two records on armed ancestors arrive");

  // The repair must NOT have written anything: a write here is discarded
  // (fact ii), and a hook that "repaired" box-less would look fixed and not be.
  assert.equal(ctx._pendingRealignTop, PARKED, "the offset is held for later");
  assert.equal(
    rail.scroller._writesAttemptedWhileBoxless,
    0,
    "and no doomed write was attempted",
  );

  // Back on the Chat tab: the wrap loses `hidden`, the box returns, and the
  // browser has nothing to hand back — the move destroyed it.
  rail.scroller.show();
  assert.equal(rail.scroller.scrollTop, 0, "the relocation left the reader at the top");

  // The ResizeObserver delivery on re-show is what pays the offset back.
  ctx._onViewportResize();
  assert.equal(rail.scroller.scrollTop, PARKED, "restored on the re-show delivery");
  assert.equal(ctx._pendingRealignTop, null, "and the restore is spent, not re-applied");
});

test("a patch, not a resize, can be what makes the pane measurable again", () => {
  // `_safeUpdate` is the second entry point. Without it the restore would
  // depend on a ResizeObserver delivery that is not guaranteed to come first.
  const rail = buildRail();
  const { ctx, mo } = armed(rail);
  mo.deliver(relocate(rail, { hidden: true }));
  assert.equal(ctx._pendingRealignTop, PARKED);

  rail.scroller.show();
  const patchCtx = Object.assign(ctx, {
    _preUpdateDistance: null,
    _observer: null,
    grouped: 0,
    applyGrouping() {
      this.grouped += 1;
    },
    scrollToBottomSawTop: null,
    scrollToBottom() {
      // Recorded so the ordering claim is checked rather than asserted: the
      // follow rule must read the RESTORED position, not the relocation's 0.
      this.scrollToBottomSawTop = this.scrollEl.scrollTop;
    },
    _safeUpdate: ScrollToBottom._safeUpdate,
  });

  patchCtx._safeUpdate();

  assert.equal(patchCtx.grouped, 1, "_safeUpdate really ran");
  assert.equal(rail.scroller.scrollTop, PARKED, "the reader keeps their place");
  assert.equal(
    patchCtx.scrollToBottomSawTop,
    PARKED,
    "and the follow rule saw the restored offset, not 0",
  );
});

test("MUTATION: with the observer narrowed back to the parent, the same batch is never delivered and the reader is lost", () => {
  const rail = buildRail();
  const scroller = rail.scroller;
  const ctx = makeCtx(scroller);
  scroller.scrollTop = PARKED;
  ctx._scrollObservedTop = PARKED;

  // The PRE-FIX wiring, stated as the one line it was: observe the parent only.
  FakeMutationObserver.live = [];
  const mo = new FakeMutationObserver((muts) => ctx._onRealignMutations(muts));
  mo.observe(scroller.parentElement, { childList: true });

  const records = relocate(rail, { hidden: true });

  // This is the defect, and it is what makes the previous tests mean something:
  // none of the three measured records has `#chat-drop-zone` as its target.
  assert.equal(
    mo.deliver(records),
    0,
    "the parent-only observer receives nothing from a relocation four levels up",
  );
  assert.equal(ctx._pendingRealignTop, null, "so no restore is ever queued");

  scroller.show();
  ctx._onViewportResize();

  assert.equal(
    scroller.scrollTop,
    0,
    "and the reader lands at the top — the gate's P4, reproduced",
  );
});

test("MUTATION: repairing immediately instead of deferring writes into a box that is not there", () => {
  // The remedy as first proposed — widen the observer, call the existing
  // `_repairRealignedScroll` — fails on fact (ii) and fails SILENTLY. This pins
  // that the deferral is load-bearing rather than defensive tidiness.
  const rail = buildRail();
  const { ctx, mo } = armed(rail);
  // Disable only the box check inside the repair, nothing else.
  ctx._hasMeasurableBox = () => true;
  mo.deliver(relocate(rail, { hidden: true }));

  assert.equal(ctx._pendingRealignTop, null, "nothing was deferred");
  assert.equal(
    rail.scroller._writesAttemptedWhileBoxless,
    1,
    "a write was attempted on the box-less scroller",
  );

  rail.scroller.show();
  assert.equal(
    rail.scroller.scrollTop,
    0,
    "and it was discarded: the reader is still at the top",
  );
});

test("the observer re-arms on the ancestors that replaced the discarded ones", () => {
  const rail = buildRail();
  const { ctx, mo } = armed(rail);
  const discardedPane = rail.pane;
  const discardedWrap = rail.wrap;

  FakeMutationObserver.live = [];
  mo.deliver(relocate(rail, { hidden: true }));

  // A second observer was constructed by the re-arm inside the callback.
  assert.equal(FakeMutationObserver.live.length, 1, "exactly one re-arm");
  const rearmed = FakeMutationObserver.live[0];
  const nodes = rearmed.observedNodes();

  assert.ok(nodes.includes(rail.pane), "the NEW depth-5 node is watched");
  assert.ok(nodes.includes(rail.wrap), "the NEW depth-6 node is watched");
  assert.ok(!nodes.includes(discardedPane), "the replaced depth-5 node is not");
  assert.ok(!nodes.includes(discardedWrap), "the replaced depth-6 node is not");
  assert.ok(nodes.includes(rail.railPane), "and depth 7, which survived, still is");
  assert.equal(mo.disconnects, 1, "the stale observer was disconnected, not leaked");
  assert.equal(ctx._pendingRealignTop, PARKED, "the restore survived the re-arm");
});

test("chain identity, not chain shape, is what detects the replacement", () => {
  // Depths 5 and 6 are NEW nodes carrying the SAME attributes and the same
  // depth. A comparison on tag, selector or length would call this unchanged —
  // and `contains` cannot help either, because by the time the callback runs the
  // scroller has already been moved out of the node that was removed.
  const rail = buildRail();
  const { ctx } = armed(rail);

  assert.equal(ctx._realignChainChanged(), false, "nothing has moved yet");

  const beforeLength = ctx._realignAncestorChain().length;
  relocate(rail, { hidden: true });
  const after = ctx._realignAncestorChain();

  assert.equal(after.length, beforeLength, "the chain is the SAME LENGTH after the move");
  assert.equal(ctx._realignChainChanged(), true, "identity still catches it");
});

test("a relocation with a real box still repairs immediately — the drawer case does not regress", () => {
  // Task 01a05873's case: the scroller is relocated while fully rendered, no
  // scroll event fires, and the offset reads 0. There is nothing to wait for
  // and deferring it would leave the reader at the top until the next resize.
  const rail = buildRail();
  const { ctx, mo } = armed(rail);

  const records = relocate(rail, { hidden: false });
  assert.ok(rail.scroller.rendered, "the box is present for this one");
  assert.equal(rail.scroller.scrollTop, 0, "and the move still lost the offset");

  mo.deliver(records);

  assert.equal(rail.scroller.scrollTop, PARKED, "restored in the callback itself");
  assert.equal(ctx._pendingRealignTop, null, "nothing was deferred");
});

test("a deferred restore does not survive into a different conversation", () => {
  const rail = buildRail();
  const { ctx, mo } = armed(rail);
  mo.deliver(relocate(rail, { hidden: true }));
  assert.equal(ctx._pendingRealignTop, PARKED);

  const switching = Object.assign(ctx, {
    _anchoredFor: "old",
    _clearSettleTimers() {},
    _connectResizeObserver() {},
    _beginConversation: ScrollToBottom._beginConversation,
  });
  switching._beginConversation("a-different-space");
  clearTimeout(switching._settleCeiling);

  assert.equal(
    switching._pendingRealignTop,
    null,
    "the previous space's offset is dropped rather than applied to a new list",
  );

  rail.scroller.show();
  ctx._onViewportResize();
  assert.equal(rail.scroller.scrollTop, 0, "and nothing is restored after the switch");
});
