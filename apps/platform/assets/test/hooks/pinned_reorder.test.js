import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import PinnedReorder, {
  DRAG_THRESHOLD_PX,
  LG_QUERY,
  SWALLOW_GRACE_MS,
  dropPosition,
} from "../../js/hooks/pinned_reorder.js"
import RowLongPress, { HOLD_MS } from "../../js/hooks/row_long_press.js"
import ChatListSettle from "../../js/hooks/chat_list_settle.js"

/**
 * `PinnedReorder` (Burrow redesign 25 stage 3): the desktop drag and the
 * Alt+arrow keys for pinned conversation rows.
 *
 * vitest runs in plain node here, as every other hook test does (jsdom is not
 * a dependency of this package), so the DOM is a small fake below: elements
 * with attributes, children, capture/bubble dispatch up to the document,
 * `closest` / `querySelectorAll` for compound attribute selectors, and a
 * fixed `getBoundingClientRect` per node. Fake timers drive the swallow
 * window and the long-press hold.
 */

// -- a minimal DOM ------------------------------------------------------------

const SELECTOR_PART = /#([\w-]+)|\[([\w-]+)(?:="([^"]*)")?\]|^([a-z]+)/g

function parseSelector(sel) {
  const parts = []
  for (const m of sel.trim().matchAll(SELECTOR_PART)) {
    if (m[1]) parts.push({ attr: "id", value: m[1] })
    else if (m[2]) parts.push({ attr: m[2], value: m[3] })
    else if (m[4]) parts.push({ tag: m[4].toUpperCase() })
  }
  return parts
}

let doc

class El {
  constructor(tag, attrs = {}, rect = {}) {
    this.tagName = tag.toUpperCase()
    this.nodeType = 1
    this.attrs = new Map()
    this.children = []
    this.parentNode = null
    this.listeners = []
    this.style = {}
    this.rect = { top: 0, bottom: 0, left: 0, ...rect }
    this.captured = []
    for (const [k, v] of Object.entries(attrs)) this.setAttribute(k, v)
  }

  get dataset() {
    const out = {}
    for (const [k, v] of this.attrs) {
      if (!k.startsWith("data-")) continue
      const key = k.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())
      out[key] = v
    }
    return out
  }

  get className() {
    return this.getAttribute("class") || ""
  }
  set className(v) {
    this.setAttribute("class", v)
  }
  get firstChild() {
    return this.children[0] || null
  }

  getAttribute(k) {
    return this.attrs.has(k) ? this.attrs.get(k) : null
  }
  setAttribute(k, v) {
    this.attrs.set(k, String(v))
  }
  removeAttribute(k) {
    this.attrs.delete(k)
  }
  hasAttribute(k) {
    return this.attrs.has(k)
  }
  getAttributeNames() {
    return [...this.attrs.keys()]
  }

  appendChild(child) {
    if (child.parentNode) child.parentNode.removeChild(child)
    child.parentNode = this
    this.children.push(child)
    return child
  }
  removeChild(child) {
    this.children = this.children.filter((c) => c !== child)
    child.parentNode = null
    return child
  }
  contains(node) {
    for (let n = node; n; n = n.parentNode) if (n === this) return true
    return false
  }

  matches(sel) {
    return parseSelector(sel).every((p) =>
      p.tag ? this.tagName === p.tag : p.value === undefined ? this.attrs.has(p.attr) : this.getAttribute(p.attr) === p.value
    )
  }
  closest(sel) {
    for (let n = this; n && n.nodeType === 1 && n !== doc; n = n.parentNode) if (n.matches(sel)) return n
    return null
  }
  querySelectorAll(sel) {
    const out = []
    const walk = (n) => {
      for (const c of n.children) {
        if (c.matches(sel)) out.push(c)
        walk(c)
      }
    }
    walk(this)
    return out
  }
  querySelector(sel) {
    return this.querySelectorAll(sel)[0] || null
  }

  cloneNode(deep) {
    const copy = new El(this.tagName.toLowerCase(), Object.fromEntries(this.attrs), this.rect)
    if (deep) for (const c of this.children) copy.appendChild(c.cloneNode(true))
    return copy
  }

  getBoundingClientRect() {
    return { ...this.rect }
  }
  focus() {
    doc.activeElement = this
  }
  setPointerCapture(id) {
    this.captured.push(id)
  }
  releasePointerCapture() {}

  addEventListener(type, fn, opts) {
    const capture = opts === true || !!(opts && opts.capture)
    this.listeners.push({ type, fn, capture })
  }
  removeEventListener(type, fn, opts) {
    const capture = opts === true || !!(opts && opts.capture)
    this.listeners = this.listeners.filter((l) => !(l.type === type && l.fn === fn && l.capture === capture))
  }

  // Capture top-down, then target and bubble bottom-up, like the platform.
  dispatch(type, props = {}) {
    const event = {
      type,
      target: this,
      defaultPrevented: false,
      stopped: false,
      preventDefault() {
        this.defaultPrevented = true
      },
      stopPropagation() {
        this.stopped = true
      },
      ...props,
    }
    const path = []
    for (let n = this; n; n = n.parentNode) path.push(n)
    const run = (node, capture) => {
      for (const l of [...node.listeners]) {
        if (l.type === type && l.capture === capture) l.fn(event)
      }
    }
    for (const node of [...path].reverse()) {
      if (event.stopped) return event
      run(node, true)
    }
    for (const node of path) {
      if (event.stopped) return event
      run(node, false)
    }
    return event
  }
}

function makeDocument() {
  const d = new El("#document")
  d.activeElement = null
  d.createElement = (tag) => new El(tag)
  return d
}

// -- the Pinned fixture ---------------------------------------------------------

const ROW_H = 44

// Rows top to bottom from y=0, ROW_H each. `spec` items:
//   {id, task: true}               a pinned task row (no data-reorder)
//   {id, pos, restricted: true}    a restricted row: position, no link
//   {id, pos}                      a draggable conversation row
function buildRows(container, spec, count) {
  spec.forEach((item, i) => {
    const rect = { top: i * ROW_H, bottom: (i + 1) * ROW_H, left: 0 }
    if (item.restricted) {
      const div = new El(
        "div",
        { "data-role": "restricted-channel-row", "data-space-id": item.id, "data-pinned-position": item.pos },
        rect
      )
      container.appendChild(div)
      return
    }
    const wrap = new El("div", { "data-role": "chat-list-row-wrap", "data-space-id": item.id }, rect)
    const attrs = {
      id: `chat-list-row-${item.id}`,
      "data-role": "chat-list-row",
      "data-space-id": item.id,
      class: "chat-list-row group/row relative flex lg:hover:bg-base-300",
      "data-long-press-event": "open_list_sheet",
      "data-long-press-sheet": "row",
      "data-long-press-space-id": item.id,
    }
    if (!item.task) {
      attrs["data-reorder"] = "true"
      attrs["data-pinned-position"] = item.pos
      attrs["data-pinned-count"] = count
    }
    const link = new El("a", attrs, rect)
    link.appendChild(new El("span", { "data-role": "chat-list-row-name" }, { ...rect, left: 60 }))
    wrap.appendChild(link)
    container.appendChild(wrap)
  })
}

const THREE = [
  { id: "task", task: true },
  { id: "a", pos: 0 },
  { id: "b", pos: 1 },
  { id: "c", pos: 2 },
]

let lg
let pushes
let replies

function mount(spec = THREE, count = 3, { scroller = false } = {}) {
  const parent = scroller ? new El("div", { id: "chat-list-scroller" }) : doc
  if (scroller) doc.appendChild(parent)
  const el = new El("div", { id: "chat-list-rows-pinned", "data-role": "chat-list-section-rows" })
  el.appendChild(new El("div", { id: "pinned-reorder-overlay", "data-role": "pinned-reorder-overlay" }))
  buildRows(el, spec, count)
  parent.appendChild(el)

  const hook = Object.assign(Object.create(PinnedReorder), {
    el,
    pushEvent: (name, payload, onReply) => {
      pushes.push([name, payload])
      if (onReply) replies.push(onReply)
    },
  })
  hook.mounted()
  return { hook, el, parent }
}

const row = (el, id) => el.querySelector(`[data-space-id="${id}"][data-role="chat-list-row"]`)
const mid = (i) => i * ROW_H + ROW_H / 2
const moves = () => pushes.filter(([name]) => name === "move_pinned_row")
const overlayParts = (el) => el.querySelector('[data-role="pinned-reorder-overlay"]').children

function pointer(target, type, x, y, extra = {}) {
  return target.dispatch(type, { pointerType: "mouse", button: 0, pointerId: 1, clientX: x, clientY: y, ...extra })
}

// Press at (x, y0), move through `ys`, release at the last y on `upTarget`.
function drag(target, y0, ys, { upTarget = target, x = 100, extra = {} } = {}) {
  pointer(target, "pointerdown", x, y0, extra)
  for (const y of ys) pointer(upTarget, "pointermove", x, y, extra)
  pointer(upTarget, "pointerup", x, ys[ys.length - 1], extra)
}

const click = (target) => target.dispatch("click")

beforeEach(() => {
  vi.useFakeTimers()
  doc = makeDocument()
  vi.stubGlobal("document", doc)
  vi.stubGlobal("navigator", { vibrate: vi.fn() })
  vi.stubGlobal("requestAnimationFrame", (fn) => setTimeout(fn, 0))
  lg = true
  vi.stubGlobal("window", { matchMedia: vi.fn((q) => ({ matches: lg && q === LG_QUERY })) })
  pushes = []
  replies = []
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe("PinnedReorder", () => {
  it("uses the direction's constants", () => {
    expect(DRAG_THRESHOLD_PX).toBe(4)
    expect(LG_QUERY).toBe("(min-width: 1024px)")
  })

  it("1. a 3px move then release pushes nothing and leaves the click alone", () => {
    const { el } = mount()
    const c = row(el, "c")
    drag(c, mid(3), [mid(3) - 3])
    expect(pushes).toEqual([])
    expect(click(c).defaultPrevented).toBe(false)
  })

  it("2. boundary: 3px does not start a drag, 4px does", () => {
    const { el } = mount()
    const c = row(el, "c")

    pointer(c, "pointerdown", 100, mid(3))
    pointer(c, "pointermove", 100, mid(3) - 3)
    expect(c.getAttribute("data-editing")).toBe(null)
    expect(overlayParts(el)).toHaveLength(0)

    pointer(c, "pointermove", 100, mid(3) - 4)
    expect(c.getAttribute("data-editing")).toBe("true")
    expect(overlayParts(el).map((n) => n.getAttribute("data-role"))).toEqual([
      "pinned-reorder-origin",
      "pinned-reorder-ghost",
      "pinned-reorder-line",
    ])
    expect(c.captured).toEqual([1])
  })

  it("3. dragging position 2 to position 0 pushes to_position 0 and swallows the click", () => {
    const { el } = mount()
    const c = row(el, "c")
    // Above the midpoint of "a" (row 1), below the task row's.
    drag(c, mid(3), [mid(3) - 10, mid(1) - 5])
    expect(moves()).toEqual([["move_pinned_row", { space_id: "c", to_position: 0 }]])

    const release = click(c)
    expect(release.defaultPrevented).toBe(true)
    expect(release.stopped).toBe(true)

    // Only that one click: the next is a real one.
    expect(click(c).defaultPrevented).toBe(false)
    expect(c.getAttribute("data-editing")).toBe(null)
    expect(overlayParts(el)).toHaveLength(0)
  })

  it("the swallow clears itself when a drag produced no click", () => {
    const { el } = mount()
    const c = row(el, "c")
    drag(c, mid(3), [mid(1) - 5])
    vi.advanceTimersByTime(SWALLOW_GRACE_MS)
    expect(click(c).defaultPrevented).toBe(false)
  })

  it("4. past the last row parks at count-1, above the first conversation row at 0, and the lifted row stays inside Pinned", () => {
    const { el } = mount()
    const a = row(el, "a")

    pointer(a, "pointerdown", 100, mid(1))
    pointer(a, "pointermove", 100, mid(1) + 10)
    pointer(a, "pointermove", 100, 2000)
    const ghost = overlayParts(el)[1]
    // The band is rows 1..3 (44..176); a 44px row parks at 132.
    expect(ghost.style.top).toBe(`${3 * ROW_H}px`)
    const line = overlayParts(el)[2]
    expect(line.getAttribute("data-to-position")).toBe("2")
    pointer(a, "pointerup", 100, 2000)
    expect(moves()).toEqual([["move_pinned_row", { space_id: "a", to_position: 2 }]])

    pushes = []
    const c = row(el, "c")
    pointer(c, "pointerdown", 100, mid(3))
    pointer(c, "pointermove", 100, mid(3) - 10)
    // Over the task row and above the section.
    pointer(c, "pointermove", 100, -500)
    expect(overlayParts(el)[1].style.top).toBe(`${ROW_H}px`)
    pointer(c, "pointerup", 100, -500)
    expect(moves()).toEqual([["move_pinned_row", { space_id: "c", to_position: 0 }]])
  })

  it("dropPosition clamps to the run", () => {
    const slots = [
      { position: 0, top: 0, bottom: 10 },
      { position: 1, top: 10, bottom: 20 },
    ]
    expect(dropPosition(slots, 2, -100, 3)).toBe(0)
    expect(dropPosition(slots, 0, 100, 2)).toBe(1)
  })

  it("5. a drop at the same position pushes nothing", () => {
    const { el } = mount()
    const b = row(el, "b")
    drag(b, mid(2), [mid(2) + 10, mid(2) + 2])
    expect(pushes).toEqual([])
  })

  it("6. below lg nothing drags, and touch never drags at lg", () => {
    lg = false
    const { el } = mount()
    const c = row(el, "c")
    drag(c, mid(3), [mid(3) - 10, mid(1) - 5])
    expect(pushes).toEqual([])
    expect(click(c).defaultPrevented).toBe(false)

    lg = true
    drag(c, mid(3), [mid(3) - 10, mid(1) - 5], { extra: { pointerType: "touch" } })
    expect(pushes).toEqual([])
    expect(c.getAttribute("data-editing")).toBe(null)
  })

  it("pen drags like a mouse; a secondary button does not", () => {
    const { el } = mount()
    const c = row(el, "c")
    drag(c, mid(3), [mid(3) - 10, mid(1) - 5], { extra: { button: 2 } })
    expect(pushes).toEqual([])
    drag(c, mid(3), [mid(3) - 10, mid(1) - 5], { extra: { pointerType: "pen" } })
    expect(moves()).toEqual([["move_pinned_row", { space_id: "c", to_position: 0 }]])
  })

  it("7. Alt+ArrowUp pushes move_pinned_step up; other chords and narrow widths push nothing", () => {
    const { hook, el } = mount()
    const b = row(el, "b")

    for (const mods of [{}, { shiftKey: true }, { metaKey: true }, { ctrlKey: true }]) {
      const e = b.dispatch("keydown", { key: "ArrowUp", ...mods })
      expect(e.defaultPrevented).toBe(false)
    }
    for (const mods of [{ altKey: true, shiftKey: true }, { altKey: true, ctrlKey: true }, { altKey: true, metaKey: true }]) {
      b.dispatch("keydown", { key: "ArrowUp", ...mods })
    }
    expect(pushes).toEqual([])

    lg = false
    b.dispatch("keydown", { key: "ArrowUp", altKey: true })
    expect(pushes).toEqual([])

    lg = true
    b.focus()
    const e = b.dispatch("keydown", { key: "ArrowUp", altKey: true })
    expect(e.defaultPrevented).toBe(true)
    b.dispatch("keydown", { key: "ArrowDown", altKey: true })
    expect(pushes).toEqual([
      ["move_pinned_step", { space_id: "b", direction: "up" }],
      ["move_pinned_step", { space_id: "b", direction: "down" }],
    ])

    // The re-render moved focus away; updated() puts it back on that row.
    doc.activeElement = null
    hook.updated()
    expect(doc.activeElement).toBe(b)
  })

  it("Alt+arrow focus also returns through the reply, and only once", () => {
    const { hook, el } = mount()
    const b = row(el, "b")
    b.dispatch("keydown", { key: "ArrowDown", altKey: true })
    replies[0]()
    expect(doc.activeElement).toBe(b)

    doc.activeElement = null
    hook.updated()
    expect(doc.activeElement).toBe(null)
  })

  it("a task row ignores Alt+arrow", () => {
    const { el } = mount()
    row(el, "task").dispatch("keydown", { key: "ArrowUp", altKey: true })
    expect(pushes).toEqual([])
  })

  it("8. Escape mid-drag cancels with no push", () => {
    const { el } = mount()
    const c = row(el, "c")
    pointer(c, "pointerdown", 100, mid(3))
    pointer(c, "pointermove", 100, mid(1) - 5)
    expect(c.getAttribute("data-editing")).toBe("true")
    doc.dispatch("keydown", { key: "Escape" })
    expect(c.getAttribute("data-editing")).toBe(null)
    expect(overlayParts(el)).toHaveLength(0)
    pointer(c, "pointerup", 100, mid(1) - 5)
    expect(pushes).toEqual([])
    expect(click(c).defaultPrevented).toBe(false)
  })

  it("pointercancel mid-drag cancels with no push", () => {
    const { el } = mount()
    const c = row(el, "c")
    pointer(c, "pointerdown", 100, mid(3))
    pointer(c, "pointermove", 100, mid(1) - 5)
    pointer(c, "pointercancel", 100, mid(1) - 5)
    pointer(c, "pointerup", 100, mid(1) - 5)
    expect(pushes).toEqual([])
  })

  it("9. a row without data-reorder (a task row) never drags", () => {
    const { el } = mount()
    const task = row(el, "task")
    drag(task, mid(0), [mid(0) + 20, mid(3) + 10])
    expect(pushes).toEqual([])
    expect(overlayParts(el)).toHaveLength(0)
    expect(click(task).defaultPrevented).toBe(false)
  })

  it("10. updated() mid-drag keeps the drag; a removed dragged row cancels", () => {
    const { hook, el } = mount()
    let c = row(el, "c")
    pointer(c, "pointerdown", 100, mid(3))
    pointer(c, "pointermove", 100, mid(3) - 10)

    // A patch re-renders the rows in the same order (fresh nodes, no
    // data-editing), the overlay untouched (phx-update="ignore").
    for (const wrap of el.querySelectorAll('[data-role="chat-list-row-wrap"]')) el.removeChild(wrap)
    buildRows(el, THREE, 3)
    c = row(el, "c")
    expect(c.getAttribute("data-editing")).toBe(null)
    hook.updated()
    expect(c.getAttribute("data-editing")).toBe("true")
    expect(overlayParts(el)).toHaveLength(3)

    pointer(c, "pointermove", 100, mid(1) - 5)
    pointer(c, "pointerup", 100, mid(1) - 5)
    expect(moves()).toEqual([["move_pinned_row", { space_id: "c", to_position: 0 }]])

    // Unpinned elsewhere mid-drag.
    pushes = []
    const b = row(el, "b")
    pointer(b, "pointerdown", 100, mid(2))
    pointer(b, "pointermove", 100, mid(2) + 30)
    el.removeChild(b.parentNode)
    hook.updated()
    expect(overlayParts(el)).toHaveLength(0)
    pointer(doc, "pointermove", 100, mid(3) + 10)
    pointer(doc, "pointerup", 100, mid(3) + 10)
    expect(pushes).toEqual([])
  })

  it("10b. with ChatListSettle on the scroller ancestor, a full drag pushes the right move", () => {
    const { el, parent } = mount(THREE, 3, { scroller: true })
    const settle = Object.assign(Object.create(ChatListSettle), {
      el: parent,
      pushEvent: (name, payload) => pushes.push([name, payload]),
    })
    settle.mounted()

    const a = row(el, "a")
    pointer(a, "pointerdown", 100, mid(1))
    pointer(a, "pointermove", 100, mid(1) + 10)
    // The hold's patch lands mid-drag.
    settle.beforeUpdate()
    settle.updated()
    pointer(a, "pointermove", 100, mid(2) + 5)
    pointer(a, "pointerup", 100, mid(2) + 5)

    expect(pushes.map(([n]) => n)).toContain("chat_list_hold")
    expect(moves()).toEqual([["move_pinned_row", { space_id: "a", to_position: 1 }]])
    for (const wrap of el.querySelectorAll('[data-role="chat-list-row-wrap"]')) {
      expect(wrap.style.transform || "").toBe("")
    }
  })

  it("10c. a move and release OUTSIDE the container end the drag, clamped", () => {
    const { el } = mount()
    const outside = new El("a", { "data-role": "chat-list-row", "data-space-id": "spaces-row" })
    doc.appendChild(outside)

    const a = row(el, "a")
    pointer(a, "pointerdown", 100, mid(1))
    pointer(outside, "pointermove", 100, mid(1) + 10)
    pointer(outside, "pointermove", 100, 900)
    pointer(outside, "pointerup", 100, 900)
    expect(moves()).toEqual([["move_pinned_row", { space_id: "a", to_position: 2 }]])
  })

  it("10d. a restricted row between two draggable rows is counted", () => {
    const spec = [
      { id: "a", pos: 0 },
      { id: "r", pos: 1, restricted: true },
      { id: "b", pos: 2 },
    ]
    const { el } = mount(spec, 3)
    const a = row(el, "a")
    // Below the restricted row's midpoint, above b's.
    drag(a, mid(0), [mid(0) + 10, mid(1) + 5])
    expect(moves()).toEqual([["move_pinned_row", { space_id: "a", to_position: 1 }]])

    pushes = []
    const b = row(el, "b")
    // Above the restricted row's midpoint, below a's.
    drag(b, mid(2), [mid(2) - 10, mid(1) - 5])
    expect(moves()).toEqual([["move_pinned_row", { space_id: "b", to_position: 1 }]])
  })

  it("11. with RowLongPress on the same row, a 6px drag held 600ms opens no sheet", () => {
    const { el } = mount()
    const c = row(el, "c")
    const longPress = Object.assign(Object.create(RowLongPress), {
      el: c,
      pushEvent: (name, payload) => pushes.push([name, payload]),
    })
    longPress.mounted()

    pointer(c, "pointerdown", 100, mid(3))
    pointer(c, "pointermove", 100, mid(3) - 6)
    vi.advanceTimersByTime(600)
    expect(HOLD_MS).toBeLessThan(600)
    expect(pushes.map(([n]) => n)).not.toContain("open_list_sheet")
    pointer(c, "pointerup", 100, mid(3) - 6)
  })

  it("12. dragstart on a reorder row is prevented; a task row keeps native drag", () => {
    const { el } = mount()
    expect(row(el, "b").dispatch("dragstart").defaultPrevented).toBe(true)
    expect(row(el, "b").firstChild.dispatch("dragstart").defaultPrevented).toBe(true)
    expect(row(el, "task").dispatch("dragstart").defaultPrevented).toBe(false)
  })

  it("draws with semantic tokens only and never transforms a row wrap", () => {
    const { el } = mount()
    const c = row(el, "c")
    pointer(c, "pointerdown", 100, mid(3))
    pointer(c, "pointermove", 100, mid(2))

    const [origin, ghost, line] = overlayParts(el)
    // The origin slot is DELIBERATELY still on `border-base-300` (the
    // direction's outline; allowlisted in border_token_direction_test.exs).
    expect(origin.className).toContain("border-base-300")
    expect(ghost.className).toContain("bg-base-100")
    expect(ghost.className).toContain("shadow-md")
    expect(line.className).toContain("h-0.5")
    expect(line.className).toContain("bg-base-content")
    // Inset to the row text's left edge.
    expect(line.style.left).toBe("60px")
    for (const part of [origin, ghost, line]) {
      expect(part.className).not.toMatch(/primary|#[0-9a-f]{3,8}/i)
      // Positioning styles only: no inline colour.
      for (const k of Object.keys(part.style)) expect(["top", "height", "left"]).toContain(k)
    }

    // The ghost copy carries no ids, data-* or fill classes.
    const copy = ghost.firstChild
    expect(copy.getAttributeNames().filter((n) => n === "id" || n.startsWith("data-"))).toEqual([])
    expect(copy.className).not.toMatch(/(^|\s|:)bg-/)
    expect(el.querySelectorAll("[data-pinned-position]")).toHaveLength(3)

    for (const wrap of el.querySelectorAll('[data-role="chat-list-row-wrap"]')) {
      expect(wrap.style.transform).toBe(undefined)
    }
    pointer(c, "pointerup", 100, mid(2))
  })
})
