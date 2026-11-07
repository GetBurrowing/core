import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { fakeDocument } from "./fake_dom.js"
import { openLayer, openLayerCount, __resetForTests, SWIPE_CLOSE_PX } from "../../js/lib/dismissable_overlay.js"
import { openImageLayer } from "../../js/lib/image_layer.js"

// Same shape as dismissable_overlay.test.js: back() only records the call and
// the test fires the echoing popstate, as a browser does asynchronously.
function fakeWindow() {
  const listeners = {}
  const w = {
    location: { href: "https://app.test/canvases/abc", origin: "https://app.test" },
    history: {
      state: null,
      pushState: vi.fn((state) => {
        w.history.state = state
      }),
      back: vi.fn(),
    },
    matchMedia: () => ({ matches: false }),
    addEventListener: (type, fn, capture) => (listeners[type] ||= []).push({ fn, capture: !!capture }),
    removeEventListener: (type, fn) => {
      listeners[type] = (listeners[type] || []).filter((l) => l.fn !== fn)
    },
    fire(type, event = {}) {
      for (const l of [...(listeners[type] || [])]) l.fn({ type, ...event })
    },
  }
  return w
}

const SRC = "/chat/attachments/01a1b67d-073f-7000-af1c-29cb60de81e4"

describe("image_layer", () => {
  let win, doc, prevWindow, anchor

  beforeEach(() => {
    __resetForTests()
    prevWindow = globalThis.window
    win = fakeWindow()
    globalThis.window = win
    doc = fakeDocument()
    doc.body = doc.createElement("body")
    anchor = doc.createElement("a")
    doc.body.appendChild(anchor)
  })

  afterEach(() => {
    __resetForTests()
    if (prevWindow === undefined) delete globalThis.window
    else globalThis.window = prevWindow
  })

  const layerEl = () => doc.body.querySelector("[data-role=image-layer]")
  const open = (opts = {}) => openImageLayer({ href: SRC, alt: "shot", returnFocusTo: anchor, doc, ...opts })

  it("builds a modal dialog on the viewer ground with the shared 44px close control", () => {
    open()
    const el = layerEl()
    expect(el).not.toBeNull()
    expect(el.getAttribute("role")).toBe("dialog")
    expect(el.getAttribute("aria-modal")).toBe("true")
    expect(el.getAttribute("class")).toContain("bg-viewer")
    expect(el.querySelector(".overlay-close-bar")).not.toBeNull()
    const x = el.querySelector("[data-role=image-layer-close]")
    expect(x.getAttribute("aria-label")).toBe("Close image")
    expect(x.getAttribute("class")).toContain("overlay-close-control")
    expect(x.getAttribute("class")).toContain("size-11")
    const img = el.querySelector("img")
    expect(img.getAttribute("src")).toBe(SRC)
    expect(img.getAttribute("class")).toContain("object-contain")
    expect(el.querySelector("[data-role=image-layer-download]").getAttribute("href")).toBe(SRC)
    expect(doc.activeElement).toBe(x)
    expect(doc.body.style.overflow).toBe("hidden")
  })

  it("file mode shows the filename and a Download link, no image", () => {
    open({ mode: "file", filename: "spec.pdf" })
    const el = layerEl()
    expect(el.getAttribute("data-mode")).toBe("file")
    expect(el.querySelector("img")).toBeNull()
    expect(el.textContent).toContain("spec.pdf")
    const dl = el.querySelector("[data-role=image-layer-download-file]")
    expect(dl.getAttribute("href")).toBe(SRC)
    expect(dl.getAttribute("download")).toBe("spec.pdf")
  })

  it("opening calls pushState exactly once", () => {
    open()
    expect(win.history.pushState).toHaveBeenCalledTimes(1)
    expect(win.history.pushState.mock.calls[0][2]).toBe(win.location.href)
  })

  it("X removes the element, goes back once, restores scroll and focus", () => {
    open()
    const el = layerEl()
    const x = el.querySelector("[data-role=image-layer-close]")
    el.fire("click", { target: x, preventDefault: vi.fn(), stopPropagation: vi.fn() })
    expect(layerEl()).toBeNull()
    expect(win.history.back).toHaveBeenCalledTimes(1)
    expect(doc.body.style.overflow).toBe("")
    expect(doc.activeElement).toBe(anchor)
    expect(openLayerCount()).toBe(0)
  })

  it("Escape removes the element", () => {
    open()
    win.fire("keydown", { key: "Escape", preventDefault: vi.fn(), stopImmediatePropagation: vi.fn() })
    expect(layerEl()).toBeNull()
    expect(win.history.back).toHaveBeenCalledTimes(1)
  })

  it("popstate (the phone's back) removes the element without another back()", () => {
    open()
    win.fire("popstate")
    expect(layerEl()).toBeNull()
    expect(win.history.back).not.toHaveBeenCalled()
  })

  it("a 150px swipe down removes the element", () => {
    open()
    const stage = layerEl().querySelector("[data-role=image-layer-stage]")
    stage.fire("pointerdown", { pointerId: 1, clientY: 100, button: 0 })
    stage.fire("pointermove", { pointerId: 1, clientY: 250 })
    stage.fire("pointerup", { pointerId: 1, clientY: 100 + 150 })
    expect(150).toBeGreaterThan(SWIPE_CLOSE_PX)
    expect(layerEl()).toBeNull()
  })

  it("over an open chat viewer, one popstate removes only the image layer", () => {
    const viewer = doc.createElement("div")
    doc.body.appendChild(viewer)
    const viewerClose = vi.fn()
    openLayer({ el: viewer, onClose: viewerClose })
    open()
    expect(openLayerCount()).toBe(2)
    expect(win.history.pushState).toHaveBeenCalledTimes(2)

    win.fire("popstate")
    expect(layerEl()).toBeNull()
    expect(viewerClose).not.toHaveBeenCalled()
    expect(openLayerCount()).toBe(1)

    // And an X close of the image layer consumes its own echo, so the viewer
    // below survives that too.
    open()
    const el = layerEl()
    el.fire("click", { target: el.querySelector("[data-role=image-layer-close]"), preventDefault: vi.fn() })
    win.fire("popstate")
    expect(viewerClose).not.toHaveBeenCalled()
    expect(openLayerCount()).toBe(1)
  })

  it("two stacked image layers: one popstate removes only the top one", () => {
    open({ alt: "first" })
    open({ alt: "second" })
    expect(doc.body.querySelectorAll("[data-role=image-layer]").length).toBe(2)
    win.fire("popstate")
    const left = doc.body.querySelectorAll("[data-role=image-layer]")
    expect(left.length).toBe(1)
    expect(left[0].getAttribute("aria-label")).toBe("first")
    expect(win.history.back).not.toHaveBeenCalled()
    expect(openLayerCount()).toBe(1)
  })
})
