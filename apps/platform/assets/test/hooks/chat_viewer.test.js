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
})
