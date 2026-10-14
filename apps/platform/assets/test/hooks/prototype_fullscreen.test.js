import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import PrototypeFullscreen from "../../js/hooks/prototype_fullscreen.js"

function setup({ enabled, popover = true, request } = {}) {
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
  // The vitest environment is node (no jsdom), so the element is a stub:
  // attributes in a Map, and the popover API modelled on the HTML spec
  // (showPopover throws on an element without the attribute).
  const attrs = new Map()
  const el = {
    dataset: { fullscreen: "false" },
    _open: false,
    requestFullscreen: vi.fn(request || (() => Promise.resolve())),
    contains: () => true,
    addEventListener: (t, f) => (el._click = f),
    removeEventListener: () => {},
    getAttribute: (n) => (attrs.has(n) ? attrs.get(n) : null),
    hasAttribute: (n) => attrs.has(n),
    setAttribute: (n, v) => attrs.set(n, String(v)),
    removeAttribute: (n) => {
      attrs.delete(n)
      if (n === "popover") el._open = false
    },
    matches: (sel) => {
      if (sel !== ":popover-open") throw new Error(`unexpected selector ${sel}`)
      return el._open
    },
  }
  if (popover) {
    el.showPopover = vi.fn(() => {
      if (!attrs.has("popover")) throw new Error("NotSupportedError")
      if (el._open) throw new Error("InvalidStateError")
      el._open = true
    })
    el.hidePopover = vi.fn(() => (el._open = false))
  }
  const js = {
    setAttribute: vi.fn((target, n, v) => target.setAttribute(n, v)),
    removeAttribute: vi.fn((target, n) => target.removeAttribute(n)),
  }
  const hook = Object.create(PrototypeFullscreen)
  hook.el = el
  hook.pushEventTo = vi.fn()
  hook.js = () => js
  hook.mounted()
  return { doc, el, hook, btn, listeners, js, attrs }
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

  describe("top-layer promotion (overlay path)", () => {
    it("promotes on updated(fullscreen=true) through the sticky js() API", () => {
      const { el, hook, js } = setup({ enabled: false })
      el.dataset.fullscreen = "true"
      hook.updated()
      expect(js.setAttribute).toHaveBeenCalledWith(el, "popover", "manual")
      expect(el.getAttribute("popover")).toBe("manual")
      expect(el.showPopover).toHaveBeenCalledTimes(1)
      expect(el.matches(":popover-open")).toBe(true)
    })

    it("a second updated() while open does not call showPopover again", () => {
      const { el, hook, js } = setup({ enabled: false })
      el.dataset.fullscreen = "true"
      hook.updated()
      hook.updated()
      hook.updated()
      expect(el.showPopover).toHaveBeenCalledTimes(1)
      expect(js.setAttribute).toHaveBeenCalledTimes(1)
    })

    it("demotes and removes the attribute when the assign goes false", () => {
      const { el, hook, js } = setup({ enabled: false })
      el.dataset.fullscreen = "true"
      hook.updated()
      el.dataset.fullscreen = "false"
      hook.updated()
      expect(el.hidePopover).toHaveBeenCalledTimes(1)
      expect(js.removeAttribute).toHaveBeenCalledWith(el, "popover")
      expect(el.hasAttribute("popover")).toBe(false)
    })

    it("an inline frame never touches the popover attribute", () => {
      const { el, hook, js } = setup({ enabled: false })
      hook.updated()
      hook.updated()
      expect(js.setAttribute).not.toHaveBeenCalled()
      expect(js.removeAttribute).not.toHaveBeenCalled()
      expect(el.hidePopover).not.toHaveBeenCalled()
    })

    it("promotes on mount when the frame mounts already fullscreen", () => {
      const { el } = setup({ enabled: false })
      // Re-mount with the assign already on, as after a LiveView reconnect.
      const again = Object.create(PrototypeFullscreen)
      el.dataset.fullscreen = "true"
      const js = { setAttribute: vi.fn((t, n, v) => t.setAttribute(n, v)), removeAttribute: vi.fn() }
      again.el = el
      again.pushEventTo = vi.fn()
      again.js = () => js
      again.mounted()
      expect(js.setAttribute).toHaveBeenCalledWith(el, "popover", "manual")
      expect(el.matches(":popover-open")).toBe(true)
    })

    it("destroyed() hides an open popover", () => {
      const { el, hook } = setup({ enabled: false })
      el.dataset.fullscreen = "true"
      hook.updated()
      hook.destroyed()
      expect(el.hidePopover).toHaveBeenCalledTimes(1)
      expect(el.matches(":popover-open")).toBe(false)
    })

    it("without the popover API (iOS < 17) stays on the plain overlay", () => {
      const { el, hook, js } = setup({ enabled: false, popover: false })
      el.dataset.fullscreen = "true"
      expect(() => hook.updated()).not.toThrow()
      expect(js.setAttribute).not.toHaveBeenCalled()
      expect(el.hasAttribute("popover")).toBe(false)
    })
  })

  describe("native path", () => {
    it("never sets the popover attribute while native fullscreen is in effect", async () => {
      const { el, hook, btn, doc, js } = setup({ enabled: true })
      el._click({ target: btn })
      // The server's assign lands while the request is still pending...
      el.dataset.fullscreen = "true"
      hook.updated()
      await Promise.resolve()
      await Promise.resolve()
      // ...and after the request resolved.
      doc.fullscreenElement = el
      hook.updated()
      expect(el.requestFullscreen).toHaveBeenCalledTimes(1)
      expect(js.setAttribute).not.toHaveBeenCalled()
      expect(el.showPopover).not.toHaveBeenCalled()
      expect(el.hasAttribute("popover")).toBe(false)
    })

    it("falls back to the top layer when the native request rejects", async () => {
      const { el, hook, btn, js } = setup({
        enabled: true,
        request: () => Promise.reject(new Error("NotAllowedError")),
      })
      el._click({ target: btn })
      el.dataset.fullscreen = "true"
      hook.updated()
      expect(el.showPopover).not.toHaveBeenCalled()
      await new Promise((r) => setTimeout(r, 0))
      expect(js.setAttribute).toHaveBeenCalledWith(el, "popover", "manual")
      expect(el.showPopover).toHaveBeenCalledTimes(1)
    })

    it("falls back to the top layer when the native request throws", () => {
      const { el, hook, btn } = setup({
        enabled: true,
        request: () => {
          throw new Error("TypeError")
        },
      })
      el._click({ target: btn })
      el.dataset.fullscreen = "true"
      hook.updated()
      expect(el.showPopover).toHaveBeenCalledTimes(1)
    })
  })
})
