// Calendar week body scroll (task 01a18d9f stage 1; prototype 01a178d2 v4
// app.js `renderMain`). A week opens with 08:00 at the top: the grid starts
// at 07:00 and an hour is 48px, so the first render scrolls 48px. Patches
// that keep the week keep the reader's scrollTop (the prototype's
// `keepScroll`); switching from Month back to Week scrolls to 08:00 again.
export const HOUR_PX = 48
export const FIRST_HOUR = 7
export const OPEN_HOUR = 8

export const openOffset = () => (OPEN_HOUR - FIRST_HOUR) * HOUR_PX

const CalendarScroll = {
  mounted() {
    this.view = this.el.dataset.view
    if (this.view === "week") this.el.scrollTop = openOffset()
  },

  beforeUpdate() {
    this.savedTop = this.el.scrollTop
  },

  updated() {
    const view = this.el.dataset.view
    if (view === "week" && this.view !== "week") {
      this.el.scrollTop = openOffset()
    } else if (typeof this.savedTop === "number") {
      this.el.scrollTop = this.savedTop
    }
    this.view = view
  },
}

export default CalendarScroll
