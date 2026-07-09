// SectionReorderTouch hook — Pointer Events long-press drag-reorder for the
// MOBILE channel-browser overlay's sub-org sections (chat sidebar mobile
// Stage 3).
//
// The desktop rail's SectionReorder hook uses HTML5 drag-and-drop
// (dragstart/dragover/dataTransfer), which never fires on touch, so the
// mobile drawer gets this separate implementation. It is a SINGLE Pointer
// Events code path — pointerdown/move/up/cancel cover touch, pen, AND mouse —
// not a touchstart fork.
//
// Gesture model:
//   * pointerdown on a `.channel-section-drag-handle` inside a
//     `data-section-reorderable="true"` section arms a long-press timer.
//     The handle is the ONLY drag origin — a touch starting even ~10px
//     outside it must scroll the rail, never drag (Stage 4 checklist #6).
//   * pointermove beyond the slop radius BEFORE the timer fires disarms it:
//     the user is scrolling, not dragging.
//   * once the timer fires the drag is live: pointermove tracks the finger
//     and highlights the section under it; pointerup over another
//     reorderable section pushes the reorder; pointercancel aborts.
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
// Suppression CSS this hook depends on (app.css, .channel-section-drag-handle--touch
// and .section-touch-drag-active) — each rule fixes ONE specific failure;
// removing any of them reintroduces it:
//   * `touch-action: none` on the drag HANDLE ONLY. It tells the browser not
//     to claim touches that start on the handle for scrolling, so we reliably
//     get pointermove instead of pointercancel mid-hold. Putting it on the
//     whole row/section would kill scroll-into-drag: the rail could no longer
//     be scrolled by touches that happen to start on a row.
//   * `user-select: none` applied ONLY while a drag is active (the
//     `.section-touch-drag-active` class this hook toggles on the rail).
//     Applying it statically would break legitimate text selection in the
//     drawer; applying it never lets iOS start selecting the section label
//     mid-drag.
//   * `-webkit-touch-callout: none` on the handle suppresses the iOS
//     long-press copy/paste callout, which otherwise pops over the handle at
//     roughly the same threshold as our long-press and swallows the gesture.
//
// Server contract: on drop we push the SAME `section_reordered {from, to}`
// event desktop sends (ChatLive handle_event -> Chat.Sidebar.put_section_order/2
// -> per-user `chat_section_order` JSONB pref). Zero backend change; identity
// is `data-section-id` (stable, unique — color/slug are not). Pinned + DMs
// are excluded at the source: they render no handle and carry
// data-section-reorderable="false", so they can never be a drag source or
// drop target regardless of gesture.
//
// Listener topology: pointerdown is on the rail (this.el); move/up/cancel are
// registered on WINDOW for the lifetime of each gesture and removed on
// teardown. This is load-bearing, not style: before pointer capture engages,
// a fast flick that leaves the rail and releases OUTSIDE it never delivers
// pointermove/pointerup to rail-scoped listeners — the long-press timer then
// fires into a released pointer and the hook is wedged in a phantom drag
// (dimmed section, dead handle; on touch, permanently, because every new
// touch gets a fresh pointerId). Found by exactly that gesture in manual
// testing (2026-07-05). For the same reason, a failed setPointerCapture in
// _beginDrag means the pointer is already gone and must tear down, not wait
// for a pointercancel that will never arrive.
const LONG_PRESS_MS = 400;
const SLOP_PX = 10;

const SectionReorderTouch = {
  mounted() {
    this._resetState();

    this._onPointerDown = (e) => {
      if (!e.isPrimary || this._pointerId !== null) return;
      // Search guard rail (mobile channel search Stage 1): while the drawer
      // list is filtered (data-search-active on the rail), reorder is
      // disabled outright — a drag over a filtered SUBSET would persist an
      // order computed against a partial view. The template also omits the
      // handles while filtering; this is defense-in-depth for a stale DOM.
      if (this.el.dataset.searchActive === "true") return;

      const handle = e.target.closest(".channel-section-drag-handle");
      if (!handle || !this.el.contains(handle)) return;

      const section = handle.closest("[data-section-reorderable]");
      if (!section || section.dataset.sectionReorderable !== "true") return;
      if (!section.dataset.sectionId) return;

      this._pointerId = e.pointerId;
      this._startX = e.clientX;
      this._startY = e.clientY;
      this._handleEl = handle;
      this._sourceEl = section;
      this._sourceId = section.dataset.sectionId;
      this._timer = setTimeout(() => this._beginDrag(), LONG_PRESS_MS);

      // Gesture-scoped window listeners — see "Listener topology" above.
      window.addEventListener("pointermove", this._onPointerMove);
      window.addEventListener("pointerup", this._onPointerUp);
      window.addEventListener("pointercancel", this._onPointerCancel);
    };

    this._onPointerMove = (e) => {
      if (e.pointerId !== this._pointerId) return;

      if (!this._dragging) {
        // Still in the hold window: real movement means the user is
        // scrolling (or gave up), so disarm rather than start a drag late.
        const dx = e.clientX - this._startX;
        const dy = e.clientY - this._startY;
        if (Math.hypot(dx, dy) > SLOP_PX) this._teardown();
        return;
      }

      e.preventDefault();
      const target = this._sectionAt(e.clientX, e.clientY);
      this._clearDropTargets();
      if (target && target !== this._sourceEl) {
        target.classList.add("channel-section--drop-target");
      }
    };

    this._onPointerUp = (e) => {
      if (e.pointerId !== this._pointerId) return;

      if (this._dragging) {
        const target = this._sectionAt(e.clientX, e.clientY);
        const targetId = target && target.dataset.sectionId;
        if (targetId && targetId !== this._sourceId) {
          this.pushEvent("section_reordered", {
            from: this._sourceId,
            to: targetId,
          });
        }
      }
      this._teardown();
    };

    this._onPointerCancel = (e) => {
      if (e.pointerId !== this._pointerId) return;
      this._teardown();
    };

    this.el.addEventListener("pointerdown", this._onPointerDown);
  },

  destroyed() {
    this._teardown();
    this.el.removeEventListener("pointerdown", this._onPointerDown);
  },

  _beginDrag() {
    this._timer = null;
    this._dragging = true;
    // Scoped user-select suppression — active for the drag's lifetime only
    // (see the suppression-CSS block in the header comment).
    this.el.classList.add("section-touch-drag-active");
    this._sourceEl.classList.add("channel-section--dragging");
    // Capture keeps pointermove/up flowing to us even when the finger
    // leaves the handle's hit box mid-drag.
    try {
      this._handleEl.setPointerCapture(this._pointerId);
    } catch (_e) {
      // Pointer no longer active — it ended before the timer fired and no
      // pointerup/cancel will ever arrive for it. Abort the phantom drag.
      this._teardown();
    }
  },

  // Reorderable section currently under the viewport point, or null. Uses
  // elementFromPoint because pointer capture retargets move events to the
  // handle, so e.target no longer reflects what's under the finger.
  _sectionAt(x, y) {
    const under = document.elementFromPoint(x, y);
    if (!under) return null;
    const section = under.closest('[data-section-reorderable="true"]');
    return section && this.el.contains(section) ? section : null;
  },

  _clearDropTargets() {
    this.el
      .querySelectorAll(".channel-section--drop-target")
      .forEach((s) => s.classList.remove("channel-section--drop-target"));
  },

  _teardown() {
    window.removeEventListener("pointermove", this._onPointerMove);
    window.removeEventListener("pointerup", this._onPointerUp);
    window.removeEventListener("pointercancel", this._onPointerCancel);
    if (this._timer) clearTimeout(this._timer);
    if (this._handleEl && this._pointerId !== null) {
      try {
        this._handleEl.releasePointerCapture(this._pointerId);
      } catch (_e) {
        // No capture held — nothing to release.
      }
    }
    if (this._sourceEl) {
      this._sourceEl.classList.remove("channel-section--dragging");
    }
    this.el.classList.remove("section-touch-drag-active");
    this._clearDropTargets();
    this._resetState();
  },

  _resetState() {
    this._pointerId = null;
    this._startX = 0;
    this._startY = 0;
    this._timer = null;
    this._dragging = false;
    this._handleEl = null;
    this._sourceEl = null;
    this._sourceId = null;
  },
};

export default SectionReorderTouch;
