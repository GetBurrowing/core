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

/**
 * Pure detection function for the removal-warning gate (editable-messages
 * contract Section f, Policy 4).
 *
 * Whitespace-tokenize both strings, normalize each token by stripping
 * leading/trailing Unicode punctuation/symbol code points and
 * lowercasing, then return true iff any normalized prev-token is missing
 * from the normalized next-set.
 *
 * Server-aligned in structure: the server's compute_removed_substrings/2
 * (apps/platform/lib/platform/chat/messages/edit.ex) uses the same
 * whitespace split (~r/\s+/, trim: true) and the same set-membership
 * check. The client adds light punctuation+case normalization so an
 * additive edit that moves trailing/leading punctuation (e.g.
 * "tomorrow?" → "tomorrow at 10am?") no longer trips the user-facing
 * warning. The server may still surface those tokens in the agent
 * payload — that's out of scope for this predicate, which only gates
 * the pre-submit warning modal where false positives erode trust.
 *
 * Acceptable false positives (matching or relaxing server behavior):
 *   - URL edits: a URL is a single whitespace-bounded token, so any
 *     change to it flags removal.
 *   - Repeated-word collapses: "go go go" → "go" reports no removal
 *     because token sets are identical — matches server.
 *   - Apostrophe-contraction expansions: "don't" → "do not" reports
 *     removal because the token "don't" is not in {do, not}. Fixing
 *     this would require a contraction table; out of scope for Stage 2.
 */
export function shortenedOrRemoved(original, next) {
  const prevTokens = tokenize(original)
  const nextSet = new Set(tokenize(next))
  return prevTokens.some(t => !nextSet.has(t))
}

function tokenize(s) {
  return s
    .split(/\s+/)
    .map(t => t.toLowerCase().replace(/^[\p{P}\p{S}]+|[\p{P}\p{S}]+$/gu, ""))
    .filter(t => t.length > 0)
}

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
      this.flagInput.value =
        shortenedOrRemoved(this.original, this.textarea.value) ? "true" : "false"
    }

    this.textarea.addEventListener("keydown", this.onKeyDown)
    this.textarea.addEventListener("input", this.onInput)
  },

  destroyed() {
    if (!this.textarea) return
    this.textarea.removeEventListener("keydown", this.onKeyDown)
    this.textarea.removeEventListener("input", this.onInput)
  }
}

export default MessageEditor
