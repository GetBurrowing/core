// SectionReorderTouch hook — Pointer Events long-press drag-reorder for the
// MOBILE channel-browser overlay's sub-org sections (chat sidebar mobile
// Stage 3; gesture engine extracted in channel-row reorder Stage 2).
//
// The desktop rail's SectionReorder hook uses HTML5 drag-and-drop
// (dragstart/dragover/dataTransfer), which never fires on touch, so the
// mobile drawer gets this separate implementation.
//
// The long-press machinery (400ms hold, 10px slop, window-scoped listeners,
// pointer capture, phantom-drag teardown, search guard) lives in
// lib/long_press_drag.js — shared with RowReorderTouch. This file is only the
// section-scale specifics: what counts as a drag source, how the candidate
// drop target is highlighted, and what gets pushed on drop.
//
// Server contract: on drop we push the SAME `section_reordered {from, to}`
// event desktop sends (ChatLive handle_event -> Chat.Sidebar.put_section_order/2
// -> per-user `chat_section_order` JSONB pref). Zero backend change; identity
// is `data-section-id` (stable, unique — color/slug are not). Pinned + DMs
// are excluded at the source: they render no handle and carry
// data-section-reorderable="false", so they can never be a drag source or
// drop target regardless of gesture.
import { createLongPressDrag } from "./lib/long_press_drag";

const SectionReorderTouch = {
  mounted() {
    this._drag = createLongPressDrag(this, {
      handleSelector: ".channel-section-drag-handle",
      activeClass: "section-touch-drag-active",

      resolveSource: (handle) => {
        const section = handle.closest("[data-section-reorderable]");
        if (!section || section.dataset.sectionReorderable !== "true") return null;
        if (!section.dataset.sectionId) return null;
        return { el: section, id: section.dataset.sectionId };
      },

      onBegin: (source) => {
        source.el.classList.add("channel-section--dragging");
      },

      onMove: (source, x, y) => {
        const target = this._sectionAt(x, y);
        this._clearDropTargets();
        if (target && target !== source.el) {
          target.classList.add("channel-section--drop-target");
        }
      },

      onDrop: (source, x, y) => {
        const target = this._sectionAt(x, y);
        const targetId = target && target.dataset.sectionId;
        if (targetId && targetId !== source.id) {
          this.pushEvent("section_reordered", { from: source.id, to: targetId });
        }
      },

      onTeardown: (source) => {
        if (source) source.el.classList.remove("channel-section--dragging");
        this._clearDropTargets();
      },
    });
    this._drag.attach();
  },

  destroyed() {
    this._drag.detach();
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
};

export default SectionReorderTouch;
