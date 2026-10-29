import { describe, it, expect, vi } from "vitest"
import GameStream from "../js/hooks/game_stream.js"
import { BUILD_STEPS, buildFailureStep, buildStep, buildTail, longerThanUsual } from "../js/hooks/lib/game_stream_build.js"

// Task 01a17b51 stage 3: the Building card (design canvas 01a170ca, 2b).

describe("buildStep", () => {
  it.each(["Compiling", "Cooking", "Staging", "Packaging", "Archiving", "Editor scripts"])("names %s", w => {
    expect(buildStep(`${w} (45s)`)).toBe(w)
    expect(buildStep(w)).toBe(w)
  })
  it("is not fooled by lookalikes, Godot's details or non-strings", () => {
    expect(buildStep("Cookbook")).toBeNull()
    expect(buildStep("Preparing task/x at 0123456789ab")).toBeNull()
    expect(buildStep("Importing assets (5s)")).toBeNull()
    expect(buildStep(null)).toBeNull()
  })
  it("lists the same words as the server's kind", () => {
    expect(BUILD_STEPS).toEqual(["Editor scripts", "Compiling", "Cooking", "Staging", "Packaging", "Archiving"])
  })
})

describe("buildTail", () => {
  it("is today's text without a step and the step with one", () => {
    expect(buildTail("Preparing (2s)")).toBe(" on the play host…")
    expect(buildTail("Cooking (45s)")).toBe(" · Cooking")
  })
})

describe("buildFailureStep", () => {
  it("reads the step from the host's failure detail", () => {
    expect(buildFailureStep("build: Build failed during Cooking: LogCook: Error")).toBe("Cooking")
    expect(buildFailureStep("Build timed out during Compiling")).toBe("Compiling")
    expect(buildFailureStep("Build failed during Editor scripts: x")).toBe("Editor scripts")
  })
  it("is null for any other failure", () => {
    expect(buildFailureStep("The game exited (code 3)")).toBeNull()
    expect(buildFailureStep(undefined)).toBeNull()
  })
})

describe("longerThanUsual", () => {
  const MIN = 60000
  it("needs twice the last build", () => {
    expect(longerThanUsual(36 * MIN, 18 * MIN)).toBe(false)
    expect(longerThanUsual(36 * MIN + 1, 18 * MIN)).toBe(true)
  })
  it("never fires without a last build, or at a fixed number of seconds", () => {
    expect(longerThanUsual(90 * MIN, null)).toBe(false)
    expect(longerThanUsual(90 * MIN, 0)).toBe(false)
    expect(longerThanUsual(11000, 18 * MIN)).toBe(false)
  })
})

function el(extra = {}) {
  return { hidden: false, textContent: "", ...extra }
}

describe("the hook keeps the card current", () => {
  it("renderBuildDetail rewrites only the text after the sha", () => {
    const h = Object.create(GameStream)
    const text = { nodeType: 3, nodeValue: " on the play host…" }
    h.buildTitleEl = { lastChild: text }
    h.renderBuildDetail("Cooking (3s)")
    expect(text.nodeValue).toBe(" · Cooking")
    h.renderBuildDetail("Preparing")
    expect(text.nodeValue).toBe(" on the play host…")
  })

  it("renderLonger shows the line only after twice the last build", () => {
    const h = Object.create(GameStream)
    h.longerEl = el({ hidden: true })
    h.buildStartedAt = 0
    h.lastBuildMs = 18 * 60000
    h.renderLonger(30 * 60000)
    expect(h.longerEl.hidden).toBe(true)
    h.renderLonger(37 * 60000)
    expect(h.longerEl.hidden).toBe(false)
    h.lastBuildMs = null
    h.renderLonger(99 * 60000)
    expect(h.longerEl.hidden).toBe(true)
  })

  function failedHook() {
    const parts = {
      "[data-gs-reason]": el(),
      "[data-gs-fail-step]": el({ hidden: true }),
      "[data-gs-fail-step-name]": el(),
      "[data-gs-open-task]": el({ hidden: true }),
      "[data-gs-restart]": el(),
    }
    const panel = { dataset: { gsPanel: "failed" }, querySelector: sel => parts[sel] || null }
    const h = Object.create(GameStream)
    h.panels = [panel]
    return { h, parts }
  }

  it("a build failure shows the step and Open task and hides Start again", () => {
    const { h, parts } = failedHook()
    h.setReason("failed", "build: Build failed during Cooking: LogCook: Error: x")
    expect(parts["[data-gs-reason]"].textContent).toBe("Build didn't finish")
    expect(parts["[data-gs-fail-step-name]"].textContent).toBe("Cooking")
    expect(parts["[data-gs-fail-step]"].hidden).toBe(false)
    expect(parts["[data-gs-open-task]"].hidden).toBe(false)
    expect(parts["[data-gs-restart]"].hidden).toBe(true)
  })

  it("any other failure keeps its text and Start again", () => {
    const { h, parts } = failedHook()
    parts["[data-gs-restart]"].hidden = true
    h.setReason("failed", "The game exited (code 3)")
    expect(parts["[data-gs-reason]"].textContent).toBe("The game exited (code 3)")
    expect(parts["[data-gs-open-task]"].hidden).toBe(true)
    expect(parts["[data-gs-restart]"].hidden).toBe(false)
  })
})
