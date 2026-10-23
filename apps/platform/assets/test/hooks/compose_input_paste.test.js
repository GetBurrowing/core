import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"

/**
 * Paste-to-thumbnail in the chat composer (redesign rung 11, task
 * 01a1557a-9de3 stage 1).
 *
 * The composer's `paste` listener stages image clipboard items through the
 * ONE staging function (`attach_stage.js` `stageFiles`) and preventDefaults
 * only when it found an image; a text paste is left to the browser.
 * `stageFiles` sends files over the inline cap to the large-file path
 * (`routeFiles`) and the rest into LiveView's upload (`hook.uploadTo`).
 *
 * vitest runs in plain node (no jsdom): `window`, `document` and `CSS` are
 * stubbed and the real listener is driven through a fake textarea.
 */

const stage = vi.hoisted(() => ({ stageFiles: vi.fn(), toast: vi.fn(), installRetry: vi.fn() }))
const large = vi.hoisted(() => ({ routeFiles: vi.fn(() => []) }))

vi.mock("../../js/attach_stage.js", async (importOriginal) => {
  const actual = await importOriginal()
  return {
    ...actual,
    stageFiles: stage.stageFiles,
    toast: stage.toast,
    installRetry: stage.installRetry,
  }
})

vi.mock("../../js/hooks/large_upload", async (importOriginal) => {
  const actual = await importOriginal()
  return { ...actual, routeFiles: large.routeFiles, inlineMaxFromDom: () => 15_000_000 }
})

import ComposeInput from "../../js/hooks/compose_input.js"
import { fakeDocument } from "../lib/fake_dom.js"

const MB = 1024 * 1024

function fileOfSize(bytes, name, type) {
  const f = new File(["x"], name, { type })
  Object.defineProperty(f, "size", { value: bytes })
  return f
}

function imageItem(blob) {
  return { kind: "file", type: blob.type, getAsFile: () => blob }
}

function textItem() {
  return { kind: "string", type: "text/plain", getAsFile: () => null }
}

function fakeTextarea(inComposeForm = true) {
  const listeners = {}
  return {
    value: "",
    defaultValue: "",
    selectionStart: 0,
    dataset: {},
    style: {},
    addEventListener(type, fn) {
      ;(listeners[type] ||= []).push(fn)
    },
    fire(type, event) {
      for (const fn of listeners[type] || []) fn(event)
    },
    closest(sel) {
      return inComposeForm && sel === "#compose-form" ? { id: "compose-form" } : null
    },
    setAttribute() {},
  }
}

function pasteEvent(items) {
  return { clipboardData: { items }, preventDefault: vi.fn() }
}

function mountHook(el) {
  const hook = Object.create(ComposeInput)
  hook.el = el
  hook.pushEvent = vi.fn()
  hook.handleEvent = vi.fn()
  hook.mounted()
  return hook
}

beforeEach(() => {
  stage.stageFiles.mockClear()
  stage.toast.mockClear()
  large.routeFiles.mockClear()
  vi.stubGlobal("window", { scrollTo: vi.fn(), matchMedia: () => ({ matches: false }) })
  vi.stubGlobal("document", { activeElement: null, getElementById: () => ({ id: "compose-form" }) })
  vi.stubGlobal("CSS", { supports: () => true })
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("ComposeInput paste listener", () => {
  it("stages an image clipboard item through stageFiles and preventDefaults", () => {
    const el = fakeTextarea()
    const hook = mountHook(el)
    const e = pasteEvent([imageItem(new Blob(["png"], { type: "image/png" }))])

    el.fire("paste", e)

    expect(e.preventDefault).toHaveBeenCalledTimes(1)
    expect(stage.stageFiles).toHaveBeenCalledTimes(1)
    const [calledHook, files] = stage.stageFiles.mock.calls[0]
    expect(calledHook).toBe(hook)
    expect(files).toHaveLength(1)
    expect(files[0].name).toMatch(/^pasted-image-\d+\.png$/)
    expect(stage.toast).toHaveBeenCalledWith("Image attached")
  })

  it("names a pasted File 'pasted-image-<ts>.<ext>' even when the browser named it image.png", async () => {
    const { imageFilesFromClipboard } = await vi.importActual("../../js/attach_stage.js")
    // What Chrome hands a real paste: a File already called "image.png".
    const chromeFile = () => new File(["png"], "image.png", { type: "image/png" })
    const first = imageFilesFromClipboard({ items: [imageItem(chromeFile()), imageItem(chromeFile())] }, 1000)
    const second = imageFilesFromClipboard({ items: [imageItem(chromeFile())] }, 1000)

    const names = [...first, ...second].map((f) => f.name)
    for (const name of names) expect(name).toMatch(/^pasted-image-\d+\.png$/)
    // Unique per file, across pastes, even inside one millisecond.
    expect(new Set(names).size).toBe(3)
    expect(names).not.toContain("image.png")
  })

  it("keeps the caption focused when Send is pressed (a phone mousedown must not blur it)", async () => {
    const { shouldHoldFocusOnSend } = await vi.importActual("../../js/hooks/compose_input.js")
    const el = { id: "caption" }
    const sendIcon = { closest: (sel) => (sel === 'button[type="submit"]' ? { type: "submit" } : null) }
    const elsewhere = { closest: () => null }

    expect(shouldHoldFocusOnSend(sendIcon, el, el)).toBe(true)
    // Positive controls: not focused, or not on Send, leaves the mousedown alone.
    expect(shouldHoldFocusOnSend(sendIcon, { id: "other" }, el)).toBe(false)
    expect(shouldHoldFocusOnSend(elsewhere, el, el)).toBe(false)
  })

  it("leaves a text paste alone: no stageFiles, no preventDefault (positive control)", () => {
    const el = fakeTextarea()
    mountHook(el)
    const e = pasteEvent([textItem()])

    el.fire("paste", e)

    expect(e.preventDefault).not.toHaveBeenCalled()
    expect(stage.stageFiles).not.toHaveBeenCalled()
  })

  it("says '<N> images attached' for several images", () => {
    const el = fakeTextarea()
    mountHook(el)
    const blob = () => new Blob(["png"], { type: "image/png" })
    el.fire("paste", pasteEvent([imageItem(blob()), imageItem(blob())]))
    expect(stage.toast).toHaveBeenCalledWith("2 images attached")
  })

  it("does nothing outside the chat composer (thread and steering composers have no tray)", () => {
    const el = fakeTextarea(false)
    mountHook(el)
    const e = pasteEvent([imageItem(new Blob(["png"], { type: "image/png" }))])
    el.fire("paste", e)
    expect(e.preventDefault).not.toHaveBeenCalled()
    expect(stage.stageFiles).not.toHaveBeenCalled()
  })
})

// Redesign rung 10 (task 01a1557a-997a stage 2): the chat composer is now a
// contenteditable chip field. An image paste still stages through the ONE
// staging function; a text paste goes in as plain text (insertText), never
// as clipboard markup.
describe("ComposeInput paste on the chip field", () => {
  function richField() {
    const doc = fakeDocument()
    const form = doc.createElement("form")
    form.setAttribute("id", "compose-form")
    const el = doc.createElement("div")
    el.setAttribute("contenteditable", "true")
    form.appendChild(el)
    doc.getElementById = () => null
    doc.execCommand = vi.fn()
    vi.stubGlobal("document", doc)
    vi.stubGlobal("window", { scrollTo: vi.fn(), matchMedia: () => ({ matches: true }), getSelection: () => null })
    const hook = mountHook(el)
    return { doc, el, hook }
  }

  it("stages a pasted image and inserts no text", () => {
    const { doc, el, hook } = richField()
    const e = pasteEvent([imageItem(new Blob(["png"], { type: "image/png" }))])
    e.clipboardData.getData = () => ""
    el.fire("paste", e)
    expect(e.preventDefault).toHaveBeenCalledTimes(1)
    expect(stage.stageFiles).toHaveBeenCalledTimes(1)
    expect(stage.stageFiles.mock.calls[0][0]).toBe(hook)
    expect(doc.execCommand).not.toHaveBeenCalled()
    expect(stage.installRetry).toHaveBeenCalled()
  })

  it("inserts a text paste as plain text only", () => {
    const { doc, el } = richField()
    const e = pasteEvent([textItem()])
    e.clipboardData.getData = (type) => (type === "text/plain" ? "line one\nline two" : "<b>rich</b>")
    el.fire("paste", e)
    expect(e.preventDefault).toHaveBeenCalledTimes(1)
    expect(stage.stageFiles).not.toHaveBeenCalled()
    expect(doc.execCommand).toHaveBeenCalledWith("insertText", false, "line one\nline two")
  })
})

describe("stageFiles routing", () => {
  it("batches files staged moments apart into ONE uploadTo", async () => {
    const { stageFiles, BATCH_MS } = await vi.importActual("../../js/attach_stage.js")
    const hook = { uploadTo: vi.fn(), pushEvent: vi.fn() }
    const a = fileOfSize(1 * MB, "a.png", "image/png")
    const b = fileOfSize(2 * MB, "b.pdf", "application/pdf")

    vi.useFakeTimers()
    stageFiles(hook, [a])
    vi.advanceTimersByTime(BATCH_MS - 10)
    stageFiles(hook, [b])
    expect(hook.uploadTo).not.toHaveBeenCalled()
    vi.runAllTimers()
    vi.useRealTimers()

    expect(hook.uploadTo).toHaveBeenCalledTimes(1)
    expect(hook.uploadTo.mock.calls[0][2]).toEqual([a, b])
  })

  it("sends a 16 MB image to routeFiles and a 1 MB image to uploadTo", async () => {
    const { stageFiles } = await vi.importActual("../../js/attach_stage.js")
    const hook = { uploadTo: vi.fn(), pushEvent: vi.fn() }
    const big = fileOfSize(16 * MB, "big.png", "image/png")
    const small = fileOfSize(1 * MB, "small.png", "image/png")

    vi.useFakeTimers()
    stageFiles(hook, [big, small])
    vi.runAllTimers()
    vi.useRealTimers()

    expect(large.routeFiles).toHaveBeenCalledTimes(1)
    expect(large.routeFiles.mock.calls[0][1]).toEqual([big])
    expect(hook.uploadTo).toHaveBeenCalledTimes(1)
    const [target, name, files] = hook.uploadTo.mock.calls[0]
    expect(target).toEqual({ id: "compose-form" })
    expect(name).toBe("attachments")
    expect(files).toEqual([small])
  })
})
