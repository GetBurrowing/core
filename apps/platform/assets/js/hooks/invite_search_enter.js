// InviteSearchEnter (task 01a192d6 stage 3).
//
// Enter in the invite search box commits the highlighted dropdown option.
// Without this, Enter inside the create sheet's form submits the whole form
// and the typed address is silently dropped.
//
// It pushes the RAW typed value rather than clicking a rendered option: the
// dropdown only exists after the 120ms-debounced keyup round trip, so a fast
// type-then-Enter would find no option to click. The server re-resolves the
// value and stages the option the dropdown would highlight.

// The input keeps focus after Enter, and LiveView does not overwrite a
// focused input's value, so the server emptying its query does not empty the
// box. The server replies `staged: true` when it staged something; only then
// is the box cleared, so a refused or ambiguous Enter keeps what was typed.
export function clearIfStaged(el, reply) {
  if (reply && reply.staged) el.value = ""
}

// A TAP on a dropdown row is a plain `phx-click`, so it has no reply to
// clear the box with; the server pushes `invite-search:clear` instead
// (task 01a199ac). The payload names the input it means: the detail panel's
// control uses this hook too, and its box must not clear when a create-sheet
// invite is staged.
export function clearIfTargeted(el, payload) {
  if (payload && payload.id === el.id) el.value = ""
}

export function handleEnter(hook, e) {
  if (e.key !== "Enter" || e.isComposing) return false
  e.preventDefault()
  const target = hook.el.getAttribute("phx-target")
  hook.pushEventTo(
    target || hook.el,
    hook.el.dataset.commitEvent,
    { value: hook.el.value },
    (reply) => clearIfStaged(hook.el, reply),
  )
  return true
}

// Enter's KEYUP must not reach the input's `phx-keyup` search binding: by
// then the box may already be cleared, and an empty search opens a dropdown
// of every member. Enter does not change the text, so nothing is lost.
export function swallowEnterKeyup(e) {
  if (e.key !== "Enter" || e.isComposing) return false
  e.stopPropagation()
  return true
}

const InviteSearchEnter = {
  mounted() {
    this.onKeydown = (e) => handleEnter(this, e)
    this.el.addEventListener("keydown", this.onKeydown)
    this.el.addEventListener("keyup", swallowEnterKeyup)
    this.handleEvent("invite-search:clear", (payload) => clearIfTargeted(this.el, payload))
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown)
    this.el.removeEventListener("keyup", swallowEnterKeyup)
  },
}

export default InviteSearchEnter
