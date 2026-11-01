import { describe, it, expect } from "vitest"
import { keyAction, fill } from "../../js/hooks/first_run_goal.js"

// The `/start` goal field's key handling (task 01a19554-fd07 stage 2).
describe("keyAction", () => {
  it("Enter with text submits", () => {
    expect(keyAction({ key: "Enter" }, "Plan this week's work")).toBe("submit")
  })

  it("Shift+Enter is a newline, not a submit", () => {
    expect(keyAction({ key: "Enter", shiftKey: true }, "Plan")).toBe("newline")
  })

  it("Enter on a blank or whitespace field submits nothing", () => {
    expect(keyAction({ key: "Enter" }, "")).toBe("block")
    expect(keyAction({ key: "Enter" }, "  \n ")).toBe("block")
  })

  it("Enter while an IME is composing does nothing", () => {
    expect(keyAction({ key: "Enter", isComposing: true }, "Plan")).toBe("none")
  })

  it("other keys do nothing", () => {
    expect(keyAction({ key: "a" }, "Plan")).toBe("none")
  })
})

describe("fill", () => {
  it("writes the goal, focuses the field and fires an input event", () => {
    const events = []
    const el = {
      value: "",
      focused: false,
      focus() {
        this.focused = true
      },
      setSelectionRange() {},
      dispatchEvent(ev) {
        events.push(ev.type)
      },
    }

    fill(el, "Start a project with my team")

    expect(el.value).toBe("Start a project with my team")
    expect(el.focused).toBe(true)
    expect(events).toEqual(["input"])
  })
})
