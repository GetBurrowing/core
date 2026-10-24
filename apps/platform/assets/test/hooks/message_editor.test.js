import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import MessageEditor, { removesMost, REMOVES_MOST_CONFIRM } from "../../js/hooks/message_editor.js"

/**
 * `removesMost(original, next)` (redesign rung 9 stage 4; masters MM
 * `startEdit`): true when the trimmed new text keeps UNDER half of the
 * trimmed original, the masters' `t.length < orig.length * 0.5`. It gates
 * the native confirm; removing exactly half does not ask.
 */
const TEN = "abcdefghij" // 10 code points

describe("removesMost(original, next)", () => {
  it("removing 55% asks", () => expect(removesMost(TEN + TEN, TEN.slice(0, 9))).toBe(true))
  it("removing exactly 50% does not ask", () => expect(removesMost(TEN, "abcde")).toBe(false))
  it("removing 40% does not ask", () => expect(removesMost(TEN, "abcdef")).toBe(false))
  it("an additive edit does not ask", () => expect(removesMost("hello", "hello world")).toBe(false))
  it("emptying the text asks", () => expect(removesMost("hello world", "   ")).toBe(true))
  it("an empty original never asks", () => expect(removesMost("", "")).toBe(false))
  it("surrounding whitespace is trimmed on both sides", () =>
    expect(removesMost("  abcd  ", " ab ")).toBe(false))
  it("an emoji counts once (code points, not UTF-16 units)", () =>
    // 4 code points (8 UTF-16 units) -> 2 code points: exactly half, no ask.
    expect(removesMost("\u{1F389}\u{1F389}ab", "\u{1F389}a")).toBe(false))
})

// The editor's keys (redesign rung 10, stage 4, coverage row 117): Enter
// saves, Shift+Enter is a newline, Cmd/Ctrl+Enter still saves, Esc cancels.
describe("MessageEditor keys", () => {
  function editor() {
    const listeners = {}
    const textarea = {
      value: "the original",
      focus: vi.fn(),
      setSelectionRange: vi.fn(),
      addEventListener: (type, fn) => (listeners[type] = fn),
      removeEventListener: vi.fn(),
    }
    const formListeners = {}
    const form = {
      dataset: { originalContent: "the original" },
      requestSubmit: vi.fn(),
      querySelector: (sel) => (sel.startsWith("textarea") ? textarea : null),
      addEventListener: (type, fn) => (formListeners[type] = fn),
      removeEventListener: vi.fn(),
    }
    const hook = Object.create(MessageEditor)
    hook.el = form
    hook.pushEvent = vi.fn()
    hook.mounted()
    const press = (key, mods = {}) => {
      const e = { key, preventDefault: vi.fn(), ...mods }
      listeners.keydown(e)
      return e
    }
    const submit = () => {
      const e = { preventDefault: vi.fn(), stopPropagation: vi.fn() }
      formListeners.submit(e)
      return e
    }
    return { form, hook, press, submit, textarea }
  }

  it("Enter submits the edit", () => {
    const { form, press } = editor()
    const e = press("Enter")
    expect(e.preventDefault).toHaveBeenCalled()
    expect(form.requestSubmit).toHaveBeenCalledTimes(1)
  })

  it("Shift+Enter does not submit (the textarea breaks the line)", () => {
    const { form, press } = editor()
    const e = press("Enter", { shiftKey: true })
    expect(e.preventDefault).not.toHaveBeenCalled()
    expect(form.requestSubmit).not.toHaveBeenCalled()
  })

  it("Enter while an IME is composing does not submit", () => {
    const { form, press } = editor()
    press("Enter", { isComposing: true })
    expect(form.requestSubmit).not.toHaveBeenCalled()
  })

  it("Cmd+Enter and Ctrl+Enter still submit", () => {
    const { form, press } = editor()
    press("Enter", { metaKey: true })
    press("Enter", { ctrlKey: true })
    expect(form.requestSubmit).toHaveBeenCalledTimes(2)
  })

  it("Esc pushes cancel_edit and submits nothing", () => {
    const { form, hook, press } = editor()
    const e = press("Escape")
    expect(e.preventDefault).toHaveBeenCalled()
    expect(hook.pushEvent).toHaveBeenCalledWith("cancel_edit", {})
    expect(form.requestSubmit).not.toHaveBeenCalled()
  })

  describe("the removal guard on submit", () => {
    let savedWindow
    beforeEach(() => {
      savedWindow = globalThis.window
      globalThis.window = { confirm: vi.fn() }
    })
    afterEach(() => {
      globalThis.window = savedWindow
    })

    // "the original" is 12 code points.
    it("removing most (58%) calls the native confirm with the exact string", () => {
      const { submit, textarea } = editor()
      window.confirm.mockReturnValue(true)
      textarea.value = "the o" // 5 of 12 kept: 58% removed
      const e = submit()
      expect(window.confirm).toHaveBeenCalledTimes(1)
      expect(window.confirm).toHaveBeenCalledWith("This edit removes most of the text. Save anyway?")
      expect(REMOVES_MOST_CONFIRM).toBe("This edit removes most of the text. Save anyway?")
      // OK lets the submit through to LiveView.
      expect(e.preventDefault).not.toHaveBeenCalled()
      expect(e.stopPropagation).not.toHaveBeenCalled()
    })

    it("removing 50% or 25% does not ask", () => {
      const { submit, textarea } = editor()
      textarea.value = "the or" // 6 of 12: 50% removed
      submit()
      textarea.value = "the origi" // 9 of 12: 25% removed
      submit()
      expect(window.confirm).not.toHaveBeenCalled()
    })

    it("a declined confirm stops the submit and keeps the draft", () => {
      const { submit, textarea, hook } = editor()
      window.confirm.mockReturnValue(false)
      textarea.value = "x"
      const e = submit()
      expect(e.preventDefault).toHaveBeenCalled()
      expect(e.stopPropagation).toHaveBeenCalled()
      expect(textarea.value).toBe("x")
      expect(hook.pushEvent).not.toHaveBeenCalled()
    })
  })
})
