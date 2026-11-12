import {describe, it, expect, vi} from "vitest"
import {unsupportedPlatform, downloadAcknowledged, startDownloadTracking, stepIndex, installGameGallery} from "../js/public_game_page"

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

// Minimal element stand-ins: the gallery only needs listeners, attributes and focus.
function fakeGallery(count) {
  const listeners = {}, dialogListeners = {}
  const shots = Array.from({length: count}, (_, i) => ({
    href: `/images/play/game-shot-${i + 1}.png`, dataset: {gameShotAlt: `Shot ${i + 1}`},
    getAttribute(name) { return name === "href" ? this.href : null },
    matches: sel => sel === "[data-game-shot]", closest(sel) { return sel === "[data-game-shot]" ? this : null },
    focus: vi.fn(),
  }))
  const image = {}, caption = {}, counter = {}
  const dialog = {
    open: false, showModal: vi.fn(function () { this.open = true }),
    close: vi.fn(function () { this.open = false; dialogListeners.close?.() }),
    addEventListener: (type, fn) => { dialogListeners[type] = fn },
    querySelector: sel => ({"[data-game-lightbox-image]": image, "[data-game-lightbox-caption]": caption,
      "[data-game-lightbox-count]": counter})[sel],
  }
  const gallery = {
    querySelector: sel => sel === "[data-game-lightbox]" ? dialog : null,
    querySelectorAll: () => shots,
    addEventListener: (type, fn) => { listeners[type] = fn },
  }
  const root = {querySelector: sel => sel === "[data-game-gallery]" ? gallery : null}
  const key = (target, key) => { const e = {key, target, preventDefault: vi.fn()}; listeners.keydown(e); return e }
  const click = target => { const e = {target, preventDefault: vi.fn()}; listeners.click(e); return e }
  return {root, shots, dialog, image, caption, counter, key, click, listeners}
}

describe("game screenshot gallery", () => {
  it("wraps at both ends", () => {
    expect(stepIndex(0, -1, 3)).toBe(2)
    expect(stepIndex(2, 1, 3)).toBe(0)
    expect(stepIndex(1, 1, 3)).toBe(2)
    expect(stepIndex(0, 1, 0)).toBe(0)
  })
  it("moves focus between thumbnails with the arrow keys", () => {
    const g = fakeGallery(3)
    installGameGallery(g.root)
    expect(g.key(g.shots[0], "ArrowRight").preventDefault).toHaveBeenCalled()
    expect(g.shots[1].focus).toHaveBeenCalled()
    g.key(g.shots[0], "ArrowLeft")
    expect(g.shots[2].focus).toHaveBeenCalled()
    expect(g.key(g.shots[0], "Enter").preventDefault).not.toHaveBeenCalled()
  })
  it("opens the viewer on the chosen shot, steps with arrows and returns focus on close", () => {
    const g = fakeGallery(3)
    installGameGallery(g.root)
    const e = g.click(g.shots[1])
    expect(e.preventDefault).toHaveBeenCalled()
    expect(g.dialog.showModal).toHaveBeenCalled()
    expect(g.image.src).toBe("/images/play/game-shot-2.png")
    expect(g.caption.textContent).toBe("Shot 2")
    expect(g.counter.textContent).toBe("2 / 3")
    g.key(g.dialog, "ArrowRight")
    g.key(g.dialog, "ArrowRight")
    expect(g.counter.textContent).toBe("1 / 3")
    vi.useFakeTimers()
    try {
      g.dialog.close()
      vi.runAllTimers()
    } finally {
      vi.useRealTimers()
    }
    expect(g.shots[0].focus).toHaveBeenCalled()
  })
  it("leaves plain image links working when dialogs are unsupported", () => {
    const g = fakeGallery(2)
    g.dialog.showModal = undefined
    installGameGallery(g.root)
    expect(g.listeners.click).toBeUndefined()
    expect(g.listeners.keydown).toBeTypeOf("function")
  })
})
