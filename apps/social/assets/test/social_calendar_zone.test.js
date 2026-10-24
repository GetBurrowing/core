import { describe, it, expect, vi, afterEach } from "vitest"
import SocialCalendarZone, { browserZone } from "../js/hooks/social_calendar_zone.js"

/**
 * The Calendar's zone hook (Social authoring 8/11): one push on mount with
 * the browser's IANA zone, nothing when the runtime has none.
 */

afterEach(() => vi.restoreAllMocks())

describe("SocialCalendarZone", () => {
  it("pushes the browser zone once on mount", () => {
    const pushEvent = vi.fn()
    SocialCalendarZone.mounted.call({ pushEvent })
    expect(pushEvent).toHaveBeenCalledTimes(1)
    expect(pushEvent).toHaveBeenCalledWith("calendar_zone", { zone: browserZone() })
  })

  it("pushes nothing when the runtime exposes no zone", () => {
    vi.spyOn(Intl, "DateTimeFormat").mockImplementation(() => ({
      resolvedOptions: () => ({ timeZone: undefined }),
    }))
    const pushEvent = vi.fn()
    SocialCalendarZone.mounted.call({ pushEvent })
    expect(browserZone()).toBe(null)
    expect(pushEvent).not.toHaveBeenCalled()
  })
})
