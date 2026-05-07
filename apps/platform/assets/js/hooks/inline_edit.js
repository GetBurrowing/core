// InlineEdit — wraps an inline-edit input so that:
//
//   1. on Enter (without Shift) the current value is pushed as the configured
//      event (default `update_task_title`). We push an explicit event in
//      addition to the `phx-blur` that fires on focus loss so behavior is
//      predictable on slow connections / when blur and Enter race.
//   2. Escape blurs the field (which fires the wired `phx-blur` handler,
//      typically `update_task_title`, so the value is committed on cancel).
//   3. the field auto-focuses and selects its existing text on mount.
//
// HTML usage on the input that replaces the title once editing starts:
//   <input phx-hook="InlineEdit" phx-blur="update_task_title"
//          phx-value-task-id={id} data-submit-event="update_task_title" />

const InlineEdit = {
  mounted() {
    if (this.el.tagName === "INPUT" || this.el.tagName === "TEXTAREA") {
      this.el.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && !e.shiftKey && this.el.tagName === "INPUT") {
          e.preventDefault()
          const event = this.el.dataset.submitEvent || "update_task_title"
          const taskId = this.el.dataset.taskId || this.el.getAttribute("phx-value-task-id")
          this.pushEvent(event, { value: this.el.value, "task-id": taskId })
        } else if (e.key === "Escape") {
          this.el.blur()
        }
      })

      // Auto-focus + select existing text so the user can type to replace.
      requestAnimationFrame(() => {
        this.el.focus()
        try { this.el.select() } catch (_) {}
      })
    }
  },
}

export default InlineEdit
