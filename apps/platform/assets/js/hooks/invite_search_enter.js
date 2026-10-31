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

export function handleEnter(hook, e) {
  if (e.key !== "Enter" || e.isComposing) return false
  e.preventDefault()
  const target = hook.el.getAttribute("phx-target")
  hook.pushEventTo(target || hook.el, hook.el.dataset.commitEvent, { value: hook.el.value })
  return true
}

const InviteSearchEnter = {
  mounted() {
    this.onKeydown = (e) => handleEnter(this, e)
    this.el.addEventListener("keydown", this.onKeydown)
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown)
  },
}

export default InviteSearchEnter
