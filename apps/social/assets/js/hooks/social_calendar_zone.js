/**
 * SocialCalendarZone hook (Social authoring 8/11): sends the viewer's IANA
 * time zone to the Calendar tab once, on mount. The server validates it
 * against Tzdata and falls back to UTC; All brands draws its week in it.
 */

/** The browser's IANA zone, or null when the runtime does not expose one. */
export function browserZone() {
  try {
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone
    return typeof zone === "string" && zone !== "" ? zone : null
  } catch (_e) {
    return null
  }
}

export default {
  mounted() {
    const zone = browserZone()
    if (zone) this.pushEvent("calendar_zone", {zone})
  },
}
