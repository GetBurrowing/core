// FirstRunGoal hook (task 01a19554-fd07 stage 2), on the `/start` goal field.
//
// It does three things and nothing else:
//
// 1. `first_run:fill` (pushed when a chip is clicked) writes the chip's text
//    into the field, focuses it and dispatches an `input` event so
//    `phx-change` syncs `@goal`. A pushed event is needed because morphdom
//    does not reliably re-sync a textarea's value once the member has typed.
//    A chip never submits.
// 2. Enter submits the form (unless the field is blank or an IME is
//    composing).
// 3. Shift+Enter inserts a newline (the browser default, left alone).

// What a keydown should do: "submit", "newline", "block" (Enter on a blank
// field: swallowed, nothing sent) or "none".
export function keyAction(e, value) {
  if (e.key !== "Enter" || e.isComposing) return "none"
  if (e.shiftKey) return "newline"
  return (value || "").trim() === "" ? "block" : "submit"
}

export function fill(el, goal) {
  el.value = goal
  el.focus()
  const end = el.value.length
  if (typeof el.setSelectionRange === "function") el.setSelectionRange(end, end)
  el.dispatchEvent(new Event("input", { bubbles: true }))
}

const FirstRunGoal = {
  mounted() {
    this.handleEvent("first_run:fill", ({ goal }) => fill(this.el, goal))

    this._onKeydown = (e) => {
      const action = keyAction(e, this.el.value)
      if (action === "submit") {
        e.preventDefault()
        if (this.el.form) this.el.form.requestSubmit()
      } else if (action === "block") {
        e.preventDefault()
      }
    }
    this.el.addEventListener("keydown", this._onKeydown)
  },

  destroyed() {
    this.el.removeEventListener("keydown", this._onKeydown)
  },
}

export default FirstRunGoal
