// RowReorderTouch hook — Pointer Events long-press drag-reorder for CHANNEL
// ROWS inside the mobile channel-browser overlay (channel-row reorder
// Stage 2; motion polish Stage 3). Mounted on a nested wrapper inside
// #mobile-section-list (one element = one phx-hook; the nav already owns
// SectionReorderTouch). Each hook arms only on its own handle class, so the
// two gestures never contend: a press on a section's ☰ can only start a
// section drag, a press on a row's ☰ can only start a row drag, and a touch
// anywhere else scrolls.
//
// The long-press machinery (400ms hold, 10px slop, window-scoped listeners,
// pointer capture, phantom-drag teardown, search guard) lives in
// lib/long_press_drag.js — shared with SectionReorderTouch.
//
// WITHIN-SECTION ONLY, enforced by CLAMPING (Marlowe decision 2026-07-06 +
// designer rec 12): the candidate slot rubber-bands at the section's
// first/last position and nothing ever renders in another section;
// prevention over snap-back-plus-toast. The server's `channel_moved`
// supports cross-section moves (desktop drag uses it) — deliberately not
// exposed on touch; mobile re-filing should be an explicit "Move to…"
// action if ever wanted, never a gesture slip.
//
// Stage 3 motion model (designer recs 16-19, iOS-native pattern):
//   * Lift — the row itself goes invisible (its vacated space IS the open
//     slot) and a fixed-position GHOST clone tracks the finger, scaled
//     ~1.02 with a shadow. Light haptic where the platform supports it
//     (navigator.vibrate — Android; iOS Safari has no API, degrades to
//     nothing). Non-source sections dim to ~50% (CSS scoped to the
//     .row-touch-drag-active class the engine toggles), teaching the
//     within-section clamp mid-gesture.
//   * Track — sibling rows shift by ±rowHeight via transform: translateY
//     so the open slot follows the candidate position. Transform-only: no
//     height/layout animation anywhere. All slot math uses ROW RECTS
//     SNAPSHOTTED AT DRAG START — live rects move as transforms apply,
//     which would make the candidate flap between two slots (classic
//     drag-reorder wobble). The rail can't scroll mid-drag (touch-action:
//     none on the handle owns the touch), so the snapshot stays valid for
//     the gesture's lifetime.
//   * Drop — ordered ids derive from the same snapshot + final slot; the
//     push is unchanged from Stage 2 (`channel_moved`, zero server change).
//     Teardown clears every inline transform BEFORE the LiveView patch
//     lands, so morphdom never reuses a row carrying a stale offset.
//   * prefers-reduced-motion — CSS swaps the sibling transition for
//     instant position updates; the ghost still tracks the finger (that is
//     direct manipulation, not decorative motion).
import { createLongPressDrag } from "./lib/long_press_drag";

const ROW_SELECTOR = "[data-channel-id]";
const HAPTIC_MS = 10;

const RowReorderTouch = {
  mounted() {
    this._ghost = null;
    this._snapshot = null;

    this._drag = createLongPressDrag(this, {
      handleSelector: ".channel-row-drag-handle",
      activeClass: "row-touch-drag-active",

      resolveSource: (handle) => {
        const row = handle.closest(ROW_SELECTOR);
        if (!row || !row.dataset.channelId) return null;
        const section = row.closest('[data-section-reorderable="true"]');
        if (!section) return null;
        return { el: row, id: row.dataset.channelId, sectionEl: section };
      },

      onBegin: (source, _x, y) => {
        this._takeSnapshot(source, y);
        this._spawnGhost(source, y);
        source.el.classList.add("channel-row-wrap--touch-dragging");
        source.sectionEl.classList.add("channel-section--row-drag-source");
        if (navigator.vibrate) navigator.vibrate(HAPTIC_MS);
      },

      onMove: (source, _x, y) => {
        this._moveGhost(y);
        this._applySlotShifts(this._slotAt(y));
      },

      onDrop: (source, _x, y) => {
        const snap = this._snapshot;
        if (!snap) return;
        const slot = this._slotAt(y);
        if (slot === snap.originSlot) return;

        const others = snap.rows.filter((r) => r.id !== source.id).map((r) => r.id);
        const ids = [...others.slice(0, slot), source.id, ...others.slice(slot)];

        this.pushEvent("channel_moved", {
          channel_id: source.id,
          target_section_id: source.sectionEl.dataset.sectionId,
          ordered_ids: ids,
        });
        // A completed drag ends with pointerup on the handle, and the
        // browser follows it with a synthetic click. Nothing in the row
        // listens for clicks anymore (Stage 2's select-tap was removed),
        // but swallow it anyway so it can't reach a control under the
        // finger's final position.
        this._suppressNextClick();
      },

      onTeardown: (source) => {
        if (this._ghost) {
          this._ghost.remove();
          this._ghost = null;
        }
        if (this._snapshot) {
          this._snapshot.rows.forEach((r) => {
            r.el.style.transform = "";
          });
          this._snapshot = null;
        }
        if (source) {
          source.el.classList.remove("channel-row-wrap--touch-dragging");
          source.sectionEl.classList.remove("channel-section--row-drag-source");
        }
      },
    });
    this._drag.attach();
  },

  destroyed() {
    this._drag.detach();
  },

  // Freeze the section's row geometry for the whole gesture. `originSlot`
  // is the dragged row's index in the list WITHOUT itself — the slot the
  // open gap starts at. `grabOffset` keeps the ghost pinned where the
  // finger actually grabbed the row, not snapped to its top edge.
  _takeSnapshot(source, y) {
    const rows = Array.from(source.sectionEl.querySelectorAll(ROW_SELECTOR)).map((el) => {
      const rect = el.getBoundingClientRect();
      return { el, id: el.dataset.channelId, top: rect.top, height: rect.height };
    });
    const originIndex = rows.findIndex((r) => r.id === source.id);
    this._snapshot = {
      rows,
      draggedId: source.id,
      rowHeight: rows[originIndex].height,
      originIndex,
      originSlot: originIndex,
      grabOffset: y - rows[originIndex].top,
    };
  },

  // Candidate slot (0..n-1 among rows-without-dragged) for the pointer's Y,
  // computed against SNAPSHOTTED midpoints and clamped to the section —
  // a pointer above/below the section rubber-bands to first/last slot.
  _slotAt(y) {
    const snap = this._snapshot;
    const others = snap.rows.filter((r) => r.id !== snap.draggedId);
    // Where the dragged row's TOP would sit, in snapshot coordinates.
    const dragTop = y - snap.grabOffset;
    let slot = 0;
    for (const [i, row] of others.entries()) {
      // Compare against the slot boundary each retained row occupies in the
      // dragged-removed layout: rows before the origin keep their top; rows
      // after it sit one rowHeight higher once the origin gap is "removed".
      const layoutTop = i < snap.originSlot ? row.top : row.top - snap.rowHeight;
      if (dragTop > layoutTop + row.height / 2) slot = i + 1;
    }
    return Math.max(0, Math.min(slot, others.length));
  },

  // Shift siblings so the open gap sits at `slot` — pure transforms against
  // the frozen snapshot; each row is at exactly one of two positions, so
  // repeated calls are idempotent and cheap.
  _applySlotShifts(slot) {
    const snap = this._snapshot;
    const others = snap.rows.filter((r) => r.id !== snap.draggedId);
    others.forEach((row, i) => {
      let shift = 0;
      if (i >= slot && i < snap.originSlot) shift = snap.rowHeight;
      if (i < slot && i >= snap.originSlot) shift = -snap.rowHeight;
      row.el.style.transform = shift ? `translateY(${shift}px)` : "";
    });
  },

  // Fixed-position clone that tracks the finger. Cloned AFTER the source
  // row's classes are still clean (before --touch-dragging lands on it in
  // onBegin's ordering) — spawn first, then mark the source.
  _spawnGhost(source, y) {
    const rect = source.el.getBoundingClientRect();
    const ghost = source.el.cloneNode(true);
    ghost.classList.add("channel-row-ghost");
    ghost.removeAttribute("data-channel-id");
    ghost.style.top = `${rect.top}px`;
    ghost.style.left = `${rect.left}px`;
    ghost.style.width = `${rect.width}px`;
    document.body.appendChild(ghost);
    this._ghost = ghost;
    this._ghostBaseY = rect.top;
    this._ghostGrabY = y;
  },

  _moveGhost(y) {
    if (!this._ghost) return;
    const dy = y - this._ghostGrabY;
    this._ghost.style.transform = `translateY(${dy}px) scale(1.02)`;
  },

  _suppressNextClick() {
    const swallow = (e) => {
      e.stopPropagation();
      e.preventDefault();
    };
    window.addEventListener("click", swallow, { capture: true, once: true });
    setTimeout(() => window.removeEventListener("click", swallow, { capture: true }), 300);
  },
};

export default RowReorderTouch;
