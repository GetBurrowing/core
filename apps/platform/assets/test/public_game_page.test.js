import {describe, it, expect, vi} from "vitest"
import {unsupportedPlatform, downloadAcknowledged, startDownloadTracking} from "../js/public_game_page"

describe("public game download", () => {
  it("guides phone, Mac and Linux users while allowing Windows and unknown browsers", () => {
    expect(unsupportedPlatform({userAgent: "iPhone"})).toBe(true)
    expect(unsupportedPlatform({platform: "MacIntel", maxTouchPoints: 5})).toBe(true)
    expect(unsupportedPlatform({userAgentData: {platform: "Linux"}})).toBe(true)
    expect(unsupportedPlatform({userAgent: "Mozilla Windows NT 10.0"})).toBe(false)
    expect(unsupportedPlatform({})).toBe(false)
  })
  it("does not mistake an old download or a similarly named cookie for this request", () => {
    expect(downloadAcknowledged("burrow_game_download=old", "new")).toBe(false)
    expect(downloadAcknowledged("other_burrow_game_download=new", "new")).toBe(false)
    expect(downloadAcknowledged("session=x; burrow_game_download=new", "new")).toBe(true)
  })
  it("shows setup only after the server acknowledges the current package request", () => {
    let tick, cookie = ""
    const onStarted = vi.fn(), onTimeout = vi.fn(), cancel = vi.fn()
    startDownloadTracking({readCookie: () => cookie, nonce: "request", onStarted, onTimeout,
      schedule: fn => {tick = fn; return 1}, cancel})
    tick()
    expect(onStarted).not.toHaveBeenCalled()
    cookie = "burrow_game_download=request"
    tick()
    expect(onStarted).toHaveBeenCalledTimes(1)
    expect(onTimeout).not.toHaveBeenCalled()
    expect(cancel).toHaveBeenCalledWith(1)
  })
  it("gives a recovery action instead of claiming a failed request started", () => {
    let tick
    const onStarted = vi.fn(), onTimeout = vi.fn()
    startDownloadTracking({readCookie: () => "", nonce: "request", onStarted, onTimeout,
      schedule: fn => {tick = fn; return 1}, cancel: vi.fn()})
    for (let i = 0; i < 80; i++) tick()
    expect(onStarted).not.toHaveBeenCalled()
    expect(onTimeout).toHaveBeenCalledTimes(1)
  })
})
