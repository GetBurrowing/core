// DateEntryGuard (task 01a192d6 stage 2).
//
// A native `<input type="date">` that is only partly filled (a month and day
// with no year) reports its value as "" to the form. On a `novalidate` form
// the browser no longer blocks that submit, so the server would read the
// half-typed date as "no date" and, with Start blank, create an UNSCHEDULED
// meeting. This hook mirrors the control's `validity.badInput` into a hidden
// flag field (named by `data-incomplete-flag`) so the server can refuse with
// a message instead.
//
// It syncs on every keystroke, on change/blur, and in the CAPTURE phase of
// the form's submit, which runs before LiveView's own submit listener on
// `window` serialises the form.

export function syncIncomplete(input, flag) {
  const incomplete = !!(input && input.validity && input.validity.badInput)
  const next = incomplete ? "true" : ""
  if (flag && flag.value !== next) flag.value = next
  return incomplete
}

const SYNC_EVENTS = ["keyup", "input", "change", "blur"]

const DateEntryGuard = {
  mounted() {
    this.sync = () =>
      syncIncomplete(this.el, document.getElementById(this.el.dataset.incompleteFlag))

    SYNC_EVENTS.forEach((name) => this.el.addEventListener(name, this.sync))
    this.form = this.el.form
    if (this.form) this.form.addEventListener("submit", this.sync, true)
    this.sync()
  },

  updated() {
    this.sync()
  },

  destroyed() {
    SYNC_EVENTS.forEach((name) => this.el.removeEventListener(name, this.sync))
    if (this.form) this.form.removeEventListener("submit", this.sync, true)
  },
}

export default DateEntryGuard
