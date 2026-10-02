/**
 * A hold's state, OUTSIDE any single hook instance's lifetime (task
 * 01a0fdef round 4 — "touch it" canvases 01a0fdef-107a / 01a0fdf2-804d).
 *
 * ## Why this exists: `updated()` is necessary but not sufficient
 *
 * `MeetingPushToTalk.updated()` and `MeetingAskHeardOverlay.updated()`
 * both already correct for `phx-update="ignore"`'s real contract — a
 * server patch that stomps a `data-*` attribute on an ignored element is
 * re-asserted from the hook's OWN `this._pressed`/`this._isHeld` the next
 * time `updated()` fires. That fix closes the window down to a single
 * patch's duration. It does nothing at all for a DIFFERENT failure Dalton
 * named in his round-4 report: a server re-render that does not patch the
 * button/overlay element but RECREATES it — a brand-new DOM node, which
 * means a brand-new hook instance, `mounted()` running from scratch with
 * `this._pressed = false` / `this._isHeld = false`. There is no stale
 * attribute to reassert in that case; the JS object that remembered the
 * hold is simply gone, which reads exactly like "the transcript box dies
 * at about a quarter second, no matter what" — the first LiveView render
 * that happens to replace rather than patch the subtree (a tick, a
 * transcript chunk, a mobile/desktop rail swap) ends the hold from the
 * hook's point of view even though the finger never left the glass.
 *
 * The fix is to stop trusting `this` to survive. The one hold a page can
 * have (there is only ever one floor a viewer can claim at a time, same
 * invariant `MeetingAskFloorVeil`/`MeetingAskHeardOverlay` already lean
 * on for being singletons) is kept on `window`, which a hook instance's
 * destruction never touches. A fresh `mounted()` — on the SAME agent's
 * button or the shared overlay — reads this object first and RESUMES
 * instead of starting cold:
 *
 *   - The button re-applies `data-pressed`/`data-held` immediately, and
 *     if a pointerId is recorded, calls `setPointerCapture(pointerId)` on
 *     ITSELF — the Pointer Events spec does not require the element
 *     calling `setPointerCapture` to be the one that received the
 *     original `pointerdown`, only that the pointerId is still active —
 *     so a brand-new button element can reacquire real OS-level capture
 *     for a hold that started on a node which no longer exists.
 *   - The overlay re-opens with whatever text had already streamed in,
 *     rather than starting blank, so a transcript mid-sentence does not
 *     visibly reset.
 *
 * Every mutation below is a plain, synchronous write to one object on
 * `window` — no persistence across a reload, no cross-tab sharing, and
 * nothing here waits on a server round-trip. It exists only to outlive a
 * single hook instance within one already-open page.
 */

const KEY = "__meetingPushToTalkHold"

function store() {
  if (typeof window === "undefined") return null
  if (!window[KEY]) window[KEY] = null
  return window
}

/** The current hold, or null if nothing is held right now. */
export function getHold() {
  const w = store()
  return w ? w[KEY] : null
}

/** Start (or replace) the one hold the page can have. */
export function beginHold(fields) {
  const w = store()
  if (!w) return
  w[KEY] = {
    agentId: fields.agentId || null,
    agentName: fields.agentName || "",
    pointerId: typeof fields.pointerId === "number" ? fields.pointerId : null,
    pressedAt: typeof fields.pressedAt === "number" ? fields.pressedAt : Date.now(),
    heldLongEnough: Boolean(fields.heldLongEnough),
    text: "",
  }
}

/** Patch fields on the current hold. A no-op if nothing is held. */
export function patchHold(fields) {
  const w = store()
  if (!w || !w[KEY]) return
  w[KEY] = { ...w[KEY], ...fields }
}

/** Append streamed transcript text onto the current hold's buffer. */
export function appendHoldText(text) {
  const w = store()
  if (!w || !w[KEY] || typeof text !== "string" || text === "") return
  const existing = w[KEY].text || ""
  w[KEY] = { ...w[KEY], text: existing ? `${existing} ${text}` : text }
}

/** End the hold. Idempotent. */
export function clearHold() {
  const w = store()
  if (!w) return
  w[KEY] = null
}
