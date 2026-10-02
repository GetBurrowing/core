/**
 * MeetingAskHeardOverlay — the floating "what Burrow heard" box, round 3
 * of task 01a0f842's ask-floor work (task 01a0fa7e-afd7, design canvas
 * `01a0fa80-da74`, "Burrow round 3: floating heard text and hittable
 * rail").
 *
 * ## Why this is a SEPARATE hook from `MeetingAskFloorVeil`
 *
 * Round 2 put the live transcript text INSIDE the centred veil card
 * (`meeting-ask-heard-box`, now retired as a text holder — see
 * `participant_rail.ex`). Harper's round-3 report named the defect
 * exactly: that card auto-grows with every word, and because it is
 * centred over the whole stage, a long utterance visibly reflows
 * everything under it. The canvas's fix is architectural, not cosmetic —
 * the heard text has to leave the card's layout flow entirely and live in
 * its own fixed-size, absolutely-positioned box that is never a sibling
 * in anyone's flex/grid flow. Splitting it into its own hook (rather than
 * teaching `MeetingAskFloorVeil` a second responsibility) keeps the
 * veil's own job — the dim scrim, the outcome fly/crumble, the
 * interrupted-error line — untouched, and keeps this hook's only job
 * positioning text that must never move anything else.
 *
 * ## A SINGLETON, like the veil
 *
 * One hook, one overlay element, for the same reason `MeetingAskFloorVeil`
 * is a singleton: a viewer can only be holding one agent's Ask key at a
 * time, so there is only ever one "what did it hear" box to show. It
 * listens to the SAME window-level `CustomEvent`s `MeetingPushToTalk`
 * dispatches, decoupled from which specific row's hook produced them.
 *
 * ## Open/close timing — mirrors the veil, does not depend on it
 *
 * Per the canvas: open at the 380ms hold threshold (`meeting:push-to-
 * talk-held`), stay open "until done or 2s after a failure." That is
 * deliberately the SAME threshold and the SAME `INTERRUPTED_CLOSE_MS`
 * window `MeetingAskFloorVeil` uses for its own error line, so the two
 * boxes resolve together — but this hook does not reach into the veil's
 * state to do it; it re-derives the same timing from the same window
 * events, exactly as `MeetingAskFloorVeil` itself is already decoupled
 * from `MeetingPushToTalk`.
 *
 * "Done" is the physical release (`meeting:push-to-talk-ended`) — this
 * box has nothing further to show once the key is up regardless of what
 * the server later resolves the press to (a real answer vs. nothing),
 * so unlike the veil it does not wait on `meeting_ask_outcome` at all;
 * the veil's own card is what carries the fly/crumble continuation. "2s
 * after a failure" mirrors the veil's `_onRejected` exactly, including
 * NOT waiting on `_isHeld`: a server rejection (`held-by-other`, via
 * `MeetingPushToTalk._serverReject` -> `_reject`) never dispatches
 * `meeting:push-to-talk-ended` at all — `_reject` only sets `_pressed =
 * false` locally and fires `-rejected` — so a close that waited for
 * `ended` after a rejection could wait forever. The veil's own moduledoc
 * says this for its error line; the same fact applies here.
 *
 * ## Size grows to ~7 lines, then scrolls (round 4, canvas 01a0fdf2-804d)
 *
 * Round 3's box was a hard 72px (3 lines) with `overflow: hidden`, which
 * Dalton's round-4 report called out as too short once a hold outlasts a
 * sentence or two. The window (`[data-role="meeting-ask-heard-window"]`)
 * now grows up to `max-h-[168px]` (~7 lines) and then scrolls —
 * `overflow-y: auto`, not `hidden`. `_appendText` pins newly-arrived text
 * to the bottom by setting `scrollTop = scrollHeight` after every chunk,
 * UNLESS `_onWindowScroll` has noticed the viewer scrolled away from the
 * bottom on their own, in which case new text keeps landing in the DOM
 * but the scroll position is left alone — "you can scroll back up inside
 * the box while you talk" (canvas). The top-fade mask that makes the
 * oldest visible line read as fading out, rather than clipping sharply,
 * is a `::before` gradient in `app.css`, keyed off the same data-role.
 * The window is carved out of the overlay's otherwise blanket
 * `pointer-events: none` (also in `app.css`) specifically so a real
 * scroll gesture can land on it — safe only because `_wouldOverlapAControl`
 * below already guarantees this window is never positioned over a
 * control a click could otherwise have hit.
 *
 * ## Placement: desktop anchors to the row, phone (or any overlap) goes
 * to the top of the viewport
 *
 * Recomputed on open, and on resize/scroll while open (the row can move
 * under an open overlay if the rail scrolls). `_desktopRect` computes the
 * canvas's desktop anchor (left edge 8px outside the rail's right border,
 * top aligned with the held row, width `min(360, stage width - 32)`).
 * `_wouldOverlapAControl` then checks that candidate rect against every
 * live rail control (`meeting-agent-hold-to-talk`, the mute/remove
 * buttons, any `Try again` retry) — not just the held row's own, since a
 * tall overlay anchored to a row near the bottom of the rail could reach
 * down into a DIFFERENT row's controls. Failing either the viewport-width
 * check or the overlap check falls back to the SAME phone placement
 * (`_phoneRect`) the canvas specifies for narrow viewports — "if a
 * computed position would overlap one of them... it moves to the
 * top-of-viewport placement" is written generally, not "only on phone."
 *
 * ## Pointer-events: none, read-only, always
 *
 * Set on the container AND propagates to every child via CSS (see
 * `app.css`'s `[data-role="meeting-ask-heard-overlay"] *` rule) — nothing
 * in here is interactive, so nothing in here may intercept a click
 * headed for a rail control underneath it.
 *
 * ## `updated()` — surviving the SAME `phx-update="ignore"` stomp
 * `MeetingPushToTalk` was just fixed for (task 01a0fa7e-afd7 stage 5/6)
 *
 * `participant_rail.ex` renders `data-open="false"`/`data-placement=
 * "desktop"` as literals on this element on EVERY render, and this
 * LiveView re-renders the row whenever ANY assign changes — including,
 * critically, the instant a real transcript segment arrives
 * (`handle_info({:transcript_chunk, ...})` in `meeting_live.ex`).
 * `DOM.mergeAttrs(fromEl, toEl, {isIgnored: true})` still copies every
 * `data-*` attribute the fresh server render carries onto this ignored
 * element — exactly the mechanism `MeetingPushToTalk.updated()`'s
 * moduledoc documents in full, confirmed live with a `MutationObserver`:
 * `data-open` flips to `"true"` at the 380ms hold threshold (`_open()`,
 * client-side only) and is then stomped back to `"false"` by the next
 * patch, ~294ms later in the observed case, with nothing in this hook
 * ever calling `_close()` to explain it. `updated()` below reasserts
 * `data-open`/`data-placement` from this hook's own JS state (`_isHeld`,
 * `_placement` — never read from the DOM it is correcting), the same
 * pattern as that hook's `updated()`. There is no row-mirroring step
 * here the way `MeetingPushToTalk._setRowPressed` has one: this overlay
 * has no sibling element carrying a parallel copy of its own state.
 */

import { getHold, appendHoldText } from "./lib/ptt_hold_state"

const INTERRUPTED_CLOSE_MS = 2_000
const DESKTOP_MIN_WIDTH_PX = 1024 // Tailwind `lg`
const DESKTOP_GAP_PX = 8
const DESKTOP_MAX_WIDTH_PX = 360
const DESKTOP_SIDE_MARGIN_PX = 16 // "stage width minus 32" => 16 each side
const PHONE_GUTTER_PX = 16
const PHONE_TOP_GAP_PX = 8
const DEFAULT_HEADER_HEIGHT_PX = 48 // `header` is a fixed `h-12`; measured as a fallback only

const MeetingAskHeardOverlay = {
  mounted() {
    this._activeAgentId = null
    this._isHeld = false
    this._closeTimer = null
    // Mirrors the template's own literal default (`data-placement=
    // "desktop"`) — the source of truth `updated()` reasserts from, kept
    // in step by `_applyRect` every time `_reposition` actually runs.
    this._placement = "desktop"

    this._status = this.el.querySelector('[data-role="meeting-ask-heard-status"]')
    this._text = this.el.querySelector('[data-role="meeting-ask-heard-text"]')
    this._window = this.el.querySelector('[data-role="meeting-ask-heard-window"]')

    // Round 4: the window now scrolls instead of clipping. New text stays
    // pinned to the bottom (`_appendText` below) UNLESS the viewer has
    // deliberately scrolled up to read something earlier — this listener
    // is the only thing that notices that and tells `_appendText` to stop
    // yanking the scroll position out from under them.
    this._userScrolledAway = false
    this._onWindowScroll = () => {
      if (!this._window) return
      const distanceFromBottom =
        this._window.scrollHeight - this._window.scrollTop - this._window.clientHeight
      this._userScrolledAway = distanceFromBottom > 12
    }
    if (this._window) this._window.addEventListener("scroll", this._onWindowScroll)

    this._onArmed = (event) => {
      const detail = event && event.detail
      if (!detail) return
      this._activeAgentId = detail.agentId || null
    }

    this._onHeld = (event) => {
      const detail = event && event.detail
      if (!detail || detail.agentId !== this._activeAgentId) return
      // `detail.resume` marks a RE-dispatch from `MeetingPushToTalk.
      // _resumeHoldIfOurs` — the exact same `-armed`/`-held` pair a fresh
      // press sends, fired again after a mid-hold remount so every
      // listener (not just this one) learns the hold is still live. If
      // THIS hook also just resumed (`_resumeFromWindowState` below,
      // which runs from `mounted()` before any listener could have
      // fired), it is already open with whatever text had streamed in
      // before the previous node was destroyed — `_open()` would wipe
      // that back to blank the instant the redispatch arrives. A GENUINE
      // fresh press never carries `resume`, so it always reopens, even if
      // `_isHeld` was left stale true by a caller that skipped `-ended`
      // between two holds.
      if (detail.resume && this._isHeld) return
      this._isHeld = true
      this._open()
    }

    this._onLevel = () => {
      // No-op: this overlay shows what was HEARD, not the outgoing mic
      // level — that meter stays on `MeetingAskFloorVeil`'s card. Kept as
      // an explicit listener slot (rather than simply never subscribing)
      // so a future reviewer sees this was a deliberate non-use, not a
      // gap nobody noticed.
    }

    // "Done" (canvas) — the physical release. See the moduledoc for why
    // this does not wait on `meeting_ask_outcome`.
    this._onEnded = (event) => {
      const detail = event && event.detail
      if (detail && detail.agentId !== this._activeAgentId) return
      this._isHeld = false
      this._close()
    }

    this._onEarlyRelease = (event) => {
      const detail = event && event.detail
      if (detail && detail.agentId !== this._activeAgentId) return
      this._isHeld = false
      this._activeAgentId = null
    }

    // A rejection arriving while this box is open (`held-by-other`, in
    // practice — the client-side rejections all fire before 380ms, so
    // this box is never open for them) keeps it up for
    // `INTERRUPTED_CLOSE_MS`, same window as the veil's inline error
    // line, then closes — "until done or 2s after a failure" (canvas).
    // Deliberately NOT gated on `_isHeld`, same as the veil's own
    // `_onRejected`: a server rejection never dispatches `-ended` (see
    // moduledoc), so waiting for the key to physically come up first
    // could wait forever.
    this._onRejected = () => {
      if (!this.isOpen()) return
      this._clearCloseTimer()
      this._closeTimer = setTimeout(() => this._close(), INTERRUPTED_CLOSE_MS)
    }

    this._onResize = () => {
      if (this.isOpen()) this._reposition()
    }

    window.addEventListener("meeting:push-to-talk-armed", this._onArmed)
    window.addEventListener("meeting:push-to-talk-held", this._onHeld)
    window.addEventListener("meeting:push-to-talk-level", this._onLevel)
    window.addEventListener("meeting:push-to-talk-ended", this._onEnded)
    window.addEventListener("meeting:push-to-talk-early-release", this._onEarlyRelease)
    window.addEventListener("meeting:push-to-talk-rejected", this._onRejected)
    window.addEventListener("resize", this._onResize)
    window.addEventListener("scroll", this._onResize, true)

    this.handleEvent("meeting_ask_transcript_chunk", (payload) => {
      if (!payload || payload.agent_id !== this._activeAgentId) return
      this._appendText(payload.text)
    })

    this._resumeFromWindowState()
  },

  // Mirrors `MeetingPushToTalk._resumeHoldIfOurs`: if `window`'s one
  // hold-state record says a hold is already in progress when this node
  // mounts, a previous overlay node was destroyed mid-hold by a server
  // re-render, not by the finger coming up. Reopen immediately with
  // whatever text had already streamed in, rather than starting blank and
  // waiting for events that — for a hold already past the threshold —
  // will never arrive again (the button only dispatches `-held` once per
  // press; see its own resume path for the one case that re-dispatches).
  _resumeFromWindowState() {
    const hold = getHold()
    if (!hold || !hold.agentId) return

    this._activeAgentId = hold.agentId
    if (!hold.heldLongEnough) return

    this._isHeld = true
    if (this._status) this._status.textContent = "Listening while you hold"
    if (this._text) this._text.textContent = hold.text || ""
    this._userScrolledAway = false
    this._clearCloseTimer()
    this._reposition()
    this.el.dataset.open = "true"
    this._scrollToBottom()
  },

  destroyed() {
    window.removeEventListener("meeting:push-to-talk-armed", this._onArmed)
    window.removeEventListener("meeting:push-to-talk-held", this._onHeld)
    window.removeEventListener("meeting:push-to-talk-level", this._onLevel)
    window.removeEventListener("meeting:push-to-talk-ended", this._onEnded)
    window.removeEventListener("meeting:push-to-talk-early-release", this._onEarlyRelease)
    window.removeEventListener("meeting:push-to-talk-rejected", this._onRejected)
    window.removeEventListener("resize", this._onResize)
    window.removeEventListener("scroll", this._onResize, true)
    if (this._window) this._window.removeEventListener("scroll", this._onWindowScroll)
    this._clearCloseTimer()
  },

  // Task 01a0fa7e-afd7 stage 5/6 (round 2 of this task's review) — see
  // the moduledoc's "`updated()`" section for the full mechanism. LiveView
  // fires `updated()` on an ignored element specifically when its live
  // `dataset` no longer equals the fresh render's `dataset` — i.e. exactly,
  // and only, when a patch has just stomped one of these two attributes.
  // Reasserting from `_isHeld`/`_placement` (this hook's own JS state)
  // closes the window back down to a single patch's duration instead of
  // leaving the overlay stuck closed (or wrongly placed) for the rest of
  // a hold.
  updated() {
    this.el.dataset.open = this._isHeld ? "true" : "false"
    this.el.dataset.placement = this._placement
  },

  /** Public, for tests: is the overlay currently showing. */
  isOpen() {
    return this.el.dataset.open === "true"
  },

  _open() {
    if (this._status) this._status.textContent = "Listening while you hold"
    if (this._text) this._text.textContent = ""
    this._userScrolledAway = false
    this._clearCloseTimer()
    this._reposition()
    this.el.dataset.open = "true"
    this._scrollToBottom()
  },

  _close() {
    this.el.dataset.open = "false"
    this._activeAgentId = null
    this._isHeld = false
    this._userScrolledAway = false
    this._clearCloseTimer()
  },

  _clearCloseTimer() {
    if (this._closeTimer) {
      clearTimeout(this._closeTimer)
      this._closeTimer = null
    }
  },

  // Round 4: newest word pinned to the bottom, unless the viewer has
  // scrolled up to read something earlier (`_onWindowScroll` above) — in
  // which case new text keeps arriving in the DOM but the scroll position
  // itself is left alone, matching "you can scroll back up inside the box
  // while you talk" (canvas 01a0fdf2-804d).
  _scrollToBottom() {
    if (!this._window) return
    this._window.scrollTop = this._window.scrollHeight
  },

  // The fixed 72px window plus the flex-end inner container (markup) do
  // all the "push old lines up and out" work — this only ever appends.
  // Gated on `_isHeld`, NOT `isOpen()`/`this.el.dataset.open`: a chunk can
  // in principle arrive for a press that has not yet crossed the 380ms
  // threshold (armed but not held), and appending it there would show
  // text nobody asked to see yet — `_open` already clears this on a
  // genuine open, so without this gate the only consequence would be a
  // stray append sitting invisibly until the next open wipes it, but
  // there is no reason to carry that for a release that never opens the
  // box at all (an early release). `_isHeld` is this hook's own JS state,
  // the same one `updated()` reasserts `data-open` from — reading the DOM
  // attribute here instead was the second half of the round-2 review's
  // bug: a real transcript chunk can land in the same tick as a
  // `phx-update="ignore"` stomp that has transiently reverted `data-open`
  // to the template's stale `"false"` (see moduledoc), and `isOpen()`
  // would read that stale value and silently drop a chunk the server
  // genuinely delivered while the hold was still live.
  _appendText(text) {
    if (!this._isHeld || !this._text || typeof text !== "string" || text === "") return
    const existing = this._text.textContent || ""
    this._text.textContent = existing ? `${existing} ${text}` : text
    // Mirrored onto `window` so a mid-hold remount of THIS element can
    // restore the text instead of reopening blank — see
    // `_resumeFromWindowState` and `./lib/ptt_hold_state`.
    appendHoldText(text)
    if (!this._userScrolledAway) this._scrollToBottom()
  },

  // ── Positioning ──────────────────────────────────────────────────────

  _reposition() {
    if (typeof document === "undefined") return

    const isDesktop =
      typeof window.matchMedia === "function" &&
      window.matchMedia(`(min-width: ${DESKTOP_MIN_WIDTH_PX}px)`).matches

    const desktopRect = isDesktop ? this._desktopRect() : null

    if (desktopRect && !this._wouldOverlapAControl(desktopRect)) {
      this._applyRect(desktopRect, "desktop")
      return
    }

    this._applyRect(this._phoneRect(), "phone")
  },

  // Left edge 8px outside the rail's right border, top aligned with the
  // held row, width `min(360, stage width - 32)` (canvas). Returns null
  // when either the held row or the rail cannot be found (e.g. the row
  // unmounted mid-hold) — the caller falls back to the phone placement,
  // which needs neither.
  _desktopRect() {
    const row = this._heldRowEl()
    const rail = document.querySelector('[data-role="meeting-left-rail"]')
    if (!row || !rail) return null

    const rowRect = row.getBoundingClientRect()
    const railRect = rail.getBoundingClientRect()
    const stage = document.querySelector('[data-pane="center-stage"]')
    const stageWidth =
      stage && typeof stage.getBoundingClientRect === "function"
        ? stage.getBoundingClientRect().width
        : window.innerWidth - railRect.width

    const width = Math.max(
      0,
      Math.min(DESKTOP_MAX_WIDTH_PX, stageWidth - DESKTOP_SIDE_MARGIN_PX * 2)
    )

    return {
      left: railRect.right + DESKTOP_GAP_PX,
      top: rowRect.top,
      width,
    }
  },

  // Fixed to the top of the viewport, 16px gutters, below the header bar
  // and above the People sheet (which sits lower on the screen, so simply
  // anchoring near the top already clears it — canvas).
  _phoneRect() {
    const header = document.querySelector("header")
    const headerBottom =
      header && typeof header.getBoundingClientRect === "function"
        ? header.getBoundingClientRect().bottom
        : DEFAULT_HEADER_HEIGHT_PX

    return {
      left: PHONE_GUTTER_PX,
      top: headerBottom + PHONE_TOP_GAP_PX,
      width: Math.max(0, window.innerWidth - PHONE_GUTTER_PX * 2),
    }
  },

  _applyRect(rect, placement) {
    this.el.style.left = `${rect.left}px`
    this.el.style.top = `${rect.top}px`
    this.el.style.width = `${rect.width}px`
    this._placement = placement
    this.el.dataset.placement = placement
  },

  _heldRowEl() {
    const agentId = this._activeAgentId
    if (!agentId || typeof CSS === "undefined" || typeof CSS.escape !== "function") return null

    const button = document.querySelector(
      `[data-role="meeting-agent-hold-to-talk"][data-agent-id="${CSS.escape(agentId)}"]`
    )
    return button && typeof button.closest === "function"
      ? button.closest('[data-participant-type="agent"]')
      : null
  },

  // Must never cover the Ask key it belongs to, any mute/remove button,
  // or a failure line's "Try again" — checked against every such control
  // currently in the rail, not only the held row's own, because a tall
  // overlay anchored near the bottom of a long roster can reach into the
  // row below it.
  _wouldOverlapAControl(rect) {
    const overlayRect = {
      left: rect.left,
      top: rect.top,
      right: rect.left + rect.width,
      // Height is unknown until the fixed CSS box exists; a status line
      // plus the 72px window plus padding is comfortably under 160px in
      // every themed build, and overlap only needs to be conservative —
      // false positives cost a desktop-only cosmetic fallback, false
      // negatives cost a hidden control, so this rounds generously up.
      bottom: rect.top + 160,
    }

    const controls = document.querySelectorAll(
      [
        '[data-role="meeting-agent-hold-to-talk"]',
        // Round 4: the bare "Remove from meeting" button became the Kick
        // ✕ (`meeting-agent-kick`), which can itself be replaced by the
        // inline confirm (`meeting-agent-kick-confirm`, holding Cancel/
        // Remove) — both need to stay reachable under the overlay, same
        // as the old single button did.
        '[data-role="meeting-agent-kick"]',
        '[data-role="meeting-agent-kick-confirm"]',
        '[data-role="meeting-agent-remove-retry"]',
        '[data-role="meeting-agent-mute-retry"]',
        '[data-role="meeting-agent-mute"]',
      ].join(", ")
    )

    for (const control of controls) {
      if (typeof control.getBoundingClientRect !== "function") continue
      const controlRect = control.getBoundingClientRect()
      const intersects =
        overlayRect.left < controlRect.right &&
        overlayRect.right > controlRect.left &&
        overlayRect.top < controlRect.bottom &&
        overlayRect.bottom > controlRect.top

      if (intersects) return true
    }

    return false
  },
}

export default MeetingAskHeardOverlay
