import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import ScrollToBottom from "../../js/hooks/scroll_to_bottom.js";

/**
 * THE SCROLL STUTTER, MEASURED (task 01a0419a stage 2).
 *
 * Rowan, on the shipped build: "as we scroll up there is some noticeable ui
 * thrashing as we cross what I presume are the near and far thresholds. it
 * makes scrolling through history stutter and feel strange."
 *
 * STAGE 3 HAS LANDED AND THIS FILE NOW ASSERTS THE CURE. Stage 2 wrote it
 * against the PRE-FIX behaviour, where the `describes the pre-fix stutter`
 * cases passed and encoded the bug. Stage 3 dropped the
 * `_reportDistance` -> `holdAnchorThroughReflow()` call, those cases went red
 * exactly as stage 2 predicted, and they were INVERTED rather than deleted:
 * the `CURED:` cases below assert that a threshold crossing now delivers the
 * control window's numbers exactly. The change of state is therefore a diff in
 * this file rather than a memory. The measured table further down is the
 * PRE-FIX baseline and is kept verbatim as the thing being compared against.
 *
 * THE ZEROES NEED A GUARD AND THEY HAVE ONE. Every `CURED:` case asserts an
 * absence — the reader was not pinned — which is also what a broken harness
 * reports. `POSITIVE CONTROL: the harness can still see a pin` drives
 * `holdAnchorThroughReflow()` directly and asserts the pre-fix profile still
 * shows up for it. That case is doing double duty: it keeps the instrument
 * honest, and it is one of the two places that catch the method being deleted
 * as dead code when its only remaining caller is a `handleEvent`
 * registration (the other is `scroll_to_bottom.test.js`).
 *
 * THE OBSERVABLE, AND WHY IT IS NOT `scrollTop`.
 *
 * A per-frame `scrollTop` series cannot separate the stutter from ordinary
 * scrolling: smooth scrolling also moves it every frame. What separates them
 * is NET TRAVEL over a fixed window against a CONTROL WINDOW of the same
 * length taken mid-band, where no boolean flipped. A reader supplying a
 * continuous gesture covers ground; a pinned reader supplies the same input
 * and covers none.
 *
 * I ORIGINALLY REACHED FOR SIGN REVERSALS AND THEY ARE THE WRONG PRIMARY
 * STATISTIC. The pin writes back the distance it captured, so the position it
 * leaves is CONSTANT — the reader is frozen, not dragged. A frozen frame has
 * delta 0, and a series of 0s and -30s has |sum| == sum of |terms|, so a
 * reversal-ratio reads a pure freeze as perfectly healthy scrolling. Reversals
 * do show up in a real browser (see below) because wheel input lands on the
 * compositor asynchronously and the sampler does not always run on the same
 * side of the hold's own animation frame — but that makes reversal COUNT a
 * property of when you looked as much as of what happened. Net travel is not.
 * Both are recorded; only net travel is asserted on.
 *
 * ── MEASURED ON A REAL BROWSER, NOT ONLY HERE ────────────────────────────────
 *
 * Headless Chrome driving real `mouseWheel` input at `origin/main` @ 09bfbce2,
 * against a 200-message seeded channel, sampling the live
 * `#chat-message-scroller` once per animation frame. Frames on which the
 * scroller's own geometry changed (history pagination prepending rows) are
 * excluded, because a prepend moves `scrollTop` without moving the reader.
 * Every window is 400ms — one REFLOW_HOLD_MS.
 *
 *   viewport   window                   frames  NET TRAVEL  reversals  ratio
 *   ──────────────────────────────────────────────────────────────────────────
 *   1440x900   FLIP away (dist>150)        24       -30 px  11 (45.8%)  0.043
 *   1440x900   FLIP deep (dist>1800)       18       -12 px   8 (44.4%)  0.024
 *   1440x900   CONTROL mid-band #1         23      -570 px   0 ( 0.0%)  1.000
 *   1440x900   CONTROL mid-band #2         24      -690 px   0 ( 0.0%)  1.000
 *   1440x900   CONTROL mid-band #3         24      -570 px   0 ( 0.0%)  1.000
 *   390x844    FLIP away (dist>150)        25       -60 px  11 (44.0%)  0.083
 *   390x844    FLIP deep (dist>1800)       23       -30 px  11 (47.8%)  0.043
 *   390x844    CONTROL mid-band #1         24      -600 px   0 ( 0.0%)  1.000
 *   390x844    CONTROL mid-band #2         24      -570 px   0 ( 0.0%)  1.000
 *   390x844    CONTROL mid-band #3         23      -540 px   0 ( 0.0%)  1.000
 *
 * Three things in that table are load-bearing.
 *
 * FIRST, THE SEPARATION IS AN ORDER OF MAGNITUDE AND THE CONTROLS ARE CLEAN.
 * A flip window delivers 12-60px of travel for the same 400ms of gesture that
 * carries the reader 540-690px mid-band. The controls show ZERO reversals
 * across 71 clean frames per viewport — the reversals are not a property of
 * the gesture, they exist only inside the window after a flip. Had the control
 * shown the same profile the diagnosis would have been refuted; it does not.
 *
 * SECOND, THE PROFILE IS WIDTH-INDEPENDENT, and that is what identifies the
 * cause. A layout-driven stutter would differ between a 390px viewport (where
 * the jump-to-latest control is a zero-height overlay and its appearance
 * changes no geometry at all) and a 1440px one (where the control is an
 * in-flow flex sibling and does change `clientHeight`). It does not differ.
 * The cause is the unconditional `holdAnchorThroughReflow()` call, which runs
 * identically at both widths.
 *
 * THAT SECOND POINT FALSIFIES A COMMENT IN THE HOOK. `_reportDistance` says
 * the hold "is a no-op on mobile (the pin re-writes the distance it just
 * read)". It is a no-op for ABSORBING A REFLOW, which is what that sentence
 * was reasoning about. It is emphatically not a no-op for a reader who is
 * MOVING: re-writing the distance it just read is precisely what pins a
 * scrolling reader in place. The measured mobile numbers are as bad as the
 * desktop ones, and the mobile `away` window is the worst reversal count in
 * the table.
 *
 * Raw per-frame captures and the CDP driver that produced them live in
 * `priv/measurements/01a0419a-scroll-stutter/`.
 */

const NEAR_BOTTOM_PX = 150;
const DEEP_HISTORY_PX = 1800;
const REFLOW_HOLD_MS = 400;
const FRAME_MS = 16;
// One wheel notch per frame, upward. Sign is what matters, not the size.
const WHEEL_PX = 30;
// One REFLOW_HOLD_MS is 25 frames at 16ms. Every window measured below is
// exactly that long, so a flip window and a control window are the same size
// and their net travel is directly comparable.
const HOLD_FRAMES = Math.ceil(REFLOW_HOLD_MS / FRAME_MS);
// What the gesture would deliver over one window with nothing in its way.
const FREE_TRAVEL = WHEEL_PX * (HOLD_FRAMES - 1);

function fakeScroller({ scrollHeight = 12000, clientHeight = 600 } = {}) {
  return {
    dataset: { spaceId: "space-fixture-stutter" },
    scrollHeight,
    clientHeight,
    _scrollTop: 0,
    get scrollTop() {
      return this._scrollTop;
    },
    set scrollTop(v) {
      this._scrollTop = Math.max(
        0,
        Math.min(v, this.scrollHeight - this.clientHeight),
      );
    },
    closest: () => null,
    listeners: [],
    addEventListener(type, fn) {
      this.listeners.push({ type, fn });
    },
    removeEventListener(type, fn) {
      this.listeners = this.listeners.filter(
        (l) => !(l.type === type && l.fn === fn),
      );
    },
    fire(type) {
      this.listeners.filter((l) => l.type === type).forEach((l) => l.fn());
    },
    querySelectorAll: () => [],
    querySelector: () => null,
  };
}

/**
 * A hook past its initial-snap phase, parked `distance` px from the bottom,
 * with the two booleans already reported once — so the very next report is an
 * EDGE, which is the only kind that calls the hold.
 */
function readerAt(distance, opts) {
  const el = fakeScroller(opts);
  const hook = Object.create(ScrollToBottom);
  hook.el = el;
  hook.handleEvent = vi.fn();
  hook.pushEvent = vi.fn();
  hook.mounted();
  // Drain the frame `mounted()` queues for its own first snap BEFORE parking
  // the reader. Left pending it fires inside the first gesture frame and
  // hard-snaps the scroller to the bottom, which silently relocates the
  // fixture out of the band under test.
  opts.drain();
  hook._initialScroll = false;
  hook._clearSettleTimers();
  hook._disconnectResizeObserver();
  el.scrollTop = el.scrollHeight - el.clientHeight - distance;
  // Seed the edge-trigger state from where the reader actually is, so the
  // first report of the gesture is a genuine transition and not a first-report
  // (which `_reportDistance` deliberately does not hold through).
  hook._lastAway = distance > NEAR_BOTTOM_PX;
  hook._lastDeep = distance > DEEP_HISTORY_PX;
  hook.pushEvent.mockClear();
  return { el, hook };
}

/**
 * Drive one continuous upward gesture and sample the position once per frame,
 * AFTER every callback that frame has run — which is what the reader's eye
 * sees, and which is where the hold's write lands.
 */
function gesture(el, frames, clock) {
  const samples = [];
  for (let i = 0; i < frames; i++) {
    // The compositor moves the scroller, then notifies.
    el.scrollTop = el.scrollTop - WHEEL_PX;
    el.fire("scroll");
    clock.advance(FRAME_MS);
    samples.push(el.scrollTop);
  }
  const deltas = samples.slice(1).map((v, i) => v - samples[i]);
  const gross = deltas.reduce((a, d) => a + Math.abs(d), 0);
  const net = deltas.reduce((a, d) => a + d, 0);
  return {
    samples,
    deltas,
    frames: deltas.length,
    // A reversal is a frame whose delta opposes the gesture. The gesture is
    // upward, so every honest delta is negative.
    reversals: deltas.filter((d) => d > 0).length,
    // The reader supplied input on every frame; these are the frames on which
    // none of it reached the screen — pinned back, or pinned still.
    nonAdvancing: deltas.filter((d) => d >= 0).length,
    grossTravel: gross,
    netTravel: net,
    // Recorded, not asserted on: a pure freeze is invisible to it. See the
    // header. Kept because it is what separates the two states in a real
    // browser, where the sampler and the hold interleave.
    progressRatio: gross === 0 ? 0 : Math.abs(net) / gross,
  };
}

describe("ScrollToBottom — a threshold crossing no longer pins a scrolling reader", () => {
  let priorMO, priorRO, priorRAF, priorCAF, priorNow, clock, drain;

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

    // A frame clock we drive by hand. `holdAnchorThroughReflow` compares
    // `performance.now()` against a deadline, so a real clock would make the
    // hold's LENGTH depend on how fast the test machine is — the load
    // sensitivity that makes a timing assertion a flake.
    priorNow = globalThis.performance.now;
    let t = 0;
    let queue = [];
    let nextId = 1;
    drain = () => {
      for (let i = 0; i < 5; i++) {
        const due = queue;
        queue = [];
        due.forEach(({ cb }) => cb());
      }
    };
    clock = {
      advance(ms) {
        t += ms;
        const due = queue;
        queue = [];
        due.forEach(({ cb }) => cb());
      },
      now: () => t,
    };
    globalThis.performance.now = clock.now;
    priorRAF = globalThis.requestAnimationFrame;
    priorCAF = globalThis.cancelAnimationFrame;
    globalThis.requestAnimationFrame = (cb) => {
      const id = nextId++;
      queue.push({ id, cb });
      return id;
    };
    globalThis.cancelAnimationFrame = (id) => {
      queue = queue.filter((q) => q.id !== id);
    };
  });

  afterEach(() => {
    globalThis.MutationObserver = priorMO;
    globalThis.ResizeObserver = priorRO;
    globalThis.requestAnimationFrame = priorRAF;
    globalThis.cancelAnimationFrame = priorCAF;
    globalThis.performance.now = priorNow;
  });

  it("CONTROL: a window that crosses no threshold delivers the whole gesture", () => {
    // Mid-band, far from both boundaries, and the window is far too short to
    // reach either. Nothing flips, so nothing holds. This is the number every
    // assertion below is measured against; without it "the reader barely
    // moved" says nothing about the hold.
    const { el } = readerAt(900, { drain });
    const run = gesture(el, HOLD_FRAMES, clock);

    expect(run.netTravel).toBe(-FREE_TRAVEL);
    expect(run.nonAdvancing).toBe(0);
    expect(run.reversals).toBe(0);
  });

  it("CURED: crossing NEAR_BOTTOM_PX now delivers the gesture in full", () => {
    // Was "describes the pre-fix stutter". Stage 3 dropped the
    // `_reportDistance` -> `holdAnchorThroughReflow()` call, so crossing a
    // threshold no longer pins a moving reader. Parked just below the near
    // boundary; the gesture crosses it.
    const { el, hook } = readerAt(NEAR_BOTTOM_PX - WHEEL_PX, { drain });
    const run = gesture(el, HOLD_FRAMES, clock);

    // The CONTROL's numbers, exactly — same gesture, same window length. The
    // pre-fix tree gave |netTravel| <= 60 here against the control's 690.
    expect(run.netTravel).toBe(-FREE_TRAVEL);
    expect(run.nonAdvancing).toBe(0);
    expect(run.reversals).toBe(0);

    // ANTI-VACUITY: the edge really was crossed. Without this, a fixture that
    // silently relocated out of the band would produce the same clean numbers
    // and the test would pass for the wrong reason.
    expect(hook.pushEvent).toHaveBeenCalledWith("jump_to_latest_distance", {
      away: true,
      deep: false,
    });
  });

  it("CURED: crossing DEEP_HISTORY_PX now delivers the gesture in full", () => {
    const { el, hook } = readerAt(DEEP_HISTORY_PX - WHEEL_PX, { drain });
    const run = gesture(el, HOLD_FRAMES, clock);

    expect(run.netTravel).toBe(-FREE_TRAVEL);
    expect(run.nonAdvancing).toBe(0);
    expect(run.reversals).toBe(0);
    expect(hook.pushEvent).toHaveBeenCalledWith("jump_to_latest_distance", {
      away: true,
      deep: true,
    });
  });

  it("POSITIVE CONTROL: the harness can still see a pin, so the zeroes above are not vacuous", () => {
    // Every assertion above is "the reader was NOT pinned". A harness that had
    // stopped being able to observe a pin at all — a broken clock, a drained
    // frame queue, a fixture outside the band — would satisfy all of them.
    // This drives the pin DIRECTLY, by the one caller that survives stage 3
    // (`sidebar_collapsed_changed` -> `holdAnchorThroughReflow`), and asserts
    // the harness still reports the pre-fix profile for it.
    //
    // It is therefore two proofs in one: the instrument works, AND the method
    // is still live and still does its job for the rail-collapse reflow it was
    // written for in task 019f51d1.
    const { el, hook } = readerAt(900, { drain });
    hook.holdAnchorThroughReflow();
    const run = gesture(el, HOLD_FRAMES, clock);

    expect(Math.abs(run.netTravel)).toBeLessThanOrEqual(WHEEL_PX * 2);
    expect(run.nonAdvancing).toBeGreaterThan(run.frames * 0.3);
  });

  it("the pin still releases after REFLOW_HOLD_MS", () => {
    // The hold remains BOUNDED for its surviving caller: a rail collapse
    // costs the reader 400ms of anchoring, not a permanent freeze.
    const { el, hook } = readerAt(900, { drain });
    hook.holdAnchorThroughReflow();
    gesture(el, HOLD_FRAMES + 2, clock);
    const after = gesture(el, HOLD_FRAMES, clock);

    expect(after.netTravel).toBe(-FREE_TRAVEL);
    expect(after.nonAdvancing).toBe(0);
  });

  it("CURED: width-independent — the 390px case is clean too", () => {
    // The mobile window was the WORST in stage 2's table (-60px against a
    // -600px control) precisely because there was no reflow there to justify
    // the pin. `clientHeight` is held fixed for the whole gesture.
    const short = readerAt(NEAR_BOTTOM_PX - WHEEL_PX, {
      clientHeight: 844,
      drain,
    });
    const before = short.el.clientHeight;
    const run = gesture(short.el, HOLD_FRAMES, clock);

    expect(short.el.clientHeight).toBe(before);
    expect(run.netTravel).toBe(-FREE_TRAVEL);
    expect(run.nonAdvancing).toBe(0);
    expect(short.hook.pushEvent).toHaveBeenCalledWith(
      "jump_to_latest_distance",
      { away: true, deep: false },
    );
  });
});
