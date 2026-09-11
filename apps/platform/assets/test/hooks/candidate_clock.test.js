import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import CandidateClock, { SheetHandleClock } from "../../js/hooks/candidate_clock.js"

/**
 * Tests for the `CandidateClock` hook (task 01a03f4e-78b1, retimed by
 * 01a0740e-5f37).
 *
 * Two defects are pinned here, and they are different claims.
 *
 * The ORIGINAL defect: the countdown number was computed on the server at
 * render time and then *did not move*. A card said "30" until the next
 * LiveView patch, whenever that happened to be. So "the element exists" and
 * "a number is rendered" are both worthless assertions — the rail this
 * replaced passed both. Every test below asserts that a number CHANGES, and
 * by how much, against a deadline the test chose.
 *
 * Stage 3 (01a0740e) then replaced the ring with a DRAIN and a threshold:
 * what the ticker paints is a number, a width, and one class that steps at
 * `data-warning-seconds`. The ring's dash-offset arithmetic is gone, and the
 * prose line that restated the same number went with it. The threshold tests
 * below are TWO-SIDED on purpose — "amber appears at 5" passes just as well
 * on a card that is amber at every value, which is the mutation named in the
 * stage notes.
 *
 * The defect the PREVIOUS stage fixed: the hook sat on each card, so every
 * armed candidate opened its own `setInterval`. Five armed cards was five
 * timers.
 * The load-bearing assertion for that is a COUNT of `setInterval` calls, and
 * it has to be a count. "All three numbers advanced" passes just as happily
 * on three per-card intervals as on one rail-level one, so it cannot be the
 * test for this change — it is a test of the design being replaced.
 *
 * The hook runs in vitest's default `node` env (no jsdom), so this builds a
 * minimal fake DOM. The fakes resolve `[data-role=...]` selectors literally
 * against the roles their nodes were built with rather than returning a
 * fixed node for any input — a fake that answered everything would let a
 * hook querying the wrong selector pass.
 */

// ── Fakes ────────────────────────────────────────────────────────────────

// A minimal `classList` that only knows `toggle`, `add` and `remove`,
// which is all the hook uses. Backed by a real Set so a class added twice
// is still one class and `has()` is a genuine reading rather than a
// substring match on a string somebody assembled.
//
// `add` and `remove` are here as well as `toggle` because they are not the
// same instrument: the re-arm snap must leave the class ALONE when the
// width it is painting has not changed, and `toggle(name, false)` cannot
// express "no opinion". A fake offering only `toggle` would make the
// distinction untestable, which is the same as not having made it.
function fakeClassList() {
  const set = new Set()
  return {
    set,
    toggle(name, on) {
      if (on) set.add(name)
      else set.delete(name)
    },
    add(name) {
      set.add(name)
    },
    remove(name) {
      set.delete(name)
    },
    contains(name) {
      return set.has(name)
    },
  }
}

function fakeNode(role, { withDataset = false } = {}) {
  return {
    role,
    textContent: "",
    attrs: {},
    style: {},
    classList: fakeClassList(),
    dataset: withDataset ? { remaining: "" } : {},
    setAttribute(name, value) {
      this.attrs[name] = value
    },
  }
}

// Resolves `[data-role='x'], [data-role='y']` against a node list by the
// role each node was built with. Deliberately literal: an unknown selector
// matches nothing, so a typo in the hook shows up as a dead assertion
// rather than as a passing test.
function rolesIn(selector) {
  return [...selector.matchAll(/data-role='([^']+)'/g)].map((m) => m[1])
}

// One SPENT ROW: what a stop leaves in the slot the card held (task
// 01a0740e stage 5). It carries a deadline and nothing else — no number
// to repaint and no width to move — so `hidden` is the only thing the
// ticker can do to it.
//
// `hidden` starts FALSE rather than undefined, so "it was hidden" is a
// transition this suite watched happen and not an initial value it read
// back.
function fakeSpentRow({ expiresAt } = {}) {
  const dataset = {}
  if (expiresAt !== null && expiresAt !== undefined) dataset.expiresAt = expiresAt

  return {
    role: "meeting-candidate-spent",
    dataset,
    hidden: false,
  }
}

function queryable(nodes) {
  return {
    querySelectorAll(selector) {
      const roles = rolesIn(selector)
      return nodes.filter((n) => roles.includes(n.role))
    },
    querySelector(selector) {
      const roles = rolesIn(selector)
      return nodes.find((n) => roles.includes(n.role)) || null
    },
  }
}

// One CARD: the `.candidate-foot` element the server stamps the deadline
// onto. It no longer carries a hook — it is inert markup that the rail's
// single ticker reads.
function fakeCard({ actsAt, totalSeconds = 30, warningSeconds = 5 } = {}) {
  const children = [
    fakeNode("meeting-candidate-remaining", { withDataset: true }),
    fakeNode("meeting-candidate-drain"),
  ]

  const dataset = { actsAt, totalSeconds: String(totalSeconds) }

  // `null`, NOT `undefined`: a destructuring default fires on `undefined`,
  // so `fakeCard({ warningSeconds: undefined })` would silently rebuild the
  // 5 and the "no threshold" test would be measuring the opposite case. It
  // means the server rendered NO threshold onto this card, which the hook
  // must leave unwarned rather than falling back to a constant of its own.
  if (warningSeconds !== null) {
    dataset.warningSeconds = String(warningSeconds)
  }

  return {
    role: "meeting-candidate-countdown",
    dataset,
    children,
    ...queryable(children),
    node(role) {
      return children.find((n) => n.role === role)
    },
  }
}

// The RAIL `<section>`, which is where the hook now lives. `cards` is
// mutable on purpose: adding to it mid-test is how a candidate arriving
// after mount is simulated, and the hook must pick it up because it
// re-queries rather than because anything told it to.
function fakeRail(cards = []) {
  // A real listener registry, keyed by type, so `removeEventListener`
  // has to be handed the SAME function reference to take a listener off
  // — which is the property `destroyed()` is being tested for. A stub
  // that just recorded calls would let a hook that rebinds an inline
  // arrow on every mount pass its own cleanup test.
  const listeners = new Map()

  const rail = {
    cards,
    listeners,
    addEventListener(type, fn) {
      if (!listeners.has(type)) listeners.set(type, new Set())
      listeners.get(type).add(fn)
    },
    removeEventListener(type, fn) {
      listeners.get(type)?.delete(fn)
    },
    // Not `dispatchEvent`: this fake carries no Event objects, and naming
    // it after the DOM method would invite a test to assume one.
    fire(type) {
      for (const fn of listeners.get(type) || []) fn()
    },
    ...queryable(cards),
  }

  // Rebind the closures to the live array, so `rail.cards.push(...)` is
  // visible to the next `querySelectorAll`.
  rail.querySelectorAll = (selector) => {
    const roles = rolesIn(selector)
    return rail.cards.filter((n) => roles.includes(n.role))
  }

  return rail
}

// A hook instance bound to a fake rail, with `pushEvent` spies so the
// "never polls the server" claim is checkable rather than asserted in a
// comment.
function mountHook(el) {
  const hook = Object.create(CandidateClock)
  hook.el = el
  hook.pushEvent = vi.fn()
  hook.pushEventTo = vi.fn()
  hook.mounted()
  return hook
}

function shownNumber(card) {
  return card.node("meeting-candidate-remaining").textContent
}

function drainWidth(card) {
  return card.node("meeting-candidate-drain").style.width
}

function countWarned(card) {
  return card
    .node("meeting-candidate-remaining")
    .classList.contains("candidate-count--warning")
}

function drainWarned(card) {
  return card
    .node("meeting-candidate-drain")
    .classList.contains("candidate-drain--warning")
}

// Is the drain's width easing SUPPRESSED for this paint? `.candidate-drain`
// transitions `width` over 0.9s and `.candidate-drain--snap` turns that off,
// so this reads "the bar will jump to its new width" and its absence reads
// "the bar will ease to its new width".
function drainSnapped(card) {
  return card.node("meeting-candidate-drain").classList.contains("candidate-drain--snap")
}

// The BOTTOM-SHEET HANDLE (task 01a07410 stage 2). Built with the same
// child roles as a card, deliberately: the handle is painted by the SAME
// `_paint`, so it reports the same number the card does by construction
// rather than by two implementations agreeing.
//
// Built WITHOUT a drain child by default, which is the shape the handle
// actually has — `_paint` must still write the number before it gives up
// on the width.
//
// `withDrain` exists for exactly one case: `call_rail_frame.ex` renders the
// handle's `.sheet-handle__fill` with `data-role="meeting-candidate-drain"`,
// so when the Canvas tab is open that ONE node is painted by two hooks off
// two unsynchronised intervals. That is the only place in the tree where a
// drain is painted twice per second, and it is where the snap class can be
// taken back off by the second painter.
function fakeHandle({
  actsAt,
  totalSeconds = 30,
  warningSeconds = 5,
  withDrain = false,
} = {}) {
  const children = [fakeNode("meeting-candidate-remaining", { withDataset: true })]
  if (withDrain) children.push(fakeNode("meeting-candidate-drain"))

  const dataset = { actsAt, totalSeconds: String(totalSeconds) }
  if (warningSeconds !== null) dataset.warningSeconds = String(warningSeconds)

  return {
    role: "meeting-sheet-handle-countdown",
    dataset,
    children,
    ...queryable(children),
    node(role) {
      return children.find((n) => n.role === role)
    },
  }
}

// A rail that knows about nodes OUTSIDE itself. The handle is not a
// descendant of the rail `<section>` — it is the sheet's grab bar, and
// below `lg` the rail is inside a drawer translated off screen — so a
// fake whose handle sat in `rail.cards` would be testing a DOM that
// cannot exist and would pass on a hook that never widened its root.
function fakeRailWithDocument(cards, outside) {
  const rail = fakeRail(cards)
  rail.ownerDocument = queryable(outside)
  return rail
}

// ── Suite ────────────────────────────────────────────────────────────────

describe("CandidateClock", () => {
  const T0 = new Date("2026-08-29T12:00:00.000Z").getTime()

  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(T0)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  // ── The property this stage exists to create ──────────────────────────

  describe("one ticker for the whole rail", () => {
    it("opens EXACTLY ONE interval for a rail of three armed cards", () => {
      const spy = vi.spyOn(globalThis, "setInterval")

      const cards = [
        fakeCard({ actsAt: new Date(T0 + 30_000).toISOString() }),
        fakeCard({ actsAt: new Date(T0 + 20_000).toISOString() }),
        fakeCard({ actsAt: new Date(T0 + 10_000).toISOString() }),
      ]
      const hook = mountHook(fakeRail(cards))

      // THE assertion. Counted, not inferred: three per-card intervals
      // would advance three numbers just as well, so any check phrased as
      // "the numbers move" passes on the design this replaces. Mutation
      // check — mount one hook per card instead of one per rail — takes
      // this to 3 and the suite red.
      expect(spy).toHaveBeenCalledTimes(1)

      // Positive control on the fixture itself. If the rail were empty, or
      // the cards unarmed, "one interval" would be true for the wrong
      // reason and this whole describe block would be measuring nothing.
      expect(cards).toHaveLength(3)
      expect(cards.every((c) => shownNumber(c) !== "")).toBe(true)

      hook.destroyed()
      spy.mockRestore()
    })

    it("drives ALL THREE cards from that one interval, each on its own deadline", () => {
      const near = fakeCard({ actsAt: new Date(T0 + 5_000).toISOString() })
      const mid = fakeCard({ actsAt: new Date(T0 + 15_000).toISOString() })
      const far = fakeCard({ actsAt: new Date(T0 + 25_000).toISOString() })
      const hook = mountHook(fakeRail([near, mid, far]))

      // The anti-vacuity trio. One shared interval must not become one
      // shared COUNTDOWN: a ticker that cached a deadline on the hook, or
      // decremented a single number, would show the same value on all
      // three and pass "the numbers moved".
      expect([shownNumber(near), shownNumber(mid), shownNumber(far)]).toEqual([
        "5",
        "15",
        "25",
      ])

      vi.advanceTimersByTime(3000)
      expect([shownNumber(near), shownNumber(mid), shownNumber(far)]).toEqual([
        "2",
        "12",
        "22",
      ])

      // Each card's DRAIN moves with its own number, and the three
      // widths differ. This is the ladder the rail exists to show — one
      // shared width across three cards would satisfy "the bar moved".
      expect([drainWidth(near), drainWidth(mid), drainWidth(far)]).toEqual([
        "6.67%",
        "40.00%",
        "73.33%",
      ])

      hook.destroyed()
    })

    it("still opens exactly one interval for a rail of ten armed cards", () => {
      const spy = vi.spyOn(globalThis, "setInterval")

      const cards = Array.from({ length: 10 }, (_, i) =>
        fakeCard({ actsAt: new Date(T0 + (i + 1) * 1000).toISOString() })
      )
      const hook = mountHook(fakeRail(cards))

      // The cost is flat in the card count. Under the per-card hook this
      // number tracked the fixture size, which is the defect.
      expect(spy).toHaveBeenCalledTimes(1)

      hook.destroyed()
      spy.mockRestore()
    })

    it("picks up a card that ARRIVES after mount, with no new interval", () => {
      const spy = vi.spyOn(globalThis, "setInterval")

      const first = fakeCard({ actsAt: new Date(T0 + 30_000).toISOString() })
      const rail = fakeRail([first])
      const hook = mountHook(rail)

      // A candidate is opened mid-meeting and LiveView patches it in.
      const late = fakeCard({ actsAt: new Date(T0 + 12_000).toISOString() })
      rail.cards.push(late)

      vi.advanceTimersByTime(2000)

      // Driven from the SAME interval, on its own deadline. This is what
      // re-querying every tick buys: no mounted/destroyed bookkeeping, and
      // no second timer.
      expect(shownNumber(late)).toBe("10")
      expect(shownNumber(first)).toBe("28")
      expect(spy).toHaveBeenCalledTimes(1)

      hook.destroyed()
      spy.mockRestore()
    })

    it("keeps ticking the survivors after a card LEAVES the rail", () => {
      const staying = fakeCard({ actsAt: new Date(T0 + 30_000).toISOString() })
      const leaving = fakeCard({ actsAt: new Date(T0 + 30_000).toISOString() })
      const rail = fakeRail([staying, leaving])
      const hook = mountHook(rail)

      vi.advanceTimersByTime(2000)
      expect(shownNumber(leaving)).toBe("28")

      // The candidate was stopped and the rail re-rendered without it.
      rail.cards = [staying]
      vi.advanceTimersByTime(3000)

      // The detached node is frozen where it was — nothing holds a
      // reference to it — and the rail's own card is still counting.
      expect(shownNumber(leaving)).toBe("28")
      expect(shownNumber(staying)).toBe("25")

      hook.destroyed()
    })

    it("does not open a second interval when the rail is patched", () => {
      const spy = vi.spyOn(globalThis, "setInterval")

      const card = fakeCard({ actsAt: new Date(T0 + 30_000).toISOString() })
      const hook = mountHook(fakeRail([card]))

      // LiveView patches the rail repeatedly over a meeting — every new
      // card, every stage change, every closed-card toggle. An `updated()`
      // that restarted the timer would make "one interval" a claim about
      // how often the server patches rather than about this hook.
      hook.updated()
      hook.updated()
      hook.updated()

      expect(spy).toHaveBeenCalledTimes(1)

      hook.destroyed()
      spy.mockRestore()
    })
  })

  // ── Properties the per-card hook had, which must survive the move ─────

  describe("the number is a rendering of the server's deadline", () => {
    it("ticks down once a second — the original defect", () => {
      const card = fakeCard({ actsAt: new Date(T0 + 30_000).toISOString() })
      const hook = mountHook(fakeRail([card]))

      // The value at mount, before any time passes.
      expect(shownNumber(card)).toBe("30")

      vi.advanceTimersByTime(3000)
      expect(shownNumber(card)).toBe("27")

      vi.advanceTimersByTime(7000)
      expect(shownNumber(card)).toBe("20")

      hook.destroyed()
    })

    it("drains the BAR in step with the number, agreeing with the server at both ends", () => {
      const card = fakeCard({ actsAt: new Date(T0 + 30_000).toISOString() })
      const hook = mountHook(fakeRail([card]))

      // Full width at t=total: nothing drained.
      expect(drainWidth(card)).toBe("100.00%")

      // Half at half time — the assertion that catches a bar wired to the
      // wrong end of the fraction, which would look entirely plausible and
      // GROW as the card ran out.
      vi.advanceTimersByTime(15_000)
      expect(drainWidth(card)).toBe("50.00%")

      // Nothing left at zero.
      vi.advanceTimersByTime(15_000)
      expect(drainWidth(card)).toBe("0.00%")

      hook.destroyed()
    })

    it("reads each card's OWN total, not one cached on the ticker", () => {
      const long = fakeCard({
        actsAt: new Date(T0 + 30_000).toISOString(),
        totalSeconds: 30,
      })
      const short = fakeCard({
        actsAt: new Date(T0 + 30_000).toISOString(),
        totalSeconds: 60,
      })
      const hook = mountHook(fakeRail([long, short]))

      vi.advanceTimersByTime(15_000)

      // Same remaining, different bars. A ticker that read the scale once
      // at mount would paint the first card's width onto both.
      expect(drainWidth(long)).toBe("50.00%")
      expect(drainWidth(short)).toBe("25.00%")

      hook.destroyed()
    })

    it("floors at zero rather than counting into negative seconds", () => {
      const card = fakeCard({ actsAt: new Date(T0 + 2_000).toISOString() })
      const hook = mountHook(fakeRail([card]))

      vi.advanceTimersByTime(10_000)
      expect(shownNumber(card)).toBe("0")

      // Still zero a further minute on. Under the per-card hook the timer
      // stopped itself at zero; the rail's ticker keeps running for the
      // other cards, so the floor is now the ONLY thing standing between a
      // fired-but-unswept card and a participant seeing "-58".
      vi.advanceTimersByTime(60_000)
      expect(shownNumber(card)).toBe("0")

      hook.destroyed()
    })

    it("renders 0, not a negative, for a card already overdue at mount", () => {
      // A card whose `acts_at` has passed — rendered by the server in the
      // window before the sweeper claims it — arrives overdue. Without the
      // floor that participant is shown "-5".
      const card = fakeCard({ actsAt: new Date(T0 - 5_000).toISOString() })
      const hook = mountHook(fakeRail([card]))

      expect(shownNumber(card)).toBe("0")

      hook.destroyed()
    })

    it("a card at zero does not stop the cards beside it", () => {
      const expired = fakeCard({ actsAt: new Date(T0 + 1_000).toISOString() })
      const live = fakeCard({ actsAt: new Date(T0 + 30_000).toISOString() })
      const hook = mountHook(fakeRail([expired, live]))

      vi.advanceTimersByTime(5000)
      expect(shownNumber(expired)).toBe("0")

      // The regression a shared interval makes possible: one card reaching
      // zero must not clear the timer every other card is riding on.
      vi.advanceTimersByTime(5000)
      expect(shownNumber(live)).toBe("20")

      hook.destroyed()
    })

    it("never asks the server for anything — not even at zero", () => {
      const card = fakeCard({ actsAt: new Date(T0 + 2_000).toISOString() })
      const hook = mountHook(fakeRail([card]))

      vi.advanceTimersByTime(30_000)

      // The countdown is a rendering of the server's `acts_at`; the sweeper
      // fires on its own and broadcasts. A push here — per card, per
      // second, per participant — is exactly what a client-side countdown
      // exists to avoid, and at zero it would give every browser its own
      // opinion about when a card fired.
      expect(hook.pushEvent).not.toHaveBeenCalled()
      expect(hook.pushEventTo).not.toHaveBeenCalled()

      hook.destroyed()
    })

    it("picks up a moved deadline instead of counting from the old one", () => {
      const card = fakeCard({ actsAt: new Date(T0 + 10_000).toISOString() })
      const hook = mountHook(fakeRail([card]))

      vi.advanceTimersByTime(5000)
      expect(shownNumber(card)).toBe("5")

      // The server extended the countdown and re-rendered the card.
      card.dataset.actsAt = new Date(T0 + 5000 + 30_000).toISOString()
      hook.updated()

      expect(shownNumber(card)).toBe("30")

      hook.destroyed()
    })

    it("stops ticking once destroyed", () => {
      const card = fakeCard({ actsAt: new Date(T0 + 30_000).toISOString() })
      const hook = mountHook(fakeRail([card]))

      vi.advanceTimersByTime(2000)
      expect(shownNumber(card)).toBe("28")

      hook.destroyed()
      vi.advanceTimersByTime(10_000)

      // Frozen at the last value. A leaked interval on a rail that has left
      // the DOM keeps the whole card list alive for the life of the tab.
      expect(shownNumber(card)).toBe("28")
    })

    it("leaves a card with no deadline alone rather than counting from now", () => {
      const disarmed = fakeCard({ actsAt: undefined })
      const armed = fakeCard({ actsAt: new Date(T0 + 30_000).toISOString() })
      const hook = mountHook(fakeRail([disarmed, armed]))

      vi.advanceTimersByTime(5000)

      // A stopped card has no `acts_at`. Defaulting to "now + total" is how
      // a stopped card would appear to still be counting down — and with
      // one shared ticker, the tempting bug is to hand it the neighbour's
      // deadline instead.
      expect(shownNumber(disarmed)).toBe("")
      expect(shownNumber(armed)).toBe("25")

      hook.destroyed()
    })

    it("survives an EMPTY rail without throwing", () => {
      // The rail renders for a closed-cards-only or error-only state, with
      // no armed card in it at all. One ticker over zero cards has to be a
      // no-op; under the per-card hook this case simply had no hook.
      const hook = mountHook(fakeRail([]))

      expect(() => vi.advanceTimersByTime(5000)).not.toThrow()

      hook.destroyed()
    })
  })

  // ── The amber step (task 01a0740e stage 3) ────────────────────────────

  describe("the amber step at the threshold", () => {
    // EVERY test here is two-sided. "The class appears at 5" is satisfied
    // by a hook that warns at every value, which is the mutation named in
    // the stage notes, so each assertion is paired with a refutation at a
    // value on the other side of the threshold.

    it("is grey at 6 and amber at 5 — the same card, one second apart", () => {
      const card = fakeCard({ actsAt: new Date(T0 + 6_000).toISOString() })
      const hook = mountHook(fakeRail([card]))

      // The positive control: the card is armed and painting.
      expect(shownNumber(card)).toBe("6")

      // ABOVE the threshold, both elements.
      expect(countWarned(card)).toBe(false)
      expect(drainWarned(card)).toBe(false)

      vi.advanceTimersByTime(1000)

      // AT the threshold. `<=`, so 5 itself steps.
      expect(shownNumber(card)).toBe("5")
      expect(countWarned(card)).toBe(true)
      expect(drainWarned(card)).toBe(true)

      // And it stays stepped all the way down, including at zero — a card
      // past its deadline waiting for the sweeper is the most committed
      // thing on the rail and must not drop back to rest.
      vi.advanceTimersByTime(5000)
      expect(shownNumber(card)).toBe("0")
      expect(countWarned(card)).toBe(true)
      expect(drainWarned(card)).toBe(true)

      hook.destroyed()
    })

    it("takes the class BACK OFF when a deadline is extended", () => {
      const card = fakeCard({ actsAt: new Date(T0 + 3_000).toISOString() })
      const hook = mountHook(fakeRail([card]))

      expect(countWarned(card)).toBe(true)
      expect(drainWarned(card)).toBe(true)

      // An utterance attached and the server moved `acts_at` forward.
      card.dataset.actsAt = new Date(T0 + 33_000).toISOString()
      hook.updated()

      // A hook that only ever ADDS the class passes every "amber appears"
      // assertion above and leaves an extended card permanently alarming.
      expect(shownNumber(card)).toBe("33")
      expect(countWarned(card)).toBe(false)
      expect(drainWarned(card)).toBe(false)

      hook.destroyed()
    })

    it("warns each card on its OWN remaining, not on the rail's soonest", () => {
      const urgent = fakeCard({ actsAt: new Date(T0 + 4_000).toISOString() })
      const calm = fakeCard({ actsAt: new Date(T0 + 25_000).toISOString() })
      const hook = mountHook(fakeRail([urgent, calm]))

      // The ladder: one card stepped, its neighbour not. A ticker that
      // decided the threshold once per tick and applied it to every card
      // would paint them both.
      expect(countWarned(urgent)).toBe(true)
      expect(countWarned(calm)).toBe(false)
      expect(drainWarned(urgent)).toBe(true)
      expect(drainWarned(calm)).toBe(false)

      hook.destroyed()
    })

    it("reads each card's OWN threshold rather than a constant in the hook", () => {
      // The server publishes the threshold as `data-warning-seconds` from
      // `Countdown.warning_seconds/0`. If this hook carried its own 5, the
      // two would drift the moment the server's number moved and a card
      // would be amber on render and grey a second later.
      const strict = fakeCard({
        actsAt: new Date(T0 + 8_000).toISOString(),
        warningSeconds: 5,
      })
      const generous = fakeCard({
        actsAt: new Date(T0 + 8_000).toISOString(),
        warningSeconds: 10,
      })
      const hook = mountHook(fakeRail([strict, generous]))

      // Identical remaining, different verdicts. A hardcoded 5 makes both
      // of these false and the test red.
      expect(shownNumber(strict)).toBe("8")
      expect(shownNumber(generous)).toBe("8")
      expect(countWarned(strict)).toBe(false)
      expect(countWarned(generous)).toBe(true)

      hook.destroyed()
    })

    it("never warns a card the server rendered no threshold onto", () => {
      const missing = fakeCard({
        actsAt: new Date(T0 + 1_000).toISOString(),
        warningSeconds: null,
      })
      const present = fakeCard({ actsAt: new Date(T0 + 1_000).toISOString() })
      const hook = mountHook(fakeRail([missing, present]))

      // The control: a card WITH the attribute, at the same remaining, is
      // warned. So the refutation below is about the missing attribute and
      // not about the ticker being asleep.
      expect(countWarned(present)).toBe(true)

      // Defaulting to 5 here would paint a card the server never marked,
      // and hide the plumbing failure that produced it.
      expect(countWarned(missing)).toBe(false)
      expect(drainWarned(missing)).toBe(false)

      hook.destroyed()
    })
  })

  // ── The pointer freeze (task 01a0740e stage 4) ─────────────────────────

  // ── The window coming BACK is not a countdown ─────────────────────────
  //
  // `.candidate-drain` eases `width` over 0.9s, added by FE-9 (adef1917)
  // for a bar that only ever shrinks. `Candidates.rearm/2` (FE-10) is the
  // first thing in the codebase that makes the width GROW, and because the
  // drain node is patched in place rather than replaced, the inherited rule
  // eased the growth into a visible left-to-right sweep: measured in a real
  // browser at 228px -> 285px over ten samples, reproduced in three trials.
  // The numeral jumped and the bar refilled.
  //
  // The fix is a `transition: none` class for the tick that grows. Both
  // halves of that sentence carry a test below, and the second is the
  // important one: deleting the transition outright, or leaving the
  // suppression on, would satisfy the first test and quietly undo FE-9 on
  // every normal second of every countdown.
  describe("the drain when the window comes BACK", () => {
    // What a correction does, from this hook's side: the server re-armed
    // the row, so the rail is patched with a later `data-acts-at` and
    // LiveView calls `updated()` — in the SAME synchronous task as the
    // patch, which is why suppressing the easing here is early enough that
    // no interpolated frame is ever painted.
    function rearm(card, seconds) {
      card.dataset.actsAt = new Date(Date.now() + seconds * 1000).toISOString()
    }

    it("snaps the bar to full instead of sweeping it there", () => {
      const card = fakeCard({ actsAt: new Date(T0 + 30_000).toISOString() })
      const hook = mountHook(fakeRail([card]))

      vi.advanceTimersByTime(24_000)

      // The premise, measured rather than assumed: the bar really is
      // part-drained, so what follows is a GROWTH and not a repaint of a
      // width that was already full.
      expect(shownNumber(card)).toBe("6")
      expect(drainWidth(card)).toBe("20.00%")
      expect(drainSnapped(card)).toBe(false)

      rearm(card, 30)
      hook.updated()

      expect(shownNumber(card)).toBe("30")
      expect(drainWidth(card)).toBe("100.00%")
      expect(drainSnapped(card)).toBe(true)

      hook.destroyed()
    })

    it("never snaps on the way DOWN — every normal second still eases", () => {
      const card = fakeCard({ actsAt: new Date(T0 + 30_000).toISOString() })
      const hook = mountHook(fakeRail([card]))

      const widths = [drainWidth(card)]
      expect(drainSnapped(card)).toBe(false)

      for (let second = 0; second < 30; second++) {
        vi.advanceTimersByTime(1000)
        widths.push(drainWidth(card))
        expect(drainSnapped(card)).toBe(false)
      }

      // Positive control for those thirty-one assertions: the bar was
      // genuinely repainted to a NEW width on every one of those seconds.
      // Without this, a hook that stopped painting the drain entirely would
      // pass the loop above, and so would a fix that deleted the class.
      expect(widths[0]).toBe("100.00%")
      expect(widths[30]).toBe("0.00%")
      expect(new Set(widths).size).toBe(31)

      hook.destroyed()
    })

    it("takes the suppression back off on the very next second", () => {
      const card = fakeCard({ actsAt: new Date(T0 + 30_000).toISOString() })
      const hook = mountHook(fakeRail([card]))

      vi.advanceTimersByTime(24_000)
      rearm(card, 30)
      hook.updated()
      expect(drainSnapped(card)).toBe(true)

      vi.advanceTimersByTime(1000)

      // A re-armed card is an ordinary card one second later. A suppression
      // that stayed on would leave this drain, and eventually every drain
      // on a rail anyone has ever corrected, stepping once a second.
      expect(shownNumber(card)).toBe("29")
      expect(drainWidth(card)).toBe("96.67%")
      expect(drainSnapped(card)).toBe(false)

      hook.destroyed()
    })

    it("snaps ONLY the card that was re-armed, never the one beside it", () => {
      const corrected = fakeCard({ actsAt: new Date(T0 + 30_000).toISOString() })
      const neighbour = fakeCard({ actsAt: new Date(T0 + 30_000).toISOString() })
      const hook = mountHook(fakeRail([corrected, neighbour]))

      vi.advanceTimersByTime(24_000)
      expect(drainWidth(corrected)).toBe("20.00%")
      expect(drainWidth(neighbour)).toBe("20.00%")

      rearm(corrected, 30)
      hook.updated()

      expect(drainWidth(corrected)).toBe("100.00%")
      expect(drainSnapped(corrected)).toBe(true)

      // The neighbour is still draining and must still ease. A previous
      // width cached on the HOOK rather than on each drain node would apply
      // the corrected card's growth to this one as well — the exact bug
      // `_paint`'s own comment says one ticker over N cards invites.
      expect(drainWidth(neighbour)).toBe("20.00%")
      expect(drainSnapped(neighbour)).toBe(false)

      hook.destroyed()
    })

    it("survives a SECOND ticker repainting the same node at the same width", () => {
      // `call_rail_frame.ex` gives the sheet handle's fill
      // `data-role="meeting-candidate-drain"`, so with the Canvas tab open
      // that one node is painted by `CandidateClock` AND `SheetHandleClock`
      // off two intervals that are not in step. It is the only node in the
      // tree painted twice a second, and it is where a `toggle(.., grew)`
      // silently loses the snap.
      const handle = fakeHandle({
        actsAt: new Date(T0 + 30_000).toISOString(),
        withDrain: true,
      })
      const railHook = mountHook(fakeRailWithDocument([], [handle]))

      handle.ownerDocument = queryable([handle])
      const handleHook = Object.create(SheetHandleClock)
      handleHook.el = handle
      handleHook.pushEvent = vi.fn()
      handleHook.mounted()

      vi.advanceTimersByTime(24_000)
      expect(drainWidth(handle)).toBe("20.00%")
      expect(drainSnapped(handle)).toBe(false)

      rearm(handle, 30)
      railHook.updated()
      expect(drainSnapped(handle)).toBe(true)

      // The second painter computes the SAME width and must state no
      // opinion. "Did not grow" is not "shrank", and only a shrink restores
      // the easing.
      handleHook.updated()
      expect(drainWidth(handle)).toBe("100.00%")
      expect(drainSnapped(handle)).toBe(true)

      // And that second painter is not merely inert: one second on it
      // computes a narrower width and restores the easing like any other.
      vi.advanceTimersByTime(1000)
      expect(drainWidth(handle)).toBe("96.67%")
      expect(drainSnapped(handle)).toBe(false)

      railHook.destroyed()
      handleHook.destroyed()
    })
  })

  describe("the pointer freeze", () => {
    it("pushes a freeze on pointerenter and a thaw on pointerleave", () => {
      const rail = fakeRail([fakeCard({ actsAt: new Date(T0 + 10_000).toISOString() })])
      const hook = mountHook(rail)

      // The precondition, and it matters: ticking alone must push
      // NOTHING, so the pushes below are attributable to the pointer and
      // not to the clock that shares this hook.
      vi.advanceTimersByTime(5000)
      expect(hook.pushEvent).not.toHaveBeenCalled()

      rail.fire("pointerenter")
      expect(hook.pushEvent).toHaveBeenCalledWith("candidate_rail_freeze", {})
      expect(hook.pushEvent).toHaveBeenCalledTimes(1)

      rail.fire("pointerleave")
      expect(hook.pushEvent).toHaveBeenCalledWith("candidate_rail_thaw", {})
      expect(hook.pushEvent).toHaveBeenCalledTimes(2)

      hook.destroyed()
    })

    it("sends NO card ids — the server re-derives the order it froze", () => {
      const rail = fakeRail([fakeCard({ actsAt: new Date(T0 + 10_000).toISOString() })])
      const hook = mountHook(rail)

      rail.fire("pointerenter")

      // The payload is empty on purpose. A hook that shipped the
      // on-screen sequence up would be letting a browser dictate which
      // cards a rail draws and in what order, which is a far larger
      // promise than "a pointer is over the rail" — and the LiveView
      // holds the same list anyway.
      const [, payload] = hook.pushEvent.mock.calls[0]
      expect(payload).toEqual({})

      hook.destroyed()
    })

    it("binds enter and leave once, and takes both off again on destroy", () => {
      const rail = fakeRail([])
      const hook = mountHook(rail)

      expect(rail.listeners.get("pointerenter").size).toBe(1)
      expect(rail.listeners.get("pointerleave").size).toBe(1)

      hook.destroyed()

      // A leftover listener fires a push at a socket that has moved on,
      // and holds the detached rail alive for the rest of the meeting.
      expect(rail.listeners.get("pointerenter").size).toBe(0)
      expect(rail.listeners.get("pointerleave").size).toBe(0)

      // And the proof that "size 0" means it cannot fire, rather than
      // that the registry was emptied by something else.
      rail.fire("pointerenter")
      expect(hook.pushEvent).not.toHaveBeenCalled()
    })

    it("does not re-freeze when the rail is patched under a held pointer", () => {
      const rail = fakeRail([fakeCard({ actsAt: new Date(T0 + 10_000).toISOString() })])
      const hook = mountHook(rail)

      rail.fire("pointerenter")
      expect(hook.pushEvent).toHaveBeenCalledTimes(1)

      // A card arrived while the pointer was still on the rail. The
      // freeze is already held; pushing again on every patch would turn
      // one hover into a stream of round trips.
      rail.cards.push(fakeCard({ actsAt: new Date(T0 + 3_000).toISOString() }))
      hook.updated()
      vi.advanceTimersByTime(3000)

      expect(hook.pushEvent).toHaveBeenCalledTimes(1)

      hook.destroyed()
    })
  })

  // ── The spent row's own expiry (task 01a0740e stage 5) ────────────────

  describe("the spent row a stop leaves behind", () => {
    it("stays up until `data-expires-at` passes, then goes", () => {
      const row = fakeSpentRow({ expiresAt: new Date(T0 + 10_000).toISOString() })
      const hook = mountHook(fakeRail([row]))

      // Mounting paints once. Ten seconds out, so the row is up — and
      // this reading is what makes the one below a CHANGE rather than a
      // static assertion that would pass against a row hidden on sight.
      expect(row.hidden).toBe(false)

      vi.advanceTimersByTime(9000)
      expect(row.hidden).toBe(false)

      vi.advanceTimersByTime(1000)
      expect(row.hidden).toBe(true)

      hook.destroyed()
    })

    it("hides the EXPIRED row and leaves a live one beside it alone", () => {
      // Two rows, one interval. A ticker that cached a deadline off the
      // first row would hide both, which is the tempting bug when one
      // clock walks N rows and is exactly what `_paint` is already
      // guarded against for cards.
      const gone = fakeSpentRow({ expiresAt: new Date(T0 + 2_000).toISOString() })
      const fresh = fakeSpentRow({ expiresAt: new Date(T0 + 20_000).toISOString() })
      const hook = mountHook(fakeRail([gone, fresh]))

      vi.advanceTimersByTime(3000)

      expect(gone.hidden).toBe(true)
      expect(fresh.hidden).toBe(false)

      hook.destroyed()
    })

    it("leaves a row with no expiry — or an unreadable one — VISIBLE", () => {
      // Hiding on a plumbing failure makes a broken attribute look
      // exactly like a working expiry. The visible failure is the one
      // somebody reports.
      const missing = fakeSpentRow({ expiresAt: null })
      const garbage = fakeSpentRow({ expiresAt: "soon" })
      const hook = mountHook(fakeRail([missing, garbage]))

      vi.advanceTimersByTime(60_000)

      expect(missing.hidden).toBe(false)
      expect(garbage.hidden).toBe(false)

      hook.destroyed()
    })

    it("keeps painting the cards on the same rail as a spent row", () => {
      // The spent row is a second query inside one tick. A `return` in
      // the wrong place would leave the countdown frozen the moment
      // somebody stopped a neighbouring card.
      const card = fakeCard({ actsAt: new Date(T0 + 20_000).toISOString() })
      const row = fakeSpentRow({ expiresAt: new Date(T0 + 5_000).toISOString() })
      const hook = mountHook(fakeRail([card, row]))

      expect(shownNumber(card)).toBe("20")

      vi.advanceTimersByTime(6000)

      expect(shownNumber(card)).toBe("14")
      expect(row.hidden).toBe(true)

      hook.destroyed()
    })
  })

  // ── The handle's OWN heartbeat ─────────────────────────────────────────
  //
  // `CandidateClock` mounts on the candidate rail `<section>`, which the
  // call rail renders only inside the Canvas tab. On every other tab there
  // is no rail ticker, so the shut sheet's handle mounts `SheetHandleClock`:
  // the same `_tick`/`_paint`, no pointer freeze.
  describe("SheetHandleClock", () => {
    it("ticks the handle from ONE interval of its own, with no card in sight", () => {
      const spy = vi.spyOn(globalThis, "setInterval")

      const handle = fakeHandle({ actsAt: new Date(T0 + 20_000).toISOString() })
      // The hook's `el` IS the handle; the document query finds it again.
      handle.ownerDocument = queryable([handle])

      const hook = Object.create(SheetHandleClock)
      hook.el = handle
      hook.pushEvent = vi.fn()
      hook.mounted()

      expect(spy).toHaveBeenCalledTimes(1)
      expect(shownNumber(handle)).toBe("20")

      vi.advanceTimersByTime(6000)
      expect(shownNumber(handle)).toBe("14")

      hook.destroyed()
      vi.advanceTimersByTime(6000)
      // Stopped: nothing paints after `destroyed()`.
      expect(shownNumber(handle)).toBe("14")
    })

    it("never binds the rail's pointer freeze — a thumb on the handle freezes nothing", () => {
      const handle = fakeHandle({ actsAt: new Date(T0 + 20_000).toISOString() })
      handle.ownerDocument = queryable([handle])
      const listeners = []
      handle.addEventListener = (name) => listeners.push(name)

      const hook = Object.create(SheetHandleClock)
      hook.el = handle
      hook.pushEvent = vi.fn()
      hook.mounted()

      expect(listeners).toEqual([])
      expect(hook.pushEvent).not.toHaveBeenCalled()

      hook.destroyed()
    })
  })

  // ── The handle and the cards, driven by ONE tick ──────────────────────

  describe("the bottom-sheet handle countdown", () => {
    it("paints the handle and the cards from a SINGLE interval and a single tick", () => {
      const spy = vi.spyOn(globalThis, "setInterval")

      const card = fakeCard({ actsAt: new Date(T0 + 20_000).toISOString() })
      const handle = fakeHandle({ actsAt: new Date(T0 + 20_000).toISOString() })
      const hook = mountHook(fakeRailWithDocument([card], [handle]))

      // ONE interval, not two. This is the load-bearing assertion: a
      // second hook mounted on the sheet would paint the same numbers
      // and pass every value assertion below while drifting away from
      // the sweeper, which is the failure the rail was consolidated to
      // remove. Only a COUNT can tell the two designs apart.
      expect(spy).toHaveBeenCalledTimes(1)

      expect(shownNumber(card)).toBe("20")
      expect(shownNumber(handle)).toBe("20")

      vi.advanceTimersByTime(6000)

      // Both MOVED, and moved together. Equal-and-changed, not merely
      // equal: two frozen nodes are also equal.
      expect(shownNumber(card)).toBe("14")
      expect(shownNumber(handle)).toBe("14")
      expect(spy).toHaveBeenCalledTimes(1)

      hook.destroyed()
    })

    it("steps the handle to amber at the SERVER's threshold, and not before", () => {
      // Two-sided, for the reason the card threshold tests are: "amber
      // appears at 5" passes just as well on a handle that is amber at
      // every value.
      const handle = fakeHandle({
        actsAt: new Date(T0 + 8000).toISOString(),
        warningSeconds: 5,
      })
      const hook = mountHook(fakeRailWithDocument([], [handle]))

      expect(shownNumber(handle)).toBe("8")
      expect(countWarned(handle)).toBe(false)

      vi.advanceTimersByTime(3000)

      expect(shownNumber(handle)).toBe("5")
      expect(countWarned(handle)).toBe(true)

      hook.destroyed()
    })

    it("paints a handle with no drain child rather than throwing", () => {
      // `_paint` returns early when the drain lookup misses. That early
      // return sits AFTER the number is written, and the handle is the
      // first node in the tree that exercises it — a card always has a
      // drain, so nothing before this stage could have caught a return
      // that moved above the text node.
      const handle = fakeHandle({ actsAt: new Date(T0 + 12_000).toISOString() })
      const hook = mountHook(fakeRailWithDocument([], [handle]))

      expect(shownNumber(handle)).toBe("12")

      hook.destroyed()
    })

    it("rewrites the status row's accessible name from the SERVER's template, every tick", () => {
      // The digit on the handle is `aria-hidden`; this string is the whole
      // of what a screen reader gets. A name that said "20 seconds" for the
      // entire window would be a lie told only to the people least able
      // to recover from a missed window.
      const row = fakeNode("sheet-handle-row")
      const handle = fakeHandle({ actsAt: new Date(T0 + 20_000).toISOString() })
      handle.dataset.labelTemplate = "%{n} second%{s} until a task is created"
      handle.dataset.labelTarget = "meeting-rail-sheet-handle"

      const rail = fakeRailWithDocument([], [handle])
      rail.ownerDocument.getElementById = (id) =>
        id === "meeting-rail-sheet-handle" ? row : null

      const hook = mountHook(rail)

      expect(row.attrs["aria-label"]).toBe("20 seconds until a task is created")

      vi.advanceTimersByTime(19_000)

      // Singular at one: "1 seconds" is the kind of sloppiness a template
      // with one placeholder produces, and it is exactly what a
      // screen-reader user would hear at the moment it matters most.
      expect(row.attrs["aria-label"]).toBe("1 second until a task is created")

      hook.destroyed()
    })

    it("names the node ITSELF when no target is given, and leaves cards alone", () => {
      const handle = fakeHandle({ actsAt: new Date(T0 + 7_000).toISOString() })
      handle.dataset.labelTemplate = "%{n} second%{s} left"
      handle.attrs = {}
      handle.setAttribute = function (name, value) {
        this.attrs[name] = value
      }

      const card = fakeCard({ actsAt: new Date(T0 + 7_000).toISOString() })
      card.attrs = {}
      card.setAttribute = function (name, value) {
        this.attrs[name] = value
      }

      const hook = mountHook(fakeRailWithDocument([card], [handle]))

      expect(handle.attrs["aria-label"]).toBe("7 seconds left")
      // A card has no template and is not a live region: untouched.
      expect(card.attrs["aria-label"]).toBeUndefined()

      hook.destroyed()
    })

    it("still paints the cards when there is no wider root at all", () => {
      // `fakeRail` has no `ownerDocument`, i.e. a detached rail. The
      // fallback must not take the card loop down with it.
      const card = fakeCard({ actsAt: new Date(T0 + 20_000).toISOString() })
      const hook = mountHook(fakeRail([card]))

      vi.advanceTimersByTime(6000)

      expect(shownNumber(card)).toBe("14")

      hook.destroyed()
    })
  })
})
