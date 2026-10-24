import { describe, it, expect } from "vitest"
import {
  NBSP,
  serialize,
  hydrate,
  insertChip,
  chipBeforeCaret,
  deleteChipBeforeCaret,
  mentionQueryAtCaret,
  needsSpaceBefore,
  isSendable,
} from "../../js/lib/mention_field.js"
import { fakeDocument, caret } from "./fake_dom.js"

/**
 * The composer's rich field (redesign rung 10, task 01a1557a-997a stage 2).
 * `serialize/1` is the wire format: whatever the field shows, the server
 * receives ADR 0037 `@[Name]` text through the hidden `compose[text]` input.
 */

function field() {
  const doc = fakeDocument()
  const el = doc.createElement("div")
  el.setAttribute("contenteditable", "true")
  return el
}

function chips(el) {
  return el.childNodes.filter((n) => n.nodeType === 1 && n.getAttribute("data-mention") !== null)
}

describe("serialize / hydrate round trip", () => {
  const cases = [
    ["plain text", "hello there"],
    ["a name with spaces", "hi @[Design Lead] can you look"],
    ["adjacent chips", "@[Builder]@[Reviewer]"],
    ["adjacent chips with a space", "@[Builder] @[Reviewer] both"],
    ["newlines", "line one\nline two\n\nline four"],
    ["a chip at the start", "@[Builder] start"],
    ["a chip at the end", "ending with @[Reviewer]"],
    ["a chip alone", "@[Reviewer]"],
    ["a trailing newline", "text\n"],
    ["a chip on its own line", "a\n@[Builder]\nb"],
    ["empty", ""],
  ]

  for (const [label, text] of cases) {
    it(`round-trips ${label}`, () => {
      const el = field()
      hydrate(el, text)
      expect(serialize(el)).toBe(text)
    })
  }

  it("renders each @[Name] as one non-editable chip reading @Name", () => {
    const el = field()
    hydrate(el, "hi @[Design Lead] and @[Reviewer]")
    const cs = chips(el)
    expect(cs).toHaveLength(2)
    expect(cs[0].getAttribute("class")).toBe("compose-chip")
    expect(cs[0].getAttribute("contenteditable")).toBe("false")
    expect(cs[0].getAttribute("data-mention")).toBe("Design Lead")
    expect(cs[0].textContent).toBe("@Design Lead")
  })

  it("serializes a chip with brackets, never as bare @Name", () => {
    const el = field()
    hydrate(el, "@[Design Lead] hi")
    expect(serialize(el)).toBe("@[Design Lead] hi")
    expect(serialize(el)).not.toContain("@Design Lead")
  })

  it("reads browser-made blocks and placeholder <br>s as the lines they show", () => {
    const el = field()
    const doc = el.ownerDocument
    const d1 = doc.createElement("div")
    d1.appendChild(doc.createTextNode("first"))
    const d2 = doc.createElement("div")
    d2.appendChild(doc.createElement("br"))
    const d3 = doc.createElement("div")
    d3.appendChild(doc.createTextNode("third"))
    el.appendChild(d1)
    el.appendChild(d2)
    el.appendChild(d3)
    expect(serialize(el)).toBe("first\n\nthird")

    const only = field()
    only.appendChild(only.ownerDocument.createElement("br"))
    expect(serialize(only)).toBe("")
  })

  it("turns no-break spaces back into plain spaces", () => {
    const el = field()
    el.appendChild(el.ownerDocument.createTextNode(`a${NBSP}b${NBSP}`))
    expect(serialize(el)).toBe("a b ")
  })
})

describe("insertChip", () => {
  it("replaces the typed @query with a chip and a no-break space, caret after it", () => {
    const el = field()
    hydrate(el, "ask @Da please")
    const text = el.firstChild
    const pos = insertChip(el, { startContainer: text, startOffset: 4, endContainer: text, endOffset: 7 }, "Builder")

    expect(serialize(el)).toBe("ask @[Builder] please")
    expect(pos.node.data[0]).toBe(NBSP)
    expect(pos.offset).toBe(1)
    expect(chips(el)).toHaveLength(1)
  })

  it("inserts at a collapsed caret in the field itself", () => {
    const el = field()
    const pos = insertChip(el, { startContainer: el, startOffset: 0, endContainer: el, endOffset: 0 }, "Reviewer")
    expect(serialize(el)).toBe("@[Reviewer] ")
    expect(pos.node.parentNode).toBe(el)
  })
})

describe("Backspace after a chip", () => {
  it("removes the whole chip and its space in ONE press when the caret is past the space", () => {
    const el = field()
    hydrate(el, "hi @[Builder] there")
    const tail = el.childNodes[2]
    expect(tail.data).toBe(`${NBSP}there`)

    const pos = deleteChipBeforeCaret(caret(tail, 1))
    expect(pos).not.toBeNull()
    expect(serialize(el)).toBe("hi there")
    expect(chips(el)).toHaveLength(0)
  })

  it("removes the whole chip when the caret is right after it", () => {
    const el = field()
    hydrate(el, "@[Design Lead]")
    const pos = deleteChipBeforeCaret(caret(el, 1))
    expect(pos).toEqual({ node: el, offset: 0 })
    expect(serialize(el)).toBe("")
  })

  it("removes a lone-space tail with the chip", () => {
    const el = field()
    insertChip(el, { startContainer: el, startOffset: 0, endContainer: el, endOffset: 0 }, "Reviewer")
    const pos = deleteChipBeforeCaret(caret(el.lastChild, 1))
    expect(pos).toEqual({ node: el, offset: 0 })
    expect(el.childNodes).toHaveLength(0)
  })

  it("leaves ordinary text to the browser (positive control)", () => {
    const el = field()
    hydrate(el, "@[Builder] there")
    expect(chipBeforeCaret(caret(el.childNodes[1], 4))).toBeNull()
    expect(deleteChipBeforeCaret(caret(el.childNodes[1], 4))).toBeNull()
    expect(serialize(el)).toBe("@[Builder] there")
  })
})

describe("mentionQueryAtCaret / needsSpaceBefore", () => {
  it("finds an @query after whitespace and not inside an email", () => {
    const el = field()
    hydrate(el, "hi @Da")
    expect(mentionQueryAtCaret(caret(el.firstChild, 6))).toMatchObject({ query: "Da", start: 3, end: 6 })

    const mail = field()
    hydrate(mail, "foo@bar")
    expect(mentionQueryAtCaret(caret(mail.firstChild, 7))).toBeNull()
  })

  it("asks for a leading space only after a non-space character", () => {
    const el = field()
    hydrate(el, "word")
    expect(needsSpaceBefore(caret(el.firstChild, 4))).toBe(true)
    hydrate(el, "word ")
    expect(needsSpaceBefore(caret(el.firstChild, 5))).toBe(false)
    expect(needsSpaceBefore(caret(el, 0))).toBe(false)
  })
})

describe("isSendable", () => {
  it("is false for empty and whitespace-only text with nothing staged", () => {
    expect(isSendable("", false)).toBe(false)
    expect(isSendable("   ", false)).toBe(false)
    expect(isSendable(" \n\t ", false)).toBe(false)
  })

  it("is true for text, or for anything staged", () => {
    expect(isSendable("hi", false)).toBe(true)
    expect(isSendable("@[Builder]", false)).toBe(true)
    expect(isSendable("", true)).toBe(true)
    expect(isSendable("   ", true)).toBe(true)
  })
})
