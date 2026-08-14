import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import ScrollToBottom from "../../js/hooks/scroll_to_bottom.js"

/**
 * Tests for the `ScrollToBottom` hook's deep-link anchor branch
 * (task 019fabe8 stage 3).
 *
 * Background: `scrollToBottom()` hard-snaps `scrollTop = scrollHeight`
 * on mount and again on EVERY MutationObserver fire while
 * `_initialScroll` is true, and that phase only ends once the container
 * actually overflows. Stream batches land async after mount, so an
 * anchored window (stages 1 + 2) gets yanked to the bottom repeatedly —
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
  const classes = new Set()
  return {
    dataset: { messageId, participantId },
    style: {},
    // `applyGrouping` marks continuation rows with a class and lets
    // app.css own the collapsed geometry, so the shim needs a real
    // `classList.toggle`. Only the two-argument form is used.
    classList: {
      toggle(name, force) {
        if (force) classes.add(name)
        else classes.delete(name)
        return Boolean(force)
      },
      contains: (name) => classes.has(name),
    },
    scrollIntoViewCalls: [],
    scrollIntoView(opts) {
      this.scrollIntoViewCalls.push(opts)
    },
    querySelector() {
      return null
    },
  }
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
} = {}) {
  const el = {
    dataset: {},
    rows,
    scrollHeight,
    clientHeight,
    _scrollTop: scrollTop,
    scrollTopWrites: [],
    get scrollTop() {
      return this._scrollTop
    },
    set scrollTop(v) {
      this._scrollTop = v
      this.scrollTopWrites.push(v)
    },
    closest() {
      return null
    },
    querySelectorAll(sel) {
      if (sel === "[data-participant-id]") {
        return this.rows.filter((r) => r.dataset.participantId)
      }
      return []
    },
    querySelector(sel) {
      const match = /^\[data-message-id="(.+)"\]$/.exec(sel)
      if (!match) return null
      return this.rows.find((r) => r.dataset.messageId === match[1]) || null
    },
  }
  if (anchorId) el.dataset.anchorMessageId = anchorId
  return el
}

function buildHook(el) {
  const hook = Object.create(ScrollToBottom)
  hook.el = el
  hook.handleEvent = vi.fn()
  return hook
}

function anchoredRows(el) {
  return el.rows.flatMap((r) => r.scrollIntoViewCalls)
}

// `applyGrouping` marks continuations AND run boundaries; these read the two
// class flags back off the rows in list order.
function groupings(el) {
  return el.rows.map((r) => r.classList.contains("message-row--grouped"))
}

function runEnds(el) {
  return el.rows.map((r) => r.classList.contains("message-row--run-end"))
}

// ── Tests ──────────────────────────────────────────────────────────────

describe("ScrollToBottom — deep-link anchor holds the arrival position", () => {
  let priorMO, priorRO, priorRAF

  beforeEach(() => {
    priorMO = globalThis.MutationObserver
    globalThis.MutationObserver = class {
      constructor(cb) {
        this.cb = cb
      }
      observe() {}
      disconnect() {}
    }

    // Polyfill ResizeObserver for node test env (task 019ff6c9)
    priorRO = globalThis.ResizeObserver
    globalThis.ResizeObserver = class {
      constructor(cb) {
        this.cb = cb
      }
      observe() {}
      disconnect() {}
    }

    // Polyfill requestAnimationFrame / cancelAnimationFrame
    priorRAF = globalThis.requestAnimationFrame
    globalThis.requestAnimationFrame = (cb) => setTimeout(cb, 0)
    globalThis.cancelAnimationFrame = (id) => clearTimeout(id)
  })

  afterEach(() => {
    globalThis.MutationObserver = priorMO
    if (priorRO !== undefined) globalThis.ResizeObserver = priorRO
    else delete globalThis.ResizeObserver
    if (priorRAF !== undefined) globalThis.requestAnimationFrame = priorRAF
    else delete globalThis.requestAnimationFrame
  })

  it("BASELINE: with no anchor attribute, mount hard-snaps to the bottom", () => {
    const el = fakeList({ rows: [fakeRow("m-1"), fakeRow("m-2")] })
    const hook = buildHook(el)

    hook.mounted()

    // This is the untouched behaviour every other test is measured
    // against. If this ever stops snapping, the "anchor suppressed the
    // snap" assertions below become vacuous.
    expect(el.scrollTopWrites).toEqual([4000])
    expect(hook._initialScroll).toBe(false)
    expect(anchoredRows(el)).toEqual([])
  })

  it("honours the anchor instead of the initial snap", () => {
    const target = fakeRow("m-42")
    const el = fakeList({
      rows: [fakeRow("m-40"), target, fakeRow("m-44")],
      anchorId: "m-42",
    })
    const hook = buildHook(el)

    hook.mounted()

    // Negative: the bottom snap did not fire.
    expect(el.scrollTopWrites).toEqual([])
    // Positive control in the same test: the anchored scroll DID fire,
    // centred, on the right row. A hook that simply never ran would
    // fail here.
    expect(target.scrollIntoViewCalls).toEqual([{ block: "center" }])
    // The initial-snap phase is over, so later stream batches take the
    // ordinary near-bottom path rather than re-snapping.
    expect(hook._initialScroll).toBe(false)
  })

  it("keeps holding the anchor across the async stream batches that follow mount", () => {
    const target = fakeRow("m-42")
    const el = fakeList({ rows: [target], anchorId: "m-42" })
    const hook = buildHook(el)

    hook.mounted()
    expect(target.scrollIntoViewCalls).toHaveLength(1)

    // Stream batches land after mount and mutate childList; each one
    // used to get an unconditional yank to the bottom.
    el.rows.push(fakeRow("m-43"), fakeRow("m-44"))
    el.scrollHeight = 6000
    hook.updated()
    el.rows.push(fakeRow("m-45"))
    el.scrollHeight = 7000
    hook.updated()

    expect(el.scrollTopWrites).toEqual([])
    // Honoured exactly once for that id — no repeated re-centring that
    // would fight a reader who has started scrolling.
    expect(target.scrollIntoViewCalls).toHaveLength(1)
  })

  it("re-anchors when the attribute changes to a new id", () => {
    const first = fakeRow("m-1")
    const second = fakeRow("m-2")
    const el = fakeList({ rows: [first, second], anchorId: "m-1" })
    const hook = buildHook(el)

    hook.mounted()
    expect(first.scrollIntoViewCalls).toHaveLength(1)
    expect(second.scrollIntoViewCalls).toHaveLength(0)

    // A second deep-link arrival in the same LiveView session patches
    // the attribute; the once-per-id guard must not swallow it.
    el.dataset.anchorMessageId = "m-2"
    hook.updated()

    expect(second.scrollIntoViewCalls).toEqual([{ block: "center" }])
    expect(first.scrollIntoViewCalls).toHaveLength(1)
    expect(el.scrollTopWrites).toEqual([])
  })

  it("falls back to the bottom snap when the anchor row is not in the DOM yet, then anchors once it arrives", () => {
    const el = fakeList({ rows: [fakeRow("m-1")], anchorId: "m-99" })
    const hook = buildHook(el)

    hook.mounted()

    // Byte-identical to the no-attribute baseline: an anchor we cannot
    // resolve must never leave the reader mid-nowhere.
    expect(el.scrollTopWrites).toEqual([4000])
    expect(anchoredRows(el)).toEqual([])

    // Positive control that the fallback is not permanent: when the
    // target row lands in a later stream batch the hook still anchors.
    const late = fakeRow("m-99")
    el.rows.push(late)
    hook.updated()

    expect(late.scrollIntoViewCalls).toEqual([{ block: "center" }])
    expect(el.scrollTopWrites).toEqual([4000])
  })

  it("resumes the ordinary near-bottom rule after the anchor is honoured", () => {
    const target = fakeRow("m-42")
    const el = fakeList({ rows: [target], anchorId: "m-42" })
    const hook = buildHook(el)

    hook.mounted()
    expect(target.scrollIntoViewCalls).toHaveLength(1)
    expect(el.scrollTopWrites).toEqual([])

    // Reader is parked mid-history (distance from bottom 3400px): a new
    // message must NOT yank them down.
    el._scrollTop = 0
    hook.updated()
    expect(el.scrollTopWrites).toEqual([])

    // Positive control for the same rule: once the reader scrolls back
    // down to within NEAR_BOTTOM_PX, live tailing resumes exactly as it
    // does on a normal entry. Without this the previous assertion would
    // also pass on a hook that had stopped scrolling entirely.
    el._scrollTop = 3350 // 4000 - 600 - 3350 = 50px from the bottom
    hook.updated()
    expect(el.scrollTopWrites).toEqual([4000])
  })

  it("leaves message grouping untouched on the anchored path", () => {
    const grouped = fakeRow("m-2", "p-1")
    const el = fakeList({
      rows: [fakeRow("m-1", "p-1"), grouped, fakeRow("m-3", "p-2")],
      anchorId: "m-2",
    })
    const hook = buildHook(el)

    hook.mounted()

    // `applyGrouping` runs before `scrollToBottom` in `_safeUpdate`;
    // returning early from the anchor branch must not skip it.
    expect(grouped.classList.contains("message-row--grouped")).toBe(true)
    // …and the row after it opens a new author group, so it stays ungrouped.
    expect(el.rows[2].classList.contains("message-row--grouped")).toBe(false)

    // Run boundaries ride the same pass, so they must survive the anchored
    // path too. m-2 closes p-1's run (m-3 switches author) and m-3 is last in
    // the container, so both end runs; m-1 is mid-run and does not.
    expect(runEnds(el)).toEqual([false, true, true])
  })

  it("marks the last row of each author run, on the ordinary snap path", () => {
    const el = fakeList({
      rows: [
        fakeRow("m-1", "p-1"),
        fakeRow("m-2", "p-1"),
        fakeRow("m-3", "p-1"),
        fakeRow("m-4", "p-2"),
        fakeRow("m-5", "p-1"),
      ],
    })
    const hook = buildHook(el)

    hook.mounted()

    // Only the LAST row of each run is a boundary. The two middles of the
    // opening three-row run are the rows a "mark everything" implementation
    // would get wrong.
    expect(runEnds(el)).toEqual([false, false, true, true, true])
    // m-4 and m-5 are single-message runs: no `--grouped`, but still a
    // run end each, which is what keeps them fully rounded.
    expect(groupings(el)).toEqual([false, true, true, false, false])
  })

  it("clears a stale run-end once a later row joins the run", () => {
    // The re-render case: `toggle` must UNmark a row that has stopped being
    // the end of its run, exactly as it already does for `--grouped`.
    const first = fakeRow("m-1", "p-1")
    const second = fakeRow("m-2", "p-2")
    const el = fakeList({ rows: [first, second] })
    const hook = buildHook(el)

    hook.mounted()
    expect(runEnds(el)).toEqual([true, true])

    // Server re-renders m-2 under the same author, merging the two runs.
    second.dataset.participantId = "p-1"
    hook.updated()

    expect(runEnds(el)).toEqual([false, true])
    expect(groupings(el)).toEqual([false, true])
  })

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
    })
    const hook = buildHook(el)

    hook.mounted()

    // Positive control: grouping really did run on these rows, so the
    // "no inline style" assertion below is a statement about a hook that
    // did its job rather than one that never executed.
    expect(groupings(el)).toEqual([false, true, true, false])

    for (const row of el.rows) {
      expect(
        Object.keys(row.style),
        `applyGrouping wrote inline style ${JSON.stringify(row.style)} on ` +
          `${row.dataset.messageId}. Row geometry belongs in app.css — an ` +
          `inline style can only hide something, never reclaim its space.`,
      ).toEqual([])
    }
  })
})
