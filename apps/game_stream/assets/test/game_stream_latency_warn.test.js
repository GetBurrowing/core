import { describe, it, expect, vi } from "vitest"
import GameStream from "../js/hooks/game_stream.js"

// Task 01a1557a-efdd stage 3: the Game view's Latency warning writes the
// node's latency_warn_ms. The wrapper is phx-update="ignore", but LiveView
// still patches the wrapper's OWN attributes, so data-latency-warn-ms changes
// in place and the hook's updated() runs. It must re-read the threshold and
// re-render the readout, or the warning keeps the mount-time value until a
// reload.
function hook(dataset, warnMs = 50) {
  const h = Object.create(GameStream)
  h.el = { dataset }
  h.panel = "live"
  h.warnMs = warnMs
  h.statsEl = {}
  h.renderFooter = vi.fn()
  return h
}

describe("GameStream updated(): latency_warn_ms", () => {
  it("picks up a new data-latency-warn-ms and re-renders the readout", () => {
    const h = hook({ latencyWarnMs: "80", state: "building" })
    h.updated()
    expect(h.warnMs).toBe(80)
    expect(h.renderFooter).toHaveBeenCalledTimes(1)
    // The hook still owns data-state.
    expect(h.el.dataset.state).toBe("live")
  })

  it("an unchanged threshold re-renders nothing", () => {
    const h = hook({ latencyWarnMs: "50" })
    h.updated()
    expect(h.warnMs).toBe(50)
    expect(h.renderFooter).not.toHaveBeenCalled()
  })

  it("a missing or bad value falls back to the kind's default 50", () => {
    const h = hook({ latencyWarnMs: "nope" }, 30)
    h.updated()
    expect(h.warnMs).toBe(50)
  })
})
