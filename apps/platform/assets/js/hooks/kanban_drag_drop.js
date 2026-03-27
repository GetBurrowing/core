// KanbanDragDrop hook — HTML5 drag-and-drop for task cards between kanban columns.
// Attach to the kanban board container. Cards with [data-task-id][draggable="true"]
// become draggable; columns with [data-column] become drop targets.
const KanbanDragDrop = {
  mounted() {
    this._draggedTaskId = null;
    this._sourceColumn = null;

    // ── Drag start ─────────────────────────────────────────────────────
    this._onDragStart = (e) => {
      const card = e.target.closest("[data-task-id]");
      if (!card) return;

      this._draggedTaskId = card.dataset.taskId;
      this._sourceColumn = card.closest("[data-column]")?.dataset.column || null;

      e.dataTransfer.effectAllowed = "move";
      e.dataTransfer.setData("text/plain", this._draggedTaskId);

      // Apply dragging class after a frame so the drag image captures the
      // original appearance, then the source card fades out.
      requestAnimationFrame(() => {
        card.classList.add("kanban-dragging");
      });
    };

    // ── Drag end (cleanup) ─────────────────────────────────────────────
    this._onDragEnd = (e) => {
      const card = e.target.closest("[data-task-id]");
      if (card) {
        card.classList.remove("kanban-dragging");
      }
      this._clearHighlights();
      this._draggedTaskId = null;
      this._sourceColumn = null;
    };

    // ── Drag over (allow drop + highlight) ─────────────────────────────
    this._onDragOver = (e) => {
      const column = e.target.closest("[data-column]");
      if (!column) return;

      e.preventDefault();
      e.dataTransfer.dropEffect = "move";

      // Highlight only the hovered column
      this._clearHighlights();
      column.classList.add("kanban-drag-over");
    };

    // ── Drag leave ─────────────────────────────────────────────────────
    this._onDragLeave = (e) => {
      const column = e.target.closest("[data-column]");
      if (column && !column.contains(e.relatedTarget)) {
        column.classList.remove("kanban-drag-over");
      }
    };

    // ── Drop ───────────────────────────────────────────────────────────
    this._onDrop = (e) => {
      e.preventDefault();
      this._clearHighlights();

      const column = e.target.closest("[data-column]");
      if (!column || !this._draggedTaskId) return;

      const targetColumn = column.dataset.column;

      // No-op if dropped on same column
      if (targetColumn === this._sourceColumn) return;

      this.pushEvent("kanban_drop", {
        task_id: this._draggedTaskId,
        column: targetColumn,
      });

      this._draggedTaskId = null;
      this._sourceColumn = null;
    };

    this.el.addEventListener("dragstart", this._onDragStart);
    this.el.addEventListener("dragend", this._onDragEnd);
    this.el.addEventListener("dragover", this._onDragOver);
    this.el.addEventListener("dragleave", this._onDragLeave);
    this.el.addEventListener("drop", this._onDrop);
  },

  destroyed() {
    this.el.removeEventListener("dragstart", this._onDragStart);
    this.el.removeEventListener("dragend", this._onDragEnd);
    this.el.removeEventListener("dragover", this._onDragOver);
    this.el.removeEventListener("dragleave", this._onDragLeave);
    this.el.removeEventListener("drop", this._onDrop);
  },

  _clearHighlights() {
    this.el
      .querySelectorAll("[data-column]")
      .forEach((col) => col.classList.remove("kanban-drag-over"));
  },
};

export default KanbanDragDrop;
