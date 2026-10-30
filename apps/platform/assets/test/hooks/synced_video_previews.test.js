import {describe, it, expect, beforeEach, afterEach, vi} from "vitest"
import Hook from "../../js/hooks/synced_video_previews.js"

function video(ready = 2) {
  const v = new EventTarget()
  v.media = {dataset: {}}
  v.readyState = ready
  v.error = null
  v.currentTime = 1.2
  v.duration = 3.8
  v.paused = true
  v.closest = selector => selector === "[data-preview-media]" ? v.media : null
  v.play = vi.fn(() => { v.paused = false; return Promise.resolve() })
  v.pause = vi.fn(() => { v.paused = true })
  return v
}
let hook, videos, motion, doc, observer, now
beforeEach(() => {
  vi.useFakeTimers()
  now = 0
  vi.stubGlobal("performance", {now: () => now})
  videos = [video(), video()]
  motion = new EventTarget()
  motion.matches = false
  doc = new EventTarget()
  doc.hidden = false
  doc.getElementById = id => id === "previews" ? {
    querySelectorAll: selector => selector === "[data-preview-video]" ? videos : []
  } : null
  vi.stubGlobal("document", doc)
  vi.stubGlobal("window", {matchMedia: () => motion, setInterval, clearInterval})
  vi.stubGlobal("MutationObserver", class {
    constructor(fn) { this.fn = fn; observer = this }
    observe = vi.fn()
    disconnect = vi.fn()
  })
  hook = {...Hook, el: {dataset: {previewControls: "previews"}}}
})
afterEach(() => { hook.destroyed(); vi.unstubAllGlobals(); vi.useRealTimers() })

describe("same-excerpt previews", () => {
  it("starts all videos muted at the same phase and corrects actual drift", () => {
    hook.mounted()
    expect(videos.map(v => v.muted)).toEqual([true, true])
    expect(videos.map(v => v.currentTime)).toEqual([0, 0])
    expect(vi.getTimerCount()).toBe(1)
    now = 1000
    videos[0].currentTime = .3
    videos[1].currentTime = .98
    vi.advanceTimersByTime(250)
    expect(videos[0].currentTime).toBe(1)
    expect(videos[1].currentTime).toBe(.98)
    now = 4000
    vi.advanceTimersByTime(250)
    expect(videos[0].currentTime).toBeCloseTo(.2)
  })
  it("waits for every load, then excludes failed media without changing a style control", () => {
    videos[1].readyState = 0
    hook.mounted()
    expect(videos[0].play).not.toHaveBeenCalled()
    expect(videos[1].media.dataset.previewState).toBe("loading")
    videos[1].dispatchEvent(new Event("error"))
    expect(videos[1].media.dataset.previewState).toBe("error")
    expect(videos[1].play).not.toHaveBeenCalled()
    expect(videos[0].play).toHaveBeenCalledOnce()
    expect(videos[0].currentTime).toBe(0)
  })
  it("shows stills with zero playback under reduced motion, including preference changes", () => {
    motion.matches = true
    hook.mounted()
    expect(videos[0].play).not.toHaveBeenCalled()
    expect(videos[0].media.dataset.previewMotion).toBe("reduced")
    expect(vi.getTimerCount()).toBe(0)
    motion.matches = false
    motion.dispatchEvent(new Event("change"))
    expect(videos[0].play).toHaveBeenCalledOnce()
    motion.matches = true
    motion.dispatchEvent(new Event("change"))
    expect(videos.every(v => v.paused)).toBe(true)
    expect(vi.getTimerCount()).toBe(0)
  })
  it("cleans listeners and timers on replacement, hiding and destruction", () => {
    hook.mounted()
    const old = videos[0]
    videos = [video(), video(), video()]
    observer.fn()
    expect(old.paused).toBe(true)
    expect(vi.getTimerCount()).toBe(1)
    old.dispatchEvent(new Event("error"))
    expect(old.media.dataset.previewState).toBe("ready")
    doc.hidden = true
    doc.dispatchEvent(new Event("visibilitychange"))
    expect(vi.getTimerCount()).toBe(0)
    doc.hidden = false
    doc.dispatchEvent(new Event("visibilitychange"))
    expect(vi.getTimerCount()).toBe(1)
    hook.destroyed()
    expect(vi.getTimerCount()).toBe(0)
    expect(observer.disconnect).toHaveBeenCalledOnce()
    motion.dispatchEvent(new Event("change"))
    expect(vi.getTimerCount()).toBe(0)
  })
  it("reports a broken reduced-motion still and removes its listener on destruction", () => {
    const image = new EventTarget()
    image.complete = false
    image.naturalWidth = 240
    videos[0].media.querySelectorAll = selector => selector === "[data-preview-stills] img" ? [image] : []
    motion.matches = true
    hook.mounted()
    image.complete = true
    image.naturalWidth = 0
    image.dispatchEvent(new Event("error"))
    expect(videos[0].media.dataset.previewState).toBe("error")
    expect(videos.every(v => v.paused)).toBe(true)
    hook.destroyed()
    videos[0].media.dataset.previewState = "detached"
    image.dispatchEvent(new Event("error"))
    expect(videos[0].media.dataset.previewState).toBe("detached")
  })
  it("handles blocked autoplay with a truthful still-frame fallback", async () => {
    videos[0].play = vi.fn(() => { videos[0].paused = true; return Promise.reject(new Error("blocked")) })
    hook.mounted()
    expect(videos[0].play).toHaveBeenCalledOnce()
    await vi.advanceTimersByTimeAsync(0)
    expect(videos[0].media.dataset.previewState).toBe("error")
    expect(videos[0].media.dataset.previewMotion).toBe("reduced")
    expect(videos[1].media.dataset.previewState).toBe("ready")
  })
})
