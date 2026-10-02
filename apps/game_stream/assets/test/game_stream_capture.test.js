import { describe, it, expect } from "vitest"
import {
  captureReduce,
  forwardable,
  initialCapture,
} from "../js/hooks/lib/game_stream_capture.js"

/**
 * The game_stream capture machine (task 01a0db5f stage 4): capture only on
 * an explicit click in a live frame; Esc releases; in fullscreen the first
 * Esc leaves fullscreen and the second releases; blur, hidden and focus
 * moving to an editable element release and send release_all; Esc is never
 * forwarded.
 */

const run = (state, ...events) =>
  events.reduce(
    (acc, e) => {
      const r = captureReduce(acc.state, e)
      return { state: r.state, actions: [...acc.actions, ...r.actions] }
    },
    { state, actions: [] },
  )

const captured = () => captureReduce(initialCapture(), { type: "click", live: true }).state

describe("capture starts only on an explicit click in a live frame", () => {
  it("starts not captured", () => {
    expect(initialCapture()).toEqual({ captured: false, fullscreen: false })
  })

  it("a click in a live frame captures", () => {
    const r = captureReduce(initialCapture(), { type: "click", live: true })
    expect(r.state.captured).toBe(true)
    expect(r.actions).toEqual(["capture"])
  })

  it("a click before the frame is live does nothing", () => {
    const r = captureReduce(initialCapture(), { type: "click", live: false })
    expect(r.state.captured).toBe(false)
    expect(r.actions).toEqual([])
  })

  it("no key captures, not even Enter or Space", () => {
    for (const code of ["Enter", "Space", "KeyW"]) {
      const r = captureReduce(initialCapture(), { type: "key", code })
      expect(r.state.captured).toBe(false)
      expect(r.actions).toEqual([])
    }
  })
})

describe("Esc", () => {
  it("releases capture outside fullscreen and tells the game to let go", () => {
    const r = captureReduce(captured(), { type: "key", code: "Escape" })
    expect(r.state.captured).toBe(false)
    expect(r.actions).toEqual(["release", "release_all"])
  })

  it("double-Esc in fullscreen: the first exits fullscreen, the second releases", () => {
    const start = captureReduce(captured(), { type: "fullscreen", on: true }).state
    const first = captureReduce(start, { type: "key", code: "Escape" })
    expect(first.actions).toEqual(["exit_fullscreen"])
    expect(first.state).toEqual({ captured: true, fullscreen: false })

    const second = captureReduce(first.state, { type: "key", code: "Escape" })
    expect(second.actions).toEqual(["release", "release_all"])
    expect(second.state.captured).toBe(false)
  })

  it("the browser swallowing the first Esc still leaves one Esc to release", () => {
    // Chrome may exit fullscreen on Esc without delivering the key; only the
    // fullscreenchange arrives.
    const r = run(
      captured(),
      { type: "fullscreen", on: true },
      { type: "fullscreen", on: false },
      { type: "key", code: "Escape" },
    )
    expect(r.state.captured).toBe(false)
    expect(r.actions).toEqual(["release", "release_all"])
  })

  it("leaving fullscreen does not release", () => {
    const r = run(captured(), { type: "fullscreen", on: true }, { type: "fullscreen", on: false })
    expect(r.state.captured).toBe(true)
    expect(r.actions).toEqual([])
  })

  it("is never forwarded to the game", () => {
    expect(forwardable("Escape")).toBe(false)
    expect(forwardable("KeyW")).toBe(true)
    expect(forwardable("")).toBe(false)
    expect(forwardable(undefined)).toBe(false)
  })
})

describe("release on blur, hidden, editable focus and end of stream", () => {
  for (const type of ["blur", "hidden", "focus_editable", "not_live"]) {
    it(`${type} releases and sends release_all`, () => {
      const r = captureReduce(captured(), { type })
      expect(r.state.captured).toBe(false)
      expect(r.actions).toEqual(["release", "release_all"])
    })

    it(`${type} while not captured does nothing`, () => {
      const r = captureReduce(initialCapture(), { type })
      expect(r.actions).toEqual([])
    })
  }

  it("a second click while captured does not re-capture", () => {
    const r = captureReduce(captured(), { type: "click", live: true })
    expect(r.actions).toEqual([])
  })
})
