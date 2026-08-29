import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import ScrollToBottom from "../../js/hooks/scroll_to_bottom.js";

/**
 * Tests for the `ScrollToBottom` hook's deep-link anchor branch
 * (task 019fabe8 stage 3).
 *
 * Background: `scrollToBottom()` hard-snaps `scrollTop = scrollHeight`
 * on mount and again on EVERY MutationObserver fire while
 * `_initialScroll` is true. That phase ends on ARRIVAL — 250ms of quiet
 * layout, a 3s ceiling, or a real wheel/touchmove/keydown gesture —
 * whichever comes first (task 01a03f3a). It used to end the first time
 * the container merely OVERFLOWED; these fixtures overflow on the mount
 * frame (4000 > 600), so under the old rule the phase was spent before
 * the first assertion ran, and several tests below silently depended on
 * that. See `mountedAndScrolledUp` and the BASELINE test.
 *
 * Stream batches land async after mount, so an anchored window
 * (stages 1 + 2) gets yanked to the bottom repeatedly —
 * including after `chat:scroll-to-message` has already centred the
 * target. Server-side anchoring cannot win that race; the hook has to
 * be told not to snap. `#message-list` carries
 * `data-anchor-message-id` so the instruction arrives in the SAME diff
 * as the streamed window rather than as a second round trip.
 *
 * Every "it did not snap" assertion here is paired with a positive
 * control in the same test asserting the anchored scroll actually
 * happened — otherwise a hook that never ran at all would pass.
 *
 * Vitest's default env is node (no jsdom), matching the other hook
 * suites in this directory; we build minimal fake elements that record
 * `scrollTop` writes and `scrollIntoView` calls.
 */

// ── Fakes ──────────────────────────────────────────────────────────────

function fakeRow(messageId, participantId = "p-1") {
  const classes = new Set();
  return {
    dataset: { messageId, participantId },
    style: {},
    // `applyGrouping` marks continuation rows with a class and lets
    // app.css own the collapsed geometry, so the shim needs a real
    // `classList.toggle`. Only the two-argument form is used.
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

// `#message-list`. In the real DOM the hook climbs to the
// `#chat-message-scroller` wrapper via `closest("[data-scroll-container]")`;
// `scrollContainer` lets a test model that separation, and defaults to
// the list being its own scroller.
function fakeList({
  rows = [],
  anchorId = null,
  scrollHeight = 4000,
  clientHeight = 600,
  scrollTop = 0,
  spaceId = undefined,
} = {}) {
  const el = {
    dataset: {},
    rows,
    scrollHeight,
    clientHeight,
    _scrollTop: scrollTop,
    scrollTopWrites: [],
    get scrollTop() {
      return this._scrollTop;
    },
    set scrollTop(v) {
      // Only a write that CHANGES the value is recorded. Assigning scrollTop
      // its current value is a no-op in a real scroller, and the reflow hold
      // (`holdAnchorThroughReflow`) does exactly that every frame when the
      // layout has not moved — recording those would turn "the reader was
      // not yanked" assertions into noise about a pin that moved nothing.
      if (v === this._scrollTop) return;
      this._scrollTop = v;
      this.scrollTopWrites.push(v);
    },
    closest() {
      return null;
    },
    // The jump-to-latest distance signal listens for `scroll` on the
    // scroller. Recorded rather than dispatched so a test can assert the
    // registration options (passive) as well as drive the handler.
    listeners: [],
    addEventListener(type, fn, opts) {
      this.listeners.push({ type, fn, opts });
    },
    removeEventListener(type, fn) {
      this.listeners = this.listeners.filter(
        (l) => !(l.type === type && l.fn === fn),
      );
    },
    emit(type) {
      this.listeners.filter((l) => l.type === type).forEach((l) => l.fn());
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
  if (anchorId) el.dataset.anchorMessageId = anchorId;
  // Mirrors `data-space-id={@active_space && @active_space.id}`: a nil
  // assign renders NO attribute at all, so the undefined default is the
  // real no-space landing shape, not an oversight.
  if (spaceId !== undefined) el.dataset.spaceId = spaceId;
  return el;
}

function buildHook(el) {
  const hook = Object.create(ScrollToBottom);
  hook.el = el;
  // Records `(name, cb)` so a test can invoke a server-pushed event the way
  // LiveView would.
  hook.serverEvents = {};
  hook.handleEvent = vi.fn((name, cb) => {
    hook.serverEvents[name] = cb;
  });
  hook.pushEvent = vi.fn();
  return hook;
}

function anchoredRows(el) {
  return el.rows.flatMap((r) => r.scrollIntoViewCalls);
}

// `applyGrouping` marks continuations AND run boundaries; these read the two
// class flags back off the rows in list order.
function groupings(el) {
  return el.rows.map((r) => r.classList.contains("message-row--grouped"));
}

function runEnds(el) {
  return el.rows.map((r) => r.classList.contains("message-row--run-end"));
}

// ── Tests ──────────────────────────────────────────────────────────────

describe("ScrollToBottom — deep-link anchor holds the arrival position", () => {
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

    // Polyfill ResizeObserver for node test env (task 019ff6c9)
    priorRO = globalThis.ResizeObserver;
    globalThis.ResizeObserver = class {
      constructor(cb) {
        this.cb = cb;
      }
      observe() {}
      disconnect() {}
    };

    // Polyfill requestAnimationFrame / cancelAnimationFrame
    priorRAF = globalThis.requestAnimationFrame;
    // Track every pending frame so `afterEach` can cancel the survivors.
    // `holdAnchorThroughReflow` self-reschedules for 400ms; left running, it
    // fires after the polyfill is torn down and throws into the runner as an
    // unhandled error attributed to whichever test happens to be in flight.
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

  it("BASELINE: with no anchor attribute, mount hard-snaps to the bottom", async () => {
    const el = fakeList({ rows: [fakeRow("m-1"), fakeRow("m-2")] });
    const hook = buildHook(el);

    hook.mounted();

    // This is the untouched behaviour every other test is measured
    // against. If this ever stops snapping, the "anchor suppressed the
    // snap" assertions below become vacuous.
    expect(el.scrollTopWrites).toEqual([4000]);
    expect(anchoredRows(el)).toEqual([]);

    // The arrival phase is still OPEN on the mount frame, and that is the
    // contract task 01a03f3a landed. It used to end the moment the container
    // merely overflowed, which this fixture does immediately (4000 > 600) —
    // and ending it there also tore down the late-layout ResizeObserver on
    // that same frame, stranding a reader above the newest message once
    // fonts/images/tables grew the list by more than NEAR_BOTTOM_PX.
    // Restoring the overflow exit flips this back to false.
    expect(hook._initialScroll).toBe(true);

    // …and it must still END, or the fix reinstates the unconditional
    // yank-to-bottom that task 019f51d1 removed — the direction the deleted
    // `toBe(false)` assertion used to cover. Waited out in real time past
    // SETTLE_QUIET_MS (250ms) rather than reaching into the hook's timers,
    // the same idiom as the sibling guard in
    // test/scroll_to_bottom_arrival_test.mjs.
    await new Promise((resolve) => setTimeout(resolve, 500));
    expect(hook._initialScroll).toBe(false);
    // The settle exit is not a second snap: nothing moved while it waited.
    expect(el.scrollTopWrites).toEqual([4000]);
  });

  it("honours the anchor instead of the initial snap", () => {
    const target = fakeRow("m-42");
    const el = fakeList({
      rows: [fakeRow("m-40"), target, fakeRow("m-44")],
      anchorId: "m-42",
    });
    const hook = buildHook(el);

    hook.mounted();

    // Negative: the bottom snap did not fire.
    expect(el.scrollTopWrites).toEqual([]);
    // Positive control in the same test: the anchored scroll DID fire,
    // centred, on the right row. A hook that simply never ran would
    // fail here.
    expect(target.scrollIntoViewCalls).toEqual([{ block: "center" }]);
    // The initial-snap phase is over, so later stream batches take the
    // ordinary near-bottom path rather than re-snapping.
    expect(hook._initialScroll).toBe(false);
  });

  it("keeps holding the anchor across the async stream batches that follow mount", () => {
    const target = fakeRow("m-42");
    const el = fakeList({ rows: [target], anchorId: "m-42" });
    const hook = buildHook(el);

    hook.mounted();
    expect(target.scrollIntoViewCalls).toHaveLength(1);

    // Stream batches land after mount and mutate childList; each one
    // used to get an unconditional yank to the bottom.
    el.rows.push(fakeRow("m-43"), fakeRow("m-44"));
    el.scrollHeight = 6000;
    hook.updated();
    el.rows.push(fakeRow("m-45"));
    el.scrollHeight = 7000;
    hook.updated();

    expect(el.scrollTopWrites).toEqual([]);
    // Honoured exactly once for that id — no repeated re-centring that
    // would fight a reader who has started scrolling.
    expect(target.scrollIntoViewCalls).toHaveLength(1);
  });

  it("re-anchors when the attribute changes to a new id", () => {
    const first = fakeRow("m-1");
    const second = fakeRow("m-2");
    const el = fakeList({ rows: [first, second], anchorId: "m-1" });
    const hook = buildHook(el);

    hook.mounted();
    expect(first.scrollIntoViewCalls).toHaveLength(1);
    expect(second.scrollIntoViewCalls).toHaveLength(0);

    // A second deep-link arrival in the same LiveView session patches
    // the attribute; the once-per-id guard must not swallow it.
    el.dataset.anchorMessageId = "m-2";
    hook.updated();

    expect(second.scrollIntoViewCalls).toEqual([{ block: "center" }]);
    expect(first.scrollIntoViewCalls).toHaveLength(1);
    expect(el.scrollTopWrites).toEqual([]);
  });

  it("falls back to the bottom snap when the anchor row is not in the DOM yet, then anchors once it arrives", () => {
    const el = fakeList({ rows: [fakeRow("m-1")], anchorId: "m-99" });
    const hook = buildHook(el);

    hook.mounted();

    // Byte-identical to the no-attribute baseline: an anchor we cannot
    // resolve must never leave the reader mid-nowhere.
    expect(el.scrollTopWrites).toEqual([4000]);
    expect(anchoredRows(el)).toEqual([]);

    // Positive control that the fallback is not permanent: when the
    // target row lands in a later stream batch the hook still anchors.
    const late = fakeRow("m-99");
    el.rows.push(late);
    hook.updated();

    expect(late.scrollIntoViewCalls).toEqual([{ block: "center" }]);
    expect(el.scrollTopWrites).toEqual([4000]);
  });

  it("resumes the ordinary near-bottom rule after the anchor is honoured", () => {
    const target = fakeRow("m-42");
    const el = fakeList({ rows: [target], anchorId: "m-42" });
    const hook = buildHook(el);

    hook.mounted();
    expect(target.scrollIntoViewCalls).toHaveLength(1);
    expect(el.scrollTopWrites).toEqual([]);

    // Reader is parked mid-history (distance from bottom 3400px): a new
    // message must NOT yank them down.
    el._scrollTop = 0;
    hook.updated();
    expect(el.scrollTopWrites).toEqual([]);

    // Positive control for the same rule: once the reader scrolls back
    // down to within NEAR_BOTTOM_PX, live tailing resumes exactly as it
    // does on a normal entry. Without this the previous assertion would
    // also pass on a hook that had stopped scrolling entirely.
    el._scrollTop = 3350; // 4000 - 600 - 3350 = 50px from the bottom
    hook.updated();
    expect(el.scrollTopWrites).toEqual([4000]);
  });

  it("leaves message grouping untouched on the anchored path", () => {
    const grouped = fakeRow("m-2", "p-1");
    const el = fakeList({
      rows: [fakeRow("m-1", "p-1"), grouped, fakeRow("m-3", "p-2")],
      anchorId: "m-2",
    });
    const hook = buildHook(el);

    hook.mounted();

    // `applyGrouping` runs before `scrollToBottom` in `_safeUpdate`;
    // returning early from the anchor branch must not skip it.
    expect(grouped.classList.contains("message-row--grouped")).toBe(true);
    // …and the row after it opens a new author group, so it stays ungrouped.
    expect(el.rows[2].classList.contains("message-row--grouped")).toBe(false);

    // Run boundaries ride the same pass, so they must survive the anchored
    // path too. m-2 closes p-1's run (m-3 switches author) and m-3 is last in
    // the container, so both end runs; m-1 is mid-run and does not.
    expect(runEnds(el)).toEqual([false, true, true]);
  });

  it("marks the last row of each author run, on the ordinary snap path", () => {
    const el = fakeList({
      rows: [
        fakeRow("m-1", "p-1"),
        fakeRow("m-2", "p-1"),
        fakeRow("m-3", "p-1"),
        fakeRow("m-4", "p-2"),
        fakeRow("m-5", "p-1"),
      ],
    });
    const hook = buildHook(el);

    hook.mounted();

    // Only the LAST row of each run is a boundary. The two middles of the
    // opening three-row run are the rows a "mark everything" implementation
    // would get wrong.
    expect(runEnds(el)).toEqual([false, false, true, true, true]);
    // m-4 and m-5 are single-message runs: no `--grouped`, but still a
    // run end each, which is what keeps them fully rounded.
    expect(groupings(el)).toEqual([false, true, true, false, false]);
  });

  it("clears a stale run-end once a later row joins the run", () => {
    // The re-render case: `toggle` must UNmark a row that has stopped being
    // the end of its run, exactly as it already does for `--grouped`.
    const first = fakeRow("m-1", "p-1");
    const second = fakeRow("m-2", "p-2");
    const el = fakeList({ rows: [first, second] });
    const hook = buildHook(el);

    hook.mounted();
    expect(runEnds(el)).toEqual([true, true]);

    // Server re-renders m-2 under the same author, merging the two runs.
    second.dataset.participantId = "p-1";
    hook.updated();

    expect(runEnds(el)).toEqual([false, true]);
    expect(groupings(el)).toEqual([false, true]);
  });

  // Task 019ffe5e stage 3 — the JS half of the reclaimed-height guard.
  //
  // #733 got a grouped one-line row from 66px to 31px by taking geometry
  // AWAY from this hook: it used to hide the grouped avatar with an inline
  // `visibility: hidden`, which conceals the picture while its 47px box
  // holds the row open, and no stylesheet rule can get under a ghost that
  // an inline style is propping up. The hook now only says WHICH rows
  // continue a run; app.css decides what one looks like.
  //
  // The e2e guard in `e2e/tests/chat_message_density.spec.ts` measures the
  // resulting 31px, but it can only see the final number, not who chose
  // it. This sees who chose it. The regression it catches is a future
  // "just hide the avatar in the hook" patch, which is the natural shape
  // for that fix to take and would put the dead space straight back while
  // the class assertions above all stayed green.
  it("writes no inline geometry — the stylesheet owns what a grouped row looks like", () => {
    const el = fakeList({
      rows: [
        fakeRow("m-1", "p-1"),
        fakeRow("m-2", "p-1"),
        fakeRow("m-3", "p-1"),
        fakeRow("m-4", "p-2"),
      ],
    });
    const hook = buildHook(el);

    hook.mounted();

    // Positive control: grouping really did run on these rows, so the
    // "no inline style" assertion below is a statement about a hook that
    // did its job rather than one that never executed.
    expect(groupings(el)).toEqual([false, true, true, false]);

    for (const row of el.rows) {
      expect(
        Object.keys(row.style),
        `applyGrouping wrote inline style ${JSON.stringify(row.style)} on ` +
          `${row.dataset.messageId}. Row geometry belongs in app.css — an ` +
          `inline style can only hide something, never reclaim its space.`,
      ).toEqual([]);
    }
  });
});

/**
 * Conversation-change reset (task 01a03c75 stage 2).
 *
 * Every channel/DM link in `chat_live.html.heex` is `patch=`, so switching
 * conversations runs `handle_params/3` without a remount: `#message-list`
 * keeps its DOM id and this hook instance, and `mounted()` does NOT re-run.
 * The initial-snap phase was therefore spent once per page load, and a
 * reader who had scrolled up carried their old offset into the next
 * conversation — by construction they are not within NEAR_BOTTOM_PX, so
 * nothing snapped them to the newest message.
 *
 * The reset is keyed strictly on `data-space-id` CHANGING VALUE. `updated()`
 * fires on every stream batch inside one conversation; resetting there would
 * reinstate the unconditional yank-to-bottom that task 019f51d1 removed.
 * That is why the "did not snap" case below is paired with a near-bottom
 * positive control on the same unchanged id.
 */
describe("ScrollToBottom — conversation change re-arms the initial snap", () => {
  let priorMO, priorRO, priorRAF, pendingFrames;
  // Every ResizeObserver the hook constructs, in order, with the elements it
  // observed. Counting constructions is how a re-arm is distinguished from a
  // flag flip: the observer disconnects itself as soon as the initial phase
  // ends, so reading `hook._resizeObserver` after `updated()` returns always
  // finds null whether or not it was ever re-armed.
  let observers;

  // The hook constructs TWO kinds of ResizeObserver, and only one of them is
  // re-armed per conversation (task 01a04aec): the ARRIVAL observer, torn down
  // by `_endInitialPhase`, and a PERMANENT viewport observer built once in
  // `mounted()` and kept for the life of the hook. This narrows the count back
  // to the arrival ones, so these assertions keep meaning exactly what they
  // meant — "a re-arm happened" — rather than being loosened to accommodate a
  // second constructor call.
  const arrivalObservers = (hook) =>
    observers.filter((o) => o !== hook._viewportObserver);

  beforeEach(() => {
    observers = [];
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
        this.observed = [];
        observers.push(this);
      }
      observe(el) {
        this.observed.push(el);
      }
      disconnect() {}
    };

    priorRAF = globalThis.requestAnimationFrame;
    // Track every pending frame so `afterEach` can cancel the survivors.
    // `holdAnchorThroughReflow` self-reschedules for 400ms; left running, it
    // fires after the polyfill is torn down and throws into the runner as an
    // unhandled error attributed to whichever test happens to be in flight.
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

  // Mount in one conversation, then park the reader well above the bottom
  // and clear the mount's own writes so each test measures ONLY what the
  // subsequent `updated()` did.
  //
  // The mount snap does NOT end the arrival phase any more (task 01a03f3a);
  // it ends on quiet layout, a 3s ceiling, or a real reader gesture. This
  // fixture's reader is one who SCROLLED UP, and scrolling up is that
  // gesture — so end the phase the way this reader actually would, through
  // the wheel listener `mounted()` really registered, rather than by poking
  // `_initialScroll` directly. Driving the shipped wiring is what keeps the
  // "does NOT snap" test below non-vacuous: unwire the gesture exit and the
  // phase stays open, every `updated()` hard-snaps, and it goes red.
  //
  // Everything after this point is the near-bottom gate's business.
  function mountedAndScrolledUp(opts = {}) {
    const el = fakeList({ rows: [fakeRow("m-1"), fakeRow("m-2")], ...opts });
    const hook = buildHook(el);
    hook.mounted();
    el.emit("wheel");
    expect(hook._initialScroll).toBe(false);
    el._scrollTop = 500;
    el.scrollTopWrites = [];
    return { el, hook };
  }

  it("snaps a scrolled-up reader to the bottom when the space id changes", () => {
    const { el, hook } = mountedAndScrolledUp({ spaceId: "space-larkspur" });

    // 4000 - 500 - 600 = 2900px up: far outside NEAR_BOTTOM_PX, so nothing
    // but a genuine phase reset can produce a snap here.
    expect(el.scrollHeight - el._scrollTop - el.clientHeight).toBe(2900);

    el.dataset.spaceId = "space-marigold";
    hook.updated();

    expect(el.scrollTopWrites).toEqual([4000]);
    expect(hook._spaceId).toBe("space-marigold");
    // Re-armed, not merely flipped: the ResizeObserver is disconnected the
    // moment the initial phase ends, so a flag-only reset would leave the
    // late-layout re-snap protection dead for every later conversation. One
    // observer came from `mounted()`; the second is the re-arm, and it is
    // watching the same scroller.
    expect(arrivalObservers(hook).length).toBe(2);
    expect(arrivalObservers(hook)[1].observed).toEqual([el]);
  });

  it("does NOT snap a scrolled-up reader when the space id is unchanged", () => {
    const { el, hook } = mountedAndScrolledUp({ spaceId: "space-larkspur" });

    // Same value re-read, exactly as a stream batch inside one conversation
    // presents it.
    el.dataset.spaceId = "space-larkspur";
    hook.updated();

    expect(el.scrollTopWrites).toEqual([]);
    expect(hook._initialScroll).toBe(false);
    // No reset happened at all — only `mounted()`'s arrival observer exists.
    expect(arrivalObservers(hook).length).toBe(1);
  });

  it("POSITIVE CONTROL: still snaps a near-bottom reader on an unchanged space id", () => {
    const { el, hook } = mountedAndScrolledUp({ spaceId: "space-larkspur" });

    // 4000 - 3300 - 600 = 100px, inside NEAR_BOTTOM_PX. This is what stops
    // the test above passing merely because the hook never ran.
    el._scrollTop = 3300;
    el.scrollTopWrites = [];
    hook.updated();

    expect(el.scrollTopWrites).toEqual([4000]);
  });

  it("honours a deep link into the new space instead of snapping to its bottom", () => {
    const target = fakeRow("m-77");
    const { el, hook } = mountedAndScrolledUp({
      rows: [fakeRow("m-70"), target, fakeRow("m-80")],
      spaceId: "space-larkspur",
    });

    el.dataset.spaceId = "space-marigold";
    el.dataset.anchorMessageId = "m-77";
    hook.updated();

    // `honourAnchor()` runs before the `_initialScroll` branch inside
    // `scrollToBottom()`, so re-arming the snap cannot override an anchored
    // arrival. Clearing `_anchoredFor` on the change is what makes the new
    // space's anchor eligible at all.
    expect(el.scrollTopWrites).toEqual([]);
    expect(target.scrollIntoViewCalls).toEqual([{ block: "center" }]);
    expect(hook._initialScroll).toBe(false);
  });

  it("treats a space id going away and coming back as two changes", () => {
    const { el, hook } = mountedAndScrolledUp({ spaceId: "space-larkspur" });

    // A no-space landing: `data-space-id={@active_space && @active_space.id}`
    // renders no attribute when the assign is nil.
    delete el.dataset.spaceId;
    expect(() => hook.updated()).not.toThrow();
    expect(hook._spaceId).toBe(null);
    expect(el.scrollTopWrites).toEqual([4000]);

    el._scrollTop = 500;
    el.scrollTopWrites = [];
    el.dataset.spaceId = "space-larkspur";
    hook.updated();

    expect(hook._spaceId).toBe("space-larkspur");
    expect(el.scrollTopWrites).toEqual([4000]);
  });
});

describe("ScrollToBottom — jump-to-latest distance signal", () => {
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
    // Track every pending frame so `afterEach` can cancel the survivors.
    // `holdAnchorThroughReflow` self-reschedules for 400ms; left running, it
    // fires after the polyfill is torn down and throws into the runner as an
    // unhandled error attributed to whichever test happens to be in flight.
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

  // Mount, then discard the mount-time report so each test measures only the
  // transitions it causes. `_lastAway` is left at the value the mount
  // established (false — the initial snap parks the reader at the bottom),
  // which is the real starting state, not a synthetic one.
  function mountedAtBottom(opts = {}) {
    const el = fakeList({ rows: [fakeRow("m-1"), fakeRow("m-2")], ...opts });
    const hook = buildHook(el);
    hook.mounted();
    expect(hook._lastAway).toBe(false);
    hook.pushEvent.mockClear();
    el.scrollTopWrites = [];
    return { el, hook };
  }

  // scrollHeight 4000, clientHeight 600 → bottom is scrollTop 3400.
  const scrollTo = (el, top) => {
    el._scrollTop = top;
    el.scrollTopWrites = [];
  };

  it("pushes nothing while the reader stays within the near-bottom band", () => {
    const { el, hook } = mountedAtBottom();

    // 3300 → 100px from the bottom, and 3251 → 149px: both under the
    // NEAR_BOTTOM_PX threshold the auto-scroll predicate uses.
    scrollTo(el, 3300);
    hook._reportDistance();
    scrollTo(el, 3251);
    hook._reportDistance();

    expect(hook.pushEvent).not.toHaveBeenCalled();
    expect(hook._lastAway).toBe(false);
    expect(hook._lastDeep).toBe(false);
  });

  it("pushes away:true exactly once on crossing above the threshold", () => {
    const { el, hook } = mountedAtBottom();

    scrollTo(el, 3200); // 200px away
    hook._reportDistance();

    expect(hook.pushEvent).toHaveBeenCalledTimes(1);
    // Two booleans since task 01a0419a stage 4. 200px is past NEAR_BOTTOM_PX
    // and far short of DEEP_HISTORY_PX, so this is the SHALLOW band: the
    // server raises no pill from this report alone.
    expect(hook.pushEvent).toHaveBeenCalledWith("jump_to_latest_distance", {
      away: true,
      deep: false,
    });
  });

  it("does not push again while the reader stays away", () => {
    const { el, hook } = mountedAtBottom();

    scrollTo(el, 3200);
    hook._reportDistance();
    hook.pushEvent.mockClear();

    // Three more evaluations at three DIFFERENT away distances. The call
    // COUNT is the assertion: a hook that pushed per scroll event would end
    // each of these with a correct-looking last call, so only the count can
    // tell the edge-triggered design from the per-event one.
    //
    // All three sit INSIDE THE SHALLOW BAND (400, 800 and 1400px — past
    // NEAR_BOTTOM_PX, short of DEEP_HISTORY_PX at 1800). They used to run out
    // to 2400 and 3400px, which since task 01a0419a stage 4 crosses into the
    // deep band and is a real transition the hook MUST push. Silence is only
    // correct while neither boolean moves; keeping the old distances here
    // would have asserted that a genuine band change goes unreported.
    scrollTo(el, 3000);
    hook._reportDistance();
    scrollTo(el, 2600);
    hook._reportDistance();
    scrollTo(el, 2000);
    hook._reportDistance();

    expect(hook.pushEvent).toHaveBeenCalledTimes(0);
    expect(hook._lastAway).toBe(true);
    expect(hook._lastDeep).toBe(false);

    // POSITIVE CONTROL for the silence above: the very next evaluation, one
    // that DOES change a band, pushes immediately. Without this the zero
    // could equally mean the hook stopped reporting altogether.
    scrollTo(el, 1000); // 2400px — deep
    hook._reportDistance();
    expect(hook.pushEvent).toHaveBeenCalledTimes(1);
    expect(hook.pushEvent).toHaveBeenCalledWith("jump_to_latest_distance", {
      away: true,
      deep: true,
    });
  });

  it("pushes away:false exactly once on returning under the threshold", () => {
    const { el, hook } = mountedAtBottom();

    scrollTo(el, 3200);
    hook._reportDistance();
    hook.pushEvent.mockClear();

    scrollTo(el, 3350); // 50px away
    hook._reportDistance();

    expect(hook.pushEvent).toHaveBeenCalledTimes(1);
    expect(hook.pushEvent).toHaveBeenCalledWith("jump_to_latest_distance", {
      away: false,
      deep: false,
    });

    // Still edge-triggered on this side too.
    hook.pushEvent.mockClear();
    scrollTo(el, 3400);
    hook._reportDistance();
    expect(hook.pushEvent).toHaveBeenCalledTimes(0);
  });

  it("does NOT hold the reading anchor on a distance edge, but still holds it for the sidebar", () => {
    const { el, hook } = mountedAtBottom();
    // INVERTED from the v2 assertion that used to stand here, which asserted
    // this call FIRED on both edges. Its stated reason was the desktop in-flow
    // chip changing the scroller's clientHeight; task 01a0419a stage 1 deleted
    // that path, and stage 2 measured the pin freezing a MOVING reader for
    // 400ms after every edge.
    const hold = vi.spyOn(hook, "holdAnchorThroughReflow");

    // Distance 200 → past the `away` band's entry at NEAR_BOTTOM_PX + 24.
    scrollTo(el, 3200);
    hook._reportDistance();
    // Distance 50 → back past the exit at NEAR_BOTTOM_PX - 24.
    scrollTo(el, 3350);
    hook._reportDistance();

    expect(hold).toHaveBeenCalledTimes(0);

    // ANTI-VACUITY, in the same block and not a separate test: zero calls is
    // also what a typo in the spy target produces. These prove both edges
    // really fired, so the refute above is about the hold and not about the
    // gesture never happening.
    expect(hook.pushEvent).toHaveBeenCalledTimes(2);
    expect(hook.pushEvent).toHaveBeenNthCalledWith(
      1,
      "jump_to_latest_distance",
      {
        away: true,
        deep: false,
      },
    );
    expect(hook.pushEvent).toHaveBeenNthCalledWith(
      2,
      "jump_to_latest_distance",
      {
        away: false,
        deep: false,
      },
    );

    // POSITIVE CONTROL — the method is still LIVE, on its original caller.
    // Dropping the `_reportDistance` call site leaves exactly one caller, not
    // zero, and a later reader deleting `holdAnchorThroughReflow()` as dead
    // code breaks the rail-collapse anchoring from task 019f51d1 silently.
    // This is the assertion that catches that.
    hook.serverEvents["sidebar_collapsed_changed"]();
    expect(hold).toHaveBeenCalledTimes(1);

    hold.mockRestore();
    if (hook._holdFrame) cancelAnimationFrame(hook._holdFrame);
  });

  // Geometry for the band cases: scrollHeight 4000, clientHeight 600, so
  // distance = 3400 - scrollTop. With THRESHOLD_HYSTERESIS_PX = 24 the `away`
  // band enters at distance 174 and leaves at 126; `deep` enters at 1824 and
  // leaves at 1776. The NOMINAL crossing points are still 150 and 1800.
  it("pushes exactly one event while the reader oscillates inside the near-bottom band, and still flips on a committed exit", () => {
    const { el, hook } = mountedAtBottom();

    // Commit past the entry edge: distance 200 > 174.
    scrollTo(el, 3200);
    hook._reportDistance();
    expect(hook.pushEvent).toHaveBeenCalledTimes(1);
    expect(hook.pushEvent).toHaveBeenCalledWith("jump_to_latest_distance", {
      away: true,
      deep: false,
    });

    // Now wobble across the NOMINAL 150 repeatedly, staying inside the band.
    // Un-banded, every one of these six is an edge and a server round trip.
    for (const distance of [160, 140, 155, 130, 149, 151]) {
      scrollTo(el, 3400 - distance);
      hook._reportDistance();
    }
    expect(hook.pushEvent).toHaveBeenCalledTimes(1);
    expect(hook._lastAway).toBe(true);

    // POSITIVE CONTROL, same test: a reader who actually commits past the
    // exit value DOES flip back. Without this the case above is satisfied by
    // a hook that has simply stopped reporting anything at all.
    scrollTo(el, 3400 - 100); // distance 100 < 126
    hook._reportDistance();
    expect(hook.pushEvent).toHaveBeenCalledTimes(2);
    expect(hook.pushEvent).toHaveBeenNthCalledWith(
      2,
      "jump_to_latest_distance",
      {
        away: false,
        deep: false,
      },
    );
  });

  it("pushes exactly one event while the reader oscillates inside the deep-history band, and still flips on a committed exit", () => {
    const { el, hook } = mountedAtBottom();

    // Commit past the entry edge: distance 2000 > 1824.
    scrollTo(el, 3400 - 2000);
    hook._reportDistance();
    expect(hook.pushEvent).toHaveBeenCalledTimes(1);
    expect(hook.pushEvent).toHaveBeenCalledWith("jump_to_latest_distance", {
      away: true,
      deep: true,
    });

    // Wobble across the NOMINAL 1800, inside the band. `away` is far from its
    // own band here, so this isolates `deep`.
    for (const distance of [1810, 1790, 1801, 1780, 1799, 1820]) {
      scrollTo(el, 3400 - distance);
      hook._reportDistance();
    }
    expect(hook.pushEvent).toHaveBeenCalledTimes(1);
    expect(hook._lastDeep).toBe(true);

    // POSITIVE CONTROL: committed exit past 1776 still flips `deep` back,
    // leaving `away` true — the middle band the two thresholds exist for.
    scrollTo(el, 3400 - 1700);
    hook._reportDistance();
    expect(hook.pushEvent).toHaveBeenCalledTimes(2);
    expect(hook.pushEvent).toHaveBeenNthCalledWith(
      2,
      "jump_to_latest_distance",
      {
        away: true,
        deep: false,
      },
    );
  });

  it("scrolls to the bottom and reports away:false on chat:scroll-to-latest", () => {
    const { el, hook } = mountedAtBottom();

    scrollTo(el, 1000);
    hook._reportDistance();
    hook.pushEvent.mockClear();
    el.scrollTopWrites = [];

    hook.serverEvents["chat:scroll-to-latest"]();

    expect(el.scrollTopWrites[0]).toBe(el.scrollHeight);
    // The server learns the reader is back in the SAME interaction, rather
    // than waiting for a scroll event a programmatic write may not produce.
    expect(hook.pushEvent).toHaveBeenCalledTimes(1);
    expect(hook.pushEvent).toHaveBeenCalledWith("jump_to_latest_distance", {
      away: false,
      deep: false,
    });
    if (hook._holdFrame) cancelAnimationFrame(hook._holdFrame);
  });

  it("registers a passive, frame-coalesced scroll listener and removes it on destroy", async () => {
    const { el, hook } = mountedAtBottom();

    const listener = el.listeners.find((l) => l.type === "scroll");
    expect(listener).toBeDefined();
    expect(listener.opts).toEqual({ passive: true });

    // End the arrival phase before scrolling away. Task 019fd1e2 (#809)
    // changed arrival to end on SETTLE rather than on overflow, so a freshly
    // mounted hook still has `_initialScroll === true` and a mount frame
    // pending. That frame runs `_safeUpdate()` first and re-snaps scrollTop
    // to the bottom, which would make the reader look near-bottom and this
    // test measure the arrival snap instead of the listener it names. The
    // sibling tests dodge this by calling `_reportDistance()` directly; this
    // one cannot, because the listener wiring is its whole subject.
    hook._endInitialPhase("test: measuring the scroll listener, not arrival");

    scrollTo(el, 3200);
    // Three events inside one frame must produce ONE evaluation, not three.
    el.emit("scroll");
    el.emit("scroll");
    el.emit("scroll");
    expect(hook.pushEvent).toHaveBeenCalledTimes(0); // still queued
    await new Promise((r) => setTimeout(r, 5));
    expect(hook.pushEvent).toHaveBeenCalledTimes(1);
    if (hook._holdFrame) cancelAnimationFrame(hook._holdFrame);

    hook.destroyed();
    expect(el.listeners.some((l) => l.type === "scroll")).toBe(false);
  });

  it("re-reports after a conversation switch even when the boolean is unchanged", () => {
    const { el, hook } = mountedAtBottom({ spaceId: "space-larkspur" });

    scrollTo(el, 3200);
    hook._reportDistance();
    hook.pushEvent.mockClear();

    // The switch goes through the SAME `data-space-id` branch that
    // `_beginConversation` already owns — there is no second detector.
    el.dataset.spaceId = "space-marigold";
    hook.updated();

    expect(hook._spaceId).toBe("space-marigold");
    // `updated()` re-snaps (fresh initial phase), so the post-switch reader
    // is at the bottom: away flips to false and is pushed because the reset
    // cleared the previous conversation's boolean.
    expect(hook.pushEvent).toHaveBeenCalledWith("jump_to_latest_distance", {
      away: false,
      deep: false,
    });
    if (hook._holdFrame) cancelAnimationFrame(hook._holdFrame);
  });
});
