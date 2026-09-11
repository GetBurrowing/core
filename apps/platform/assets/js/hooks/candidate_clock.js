/**
 * CandidateClock hook — ONE ticker for the whole candidate rail.
 *
 * The server renders the number that was true at render time and stamps
 * the real deadline into `data-acts-at`. Before this hook the number
 * simply sat there: a card that said "Starting in 30s" said it until the
 * next LiveView patch, whenever that happened to be.
 *
 * ## Why the hook is on the RAIL and not on the card
 *
 * It used to be on each `.candidate-foot`, so every armed card opened its
 * own `setInterval`. Five armed candidates was five intervals, all of them
 * doing the same arithmetic against the same wall clock and all of them
 * needing mount/destroy bookkeeping to be exactly right or a detached node
 * stays alive for the rest of the meeting.
 *
 * One interval on the rail's `<section>` costs the same whatever the card
 * count, and each tick RE-QUERIES `[data-role='meeting-candidate-countdown']`
 * inside the rail rather than holding references. Re-querying is the point:
 * cards arriving and leaving are picked up with no bookkeeping at all, and a
 * LiveView patch cannot leave a stale node being driven by a dead closure.
 *
 * ## What has NOT changed, and must not
 *
 * Everything here is still derived from each card's own `data-acts-at`,
 * which is the same `meeting_candidates.acts_at` the server's sweeper fires
 * on. That is the point: what is painted is a rendering of the server's
 * deadline, not a second clock started at mount that would drift away from
 * it. One ticker reading N deadlines is still N deadlines — the shared
 * interval is a shared HEARTBEAT, never a shared countdown. No polling
 * either: a per-card server round trip every second is exactly what a
 * client-side countdown exists to avoid.
 *
 * Reaching zero deliberately does NOT ask the server for anything. The
 * sweeper fires on its own and broadcasts a candidate event, and the rail
 * refetches on that. A hook that pushed at zero would give every connected
 * participant's browser its own opinion about when a card fired.
 *
 * The server still renders the CURRENT value into the text node,
 * `data-remaining` and the drain's inline width, so a session with JS
 * disabled sees a true (if frozen) card rather than a placeholder, and the
 * first tick is a correction of at most one second rather than a reveal.
 *
 * ## What THIS stage changed (task 01a0740e stage 3)
 *
 * The ring is gone, and its dash-offset arithmetic with it. What is painted
 * now is a NUMBER and a WIDTH, plus one threshold class.
 *
 * The threshold is read from each card's `data-warning-seconds`, which the
 * server renders from `Platform.Meetings.Countdown.warning_seconds/0`. It is
 * deliberately not a constant in this file: the server decides the class at
 * first paint and this hook re-decides it every second afterwards, so a
 * duplicated 5 here is the version where a card is amber on render and grey
 * a second later.
 *
 * The class is toggled, never faded. A CSS transition on the colour would
 * turn a threshold EVENT back into the thirty-second ramp the step exists
 * instead of, and `.candidate-drain` transitions `width` only for that
 * reason.
 *
 * ## What stage 4 added: the pointer FREEZE
 *
 * The rail is now ordered by deadline, soonest to fire at the top, so a
 * card can move while somebody is reading it and slide a different card
 * under a cursor already on its way to `Stop`. This hook reports the
 * pointer and nothing else: `pointerenter` pushes `candidate_rail_freeze`,
 * `pointerleave` pushes `candidate_rail_thaw`, and the LiveView decides
 * what the frozen order is by re-deriving it from the list it already
 * holds. No card ids are sent. A hook that shipped the on-screen order up
 * would be letting the browser choose which cards a rail draws and in
 * which sequence, which is a different and much larger promise than "a
 * pointer is over the rail".
 *
 * ## What stage 5 added: the SPENT ROW's own expiry
 *
 * A stop leaves a dimmed row in the slot the card was in, carrying an
 * `Undo`, and that row lives for ten seconds. The instant it dies is
 * stamped into `data-expires-at` by the server, and this ticker — already
 * walking the rail every second — is what hides it.
 *
 * Deliberately NOT a server timer and NOT a `setTimeout` per stop: the
 * clock that has to be right about this is the same clock already running,
 * and a second one is a second thing that can be wrong. Equally NOT a wait
 * for the next candidate broadcast, which may never come on a quiet rail
 * and would leave a stale `Undo` on screen for the rest of the meeting.
 *
 * The SERVER re-checks the same instant on every render, so this is the
 * belt and not the braces: a reload after the window has passed does not
 * draw the row at all.
 *
 * ## What the FE-10 remediation added: the RE-ARM SNAP
 *
 * A correction re-arms the card, which is the first thing in the codebase
 * that makes the drain's width GROW. `.candidate-drain` eases `width`, so
 * the growth was drawn as a 0.9s sweep left to right — the numeral jumping
 * and the bar refilling, one event drawn two contradictory ways. `_paint`
 * now compares the width it is about to write against the width it last
 * wrote and suppresses the easing for the growing tick only. See
 * `_snapIfGrowing` for why the previous value lives on the node and why
 * "equal" is not "did not grow".
 *
 * `pointerenter` / `pointerleave` rather than `pointerover` / `pointerout`:
 * the over/out pair bubbles from every child, so moving between two cards
 * would fire a thaw and a freeze on each crossing and the rail would be
 * unfrozen for a frame in the middle of a hover. The enter/leave pair
 * fires once per rail.
 */
const CandidateClock = {
  mounted() {
    this._bindPointer()
    this._start()
  },

  updated() {
    // The rail was patched: a card arrived, left, or had its deadline
    // moved by an utterance that attached and extended it. Paint once
    // immediately so the correction is not up to a second late.
    //
    // The interval is deliberately left ALONE. Stopping and restarting it
    // here would put the "exactly one interval" property at the mercy of
    // how often LiveView patches the rail, and there is nothing to restart
    // for: `_tick` holds no state between calls and reads every card fresh.
    this._tick()
  },

  destroyed() {
    this._unbindPointer()
    this._stop()
  },

  // ── Private ──────────────────────────────────────────────────────────

  // Handlers are held on the hook so `destroyed()` can take the exact
  // same function references off again. Binding an inline arrow twice
  // would leave a listener on a rail LiveView has thrown away, and the
  // push it fires lands on a socket that has moved on.
  _bindPointer() {
    this._onPointerEnter = () => this.pushEvent("candidate_rail_freeze", {})
    this._onPointerLeave = () => this.pushEvent("candidate_rail_thaw", {})

    this.el.addEventListener("pointerenter", this._onPointerEnter)
    this.el.addEventListener("pointerleave", this._onPointerLeave)
  },

  _unbindPointer() {
    this.el.removeEventListener("pointerenter", this._onPointerEnter)
    this.el.removeEventListener("pointerleave", this._onPointerLeave)
  },

  _start() {
    this._tick()
    this._interval = setInterval(() => this._tick(), 1000)
  },

  _stop() {
    if (this._interval) {
      clearInterval(this._interval)
      this._interval = null
    }
  },

  // Every node this ticker paints a deadline onto, in ONE list, so the loop
  // above stays one loop and the "exactly one interval" property is
  // untouched (task 01a07410 stage 2).
  //
  // ## Why the handle is queried from a WIDER root
  //
  // The cards are descendants of the rail `<section>` this hook is mounted
  // on, so `this.el` reaches them. The bottom-sheet HANDLE is not: it is
  // the sheet's grab bar, a sibling subtree above the rail, and on a phone
  // the rail is inside a drawer that is translated off screen. A
  // `this.el`-scoped query can never see it. So the root widens for that
  // selector and only that one.
  //
  // This does NOT start a second clock, which is the property the moduledoc
  // above argues for and the one worth protecting: it is the same interval,
  // the same `Date.now()` reading, and the same `_paint`, so the handle and
  // the card three inches away cannot show different numbers or step to
  // amber a second apart. The alternative — a hook on the sheet — is a
  // second interval started at a different moment, which is exactly the
  // drift the rail was consolidated to remove.
  //
  // Painting a handle twice (two rails on one page) is harmless BECAUSE
  // `_paint` reads everything off the node it is handed and nothing off
  // `this`: both tickers compute the same number from the same
  // `data-acts-at`. That is a property of `_paint`, not an accident, and it
  // is why the wider root is safe here and would not be if `_paint` cached.
  //
  // `ownerDocument` falls back to `this.el` rather than to `document`: the
  // global is not reachable in the hook's test environment, and a hard
  // reference to it would make this untestable without asserting anything
  // extra.
  _countdownNodes() {
    const cards = [
      ...this.el.querySelectorAll("[data-role='meeting-candidate-countdown']"),
    ]

    const root = this.el.ownerDocument || this.el

    return cards.concat([
      ...root.querySelectorAll("[data-role='meeting-sheet-handle-countdown']"),
    ])
  },

  // One wall-clock reading for the whole rail, so two cards rendered in the
  // same tick can never disagree about what time it is.
  _tick() {
    const now = Date.now()

    for (const card of this._countdownNodes()) {
      this._paint(card, now)
    }

    for (const row of this.el.querySelectorAll(
      "[data-role='meeting-candidate-spent']"
    )) {
      this._paintSpent(row, now)
    }
  },

  // The spent row is a DEADLINE and nothing else — no number to repaint
  // and no width to move, so this either leaves it alone or takes it off
  // screen. Same posture as `_paint`: everything comes off the ROW, never
  // off `this`, because one ticker over N rows is exactly where a cached
  // value becomes one row's expiry applied to all of them.
  //
  // A row with no `data-expires-at`, or an unparseable one, is left
  // VISIBLE. Hiding on a plumbing failure would make a broken attribute
  // indistinguishable from a working expiry, and the visible failure is
  // the one somebody reports.
  _paintSpent(row, now) {
    const expiresAt = row.dataset.expiresAt
    if (!expiresAt) return

    const deadline = new Date(expiresAt).getTime()
    if (isNaN(deadline)) return

    if (now >= deadline) row.hidden = true
  },

  // The ACCESSIBLE NAME, in words (task 01a07410 stage 3). A node that
  // carries `data-label-template` ("%{n} second%{s} until a task is
  // created") names a target — `data-label-target`, the sheet handle's
  // `role="status"` row, or itself when absent — whose `aria-label` is
  // rewritten every tick. The visible digit is `aria-hidden` on the
  // handle, so this string is the whole of what a screen reader gets,
  // and a name that said "30 seconds" for the entire window would be a
  // lie told only to the people least able to recover from it.
  //
  // The template is the SERVER's, from `CallRailFrame.label_template/1`;
  // the same string renders the initial name, so the first tick is a
  // number change and never a wording change.
  //
  // Cards carry no template and are untouched: their `<time>` is the
  // accessible content there, and a card's foot is not a live region.
  _paintLabel(card, remaining) {
    const template = card.dataset.labelTemplate
    if (!template) return

    const target = this._labelTarget(card)
    if (!target) return

    target.setAttribute(
      "aria-label",
      template
        .replace("%{n}", String(remaining))
        .replace("%{s}", remaining === 1 ? "" : "s")
    )
  },

  _labelTarget(card) {
    const id = card.dataset.labelTarget
    if (!id) return card

    const root = this.el.ownerDocument
    return root && typeof root.getElementById === "function"
      ? root.getElementById(id)
      : null
  },

  // Everything below reads from the CARD, never from `this`. A value cached
  // on the hook would be one card's deadline applied to all of them — and
  // with one ticker over N cards that is the tempting bug, not a theoretical
  // one.
  _paint(card, now) {
    const actsAt = card.dataset.actsAt
    if (!actsAt) return

    const deadline = new Date(actsAt).getTime()
    if (isNaN(deadline)) return

    const total = parseInt(card.dataset.totalSeconds, 10)
    if (!total || total <= 0) return

    // Floored at zero. The interval outlives any single card now, so a card
    // that has passed its deadline and is waiting for the sweeper keeps
    // being painted; without the floor that participant is shown "-58".
    const remaining = Math.max(0, Math.ceil((deadline - now) / 1000))

    // The threshold comes from the SERVER, per card. `warning_seconds/0`
    // renders it into `data-warning-seconds`; a constant here would drift
    // from the class the server painted on the same card a second earlier.
    // A card with no threshold attribute is never warned — silently
    // defaulting to 5 would hide exactly that plumbing failure.
    const warnAt = parseInt(card.dataset.warningSeconds, 10)
    const warning = !isNaN(warnAt) && remaining <= warnAt

    for (const el of card.querySelectorAll(
      "[data-role='meeting-candidate-remaining']"
    )) {
      el.textContent = String(remaining)
      if (el.dataset.remaining !== undefined) {
        el.dataset.remaining = String(remaining)
      }
      el.classList.toggle("candidate-count--warning", warning)
    }

    this._paintLabel(card, remaining)

    // Queried from the card's own subtree, never from the rail: the drain
    // is written inside `.candidate-foot` (and positioned out of it) so
    // that this lookup cannot reach a NEIGHBOUR's bar. A rail-level query
    // would paint the first card's width onto every card and still pass
    // any test that only checks "the width moved".
    const drain = card.querySelector("[data-role='meeting-candidate-drain']")
    if (!drain) return

    // Same arithmetic as `drain_width/1` on the server: full width at
    // t=total, nothing at t=0. They have to agree or the first tick visibly
    // jumps. The REMAINING fraction, not the elapsed one — wired to the
    // other end the bar looks plausible and grows as the card runs out.
    const fraction = Math.min(remaining / total, 1)
    const percent = Number((fraction * 100).toFixed(2))

    this._snapIfGrowing(drain, percent)

    drain.style.width = `${percent.toFixed(2)}%`
    drain.classList.toggle("candidate-drain--warning", warning)
  },

  // THE RE-ARM SNAP. `.candidate-drain` eases `width` over 0.9s, and that
  // easing was written for a bar that only ever shrinks. A correction calls
  // `Candidates.rearm/2` and hands the card its full window back, so the
  // width GROWS — and because the drain node is patched in place rather
  // than replaced, the inherited transition eases the growth into a visible
  // left-to-right sweep. The numeral jumps and the bar refills: the two
  // halves of one event disagreeing about whether it was an event.
  //
  // So the easing is turned off for the tick that grows, and back on for
  // the next tick that shrinks. NOT turned off permanently: that would
  // satisfy the re-arm and silently undo the drain on every normal second
  // of every countdown, which is the whole of what the transition is for.
  //
  // ## Why the previous width is stamped on the NODE
  //
  // Not on `this`, for the reason `_paint`'s own comment gives: one ticker
  // over N cards is exactly where a value cached on the hook becomes one
  // card's deadline applied to all of them. A property on the drain is
  // per-drain by construction.
  //
  // And not read back off `drain.style.width` either, which is the reading
  // that looks obvious and is wrong. The growth is applied by the LiveView
  // PATCH: morphdom writes the server's new inline width onto the node
  // before this hook's `updated()` runs, so by the time we are asked, the
  // style attribute already holds the NEW value and has forgotten the old
  // one. An expando survives the in-place patch; the style attribute does
  // not survive it unchanged. The ordering is what makes this work at all:
  // `updated()` is dispatched in the same synchronous task as the patch, a
  // transition only produces pixels at paint time, and there is no paint
  // in between — so cancelling it here means no interpolated frame is ever
  // drawn.
  //
  // ## Why `add`/`remove` on strict inequality, and not `toggle`
  //
  // The sheet handle's fill is also a `meeting-candidate-drain`, and when
  // the Canvas tab is open BOTH `CandidateClock` and `SheetHandleClock`
  // paint it, from two intervals that are not in step. The second one to
  // arrive computes the same percent and would `toggle(..., false)` the
  // class straight back off the node the first one just snapped. Equal is
  // therefore "no opinion", and only a genuine narrowing restores the
  // easing. A first paint has no previous width and states no opinion
  // either: there is no growth to hide when the server has just rendered
  // the bar at its correct width.
  _snapIfGrowing(drain, percent) {
    const previous = drain.__candidateDrainPercent
    drain.__candidateDrainPercent = percent

    if (previous === undefined || percent === previous) return

    if (percent > previous) drain.classList.add("candidate-drain--snap")
    else drain.classList.remove("candidate-drain--snap")
  },
}

/**
 * SheetHandleClock — the bottom-sheet handle's OWN heartbeat (task
 * 01a07410 stage 3).
 *
 * Stage 2 widened `_countdownNodes` so the rail's ticker reaches the
 * handle, on the premise that the rail's ticker is always running. It is
 * not: `CandidateClock` mounts on the candidate rail `<section>`, which
 * `call_rail/1` renders only inside the CANVAS tab's branch. On People,
 * Chat or Transcript there is no ticker, and a shut sheet whose handle
 * shows the server's number frozen is the lying window this whole
 * feature exists to remove.
 *
 * So the handle mounts this. It is `CandidateClock` minus the pointer
 * freeze — a thumb on the handle must not push `candidate_rail_freeze`
 * at a rail it is not touching — and it is the SAME `_tick` and `_paint`:
 * `this.el` is the handle, so the card query finds nothing, and the
 * document query finds the handle itself. When the Canvas tab is open
 * both hooks paint this node from the same `data-acts-at` with the same
 * arithmetic, which the rail's moduledoc already argues is harmless
 * because `_paint` reads nothing off `this`. Neither starts a
 * client-side countdown; both are renderings of the server's deadline.
 */
export const SheetHandleClock = {
  ...CandidateClock,

  mounted() {
    this._start()
  },

  destroyed() {
    this._stop()
  },
}

export default CandidateClock
