// SectionReorder hook — HTML5 drag-and-drop for the chat rail's sub-org
// section headers (chat plan v2 Stage 3).
//
// Attach to the <nav> that wraps the .channel-section elements. Only
// sections with `data-section-reorderable="true"` (sub-orgs) are draggable;
// Pinned + DMs are pinned to the top and have the drag handle hidden in
// the template, so they're never the dragstart source.
//
// Drop semantics: drop ON another sub-org section reorders the dragged
// section to the dropped-on section's slot. The full new order is computed
// server-side from the `{from, to}` slugs (see ChatLive
// "section_reordered" handler) so the JS stays dumb — no client-side
// optimistic mutation of order.
const SectionReorder = {
  mounted() {
    this._draggedSlug = null;
    this._draggedEl = null;

    // ── Drag start ─────────────────────────────────────────────────────
    this._onDragStart = (e) => {
      const section = e.target.closest(".channel-section");
      if (!section) return;
      if (section.dataset.sectionReorderable !== "true") return;
      // Only react when the drag originated on the section's drag handle.
      // Without this, accidental drags on a row link would also fire.
      if (!e.target.closest(".channel-section-drag-handle")) return;

      this._draggedSlug = section.dataset.sectionSlug || null;
      this._draggedEl = section;
      if (!this._draggedSlug) return;

      e.dataTransfer.effectAllowed = "move";
      e.dataTransfer.setData("text/plain", this._draggedSlug);

      // Apply dragging class on the next frame so the drag image captures
      // the section's original appearance, then fade the source row.
      requestAnimationFrame(() => {
        section.classList.add("channel-section--dragging");
      });
    };

    // ── Drag over (allow drop + highlight target) ──────────────────────
    this._onDragOver = (e) => {
      const section = e.target.closest(".channel-section");
      if (!section) return;
      if (section.dataset.sectionReorderable !== "true") return;
      if (!this._draggedSlug) return;
      if (section === this._draggedEl) return;

      e.preventDefault();
      e.dataTransfer.dropEffect = "move";

      this._clearDropTargets();
      section.classList.add("channel-section--drop-target");
    };

    // ── Drag leave ─────────────────────────────────────────────────────
    this._onDragLeave = (e) => {
      const section = e.target.closest(".channel-section");
      if (section && !section.contains(e.relatedTarget)) {
        section.classList.remove("channel-section--drop-target");
      }
    };

    // ── Drop ───────────────────────────────────────────────────────────
    this._onDrop = (e) => {
      e.preventDefault();
      this._clearDropTargets();

      const section = e.target.closest(".channel-section");
      if (!section || !this._draggedSlug) return;
      if (section.dataset.sectionReorderable !== "true") return;

      const targetSlug = section.dataset.sectionSlug;
      if (!targetSlug || targetSlug === this._draggedSlug) return;

      this.pushEvent("section_reordered", {
        from: this._draggedSlug,
        to: targetSlug,
      });
    };

    // ── Drag end (cleanup, fires whether drop succeeded or not) ────────
    this._onDragEnd = () => {
      if (this._draggedEl) {
        this._draggedEl.classList.remove("channel-section--dragging");
      }
      this._clearDropTargets();
      this._draggedSlug = null;
      this._draggedEl = null;
    };

    this.el.addEventListener("dragstart", this._onDragStart);
    this.el.addEventListener("dragover", this._onDragOver);
    this.el.addEventListener("dragleave", this._onDragLeave);
    this.el.addEventListener("drop", this._onDrop);
    this.el.addEventListener("dragend", this._onDragEnd);
  },

  destroyed() {
    this.el.removeEventListener("dragstart", this._onDragStart);
    this.el.removeEventListener("dragover", this._onDragOver);
    this.el.removeEventListener("dragleave", this._onDragLeave);
    this.el.removeEventListener("drop", this._onDrop);
    this.el.removeEventListener("dragend", this._onDragEnd);
  },

  _clearDropTargets() {
    this.el
      .querySelectorAll(".channel-section--drop-target")
      .forEach((s) => s.classList.remove("channel-section--drop-target"));
  },
};

export default SectionReorder;
