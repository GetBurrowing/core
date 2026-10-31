import { describe, it, expect } from "vitest"
import InviteSearchEnter, { clearIfStaged, handleEnter } from "../../js/hooks/invite_search_enter.js"

/**
 * Tests for the `InviteSearchEnter` hook (task 01a192d6 stage 3). The
 * vitest suite runs in plain node with no DOM, so the element and the key
 * event are plain objects with the members the hook reads. The server side
 * (what a commit stages) is covered in
 * `meeting_live_create_sheet_invite_test.exs`.
 */
function setup({ target = null } = {}) {
  const pushes = []
  const listeners = {}
  const el = {
    value: "guest@example.com",
    dataset: { commitEvent: "meeting_create_invite_commit" },
    getAttribute: (name) => (name === "phx-target" ? target : null),
    addEventListener: (name, fn) => (listeners[name] = fn),
    removeEventListener: () => {},
  }
  const hook = Object.create(InviteSearchEnter)
  hook.el = el
  hook.pushEventTo = (to, event, payload, onReply) => pushes.push({ to, event, payload, onReply })
  hook.mounted()
  return { hook, el, pushes, listeners }
}

function keyEvent(key, extra = {}) {
  const e = { key, isComposing: false, prevented: false, ...extra }
  e.preventDefault = () => (e.prevented = true)
  return e
}

describe("clearIfStaged", () => {
  it("tolerates a missing reply", () => {
    const el = { value: "x" }
    clearIfStaged(el, undefined)
    expect(el.value).toBe("x")
  })
})

describe("InviteSearchEnter", () => {
  it("Enter prevents the form submit and pushes the commit event with the raw value", () => {
    const { el, pushes, listeners } = setup()
    const e = keyEvent("Enter")
    listeners.keydown(e)

    expect(e.prevented).toBe(true)
    expect(pushes.length).toBe(1)
    expect(pushes[0].to).toBe(el)
    expect(pushes[0].event).toBe("meeting_create_invite_commit")
    expect(pushes[0].payload).toEqual({ value: "guest@example.com" })
  })

  it("clears the box when the server replies that it staged, and only then", () => {
    const { el, pushes, listeners } = setup()
    listeners.keydown(keyEvent("Enter"))

    pushes[0].onReply({})
    expect(el.value).toBe("guest@example.com")

    pushes[0].onReply({ staged: true })
    expect(el.value).toBe("")
  })

  it("pushes to the phx-target when the control has one", () => {
    const { pushes, listeners } = setup({ target: "#some-component" })
    listeners.keydown(keyEvent("Enter"))
    expect(pushes[0].to).toBe("#some-component")
  })

  it("other keys neither prevent nor push", () => {
    const { pushes, listeners } = setup()
    for (const key of ["a", "Tab", "ArrowDown", "Escape"]) {
      const e = keyEvent(key)
      listeners.keydown(e)
      expect(e.prevented).toBe(false)
    }
    expect(pushes).toEqual([])
  })

  it("Enter during IME composition neither prevents nor pushes", () => {
    const { pushes, listeners } = setup()
    const e = keyEvent("Enter", { isComposing: true })
    listeners.keydown(e)
    expect(e.prevented).toBe(false)
    expect(pushes).toEqual([])
  })

  it("Enter's keyup stops propagating so the empty-query search never fires; other keyups pass", () => {
    const { listeners } = setup()
    const stopped = []
    const up = (key) => ({ key, isComposing: false, stopPropagation: () => stopped.push(key) })

    listeners.keyup(up("Enter"))
    listeners.keyup(up("a"))
    expect(stopped).toEqual(["Enter"])
  })

  it("handleEnter reports whether it handled the key", () => {
    const { hook } = setup()
    expect(handleEnter(hook, keyEvent("Enter"))).toBe(true)
    expect(handleEnter(hook, keyEvent("x"))).toBe(false)
  })
})
