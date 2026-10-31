import { describe, it, expect } from "vitest"
import CalendarScroll, { openOffset } from "../../js/hooks/calendar_scroll.js"

/**
 * CalendarScroll (task 01a18d9f stage 1; prototype 01a178d2 v4 app.js
 * `renderMain`): a week opens at 08:00, patches keep the scroll, and Month
 * back to Week reopens at 08:00. Plain node: a fake element.
 */
function hook(view) {
  const el = { dataset: { view }, scrollTop: 0 }
  const h = Object.create(CalendarScroll)
  h.el = el
  return h
}

describe("CalendarScroll", () => {
  it("opens a week with 08:00 at the top (one 48px hour below 07:00)", () => {
    expect(openOffset()).toBe(48)
    const h = hook("week")
    h.mounted()
    expect(h.el.scrollTop).toBe(48)
  })

  it("leaves a month at the top", () => {
    const h = hook("month")
    h.mounted()
    expect(h.el.scrollTop).toBe(0)
  })

  it("keeps the reader's scroll across a patch of the same week", () => {
    const h = hook("week")
    h.mounted()
    h.el.scrollTop = 300
    h.beforeUpdate()
    h.el.scrollTop = 0 // a patch that reset the scroller
    h.updated()
    expect(h.el.scrollTop).toBe(300)
  })

  it("reopens at 08:00 when Month switches back to Week", () => {
    const h = hook("month")
    h.mounted()
    h.el.scrollTop = 200
    h.beforeUpdate()
    h.el.dataset.view = "week"
    h.updated()
    expect(h.el.scrollTop).toBe(48)
  })
})
