// ChannelMembershipDrag — HTML5 drag-and-drop for REORDERING a channel row
// WITHIN its own sub-org section, in personal edit mode only (chat sidebar
// Stage 5, desktop only).
//
// A row drag means exactly one thing: change this channel's position in my
// own copy of the section it already belongs to. It cannot move a channel
// into a different section (task 019fd76a stage 2). Cross-section filing is
// a company-wide act — it re-points canvas read access at the destination
// org — so it lives behind the explicit "Move to organisation…" action and
// its confirmation dialog, not behind a drop. The server refuses a
// cross-section `channel_moved` regardless of what this file does; the
// guards here are affordance only.
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
// Drop semantics: when a channel row is dropped inside ITS OWN section, we
// compute that section's resulting DOM order of channel ids after
// re-inserting the dragged row at the drop position, then push
// `channel_moved` with {channel_id, target_section_id, ordered_ids}. The
// server (`Sidebar.put_channel_order/3`) is the source of truth and
// re-renders; the client DOM mutation is only to read the intended order —
// the LiveView patch corrects any drift. A hover over any OTHER section is
// left un-`preventDefault`ed, so the browser shows the "no drop" cursor and
// no drop event fires there at all.
//
// Movement threshold: native HTML5 drag already requires a press-and-move
// to begin, so a plain click never starts a drag. We additionally guard
// dragstart on the grab handle so clicking the row link still navigates.

// Reorder scopes (task 019fe987). The hook is mounted twice: once around the
// sub-org sections, once around the Pinned block. Two attributes keep them
// apart, and both live on the .channel-section the rows sit in:
//
//   data-row-reorderable="true"  — rows inside me may be reordered. This is a
//     DIFFERENT question from data-section-reorderable, which asks whether the
//     section itself may be dragged to another position, and is what the
//     SectionReorder hook reads. Pinned is locked as a section (it stays at the
//     top of the rail) while its rows reorder freely, so the two answers
//     genuinely differ and one flag cannot carry both.
//
//   data-row-scope="pinned"      — push `pinned_reordered` on drop instead of
//     `channel_moved`. Absent means the channel scope.
//
// A pinned row carries data-space-id and no data-channel-id: the block holds
// DMs, and calling a person a channel in the payload is how a `kind` check
// gets written later.
// A LOCKED row is in the list but not of the arrangement: it renders inside a
// row-reorderable section, and a drag may neither move it nor land among its
// kind. The Pinned block's task rows are the only ones today. They exist
// because the block shows two pin models at once — a task pin is a row in
// `task_chat_pins`, a conversation pin is a position in the user's
// `chat_pinned_spaces` preference — so no single write could reorder both, and
// the designer's 2026-08-12 call was to keep them apart rather than define a
// cross-table order: "it's essentially two separate lists so makes me think to
// not commingle the interactions too much."
//
// Marked with a data attribute rather than a scope test so the rule is one
// rule. A section with no locked rows (every sub-org section) filters nothing
// and behaves exactly as before.
const GRAB_SELECTOR = ".channel-row-grab";
const ROW_SELECTOR = ".channel-row-wrap";
const SECTION_SELECTOR = ".channel-section";
const PINNED_SCOPE = "pinned";

const rowId = (row) => row.dataset.channelId || row.dataset.spaceId || null;
const isLocked = (row) => row.dataset.rowLocked === "true";

// The nearest ancestor that permits ROW reorder, or null. Every gate below
// goes through this, so the two scopes cannot drift apart.
const rowContainer = (target) => {
  const section = target.closest(SECTION_SELECTOR);
  if (!section || section.dataset.rowReorderable !== "true") return null;
  return section;
};

const ChannelMembershipDrag = {
  mounted() {
    this._draggedId = null;
    // The section the dragged row lives in, captured at dragstart. Every
    // later guard compares the hovered section against this, which is what
    // confines a drag to one section. Written in lockstep with `_draggedId`
    // and only ever read while that is non-null, so it needs no separate
    // teardown in `_onDragEnd`.
    //
    // `null` when the dragged row carries no `data-section-id` — a pinned row
    // is the live case, since the Pinned block is one flat list rather than a
    // client section. That is NOT "the same section as everything else
    // lacking one": a missing id means this rule has no opinion on the row,
    // so `_sameSection` below refuses only rows that DO belong to a section
    // and would be leaving it. Leaving it to `undefined === undefined` would
    // rest the whole property on two absent attributes matching by accident.
    this._draggedSectionId = null;

    // Personal "Edit layout" only. Admin "Edit default" no longer renders a
    // channel-row grab handle at all: refiling a channel across orgs is the
    // "Move to organisation…" action's job now.
    this._editMode = () => this.el.dataset.sidebarEdit === "true";

    // May the dragged row be dropped in this section? Only a row that BELONGS
    // to a section is confined to it. A sectionless row (see
    // `_draggedSectionId` above) is outside this rule's scope and is left to
    // whatever governs its own block.
    this._sameSection = (section) =>
      !this._draggedSectionId || section.dataset.sectionId === this._draggedSectionId;

    // ── Drag start — only from a channel-row grab handle ────────────────
    this._onDragStart = (e) => {
      if (!this._editMode()) return;
      if (!e.target.closest(GRAB_SELECTOR)) return;

      const row = e.target.closest(ROW_SELECTOR);
      if (!row) return;

      const id = rowId(row);
      if (!id) return;

      this._draggedId = id;
      this._draggedSectionId = row.dataset.sectionId || null;

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

      const section = rowContainer(e.target);
      if (!section) return;
      // Another section is not a drop target. Returning BEFORE
      // `preventDefault()` is what makes that visible: the browser keeps its
      // default "cannot drop here" cursor and fires no drop event, so the
      // refusal reads during the drag instead of after it.
      if (!this._sameSection(section)) return;

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

      const section = rowContainer(e.target);
      if (!section) return;
      // Same gate as `_onDragOver`, repeated rather than assumed: a drop can
      // still arrive on a section this hook never allowed (a nested handler
      // elsewhere may have called preventDefault), and the server refuses it
      // anyway, so there is nothing to gain by pushing it.
      if (!this._sameSection(section)) return;

      e.preventDefault();
      e.stopPropagation();
      this._clearDropTargets();

      // Pinned scope (task 019fe987): the drop is a reorder of the user's own
      // pin list and nothing else. No target section, and no admin branch —
      // there is no global default for "what the designer pinned".
      if (section.dataset.rowScope === PINNED_SCOPE) {
        const overRow = e.target.closest(ROW_SELECTOR);

        this.pushEvent("pinned_reordered", {
          space_id: this._draggedId,
          ordered_ids: this._computeOrder(section, overRow, e.clientY),
        });
        return;
      }

      const targetSectionId = section.dataset.sectionId;
      if (!targetSectionId) return;

      // Find the row we're dropping before (the row under the cursor), so the
      // reorder lands at the right slot. If dropped below all rows (or onto
      // the header / empty-state), append.
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
    // Locked rows are dropped here, before anything reads a position, so they
    // can appear in neither the computed order nor the anchor search. The
    // server writes the order it is sent, and a locked row's id names a record
    // in a different table — sending one would ask that write to mean two
    // things.
    const rows = Array.from(section.querySelectorAll(ROW_SELECTOR)).filter(
      (row) => !isLocked(row),
    );

    const beforeId = this._insertBeforeId(rows, overRow, clientY);

    const ids = [];
    let inserted = false;
    for (const row of rows) {
      if (rowId(row) === this._draggedId) continue;

      if (!inserted && rowId(row) === beforeId) {
        ids.push(this._draggedId);
        inserted = true;
      }
      ids.push(rowId(row));
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

    // Dropped ONTO a locked row. `rows` no longer contains it, so the scan
    // below would fall through to null and null means APPEND — the bottom of
    // the list, which is the opposite end from where the cursor is. Locked
    // rows render above the movable run (the Pinned block is tasks, then
    // conversations), so the nearest slot the drop is allowed to have is the
    // TOP of that run. Clamp there.
    if (isLocked(overRow)) return rows.length ? rowId(rows[0]) : null;

    const rect = overRow.getBoundingClientRect();
    const overUpperHalf = clientY < rect.top + rect.height / 2;
    if (overUpperHalf && rowId(overRow) !== this._draggedId) {
      return rowId(overRow);
    }

    const overIdx = rows.indexOf(overRow);
    if (overIdx === -1) return null;
    for (let i = overIdx + 1; i < rows.length; i++) {
      if (rowId(rows[i]) !== this._draggedId) {
        return rowId(rows[i]);
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
