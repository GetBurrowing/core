// Loader for the phone calendar island (js/calendar_mobile_island.js). The
// hooks registered in app.js are stand-ins: on mount each fetches the island
// once, takes on the real hook's methods (lifecycle included, so from then on
// LiveView calls the real `updated` and `destroyed`) and runs its `mounted`.
// A hook destroyed before the island arrives never mounts late. If the island
// cannot load, the agenda is still marked ready so its server-rendered rows
// show (without scroll-to-today, swipes or strip sync).
//
// Kept small on purpose: this file ships in app.js, which has a byte ceiling
// (test/no_excalidraw_in_app_bundle_test.mjs).

export const ISLAND_SRC = "/assets/js/calendar_mobile_island.js"

let ready

export function loadCalendarMobile(doc = document, win = window) {
  if (win.__burrowCalendarMobile) return Promise.resolve(win.__burrowCalendarMobile)
  ready ||= new Promise((resolve, reject) => {
    const script = doc.createElement("script")
    script.src = ISLAND_SRC
    script.onload = () => (win.__burrowCalendarMobile ? resolve(win.__burrowCalendarMobile) : reject())
    script.onerror = reject
    doc.head.appendChild(script)
  }).catch((error) => {
    ready = null
    throw error
  })
  return ready
}

/** A stand-in hook for the island's hook `name`. */
export function lazyHook(name, load = loadCalendarMobile) {
  return {
    mounted() {
      load().then(
        (island) => {
          if (this.gone) return
          Object.assign(this, island[name])
          this.mounted()
        },
        () => this.gone || this.js().setAttribute(this.el, "data-ready", ""),
      )
    },
    destroyed() {
      this.gone = true
    },
  }
}

export const CalendarAgenda = lazyHook("CalendarAgenda")
export const CalendarDay = lazyHook("CalendarDay")
export const CalendarSwipe = lazyHook("CalendarSwipe")
export const CalendarPhoneLayout = lazyHook("CalendarPhoneLayout")
