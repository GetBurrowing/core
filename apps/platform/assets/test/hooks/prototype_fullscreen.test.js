import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import PrototypeFullscreen from "../../js/hooks/prototype_fullscreen.js"

function setup({ enabled }) {
  const listeners = {}
  const doc = {
    fullscreenEnabled: enabled,
    fullscreenElement: null,
    addEventListener: (t, f) => (listeners[t] = f),
    removeEventListener: () => {},
    exitFullscreen: vi.fn(() => Promise.resolve()),
  }
  globalThis.document = doc
  const btn = { closest: () => btn }
  const el = {
    dataset: { fullscreen: "false" },
    requestFullscreen: vi.fn(() => Promise.resolve()),
    contains: () => true,
    addEventListener: (t, f) => (el._click = f),
    removeEventListener: () => {},
  }
  const hook = Object.create(PrototypeFullscreen)
  hook.el = el
  hook.pushEventTo = vi.fn()
  hook.mounted()
  return { doc, el, hook, btn, listeners }
}

describe("PrototypeFullscreen", () => {
  let saved
  beforeEach(() => (saved = globalThis.document))
  afterEach(() => (globalThis.document = saved))

  it("requests native fullscreen on the root when supported", () => {
    const { el, btn } = setup({ enabled: true })
    el._click({ target: btn })
    expect(el.requestFullscreen).toHaveBeenCalledTimes(1)
  })

  it("does nothing natively where the API is unavailable (iPhone)", () => {
    const { el, btn } = setup({ enabled: false })
    el._click({ target: btn })
    expect(el.requestFullscreen).not.toHaveBeenCalled()
  })

  it("syncs a native exit back to the component", () => {
    const { el, hook, doc, listeners } = setup({ enabled: true })
    el.dataset.fullscreen = "true"
    doc.fullscreenElement = null
    listeners.fullscreenchange()
    expect(hook.pushEventTo).toHaveBeenCalledWith(el, "fullscreen", { on: "false" })
  })

  it("does not push while still natively fullscreen, or when already off", () => {
    const { el, hook, doc, listeners } = setup({ enabled: true })
    el.dataset.fullscreen = "true"
    doc.fullscreenElement = el
    listeners.fullscreenchange()
    el.dataset.fullscreen = "false"
    doc.fullscreenElement = null
    listeners.fullscreenchange()
    expect(hook.pushEventTo).not.toHaveBeenCalled()
  })

  it("exits native fullscreen when the server turns the assign off", () => {
    const { el, hook, doc } = setup({ enabled: true })
    doc.fullscreenElement = el
    el.dataset.fullscreen = "false"
    hook.updated()
    expect(doc.exitFullscreen).toHaveBeenCalledTimes(1)
  })
})
