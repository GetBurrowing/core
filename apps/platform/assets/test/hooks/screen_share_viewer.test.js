import { describe, it, expect, vi } from "vitest"
import { VideoQuality } from "livekit-client"
import {
  ScreenShareFullscreenController,
  setFocusedScreenShareQuality,
} from "../../js/hooks/lib/screen_share_viewer.js"

function eventTarget(extra = {}) {
  const listeners = new Map()
  return {
    ...extra,
    addEventListener(type, fn) {
      const values = listeners.get(type) || []
      values.push(fn)
      listeners.set(type, values)
    },
    removeEventListener(type, fn) {
      listeners.set(
        type,
        (listeners.get(type) || []).filter((value) => value !== fn),
      )
    },
    dispatch(type, event = {}) {
      for (const fn of listeners.get(type) || []) fn({ type, ...event })
    },
    listenerCount(type) {
      return (listeners.get(type) || []).length
    },
  }
}

function classList() {
  const values = new Set()
  return {
    add(value) {
      values.add(value)
    },
    remove(value) {
      values.delete(value)
    },
    contains(value) {
      return values.has(value)
    },
  }
}

function fakeNode() {
  const attrs = new Map()
  const node = eventTarget({
    dataset: {},
    classList: classList(),
    style: {
      values: new Map(),
      setProperty(key, value) {
        this.values.set(key, value)
      },
      removeProperty(key) {
        this.values.delete(key)
      },
    },
    hidden: true,
    isConnected: true,
    focused: false,
    setAttribute(name, value) {
      attrs.set(name, value)
    },
    getAttribute(name) {
      return attrs.get(name)
    },
    focus() {
      this.focused = true
    },
    querySelector() {
      return null
    },
  })
  return node
}

function fakeEnvironment() {
  const documentElement = fakeNode()
  const body = fakeNode()
  const document = eventTarget({
    documentElement,
    body,
    activeElement: null,
    fullscreenElement: null,
    webkitFullscreenElement: null,
  })
  const history = {
    state: null,
    pushes: [],
    backCalls: 0,
    pushState(state) {
      this.state = state
      this.pushes.push(state)
    },
    back() {
      this.backCalls += 1
    },
  }
  return eventTarget({
    document,
    history,
    innerHeight: 844,
    visualViewport: eventTarget({ height: 800 }),
  })
}

function buildController(overrides = {}) {
  const env = overrides.env || fakeEnvironment()
  const root = overrides.root || fakeNode()
  const button = overrides.button || fakeNode()
  const video = overrides.video || fakeNode()
  const controller = new ScreenShareFullscreenController({
    root,
    viewport: overrides.viewport || root,
    button,
    video,
    publication: overrides.publication,
    env,
  }).mount()
  return { controller, env, root, button, video }
}

describe("ScreenShareFullscreenController", () => {
  it("uses the standard Fullscreen API and restores accessible state and focus", async () => {
    const env = fakeEnvironment()
    const root = fakeNode()
    const prior = fakeNode()
    env.document.activeElement = prior
    root.requestFullscreen = vi.fn(async () => {
      env.document.fullscreenElement = root
    })
    env.document.exitFullscreen = vi.fn(async () => {
      env.document.fullscreenElement = null
    })

    const { controller, button } = buildController({ env, root })
    await controller.enter()

    expect(root.requestFullscreen).toHaveBeenCalledWith({ navigationUI: "hide" })
    expect(controller.mode).toBe("standard")
    expect(button.getAttribute("aria-label")).toBe("Exit full screen")
    expect(button.getAttribute("aria-pressed")).toBe("true")
    expect(button.focused).toBe(true)

    await controller.exit()
    expect(env.document.exitFullscreen).toHaveBeenCalledOnce()
    expect(button.getAttribute("aria-label")).toBe("Enter full screen")
    expect(prior.focused).toBe(true)
  })

  it("falls through rejected standard options to legacy WebKit element fullscreen", async () => {
    const root = fakeNode()
    root.requestFullscreen = vi.fn(async () => {
      throw new Error("unsupported")
    })
    root.webkitRequestFullScreen = vi.fn()
    const { controller } = buildController({ root })

    await controller.enter()
    expect(root.requestFullscreen).toHaveBeenCalledTimes(2)
    expect(root.webkitRequestFullScreen).toHaveBeenCalledOnce()
    expect(controller.mode).toBe("webkit-element")
  })

  it("uses native WebKit video fullscreen when element fullscreen is unavailable", async () => {
    const video = fakeNode()
    video.webkitEnterFullscreen = vi.fn()
    video.webkitExitFullscreen = vi.fn()
    const { controller } = buildController({ video })

    await controller.enter()
    expect(video.webkitEnterFullscreen).toHaveBeenCalledOnce()
    expect(controller.mode).toBe("webkit-video")

    await controller.exit()
    expect(video.webkitExitFullscreen).toHaveBeenCalledOnce()
    expect(controller.active).toBe(false)
  })

  it("falls back to a safe fixed viewport and Escape exits through history", async () => {
    const { controller, env, root, button } = buildController()

    await controller.enter()
    expect(controller.mode).toBe("fallback")
    expect(root.classList.contains("screen-share-viewer--fallback")).toBe(true)
    expect(root.style.values.get("--screen-share-viewport-height")).toBe("800px")
    expect(env.history.pushes).toHaveLength(1)

    const preventDefault = vi.fn()
    env.document.dispatch("keydown", { key: "Escape", preventDefault })
    await Promise.resolve()

    expect(preventDefault).toHaveBeenCalledOnce()
    expect(controller.active).toBe(false)
    expect(env.history.backCalls).toBe(1)
    expect(button.getAttribute("aria-pressed")).toBe("false")
  })

  it("treats browser Back as an exit without navigating twice", async () => {
    const { controller, env } = buildController()
    await controller.enter()

    env.dispatch("popstate")
    await Promise.resolve()

    expect(controller.active).toBe(false)
    expect(env.history.backCalls).toBe(0)
  })

  it("updates fixed viewport height on orientation/visual viewport changes", async () => {
    const { controller, env, root } = buildController()
    await controller.enter()
    env.visualViewport.height = 390
    env.dispatch("orientationchange")
    expect(root.style.values.get("--screen-share-viewport-height")).toBe("390px")
  })

  it("cleans all locks and listeners on LiveView remount/share end", async () => {
    const publication = {
      isSubscribed: false,
      setSubscribed: vi.fn(),
      setVideoQuality: vi.fn(),
    }
    const { controller, env, root, button } = buildController({ publication })
    await controller.enter()
    controller.destroy()

    expect(controller.active).toBe(false)
    expect(root.classList.contains("screen-share-viewer--fallback")).toBe(false)
    expect(env.document.body.classList.contains("screen-share-fullscreen-active")).toBe(false)
    expect(button.hidden).toBe(true)
    expect(env.listenerCount("orientationchange")).toBe(0)
    expect(env.document.listenerCount("keydown")).toBe(0)
    expect(publication.setVideoQuality).toHaveBeenLastCalledWith(VideoQuality.LOW)
  })
})

describe("focused screen-share quality", () => {
  it("selects the highest layer while focused and a low layer after leaving", () => {
    const publication = {
      isSubscribed: false,
      setSubscribed: vi.fn(),
      setVideoQuality: vi.fn(),
    }

    expect(setFocusedScreenShareQuality(publication, true)).toBe(true)
    expect(publication.setSubscribed).toHaveBeenCalledWith(true)
    expect(publication.setVideoQuality).toHaveBeenLastCalledWith(VideoQuality.HIGH)

    expect(setFocusedScreenShareQuality(publication, false)).toBe(true)
    expect(publication.setVideoQuality).toHaveBeenLastCalledWith(VideoQuality.LOW)
  })

  it("does not attempt subscription controls for local publications", () => {
    expect(setFocusedScreenShareQuality({ source: "screen_share" }, true)).toBe(false)
  })
})


describe("screen-share viewer integration markup", () => {
  it("renders the shared accessible control in Meeting Center", async () => {
    const fs = await import("node:fs")
    const source = fs.readFileSync(
      new URL("../../../lib/platform_web/live/meeting_live.html.heex", import.meta.url),
      "utf8",
    )
    expect(source).toContain("data-screen-share-viewer")
    expect(source).toContain("data-screen-share-fullscreen")
    expect(source).toContain('aria-label="Enter full screen"')
  })

  it("renders the same control in both Quick Meet panes", async () => {
    const fs = await import("node:fs")
    const source = fs.readFileSync(
      new URL("../../../lib/platform_web/live/chat/partials.ex", import.meta.url),
      "utf8",
    )
    expect(source.match(/data-screen-share-viewer/g)).toHaveLength(2)
    expect(source.match(/data-screen-share-fullscreen(?!-label)/g)).toHaveLength(2)
  })

  it("keeps the mobile fallback safe-area and touch aware", async () => {
    const fs = await import("node:fs")
    const source = fs.readFileSync(new URL("../../css/app.css", import.meta.url), "utf8")
    expect(source).toContain(".screen-share-viewer--fallback")
    expect(source).toContain("env(safe-area-inset-bottom")
    expect(source).toContain("touch-action: manipulation")
    expect(source).toContain("--screen-share-viewport-height")
  })
})
