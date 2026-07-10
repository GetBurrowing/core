// Shared long-press → drag engine for the mobile drawer's touch reorder
// hooks (channel-row reorder Stage 2). Extracted from SectionReorderTouch
// (chat sidebar mobile Stage 3) so the section- and row-scale consumers share
// ONE copy of the load-bearing gesture machinery instead of forked copies
// where fixes silently rot.
//
// Gesture model (unchanged from the section hook that proved it):
//   * pointerdown on an element matching `handleSelector` inside the hook's
//     root arms a long-press timer. The handle is the ONLY drag origin — a
//     touch starting even ~10px outside it must scroll the rail, never drag.
//   * pointermove beyond the slop radius BEFORE the timer fires disarms it:
//     the user is scrolling, not dragging.
//   * once the timer fires the drag is live: pointermove tracks the finger,
//     pointerup drops, pointercancel aborts.
//
// Tuning values — do not change casually:
//   * LONG_PRESS_MS = 400. Decision #2 (Dalton ENDORSE): pinned inside the
//     350–500ms band. A prior 450ms attempt was reverted because it sat long
//     enough to collide with iOS native text selection on the row label;
//     400ms activates before selection wins while still being deliberate
//     enough not to eat taps.
//   * SLOP_PX = 10. Tolerates natural finger jitter during the hold without
//     misreading a short, slow scroll as "still holding". Larger values eat
//     the start of short scrolls; smaller ones make the hold fail on real
//     thumbs.
//
// Suppression CSS each consumer's handle depends on (app.css) — each rule
// fixes ONE specific failure; removing any of them reintroduces it:
//   * `touch-action: none` on the drag HANDLE ONLY. It tells the browser not
//     to claim touches that start on the handle for scrolling, so we reliably
//     get pointermove instead of pointercancel mid-hold. Putting it on the
//     whole row/section would kill scroll-into-drag.
//   * `user-select: none` applied ONLY while a drag is active (the
//     `activeClass` this engine toggles on the root). Applying it statically
//     would break legitimate text selection in the drawer; applying it never
//     lets iOS start selecting labels mid-drag.
//   * `-webkit-touch-callout: none` on the handle suppresses the iOS
//     long-press copy/paste callout, which otherwise pops at roughly the same
//     threshold as our long-press and swallows the gesture.
//
// Listener topology: pointerdown is on the root (hook.el); move/up/cancel are
// registered on WINDOW for the lifetime of each gesture and removed on
// teardown. This is load-bearing, not style: before pointer capture engages,
// a fast flick that leaves the rail and releases OUTSIDE it never delivers
// pointermove/pointerup to rail-scoped listeners — the long-press timer then
// fires into a released pointer and the hook is wedged in a phantom drag
// (dimmed source, dead handle; on touch, permanently, because every new touch
// gets a fresh pointerId). Found by exactly that gesture in manual testing
// (2026-07-05). For the same reason, a failed setPointerCapture in _beginDrag
// means the pointer is already gone and must tear down, not wait for a
// pointercancel that will never arrive.
//
// Search guard rail: while the drawer list is filtered (data-search-active on
// the ROOT), reorder is disabled outright — a drag over a filtered SUBSET
// would persist an order computed against a partial view. Templates also omit
// the handles while filtering; this is defense-in-depth for a stale DOM.
export const LONG_PRESS_MS = 400;
export const SLOP_PX = 10;

// Options contract (all callbacks receive the source object resolveSource
// returned, so consumers can stash whatever identity they need on it):
//   handleSelector : CSS selector a pointerdown target must match (via
//                    closest()) to arm the gesture.
//   activeClass    : class toggled on hook.el while a drag is live (scope
//                    your `user-select: none` rule to it).
//   resolveSource(handleEl) -> source | null
//                  : validate the press origin and return a consumer-defined
//                    source descriptor, or null to ignore the press.
//   onBegin(source, x, y)    : drag went live (timer fired, capture held);
//                              x/y are the press-origin viewport coords.
//   onMove(source, x, y, e)  : live drag pointermove (preventDefault already
//                              called). Highlight the candidate drop here.
//   onDrop(source, x, y)     : pointerup while dragging. Push the reorder.
//   onTeardown(source)       : always runs last, drag or no drag. Clear any
//                              classes/indicators the consumer added. May be
//                              called with source=null on double-teardown.
export function createLongPressDrag(hook, opts) {
  const state = {
    pointerId: null,
    startX: 0,
    startY: 0,
    timer: null,
    dragging: false,
    handleEl: null,
    source: null,
  };

  const reset = () => {
    state.pointerId = null;
    state.startX = 0;
    state.startY = 0;
    state.timer = null;
    state.dragging = false;
    state.handleEl = null;
    state.source = null;
  };

  const teardown = () => {
    window.removeEventListener("pointermove", onPointerMove);
    window.removeEventListener("pointerup", onPointerUp);
    window.removeEventListener("pointercancel", onPointerCancel);
    if (state.timer) clearTimeout(state.timer);
    if (state.handleEl && state.pointerId !== null) {
      try {
        state.handleEl.releasePointerCapture(state.pointerId);
      } catch (_e) {
        // No capture held — nothing to release.
      }
    }
    hook.el.classList.remove(opts.activeClass);
    opts.onTeardown(state.source);
    reset();
  };

  const beginDrag = () => {
    state.timer = null;
    state.dragging = true;
    hook.el.classList.add(opts.activeClass);
    opts.onBegin(state.source, state.startX, state.startY);
    // Capture keeps pointermove/up flowing to us even when the finger
    // leaves the handle's hit box mid-drag.
    try {
      state.handleEl.setPointerCapture(state.pointerId);
    } catch (_e) {
      // Pointer no longer active — it ended before the timer fired and no
      // pointerup/cancel will ever arrive for it. Abort the phantom drag.
      teardown();
    }
  };

  const onPointerDown = (e) => {
    if (!e.isPrimary || state.pointerId !== null) return;
    if (hook.el.dataset.searchActive === "true") return;

    const handle = e.target.closest(opts.handleSelector);
    if (!handle || !hook.el.contains(handle)) return;

    const source = opts.resolveSource(handle);
    if (!source) return;

    state.pointerId = e.pointerId;
    state.startX = e.clientX;
    state.startY = e.clientY;
    state.handleEl = handle;
    state.source = source;
    state.timer = setTimeout(beginDrag, LONG_PRESS_MS);

    // Gesture-scoped window listeners — see "Listener topology" above.
    window.addEventListener("pointermove", onPointerMove);
    window.addEventListener("pointerup", onPointerUp);
    window.addEventListener("pointercancel", onPointerCancel);
  };

  const onPointerMove = (e) => {
    if (e.pointerId !== state.pointerId) return;

    if (!state.dragging) {
      // Still in the hold window: real movement means the user is
      // scrolling (or gave up), so disarm rather than start a drag late.
      const dx = e.clientX - state.startX;
      const dy = e.clientY - state.startY;
      if (Math.hypot(dx, dy) > SLOP_PX) teardown();
      return;
    }

    e.preventDefault();
    opts.onMove(state.source, e.clientX, e.clientY, e);
  };

  const onPointerUp = (e) => {
    if (e.pointerId !== state.pointerId) return;
    if (state.dragging) opts.onDrop(state.source, e.clientX, e.clientY);
    teardown();
  };

  const onPointerCancel = (e) => {
    if (e.pointerId !== state.pointerId) return;
    teardown();
  };

  return {
    attach() {
      hook.el.addEventListener("pointerdown", onPointerDown);
    },
    detach() {
      teardown();
      hook.el.removeEventListener("pointerdown", onPointerDown);
    },
    // Exposed for consumers that need to know mid-callback (e.g. click
    // suppression after a completed drag).
    isDragging: () => state.dragging,
  };
}
