import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { fakeDocument } from "../lib/fake_dom.js"
import ChatViewer from "../../js/hooks/chat_viewer.js"
import { __resetForTests, openLayerCount } from "../../js/lib/dismissable_overlay.js"

function fakeWindow() {
  const listeners = {}
  const w = {
    location: { href: "https://app.test/chat/general", origin: "https://app.test" },
    innerWidth: 375,
    innerHeight: 812,
    history: {
      state: null,
      pushState: vi.fn((state) => {
        w.history.state = state
      }),
      back: vi.fn(),
    },
    matchMedia: () => ({ matches: false }),
    addEventListener: (type, fn) => (listeners[type] ||= []).push(fn),
    removeEventListener: (type, fn) => {
      listeners[type] = (listeners[type] || []).filter((f) => f !== fn)
    },
    fire(type, event = {}) {
      for (const fn of [...(listeners[type] || [])]) fn({ type, ...event })
    },
  }
  return w
}

// The open viewer as chat_viewer.ex renders it, reduced to what the hook reads.
function openViewer(doc, root) {
  root.setAttribute("data-state", "open")
  root.setAttribute("data-mode", "image")
  const bar = doc.createElement("div")
  bar.setAttribute("data-role", "viewer-bar")
  bar.setAttribute("class", "overlay-close-bar")
  const back = doc.createElement("button")
  back.setAttribute("data-role", "viewer-back")
  back.setAttribute("class", "overlay-close-control btn")
  bar.appendChild(back)
  root.appendChild(bar)
  return back
}

const flush = () => new Promise((r) => setTimeout(r, 0))

describe("ChatViewer hook on the shared overlay module", () => {
  let saved

  beforeEach(() => {
    __resetForTests()
    saved = { window: globalThis.window, document: globalThis.document, raf: globalThis.requestAnimationFrame }
    globalThis.window = fakeWindow()
    const doc = fakeDocument()
    doc.getElementById = () => null
    globalThis.document = doc
    globalThis.requestAnimationFrame = (fn) => setTimeout(fn, 0)
  })

  afterEach(() => {
    __resetForTests()
    for (const [k, v] of Object.entries({
      window: saved.window,
      document: saved.document,
      requestAnimationFrame: saved.raf,
    })) {
      if (v === undefined) delete globalThis[k]
      else globalThis[k] = v
    }
  })

  function mount() {
    const root = document.createElement("div")
    root.setAttribute("id", "chat-viewer")
    root.setAttribute("data-state", "closed")
    const hook = Object.create(ChatViewer)
    hook.el = root
    hook.pushEvent = vi.fn()
    hook.mounted()
    return { hook, root }
  }

  it("opening the viewer calls pushState exactly once and focuses back", () => {
    const { hook, root } = mount()
    expect(window.history.pushState).not.toHaveBeenCalled()
    const back = openViewer(document, root)
    hook.updated()
    expect(window.history.pushState).toHaveBeenCalledTimes(1)
    expect(document.activeElement).toBe(back)
    // A later patch while open (paging, zoom) pushes nothing more.
    hook.updated()
    expect(window.history.pushState).toHaveBeenCalledTimes(1)
  })

  it("popstate (the phone's back) pushes viewer_close", async () => {
    const { hook, root } = mount()
    openViewer(document, root)
    hook.updated()
    window.fire("popstate")
    await flush()
    expect(hook.pushEvent).toHaveBeenCalledWith("viewer_close", {})
    expect(hook.pushEvent).toHaveBeenCalledTimes(1)
    expect(window.history.back).not.toHaveBeenCalled()
  })

  it("the back control closes through the layer: viewer_close once, history.back once", async () => {
    const { hook, root } = mount()
    openViewer(document, root)
    hook.updated()
    hook.close()
    await flush()
    expect(hook.pushEvent).toHaveBeenCalledWith("viewer_close", {})
    expect(window.history.back).toHaveBeenCalledTimes(1)
    // The echo of that back() is consumed, not a second close.
    window.fire("popstate")
    await flush()
    expect(hook.pushEvent).toHaveBeenCalledTimes(1)
  })

  it("a server-side close drops the history entry without a second viewer_close", async () => {
    const { hook, root } = mount()
    openViewer(document, root)
    hook.updated()
    root.setAttribute("data-state", "closed")
    hook.updated()
    await flush()
    expect(window.history.back).toHaveBeenCalledTimes(1)
    expect(hook.pushEvent).not.toHaveBeenCalled()
    expect(openLayerCount()).toBe(0)
  })

  it("in the shell (share + coarse pointer) Download goes to the share sheet, never a navigation", async () => {
    const share = vi.fn(() => Promise.resolve())
    const prevNav = globalThis.navigator
    Object.defineProperty(globalThis, "navigator", { value: { share }, configurable: true })
    try {
      const { hook, root } = mount()
      openViewer(document, root)
      const dl = document.createElement("a")
      dl.setAttribute("data-role", "viewer-download")
      dl.setAttribute("href", "/chat/attachments/a1")
      dl.setAttribute("download", "shot.png")
      root.appendChild(dl)
      hook.updated()
      const click = (coarse) => {
        window.matchMedia = () => ({ matches: coarse })
        const e = { target: dl, preventDefault: vi.fn(), stopPropagation: vi.fn() }
        root.fire("click", e)
        return e
      }
      const desktop = click(false)
      expect(desktop.preventDefault).not.toHaveBeenCalled()
      expect(share).not.toHaveBeenCalled()

      const phone = click(true)
      expect(phone.preventDefault).toHaveBeenCalled()
      await flush()
      expect(share).toHaveBeenCalledWith({ url: "https://app.test/chat/attachments/a1", title: "shot.png" })
    } finally {
      Object.defineProperty(globalThis, "navigator", { value: prevNav, configurable: true })
    }
  })

  it("Escape is the module's, and ArrowLeft no longer closes", async () => {
    const { hook, root } = mount()
    openViewer(document, root)
    hook.updated()
    const ev = (key) => ({ key, preventDefault: vi.fn(), stopImmediatePropagation: vi.fn() })
    window.fire("keydown", ev("ArrowLeft"))
    await flush()
    expect(hook.pushEvent).not.toHaveBeenCalled()
    window.fire("keydown", ev("Escape"))
    await flush()
    expect(hook.pushEvent).toHaveBeenCalledWith("viewer_close", {})
  })
  // The gallery opener exactly as chat_message.ex renders it (the ExUnit
  // render test pins these attributes). focus() behaves as a browser's: an
  // element without tabindex that is not a native control takes no focus.
  function galleryItem(doc) {
    const item = doc.createElement("div")
    item.setAttribute("id", "gallery-m1-a1")
    item.setAttribute("data-role", "gallery-item")
    item.setAttribute("data-viewer-open", "")
    item.setAttribute("role", "button")
    item.setAttribute("tabindex", "0")
    item.setAttribute("aria-label", "Open image 1 of 2: red.png")
    item.setAttribute("phx-click", "viewer_open")
    item.focus = () => {
      if (item.hasAttribute("tabindex")) doc.activeElement = item
    }
    item.getBoundingClientRect = () => ({ left: 10, top: 300, width: 120, height: 90 })
    item.classList = { add: vi.fn(), remove: vi.fn() }
    item.clicks = 0
    // A real click: the hook's capture listener, then the opener's phx-click.
    item.click = () => {
      doc.fire("click", { target: item })
      item.clicks += 1
    }
    doc.getElementById = (id) => (id === "gallery-m1-a1" ? item : null)
    return item
  }

  const key = (k, target, extra = {}) => ({
    key: k,
    target,
    preventDefault: vi.fn(),
    stopImmediatePropagation: vi.fn(),
    ...extra,
  })

  it("Enter and Space on the gallery opener open it as a tap does; nothing else does", () => {
    mount()
    const item = galleryItem(document)
    const enter = key("Enter", item)
    document.fire("keydown", enter)
    expect(item.clicks).toBe(1)
    expect(enter.preventDefault).toHaveBeenCalled()
    document.fire("keydown", key(" ", item))
    expect(item.clicks).toBe(2)
    // Held keys, modified keys and other keys do not open.
    document.fire("keydown", key("Enter", item, { repeat: true }))
    document.fire("keydown", key("Enter", item, { metaKey: true }))
    document.fire("keydown", key("a", item))
    expect(item.clicks).toBe(2)
    // A native button opener already clicks on Enter; the hook must not add one.
    const btn = document.createElement("button")
    btn.setAttribute("data-viewer-open", "")
    btn.click = vi.fn()
    document.fire("keydown", key("Enter", btn))
    expect(btn.click).not.toHaveBeenCalled()
  })

  it("Escape closes a viewer opened from the gallery and focus returns to the gallery item", async () => {
    const { hook, root } = mount()
    const item = galleryItem(document)
    item.focus()
    document.fire("keydown", key("Enter", item))
    const back = openViewer(document, root)
    hook.updated()
    expect(document.activeElement).toBe(back)

    window.fire("keydown", key("Escape", back))
    await flush()
    expect(hook.pushEvent).toHaveBeenCalledWith("viewer_close", {})
    // The close patch.
    root.setAttribute("data-state", "closed")
    hook.updated()
    await flush()
    expect(document.activeElement).toBe(item)
  })

  // The PDF viewer as chat_viewer.ex renders it: an iframe on the stage.
  function openPdf(doc, root) {
    const back = openViewer(doc, root)
    root.setAttribute("data-mode", "file")
    const frame = doc.createElement("iframe")
    frame.setAttribute("data-role", "viewer-pdf")
    root.appendChild(frame)
    return { back, frame }
  }

  it("the PDF plugin taking focus on load is undone, so Escape still closes", async () => {
    const { hook, root } = mount()
    const { back, frame } = openPdf(document, root)
    hook.updated()
    expect(document.activeElement).toBe(back)
    frame.fire("load")
    // The browser's PDF viewer focuses itself: the window blurs into the frame.
    document.activeElement = frame
    window.fire("blur")
    await flush()
    expect(document.activeElement).toBe(back)
    window.fire("keydown", key("Escape", back))
    await flush()
    expect(hook.pushEvent).toHaveBeenCalledWith("viewer_close", {})
  })

  it("a click into the PDF after load keeps its focus, and the guard ends on close", async () => {
    const { hook, root } = mount()
    const { frame } = openPdf(document, root)
    hook.updated()
    const now = Date.now()
    const spy = vi.spyOn(Date, "now").mockReturnValue(now)
    try {
      frame.fire("load")
      spy.mockReturnValue(now + 5000)
      document.activeElement = frame
      window.fire("blur")
      await flush()
      expect(document.activeElement).toBe(frame)
    } finally {
      spy.mockRestore()
    }
    root.setAttribute("data-state", "closed")
    hook.updated()
    await flush()
    // Closed: a later blur into some other frame is not the viewer's business.
    document.activeElement = frame
    window.fire("blur")
    await flush()
    expect(document.activeElement).toBe(frame)
  })
})
