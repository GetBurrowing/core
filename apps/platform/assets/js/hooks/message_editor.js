/**
 * MessageEditor — keyboard shortcuts + removed-content detection for the
 * inline message editor (task 019e0f29 Stage 5, editable-messages contract
 * Section F.4 + Section d.3).
 *
 * Mounted on the editor's `<form>` element. The form has:
 *   - a `<textarea name="body">` pre-filled with the original content
 *   - a hidden `<input name="removes_content" type="hidden">` whose value
 *     this hook keeps in sync as the user types
 *   - `data-original-content` set to the message's pre-edit content
 *
 * Hook behavior:
 *   - Cmd/Ctrl + Enter on the textarea → submits the form (phx-submit
 *     "save_edit" fires on the LV).
 *   - Escape on the textarea → pushes `cancel_edit` to the LV.
 *   - On every `input` event, compute whether the new content shortens
 *     the original OR removes a contiguous substring of the original.
 *     If yes, set the hidden input's value to "true" so the LV's
 *     save_edit handler can decide whether to surface the removal
 *     warning modal (Policy 4 in the contract).
 *
 * The actual diff broadcast on a successful save is computed
 * server-side in the controller / context layer — this hook only
 * needs a coarse "did the edit shorten / remove anything" signal to
 * gate the pre-submit modal.
 */
const MessageEditor = {
  mounted() {
    this.textarea = this.el.querySelector("textarea[name='body']")
    this.flagInput = this.el.querySelector("input[name='removes_content']")
    this.original = this.el.dataset.originalContent || ""

    if (!this.textarea || !this.flagInput) return

    this.textarea.focus()
    // Place cursor at end of pre-filled content (less surprising than
    // a fresh selection on edit-open).
    const len = this.textarea.value.length
    this.textarea.setSelectionRange(len, len)

    this.onKeyDown = (e) => {
      // Cmd+Enter (mac) or Ctrl+Enter (everywhere else) → submit
      if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault()
        this.el.requestSubmit()
        return
      }

      if (e.key === "Escape") {
        e.preventDefault()
        this.pushEvent("cancel_edit", {})
      }
    }

    this.onInput = () => {
      this.flagInput.value = this.shortenedOrRemoved(this.textarea.value) ? "true" : "false"
    }

    this.textarea.addEventListener("keydown", this.onKeyDown)
    this.textarea.addEventListener("input", this.onInput)
  },

  destroyed() {
    if (!this.textarea) return
    this.textarea.removeEventListener("keydown", this.onKeyDown)
    this.textarea.removeEventListener("input", this.onInput)
  },

  /**
   * Returns true when `next` is shorter than the original OR removes a
   * contiguous substring of the original. Two cases that both indicate
   * the user is dropping text agents may have read:
   *
   *   1. shorter length: trivially shortens — e.g. truncating the
   *      message or deleting words from the middle.
   *   2. equal/longer length BUT a contiguous run of the original is
   *      missing: the user edited mid-message (e.g. replaced a phrase
   *      with a longer one, but the original phrase no longer appears).
   *
   * Detection only; false positives are acceptable (e.g. user reorders
   * words). False negatives — claiming nothing was removed when it was —
   * are not. Mirrors the server-side diff philosophy in the contract.
   */
  shortenedOrRemoved(next) {
    if (next.length < this.original.length) return true

    // Slide a 5-character window across the original; if any window is
    // absent from `next`, we count that as a removal. 5 is small enough
    // to catch deletions of short words and big enough to be tolerant
    // of single-character typos elsewhere.
    if (this.original.length < 5) {
      return !next.includes(this.original)
    }

    for (let i = 0; i <= this.original.length - 5; i++) {
      const window = this.original.slice(i, i + 5)
      if (!next.includes(window)) return true
    }

    return false
  }
}

export default MessageEditor
