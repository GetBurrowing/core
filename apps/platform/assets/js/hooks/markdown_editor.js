/**
 * MarkdownEditor hook — sends content updates to the LiveView
 * for server-side markdown rendering and live preview.
 *
 * Used on the org context editor textarea. Debounced input events
 * push "update_preview" with the current content.
 */
const MarkdownEditor = {
  mounted() {
    this._pushUpdate = () => {
      this.pushEvent("update_preview", { content: this.el.value })
    }

    this.el.addEventListener("input", this._pushUpdate)

    // Tab key inserts spaces instead of changing focus
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Tab") {
        e.preventDefault()
        const start = this.el.selectionStart
        const end = this.el.selectionEnd
        const value = this.el.value
        this.el.value = value.substring(0, start) + "  " + value.substring(end)
        this.el.selectionStart = this.el.selectionEnd = start + 2
        this._pushUpdate()
      }
    })

    // Ctrl/Cmd+S triggers save
    this.el.addEventListener("keydown", (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key === "s") {
        e.preventDefault()
        this._save()
      }
    })

    // Save dispatched from toolbar button via JS.dispatch
    this.el.addEventListener("org-context:save", () => {
      this._save()
    })

    this._save = () => {
      this.pushEvent("save_file", { content: this.el.value })
    }
  },

  destroyed() {
    // Cleanup handled by DOM removal
  }
}

export default MarkdownEditor
