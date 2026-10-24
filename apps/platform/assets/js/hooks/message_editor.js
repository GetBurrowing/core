/**
 * MessageEditor — keyboard shortcuts and the removal guard for the inline
 * message editor (task 019e0f29 Stage 5; redesign rung 9 stage 4, masters
 * MM `startEdit`, direction canvas 01a1666e node m3 rule 8).
 *
 * Mounted on the editor's `<form>` element, which carries a
 * `<textarea name="body">` pre-filled with the original content and
 * `data-original-content` holding the pre-edit text.
 *
 * Hook behavior (keys: redesign rung 10, stage 4, coverage row 117):
 *   - Enter on the textarea submits the form (phx-submit "save_edit").
 *     Cmd/Ctrl + Enter still saves too.
 *   - Shift + Enter is a newline (the textarea's own behaviour).
 *   - Escape on the textarea pushes `cancel_edit` to the LV.
 *   - On submit (Enter or the Save button), an edit that removes MORE than
 *     half the text asks with the NATIVE `window.confirm`. Cancel keeps the
 *     editor open with the draft and nothing reaches the server; OK lets the
 *     submit through. The server applies `save_edit` directly: there is no
 *     server-side warning step.
 */

export const REMOVES_MOST_CONFIRM = "This edit removes most of the text. Save anyway?"

// Strings are measured in code points, so an emoji counts once.
const len = (s) => [...(s || "").trim()].length

/**
 * True when `next` keeps under half of `original` (both trimmed): the
 * masters' `t.length < orig.length * 0.5`. Removing exactly half does not
 * ask.
 */
export function removesMost(original, next) {
  const before = len(original)
  return before > 0 && len(next) < before * 0.5
}

const MessageEditor = {
  mounted() {
    this.textarea = this.el.querySelector("textarea[name='body']")
    this.original = this.el.dataset.originalContent || ""

    if (!this.textarea) return

    this.textarea.focus()
    // Place cursor at end of pre-filled content (less surprising than
    // a fresh selection on edit-open).
    const len = this.textarea.value.length
    this.textarea.setSelectionRange(len, len)

    this.onKeyDown = (e) => {
      // Enter saves; so do Cmd+Enter (mac) and Ctrl+Enter. Shift+Enter is
      // left to the textarea (a newline), and so is Enter while an IME is
      // composing (it commits the composition).
      if (e.key === "Enter" && !e.isComposing && (!e.shiftKey || e.metaKey || e.ctrlKey)) {
        e.preventDefault()
        this.el.requestSubmit()
        return
      }

      if (e.key === "Escape") {
        e.preventDefault()
        this.pushEvent("cancel_edit", {})
      }
    }

    // Runs on the form, before LiveView's window-level submit binding, so a
    // declined confirm stops the event before LiveView sees it.
    this.onSubmit = (e) => {
      if (!removesMost(this.original, this.textarea.value)) return
      if (window.confirm(REMOVES_MOST_CONFIRM)) return
      e.preventDefault()
      e.stopPropagation()
    }

    this.textarea.addEventListener("keydown", this.onKeyDown)
    this.el.addEventListener("submit", this.onSubmit)
  },

  destroyed() {
    if (!this.textarea) return
    this.textarea.removeEventListener("keydown", this.onKeyDown)
    this.el.removeEventListener("submit", this.onSubmit)
  }
}

export default MessageEditor
