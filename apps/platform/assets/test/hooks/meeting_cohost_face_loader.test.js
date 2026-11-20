import {describe, it, expect, vi, afterEach} from "vitest"
import Loader from "../../js/hooks/meeting_cohost_face"

afterEach(() => vi.unstubAllGlobals())

describe("cohost face island lifecycle", () => {
  it("does not mount an island that arrives after the tile was destroyed", async () => {
    let script
    vi.stubGlobal("window", {})
    vi.stubGlobal("document", {createElement: () => ({}), head: {appendChild: s => {script = s}}})
    const hook = {...Loader}
    hook.mounted()
    hook.destroyed()
    const runtime = {mounted: vi.fn(), destroyed: vi.fn()}
    window.__burrowCohostFace = runtime
    script.onload()
    await Promise.resolve()
    expect(runtime.mounted).not.toHaveBeenCalled()
    expect(script.src).toBe("/assets/js/cohost_face_island.js")
  })

  it("delegates cleanup once the audio renderer has mounted", async () => {
    const runtime = {mounted: vi.fn(), destroyed: vi.fn(), tick: vi.fn()}
    vi.stubGlobal("window", {__burrowCohostFace: runtime})
    const hook = {...Loader}
    hook.mounted()
    await Promise.resolve()
    expect(runtime.mounted).toHaveBeenCalledOnce()
    hook.destroyed()
    expect(runtime.destroyed).toHaveBeenCalledOnce()
    expect(hook.faceGone).toBe(true)
  })
})
