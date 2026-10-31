import { describe, it, expect } from "vitest"
import DateEntryGuard, { syncIncomplete } from "../../js/hooks/date_entry_guard.js"

/**
 * Tests for the `DateEntryGuard` hook (task 01a192d6 stage 2). The vitest
 * suite runs in plain node with no DOM, so the input, flag and form are
 * plain objects with the few members the hook touches. The LiveView side
 * (the server refusing `date_incomplete=true`) is covered in
 * `meeting_live_create_sheet_time_test.exs`.
 */
const input = (badInput) => ({ validity: { badInput } })

describe("syncIncomplete", () => {
  it("flags a half-typed date", () => {
    const flag = { value: "" }
    expect(syncIncomplete(input(true), flag)).toBe(true)
    expect(flag.value).toBe("true")
  })

  it("clears the flag once the date is complete or empty", () => {
    const flag = { value: "true" }
    expect(syncIncomplete(input(false), flag)).toBe(false)
    expect(flag.value).toBe("")
  })

  it("tolerates a missing flag field or validity", () => {
    expect(syncIncomplete(input(true), null)).toBe(true)
    expect(syncIncomplete({}, { value: "" })).toBe(false)
  })
})

describe("DateEntryGuard", () => {
  function mount(badInput) {
    const flag = { value: "" }
    const formListeners = []
    const elListeners = {}
    const el = {
      validity: { badInput },
      dataset: { incompleteFlag: "flag-id" },
      form: {
        addEventListener: (name, fn, capture) => formListeners.push({ name, fn, capture }),
        removeEventListener: () => {},
      },
      addEventListener: (name, fn) => (elListeners[name] = fn),
      removeEventListener: () => {},
    }
    globalThis.document = { getElementById: (id) => (id === "flag-id" ? flag : null) }
    const hook = Object.create(DateEntryGuard)
    hook.el = el
    hook.mounted()
    return { hook, el, flag, formListeners, elListeners }
  }

  it("syncs in the capture phase of the form's submit", () => {
    const { el, flag, formListeners } = mount(false)
    const submit = formListeners.find((l) => l.name === "submit")
    expect(submit.capture).toBe(true)

    el.validity.badInput = true
    submit.fn()
    expect(flag.value).toBe("true")
  })

  it("syncs on each keystroke", () => {
    const { el, flag, elListeners } = mount(false)
    el.validity.badInput = true
    elListeners.keyup()
    expect(flag.value).toBe("true")
    el.validity.badInput = false
    elListeners.keyup()
    expect(flag.value).toBe("")
  })
})
