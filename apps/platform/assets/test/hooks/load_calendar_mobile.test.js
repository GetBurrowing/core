import { describe, it, expect } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { ISLAND_SRC, lazyHook, loadCalendarMobile } from "../../js/lib/load_calendar_mobile.js"
import { weekStart } from "../../js/lib/week_start.js"

/**
 * The phone calendar hooks are an island (bundle ceiling, PR #293): app.js
 * carries only these stand-ins, which fetch js/calendar_mobile_island.js once
 * and then become the real hook.
 */

const flush = () => new Promise((r) => setTimeout(r, 0))

function standIn(name, load) {
  const hook = Object.assign(Object.create({}), lazyHook(name, load))
  const attrs = {}
  hook.el = { id: "m-agenda" }
  hook.js = () => ({ setAttribute: (_el, k, v) => (attrs[k] = v) })
  return { hook, attrs }
}

describe("lazyHook", () => {
  it("becomes the island's hook and runs its mounted, then its own lifecycle", async () => {
    const calls = []
    const island = {
      CalendarAgenda: {
        mounted() {
          calls.push(["mounted", this.el.id])
        },
        updated() {
          calls.push(["updated"])
        },
        destroyed() {
          calls.push(["destroyed"])
        },
        report() {
          return "real"
        },
      },
    }
    const { hook } = standIn("CalendarAgenda", () => Promise.resolve(island))
    hook.mounted()
    await flush()
    expect(calls).toEqual([["mounted", "m-agenda"]])
    expect(hook.report()).toBe("real")
    hook.updated()
    hook.destroyed()
    expect(calls.slice(1)).toEqual([["updated"], ["destroyed"]])
  })

  it("never mounts late on a hook destroyed while the island loads", async () => {
    let mounted = false
    const island = { CalendarDay: { mounted: () => (mounted = true) } }
    const { hook } = standIn("CalendarDay", () => Promise.resolve(island))
    hook.mounted()
    hook.destroyed()
    await flush()
    expect(mounted).toBe(false)
  })

  it("marks the agenda ready when the island cannot load, so its rows still show", async () => {
    const { hook, attrs } = standIn("CalendarAgenda", () => Promise.reject(new Error("offline")))
    hook.mounted()
    await flush()
    expect(attrs["data-ready"]).toBe("")
  })
})

describe("loadCalendarMobile", () => {
  it("injects the island script once and resolves with its global", async () => {
    const appended = []
    const doc = {
      createElement: () => ({}),
      head: { appendChild: (s) => appended.push(s) },
    }
    const win = {}
    const a = loadCalendarMobile(doc, win)
    const b = loadCalendarMobile(doc, win)
    expect(appended.length).toBe(1)
    expect(appended[0].src).toBe(ISLAND_SRC)
    win.__burrowCalendarMobile = { CalendarAgenda: {} }
    appended[0].onload()
    expect(await a).toBe(win.__burrowCalendarMobile)
    expect(await b).toBe(win.__burrowCalendarMobile)
    expect(await loadCalendarMobile(doc, win)).toBe(win.__burrowCalendarMobile)
  })

  it("the island entry exposes every hook the stand-ins name", () => {
    const src = readFileSync(resolve(__dirname, "../../js/calendar_mobile_island.js"), "utf8")
    expect(src).toMatch(/window\.__burrowCalendarMobile = CalendarMobile/)
    expect(ISLAND_SRC).toBe("/assets/js/calendar_mobile_island.js")
  })
})

describe("weekStart in app.js", () => {
  it("is the locale's first day, Monday otherwise", () => {
    class Method {
      getWeekInfo() {
        return { firstDay: 7 }
      }
    }
    class Prop {
      weekInfo = { firstDay: 6 }
    }
    expect(weekStart("en-US", Method)).toBe(7)
    expect(weekStart("ar-EG", Prop)).toBe(6)
    expect(weekStart("en-US", class {})).toBe(1)
    expect(weekStart("en-US", null)).toBe(1)
  })
})
