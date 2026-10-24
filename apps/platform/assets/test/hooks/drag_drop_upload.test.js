import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"

/**
 * The desktop drop target (redesign rung 11, task 01a1557a-9de3 stage 3):
 * a drag carrying Files shows 'Drop to attach' over the conversation, nested
 * enter/leave pairs keep it, leaving to 0 / dropping / Escape hide it, a
 * text drag never shows it, and a drop stages EVERY file (a PDF included)
 * through the one staging function.
 *
 * Plain node (no jsdom): a minimal fake element and document.
 */

const stage = vi.hoisted(() => ({ stageFiles: vi.fn() }))
vi.mock("../../js/attach_stage", () => ({ stageFiles: stage.stageFiles }))

import DragDropUpload, { hasFiles } from "../../js/hooks/drag_drop_upload.js"

function fakeEl(tag = "div") {
  const listeners = {}
  const classes = new Set()
  return {
    tagName: tag.toUpperCase(),
    children: [],
    style: {},
    attrs: {},
    textContent: "",
    set className(v) {
      classes.clear()
      String(v).split(/\s+/).filter(Boolean).forEach((c) => classes.add(c))
    },
    get className() {
      return Array.from(classes).join(" ")
    },
    classList: {
      add: (c) => classes.add(c),
      remove: (c) => classes.delete(c),
      contains: (c) => classes.has(c),
    },
    setAttribute(k, v) {
      this.attrs[k] = v
    },
    appendChild(c) {
      c.parentNode = this
      this.children.push(c)
      return c
    },
    removeChild(c) {
      this.children = this.children.filter((x) => x !== c)
    },
    addEventListener(t, fn) {
      ;(listeners[t] ||= []).push(fn)
    },
    removeEventListener() {},
    fire(t, ev) {
      for (const fn of listeners[t] || []) fn(ev)
    },
  }
}

let windowListeners

// The server renders the target (`Partials.Attach.drop_target/1`, asserted
// in attach_menu_test.exs); the hook only finds it and toggles `lg:flex`.
function mount() {
  const el = fakeEl()
  el.getBoundingClientRect = () => ({ top: 40, left: 448, width: 832, height: 760 })
  const overlay = fakeEl()
  overlay.className =
    "pointer-events-none fixed z-40 hidden items-center justify-center bg-black/40 p-6"
  el.querySelector = (sel) => (sel === "[data-role=drop-target]" ? overlay : null)
  const hook = Object.create(DragDropUpload)
  hook.el = el
  hook.mounted()
  return { hook, el, overlay }
}

const filesDT = (files) => ({ types: ["Files"], files, dropEffect: "" })
const textDT = () => ({ types: ["text/plain"], files: [] })
const ev = (dataTransfer) => ({ dataTransfer, preventDefault: vi.fn() })
const visible = (overlay) => overlay.classList.contains("lg:flex")

beforeEach(() => {
  stage.stageFiles.mockClear()
  windowListeners = {}
  vi.stubGlobal("document", { createElement: (t) => fakeEl(t) })
  vi.stubGlobal("getComputedStyle", () => ({ position: "relative" }))
  vi.stubGlobal("window", {
    addEventListener: (t, fn) => ((windowListeners[t] ||= []).push(fn)),
    removeEventListener: () => {},
  })
})

afterEach(() => vi.unstubAllGlobals())

describe("hasFiles", () => {
  it("is true only for a drag carrying Files", () => {
    expect(hasFiles(filesDT([]))).toBe(true)
    expect(hasFiles(textDT())).toBe(false)
    expect(hasFiles(undefined)).toBe(false)
  })
})

describe("DragDropUpload", () => {
  it("starts hidden; below lg it stays hidden whatever the hook does", () => {
    const { overlay } = mount()
    expect(visible(overlay)).toBe(false)
    expect(overlay.className).toContain("hidden")
  })

  it("dragenter with Files shows the overlay over the conversation's box", () => {
    const { el, overlay } = mount()
    el.fire("dragenter", ev(filesDT([])))
    expect(visible(overlay)).toBe(true)
    expect(overlay.style).toEqual({ top: "40px", left: "448px", width: "832px", height: "760px" })
  })

  it("a nested dragenter/dragleave pair keeps it; leaving to 0 hides it", () => {
    const { el, overlay } = mount()
    el.fire("dragenter", ev(filesDT([])))
    el.fire("dragenter", ev(filesDT([]))) // a child
    el.fire("dragleave", ev(filesDT([]))) // left the child
    expect(visible(overlay)).toBe(true)
    el.fire("dragleave", ev(filesDT([])))
    expect(visible(overlay)).toBe(false)
  })

  it("Escape hides it", () => {
    const { el, overlay } = mount()
    el.fire("dragenter", ev(filesDT([])))
    for (const fn of windowListeners.keydown) fn({ key: "Escape" })
    expect(visible(overlay)).toBe(false)
  })

  it("drop hides it and stages every file, a PDF included", () => {
    const { hook, el, overlay } = mount()
    const files = [
      new File(["a"], "a.png", { type: "image/png" }),
      new File(["b"], "b.png", { type: "image/png" }),
      new File(["%PDF"], "spec.pdf", { type: "application/pdf" }),
    ]
    el.fire("dragenter", ev(filesDT(files)))
    const drop = ev(filesDT(files))
    el.fire("drop", drop)

    expect(visible(overlay)).toBe(false)
    expect(drop.preventDefault).toHaveBeenCalled()
    expect(stage.stageFiles).toHaveBeenCalledTimes(1)
    expect(stage.stageFiles.mock.calls[0][0]).toBe(hook)
    expect(stage.stageFiles.mock.calls[0][1]).toEqual(files)
  })

  it("a text drag never shows it and is left to the browser", () => {
    const { el, overlay } = mount()
    const enter = ev(textDT())
    el.fire("dragenter", enter)
    expect(visible(overlay)).toBe(false)
    expect(enter.preventDefault).not.toHaveBeenCalled()
    const drop = ev(textDT())
    el.fire("drop", drop)
    expect(drop.preventDefault).not.toHaveBeenCalled()
    expect(stage.stageFiles).not.toHaveBeenCalled()
  })
})
