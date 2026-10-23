import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"

/**
 * The phone ＋ sheet's numbered library strip (redesign rung 11, task
 * 01a1557a-9de3 stage 2). Picks number 1..N in pick order, a deselect
 * renumbers, 'Attach N items' is hidden at 0, Attach hands the Files to the
 * ONE staging function in pick order, and closing the sheet clears the
 * selection and revokes every object URL.
 *
 * vitest runs in plain node (no jsdom): a minimal fake DOM below supports
 * exactly what the hook touches.
 */

const stage = vi.hoisted(() => ({ stageFiles: vi.fn() }))
vi.mock("../../js/attach_stage", () => ({ stageFiles: stage.stageFiles }))

import AttachSheet, { attachLabel, createSelection } from "../../js/hooks/attach_sheet.js"

class FakeEl {
  constructor(tag, attrs = {}) {
    this.tagName = tag.toUpperCase()
    this.attrs = { ...attrs }
    this.children = []
    this.parent = null
    this.listeners = {}
    this.hidden = false
    this.className = ""
    this.textContent = ""
  }
  setAttribute(k, v) {
    this.attrs[k] = String(v)
  }
  getAttribute(k) {
    return k in this.attrs ? this.attrs[k] : null
  }
  appendChild(c) {
    c.parent = this
    this.children.push(c)
    return c
  }
  insertBefore(c, ref) {
    c.parent = this
    const i = ref ? this.children.indexOf(ref) : -1
    if (i === -1) this.children.push(c)
    else this.children.splice(i, 0, c)
    return c
  }
  remove() {
    if (this.parent) this.parent.children = this.parent.children.filter((x) => x !== this)
    this.parent = null
  }
  all() {
    return this.children.flatMap((c) => [c, ...c.all()])
  }
  querySelectorAll(sel) {
    const attr = sel.match(/^\[([\w-]+)\]$/)[1]
    return this.all().filter((e) => e.getAttribute(attr) !== null)
  }
  querySelector(sel) {
    return this.querySelectorAll(sel)[0] || null
  }
  closest(sel) {
    const attr = sel.match(/^\[([\w-]+)\]$/) && sel.match(/^\[([\w-]+)\]$/)[1]
    const id = sel.match(/^#([\w-]+)$/) && sel.match(/^#([\w-]+)$/)[1]
    let e = this
    while (e) {
      if (attr && e.getAttribute(attr) !== null) return e
      if (id && e.getAttribute("id") === id) return e
      e = e.parent
    }
    return null
  }
  addEventListener(t, fn) {
    ;(this.listeners[t] ||= []).push(fn)
  }
  fire(t, ev) {
    for (const fn of this.listeners[t] || []) fn(ev)
  }
}

let doc
let observers
let revoked
let urlN

function setup() {
  const el = new FakeEl("div", { id: "attach-strip" })
  el.appendChild(new FakeEl("input", { "data-attach-input": "library", id: "attach-input-library" }))
  const wrap = new FakeEl("div", { id: "attach-go-wrap" })
  const go = new FakeEl("button", { id: "attach-go" })
  wrap.appendChild(go)
  const sheet = new FakeEl("div", { id: "attach-sheet", "data-open": "true" })
  const byId = { "attach-go": go, "attach-go-wrap": wrap, "attach-sheet": sheet }
  doc = {
    listeners: {},
    getElementById: (id) => byId[id] || null,
    createElement: (tag) => new FakeEl(tag),
    addEventListener(t, fn) {
      ;(this.listeners[t] ||= []).push(fn)
    },
    removeEventListener() {},
    fire(t, ev) {
      for (const fn of this.listeners[t] || []) fn(ev)
    },
  }
  vi.stubGlobal("document", doc)
  vi.stubGlobal("Element", FakeEl)
  observers = []
  vi.stubGlobal(
    "MutationObserver",
    class {
      constructor(cb) {
        this.cb = cb
        observers.push(this)
      }
      observe() {}
      disconnect() {}
    },
  )
  revoked = []
  urlN = 0
  vi.stubGlobal("URL", { createObjectURL: () => `blob:${++urlN}`, revokeObjectURL: (u) => revoked.push(u) })
  vi.stubGlobal("window", { URL: globalThis.URL })

  const hook = Object.create(AttachSheet)
  hook.el = el
  hook.pushEvent = vi.fn()
  hook.mounted()
  return { hook, el, go, wrap, sheet }
}

function pickLibrary(el, files) {
  const input = el.querySelector("[data-attach-input]")
  input.files = files
  el.fire("change", { target: input })
}

function tiles(el) {
  return el.querySelectorAll("[data-pick-id]")
}

const png = (name) => new File(["x"], name, { type: "image/png" })

beforeEach(() => stage.stageFiles.mockClear())
afterEach(() => vi.unstubAllGlobals())

describe("attachLabel", () => {
  it("says 'Attach 1 item' and 'Attach 3 items'", () => {
    expect(attachLabel(1)).toBe("Attach 1 item")
    expect(attachLabel(3)).toBe("Attach 3 items")
  })
})

describe("createSelection", () => {
  it("numbers in pick order and renumbers after a deselect", () => {
    const s = createSelection()
    const a = s.add("a")
    const b = s.add("b")
    const c = s.add("c")
    expect([s.number(a), s.number(b), s.number(c)]).toEqual([1, 2, 3])
    s.toggle(b)
    expect([s.number(a), s.number(b), s.number(c)]).toEqual([1, 0, 2])
    s.toggle(b)
    expect(s.selectedFiles()).toEqual(["a", "c", "b"])
  })
})

describe("AttachSheet hook", () => {
  it("hides 'Attach N items' at 0 picks", () => {
    const { wrap } = setup()
    expect(wrap.hidden).toBe(true)
  })

  it("adds library picks pre-selected, numbered 1..N in pick order", () => {
    const { el, wrap, go } = setup()
    pickLibrary(el, [png("one.png"), png("two.png"), png("three.png")])

    const t = tiles(el)
    expect(t.map((x) => x.getAttribute("aria-label"))).toEqual([
      "one.png, selected 1",
      "two.png, selected 2",
      "three.png, selected 3",
    ])
    expect(t.every((x) => x.getAttribute("aria-checked") === "true")).toBe(true)
    expect(wrap.hidden).toBe(false)
    expect(go.textContent).toBe("Attach 3 items")
    // Neutral selection: the badge is base-content, never primary.
    const badge = t[0].children.find((c) => c.getAttribute("aria-hidden") === "true")
    expect(badge.className).toContain("bg-base-content")
    expect(badge.className).not.toContain("primary")
  })

  it("deselecting the 2nd of 3 renumbers to 1..2 and reads 'Attach 2 items'", () => {
    const { el, go } = setup()
    pickLibrary(el, [png("one.png"), png("two.png"), png("three.png")])
    el.fire("click", { target: tiles(el)[1] })

    expect(tiles(el).map((x) => x.getAttribute("aria-label"))).toEqual([
      "one.png, selected 1",
      "two.png",
      "three.png, selected 2",
    ])
    expect(go.textContent).toBe("Attach 2 items")

    el.fire("click", { target: tiles(el)[1] })
    expect(tiles(el)[0].getAttribute("aria-label")).toBe("one.png, selected 1")
    expect(go.textContent).toBe("Attach 3 items")
  })

  it("reads 'Attach 1 item' for one pick", () => {
    const { el, go } = setup()
    pickLibrary(el, [png("one.png")])
    expect(go.textContent).toBe("Attach 1 item")
  })

  it("Attach stages the selected Files in pick order and closes the menu; nothing before", () => {
    const { hook, el, go } = setup()
    const files = [png("one.png"), png("two.png"), png("three.png")]
    pickLibrary(el, files)
    expect(stage.stageFiles).not.toHaveBeenCalled()

    el.fire("click", { target: tiles(el)[0] })
    el.fire("click", { target: tiles(el)[0] })
    doc.fire("click", { target: go })

    expect(stage.stageFiles).toHaveBeenCalledTimes(1)
    expect(stage.stageFiles.mock.calls[0][0]).toBe(hook)
    expect(stage.stageFiles.mock.calls[0][1]).toEqual([files[1], files[2], files[0]])
    expect(hook.pushEvent).toHaveBeenCalledWith("attach_menu_close", {})
  })

  it("closing the sheet empties the strip, hides Attach and revokes every object URL", () => {
    const { el, wrap, sheet } = setup()
    pickLibrary(el, [png("one.png"), png("two.png")])
    expect(revoked).toEqual([])

    sheet.setAttribute("data-open", "false")
    observers[0].cb([])

    expect(tiles(el)).toEqual([])
    expect(wrap.hidden).toBe(true)
    expect(revoked.sort()).toEqual(["blob:1", "blob:2"])

    // Reopen: nothing pre-selected.
    sheet.setAttribute("data-open", "true")
    observers[0].cb([])
    expect(tiles(el)).toEqual([])
  })

  it("a camera / file pick stages straight into the tray and closes", () => {
    const { hook, el } = setup()
    const cam = new FakeEl("input", { "data-attach-input": "camera" })
    el.appendChild(cam)
    const shot = png("IMG_0001.png")
    cam.files = [shot]
    el.fire("change", { target: cam })
    expect(stage.stageFiles).toHaveBeenCalledWith(hook, [shot])
    expect(hook.pushEvent).toHaveBeenCalledWith("attach_menu_close", {})
    expect(tiles(el)).toEqual([])
  })
})
