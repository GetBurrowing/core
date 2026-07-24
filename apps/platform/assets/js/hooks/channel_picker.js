// ChannelPicker
//
// Makes the external-grant channel checkbox list usable at real scale (40+
// channels) on a 375px mobile viewport. Purely client-side so LiveView never
// re-renders the list on a keystroke — which means a checked box is NEVER
// dropped by a filter (filtered-out rows stay in the DOM, just hidden, so
// their checked value still submits).
//
// Wires, within `this.el` (the picker wrapper, one per grant/add-channels
// form):
//   - `[data-role=channel-search]`     — type-to-filter input
//   - `[data-role=channel-checklist]`  — the scrollable list container
//   - `[data-role=channel-option]`     — each row, carries `data-channel-name`
//   - `[data-role=selected-count]`     — the live "N selected" badge
//   - `[data-role=channel-empty-filter]` — "no matches" message
//
// Filter rule: a row shows when it is CHECKED **or** its name matches the
// query. Keeping checked rows always visible is what keeps the current
// selection legible while the admin searches a long list.

export default {
  mounted() {
    this.search = this.el.querySelector("[data-role=channel-search]")
    this.count = this.el.querySelector("[data-role=selected-count]")
    this.empty = this.el.querySelector("[data-role=channel-empty-filter]")

    this.onInput = () => this.applyFilter()
    this.onChange = () => this.refresh()
    // Don't let Enter in the search field submit the grant form by accident.
    this.onKeydown = (e) => {
      if (e.key === "Enter") e.preventDefault()
    }

    if (this.search) {
      this.search.addEventListener("input", this.onInput)
      this.search.addEventListener("keydown", this.onKeydown)
    }
    this.el.addEventListener("change", this.onChange)

    this.refresh()
  },

  updated() {
    // LiveView may re-render the list (e.g. a new holding login live-appends
    // to the queue). Re-sync count + filter against the fresh DOM.
    this.refresh()
  },

  destroyed() {
    if (this.search) {
      this.search.removeEventListener("input", this.onInput)
      this.search.removeEventListener("keydown", this.onKeydown)
    }
    this.el.removeEventListener("change", this.onChange)
  },

  options() {
    return Array.from(this.el.querySelectorAll("[data-role=channel-option]"))
  },

  query() {
    return (this.search?.value || "").trim().toLowerCase()
  },

  applyFilter() {
    const q = this.query()
    let visible = 0

    for (const opt of this.options()) {
      const name = opt.getAttribute("data-channel-name") || ""
      const box = opt.querySelector("input[type=checkbox]")
      const show = (box && box.checked) || name.includes(q)
      opt.classList.toggle("hidden", !show)
      if (show) visible += 1
    }

    if (this.empty) this.empty.classList.toggle("hidden", visible > 0)
  },

  refresh() {
    // Count only ENABLED checked boxes — already-joined (disabled+checked)
    // channels on the add-channels surface are not "newly selected".
    const n = this.el.querySelectorAll(
      "input[type=checkbox]:checked:not([disabled])",
    ).length

    if (this.count) {
      this.count.textContent = `${n} selected`
      this.count.classList.toggle("badge-primary", n > 0)
      this.count.classList.toggle("badge-ghost", n === 0)
    }

    this.applyFilter()
  },
}
