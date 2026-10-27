import { describe, it, expect } from "vitest"
import { confirmText, countLines, needsConfirm } from "../../js/terminal/paste.js"
import { KEY_BYTES, applyCtrl } from "../../js/terminal/keys.js"

describe("paste confirm counts lines in the user's clipboard", () => {
  it("counts lines, treating a trailing break as an ending", () => {
    expect(countLines("")).toBe(0)
    expect(countLines("ls")).toBe(1)
    expect(countLines("ls\n")).toBe(1)
    expect(countLines("a\nb")).toBe(2)
    expect(countLines("a\r\nb\r\nc\r\n")).toBe(3)
    expect(countLines("a\rb")).toBe(2)
    expect(countLines("a\n\nb")).toBe(3)
  })

  it("asks only for more than one line, with the count in the text", () => {
    expect(needsConfirm("ls")).toBe(false)
    expect(needsConfirm("ls\n")).toBe(false)
    expect(needsConfirm("a\nb")).toBe(true)
    expect(confirmText("a\nb\nc")).toBe("Paste 3 lines into your terminal?")
  })
})

describe("phone key row", () => {
  it("maps Esc, Tab and the arrows", () => {
    expect(KEY_BYTES.esc).toBe("\x1b")
    expect(KEY_BYTES.tab).toBe("\t")
    expect(KEY_BYTES.up).toBe("\x1b[A")
    expect(KEY_BYTES.down).toBe("\x1b[B")
    expect(KEY_BYTES.right).toBe("\x1b[C")
    expect(KEY_BYTES.left).toBe("\x1b[D")
  })

  it("Ctrl turns the next character into its control code", () => {
    expect(applyCtrl("c")).toBe("\x03")
    expect(applyCtrl("C")).toBe("\x03")
    expect(applyCtrl("d")).toBe("\x04")
    expect(applyCtrl("1")).toBe("1")
    expect(applyCtrl("ab")).toBe("ab")
  })
})
