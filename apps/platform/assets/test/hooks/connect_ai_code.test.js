import { describe, it, expect } from "vitest"
import { toggleMask, clearCode, shouldFocus } from "../../js/hooks/connect_ai_code.js"

/**
 * The `ConnectAiCode` hook's DOM-free half (task 01a1b365 stage 3): the show
 * toggle and the clear both run in the browser only. vitest runs in plain
 * node, so the field and the toggle are stand-in objects.
 */
function field(value = "", type = "password") {
  return { value, type, disabled: false }
}

function toggle() {
  const attrs = {}
  return {
    textContent: "Show",
    attrs,
    setAttribute(name, v) {
      attrs[name] = v
    },
  }
}

describe("toggleMask", () => {
  it("shows a masked field and says Hide", () => {
    const input = field("abc")
    const t = toggle()
    toggleMask(input, t)
    expect(input.type).toBe("text")
    expect(t.textContent).toBe("Hide")
    expect(t.attrs["aria-pressed"]).toBe("true")
  })

  it("masks it again on the second press", () => {
    const input = field("abc")
    const t = toggle()
    toggleMask(input, t)
    toggleMask(input, t)
    expect(input.type).toBe("password")
    expect(t.textContent).toBe("Show")
    expect(t.attrs["aria-pressed"]).toBe("false")
  })

  it("leaves the value alone", () => {
    const input = field("abc")
    toggleMask(input, toggle())
    expect(input.value).toBe("abc")
  })
})

describe("clearCode", () => {
  it("empties the field and masks it", () => {
    const input = field("pasted-code", "text")
    const t = toggle()
    t.textContent = "Hide"
    clearCode(input, t)
    expect(input.value).toBe("")
    expect(input.type).toBe("password")
    expect(t.textContent).toBe("Show")
  })

  it("does nothing without a field", () => {
    expect(() => clearCode(null, null)).not.toThrow()
  })
})

describe("shouldFocus", () => {
  it("focuses an empty, enabled field on a visible tab", () => {
    expect(shouldFocus(field(""), "visible")).toBe(true)
  })

  it("never takes focus from a field that has text, is disabled, or a hidden tab", () => {
    expect(shouldFocus(field("x"), "visible")).toBe(false)
    expect(shouldFocus({ ...field(""), disabled: true }, "visible")).toBe(false)
    expect(shouldFocus(field(""), "hidden")).toBe(false)
    expect(shouldFocus(null, "visible")).toBe(false)
  })
})
