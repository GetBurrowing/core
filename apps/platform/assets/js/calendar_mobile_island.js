// The phone calendar island (canvas 01a2111c): its hooks, built SEPARATELY
// from js/app.js by the `calendar_mobile` esbuild profile and fetched on
// demand by js/lib/load_calendar_mobile.js when a calendar hook mounts. Same
// reasoning as the other islands in config/config.exs: app.js loads on every
// page, and an `import()` from it would be inlined, not lazy.
import * as CalendarMobile from "./hooks/calendar_mobile"

window.__burrowCalendarMobile = CalendarMobile
