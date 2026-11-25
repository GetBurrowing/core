// The locale's first weekday for the phone calendar (canvas 01a2111c review
// E). In app.js (not the calendar island): the connect params need it before
// any hook mounts.

/**
 * The locale's first day of the week, ISO 1 (Monday) … 7 (Sunday), from
 * `Intl.Locale#getWeekInfo()` or the older `weekInfo` property. Monday when
 * neither exists or the locale does not parse.
 */
export function weekStart(tag, IntlLocale = globalThis.Intl?.Locale) {
  try {
    const locale = new IntlLocale(tag)
    const first = +(locale.getWeekInfo ? locale.getWeekInfo() : locale.weekInfo).firstDay
    return first >= 1 && first <= 7 ? first : 1
  } catch {
    return 1
  }
}
