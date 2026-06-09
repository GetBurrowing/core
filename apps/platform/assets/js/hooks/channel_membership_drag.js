// ChannelMembershipDrag — HTML5 drag-and-drop for moving a channel row
// between (or within) sub-org sections in EDIT MODE only (chat sidebar
// Stage 5, desktop only).
//
// Attach to the dedicated <div id="channel-membership-drag"> that the
// template nests INSIDE the SectionReorder <nav> and wraps around the
// .channel-section elements. (Two drag hooks can't share one element —
// each node carries a single phx-hook — so the channel-row drag gets its
// own wrapper div while section-header reorder stays on the <nav>.) The
// hook is a no-op unless the rail is in edit mode: it gates every drag on
// `this.el.dataset.sidebarEdit === "true"`, set from the @sidebar_edit
// assign. In normal mode the drag source isn't even rendered (see below),
// so this guard is belt-and-braces.
//
// Drag source: the `.channel-row-grab` span inside each row. That span —
// not the .channel-row-wrap — carries `draggable="true"` and is `:if`-gated
// on @sidebar_edit, so it's the HTML5 drag SOURCE node and only exists in
// edit mode. dragstart's e.target is therefore the grab span, which the
// `.channel-row-grab` gate matches; a click on the row link still
// navigates because the link isn't draggable.
//
// Coexistence with SectionReorder (on the parent <nav>): that hook drags
// whole section HEADERS (`.channel-section-drag-handle` → `.channel-section`),
// this one drags channel rows. They don't fight because (a) this hook only
// starts a drag when dragstart originates on a `.channel-row-grab` handle,
// and (b) that dragstart calls e.stopPropagation() so it never bubbles up
// to the <nav>'s SectionReorder listener.
//
// Drop semantics: when a channel row is dropped onto (or into) a target
// section, we compute the resulting DOM order of channel ids in the
// TARGET section after re-inserting the dragged row at the drop position,
// then push `channel_moved` with {channel_id, target_section_id,
// ordered_ids}. The server (`Sidebar.put_channel_order/3`) is the source
// of truth and re-renders; the client DOM mutation is only to read the
// intended order — the LiveView patch corrects any drift.
//
// Movement threshold: native HTML5 drag already requires a press-and-move
// to begin, so a plain click never starts a drag. We additionally guard
// dragstart on the grab handle so clicking the row link still navigates.

const GRAB_SELECTOR = ".channel-row-grab";
const ROW_SELECTOR = ".channel-row-wrap";
const SECTION_SELECTOR = ".channel-section";

const ChannelMembershipDrag = {
  mounted() {
    this._draggedId = null;

    // The hook is active in EITHER edit mode: personal "Edit layout"
    // (data-sidebar-edit) reorders/moves channels in the user's own prefs;
    // admin "Edit default" (data-admin-edit, Stage 6) reassigns a channel's
    // org GLOBALLY. `_adminMode()` picks which event the drop pushes.
    this._adminMode = () => this.el.dataset.adminEdit === "true";
    this._editMode = () =>
      this.el.dataset.sidebarEdit === "true" || this._adminMode();

    // ── Drag start — only from a channel-row grab handle ────────────────
    this._onDragStart = (e) => {
      if (!this._editMode()) return;
      if (!e.target.closest(GRAB_SELECTOR)) return;

      const row = e.target.closest(ROW_SELECTOR);
      if (!row) return;

      const id = row.dataset.channelId;
      if (!id) return;

      this._draggedId = id;

      // Stop the section-header reorder hook from also treating this as a
      // section drag (it ignores non-handle starts, but be explicit).
      e.stopPropagation();
      e.dataTransfer.effectAllowed = "move";
      e.dataTransfer.setData("text/plain", id);

      requestAnimationFrame(() => row.classList.add("channel-row-wrap--dragging"));
    };

    // ── Drag over — allow drop + show insertion target ──────────────────
    this._onDragOver = (e) => {
      if (!this._editMode() || !this._draggedId) return;

      const section = e.target.closest(SECTION_SELECTOR);
      if (!section || section.dataset.sectionReorderable !== "true") return;

      e.preventDefault();
      e.dataTransfer.dropEffect = "move";

      // dragover fires many times per second; only sweep + re-mark when the
      // hovered section actually changed, so we avoid thrashing the drop-target
      // class (and its querySelectorAll sweep) on every mousemove tick.
      if (!section.classList.contains("channel-section--channel-drop-target")) {
        this._clearDropTargets();
        section.classList.add("channel-section--channel-drop-target");
      }
    };

    this._onDragLeave = (e) => {
      const section = e.target.closest(SECTION_SELECTOR);
      if (section && !section.contains(e.relatedTarget)) {
        section.classList.remove("channel-section--channel-drop-target");
      }
    };

    // ── Drop — compute the target section's resulting channel order ─────
    this._onDrop = (e) => {
      if (!this._editMode() || !this._draggedId) return;

      const section = e.target.closest(SECTION_SELECTOR);
      if (!section || section.dataset.sectionReorderable !== "true") return;

      e.preventDefault();
      e.stopPropagation();
      this._clearDropTargets();

      const targetSectionId = section.dataset.sectionId;
      if (!targetSectionId) return;

      // Admin-edit (Stage 6): a channel drop is a GLOBAL org reassignment, not
      // a per-user reorder. We only need the channel + the target section; the
      // server resolves the section's org_id and writes chat_spaces.org_id.
      // No ordered_ids — position within the new section is org-default order.
      if (this._adminMode()) {
        this.pushEvent("channel_reassigned", {
          channel_id: this._draggedId,
          target_section_id: targetSectionId,
        });
        return;
      }

      // Personal-edit: find the row we're dropping before (the row under the
      // cursor), so a within-section reorder lands at the right slot. If
      // dropped below all rows (or onto the header / empty-state), append.
      const overRow = e.target.closest(ROW_SELECTOR);
      const orderedIds = this._computeOrder(section, overRow, e.clientY);

      this.pushEvent("channel_moved", {
        channel_id: this._draggedId,
        target_section_id: targetSectionId,
        ordered_ids: orderedIds,
      });
    };

    this._onDragEnd = () => {
      // Query-based sweep instead of clearing the stored reference: a morphdom
      // patch during the drag can replace the dragged node, leaving a stale
      // `this._draggedEl` whose class would never get removed. Clearing every
      // matching row in the live DOM avoids a stuck dragging/opacity class.
      this.el
        .querySelectorAll(".channel-row-wrap--dragging")
        .forEach((row) => row.classList.remove("channel-row-wrap--dragging"));
      this._clearDropTargets();
      this._draggedId = null;
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

  // Build the target section's channel-id order with the dragged channel
  // inserted at the drop position. Reads the existing rows from the DOM
  // (excluding the dragged one, in case it already lives in this section),
  // then resolves a single insertion anchor — the channel id the dragged
  // row should land BEFORE — and splices around it. A null anchor means the
  // drop landed past the last row (or onto an empty section / header), so
  // the dragged id is appended.
  _computeOrder(section, overRow, clientY) {
    const rows = Array.from(section.querySelectorAll(ROW_SELECTOR));

    const beforeId = this._insertBeforeId(rows, overRow, clientY);

    const ids = [];
    let inserted = false;
    for (const row of rows) {
      if (row.dataset.channelId === this._draggedId) continue;

      if (!inserted && row.dataset.channelId === beforeId) {
        ids.push(this._draggedId);
        inserted = true;
      }
      ids.push(row.dataset.channelId);
    }
    if (!inserted) ids.push(this._draggedId);

    return ids.filter(Boolean);
  },

  // Resolve the channel id the dragged row should be inserted BEFORE, using
  // the cursor's vertical midpoint relative to the hovered row:
  //   • upper half of `overRow` → insert before `overRow`
  //   • lower half of `overRow` → insert before the NEXT row (i.e. after
  //     `overRow`); when `overRow` is the last row this yields null → append
  //   • no `overRow` (dropped on header / empty state / past last row) →
  //     null → append
  // `rows` is the section's full row list (dragged row included). We scan
  // forward from `overRow` to the next row that isn't the dragged one, so
  // the anchor is always a real, retained id; dropping on the dragged row's
  // own lower half resolves to the row that follows it.
  _insertBeforeId(rows, overRow, clientY) {
    if (!overRow) return null;

    const rect = overRow.getBoundingClientRect();
    const overUpperHalf = clientY < rect.top + rect.height / 2;
    if (overUpperHalf && overRow.dataset.channelId !== this._draggedId) {
      return overRow.dataset.channelId;
    }

    const overIdx = rows.indexOf(overRow);
    if (overIdx === -1) return null;
    for (let i = overIdx + 1; i < rows.length; i++) {
      if (rows[i].dataset.channelId !== this._draggedId) {
        return rows[i].dataset.channelId;
      }
    }
    return null;
  },

  _clearDropTargets() {
    this.el
      .querySelectorAll(".channel-section--channel-drop-target")
      .forEach((s) => s.classList.remove("channel-section--channel-drop-target"));
  },
};

export default ChannelMembershipDrag;
