// The chat composer's rich field (redesign rung 10): a contenteditable whose
// @mentions render as chips. Pure DOM in, DOM out; no LiveView here, so the
// hook (`hooks/compose_input.js`) owns events and this file owns the shape.
//
// The wire format is unchanged: `serialize/1` turns the field back into the
// ADR 0037 text the server has always parsed, one `@[Name]` per chip, and the
// hook copies it into the hidden `compose[text]` input.
//
// A chip is `<span class="compose-chip" contenteditable="false"
// data-mention="Name">@Name</span>` followed by a no-break space, so the caret
// has somewhere to land after it and a chip at a line end still wraps with
// the text around it.

export const CHIP_CLASS = "compose-chip"
export const NBSP = " "

const TEXT_NODE = 3
const ELEMENT_NODE = 1
// `@[Name]`: a name is anything but brackets and newlines (ADR 0037).
const TOKEN = /@\[([^[\]\n]+)\]/g
// Blocks a browser may insert on its own (Chrome wraps lines in <div> on a
// plain Enter, Safari in <div> or <p>); each one starts a new line.
const BLOCKS = new Set(["DIV", "P", "LI"])

export function isChip(node) {
  return (
    !!node &&
    node.nodeType === ELEMENT_NODE &&
    typeof node.getAttribute === "function" &&
    node.getAttribute("data-mention") !== null
  )
}

/** The field as ADR 0037 text: chips become `@[Name]`, `<br>` and blocks newlines. */
export function serialize(el) {
  let out = ""

  const walk = (node) => {
    for (const child of Array.from(node.childNodes)) {
      if (child.nodeType === TEXT_NODE) {
        out += child.data.replace(/ /g, " ")
      } else if (isChip(child)) {
        out += "@[" + child.getAttribute("data-mention") + "]"
      } else if (child.nodeType === ELEMENT_NODE && child.nodeName === "BR") {
        out += "\n"
      } else if (child.nodeType === ELEMENT_NODE && BLOCKS.has(child.nodeName)) {
        if (out !== "" && !out.endsWith("\n")) out += "\n"
        walk(child)
        // A block's own trailing <br> is the line's placeholder, not a line.
        if (child.lastChild && child.lastChild.nodeName === "BR" && out.endsWith("\n")) {
          out = out.slice(0, -1)
        }
        if (child.nextSibling) out += "\n"
      } else if (child.nodeType === ELEMENT_NODE) {
        walk(child)
      }
    }
  }

  walk(el)

  // A browser keeps a trailing <br> so the last empty line has height; it
  // is not a newline the writer typed. `hydrate/2` adds one back.
  if (el.lastChild && el.lastChild.nodeName === "BR" && out.endsWith("\n")) {
    out = out.slice(0, -1)
  }

  return out
}

function makeChip(doc, name) {
  const chip = doc.createElement("span")
  chip.setAttribute("class", CHIP_CLASS)
  chip.setAttribute("contenteditable", "false")
  chip.setAttribute("data-mention", name)
  chip.appendChild(doc.createTextNode("@" + name))
  return chip
}

function appendText(doc, el, text) {
  const lines = text.split("\n")
  lines.forEach((line, i) => {
    if (i > 0) el.appendChild(doc.createElement("br"))
    if (line !== "") el.appendChild(doc.createTextNode(line))
  })
}

/** Replace the field's content with `text`, every `@[Name]` as a chip. */
export function hydrate(el, text) {
  const doc = el.ownerDocument
  while (el.firstChild) el.removeChild(el.firstChild)
  const value = typeof text === "string" ? text : ""

  let last = 0
  let afterChip = false
  for (const match of value.matchAll(TOKEN)) {
    let between = value.slice(last, match.index)
    if (afterChip && between.startsWith(" ")) between = NBSP + between.slice(1)
    appendText(doc, el, between)
    el.appendChild(makeChip(doc, match[1]))
    last = match.index + match[0].length
    afterChip = true
  }

  let rest = value.slice(last)
  if (afterChip && rest.startsWith(" ")) rest = NBSP + rest.slice(1)
  appendText(doc, el, rest)

  // A trailing newline needs a second <br> to render as an empty line.
  if (value.endsWith("\n")) el.appendChild(doc.createElement("br"))
}

/**
 * Insert a chip for `name` in place of `range` (the typed "@query", or a
 * collapsed caret), followed by a no-break space. Returns where the caret
 * goes: `{node, offset}`, just after that space.
 */
export function insertChip(el, range, name) {
  const doc = el.ownerDocument
  const { startContainer: sc, startOffset: so, endContainer: ec, endOffset: eo } = range

  // A selection across nodes (a real browser Range only): delete it first,
  // which collapses the range, then insert at the caret.
  if (sc !== ec || (sc.nodeType !== TEXT_NODE && so !== eo)) {
    range.deleteContents()
    return insertChip(el, range, name)
  }

  const chip = makeChip(doc, name)

  if (sc.nodeType === TEXT_NODE) {
    const after = sc.data.slice(eo)
    sc.data = sc.data.slice(0, so)
    const tail = doc.createTextNode(NBSP + after.replace(/^[  ]/, ""))
    sc.parentNode.insertBefore(chip, sc.nextSibling)
    chip.parentNode.insertBefore(tail, chip.nextSibling)
    if (sc.data === "") sc.parentNode.removeChild(sc)
    return { node: tail, offset: 1 }
  }

  const ref = sc.childNodes[so] || null
  sc.insertBefore(chip, ref)
  const tail = doc.createTextNode(NBSP)
  sc.insertBefore(tail, chip.nextSibling)
  return { node: tail, offset: 1 }
}

function previousMeaningful(node) {
  let prev = node ? node.previousSibling : null
  while (prev && prev.nodeType === TEXT_NODE && prev.data === "") prev = prev.previousSibling
  return prev
}

/**
 * The chip the caret sits right after, or null. "Right after" includes the
 * no-break space a chip is inserted with: that space is the chip's own.
 * Returns `{chip, space}` where `space` is the text node whose first
 * character is that space when the caret is past it.
 */
export function chipBeforeCaret(sel) {
  if (!sel || !sel.anchorNode || sel.isCollapsed === false) return null
  const node = sel.anchorNode
  const offset = sel.anchorOffset

  if (node.nodeType === TEXT_NODE) {
    if (offset === 0) {
      const prev = previousMeaningful(node)
      return isChip(prev) ? { chip: prev, space: null } : null
    }
    if (offset === 1 && node.data[0] === NBSP) {
      const prev = previousMeaningful(node)
      return isChip(prev) ? { chip: prev, space: node } : null
    }
    return null
  }

  const before = offset > 0 ? node.childNodes[offset - 1] : null
  if (isChip(before)) return { chip: before, space: null }
  if (before && before.nodeType === TEXT_NODE && before.data === NBSP) {
    const prev = previousMeaningful(before)
    if (isChip(prev)) return { chip: prev, space: before }
  }
  return null
}

/**
 * Backspace right after a chip: remove the whole chip (and its space when
 * the caret was past it). Returns the new caret `{node, offset}`, or null when
 * the caret is not after a chip and the browser should handle the key.
 */
export function deleteChipBeforeCaret(sel) {
  const hit = chipBeforeCaret(sel)
  if (!hit) return null
  const { chip, space } = hit
  const parent = chip.parentNode
  const index = Array.from(parent.childNodes).indexOf(chip)

  if (space) {
    if (space.data.length > 1) {
      space.data = space.data.slice(1)
      parent.removeChild(chip)
      return { node: space, offset: 0 }
    }
    parent.removeChild(space)
  }

  parent.removeChild(chip)
  return { node: parent, offset: index }
}

/**
 * The "@query" being typed at the caret, or null. Same rule as the textarea
 * path: `@` at a line start or after whitespace, then anything but brackets,
 * another `@` or a newline.
 */
export function mentionQueryAtCaret(sel) {
  if (!sel || !sel.anchorNode || sel.anchorNode.nodeType !== TEXT_NODE) return null
  const node = sel.anchorNode
  const before = node.data.slice(0, sel.anchorOffset).replace(/ /g, " ")
  const match = before.match(/(?:^|\s)@([^[\]@\n]*)$/)
  if (!match) return null
  const start = before.length - match[1].length - 1
  return { query: match[1], node, start, end: sel.anchorOffset }
}

/** True when the character before the caret is not whitespace (or a line start). */
export function needsSpaceBefore(sel) {
  if (!sel || !sel.anchorNode) return false
  const node = sel.anchorNode
  const offset = sel.anchorOffset
  let prevChar = ""

  if (node.nodeType === TEXT_NODE && offset > 0) {
    prevChar = node.data[offset - 1]
  } else {
    const prev = node.nodeType === TEXT_NODE ? previousMeaningful(node) : node.childNodes[offset - 1]
    if (!prev) return false
    if (prev.nodeType === TEXT_NODE) prevChar = prev.data[prev.data.length - 1] || ""
    else if (prev.nodeName === "BR") return false
    else prevChar = "x"
  }

  return prevChar !== "" && !/[\s ]/.test(prevChar)
}

/** Send is lit with non-whitespace text or anything staged. */
export function isSendable(text, staged) {
  return /\S/.test(typeof text === "string" ? text : "") || !!staged
}
