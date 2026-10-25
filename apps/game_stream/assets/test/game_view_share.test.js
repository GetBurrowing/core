import { describe, it, expect, vi } from "vitest"
import GameViewShare, { copy } from "../js/hooks/game_view_share.js"
import hooks from "../js/extension.js"

// Task 01a1557a-efdd stage 2: the Game view's share button copies the build
// link and only then asks the server for the "Build link copied" toast.
describe("GameViewShare", () => {
  it("is registered in Play's hook map under the name the Game view renders", () => {
    expect(hooks.GameViewShare).toBe(GameViewShare)
  })

  it("writes the url, then reports the copy", async () => {
    const clipboard = { writeText: vi.fn(() => Promise.resolve()) }
    const done = vi.fn()
    expect(await copy("https://example.test/m/games?canvas=abc", clipboard, done)).toBe(true)
    expect(clipboard.writeText).toHaveBeenCalledWith("https://example.test/m/games?canvas=abc")
    expect(done).toHaveBeenCalledTimes(1)
  })

  it("a refused write reports nothing (no false toast)", async () => {
    const clipboard = { writeText: vi.fn(() => Promise.reject(new Error("denied"))) }
    const done = vi.fn()
    expect(await copy("u", clipboard, done)).toBe(false)
    expect(done).not.toHaveBeenCalled()
  })

  it("no clipboard or no url reports nothing", async () => {
    const done = vi.fn()
    expect(await copy("u", undefined, done)).toBe(false)
    expect(await copy("", { writeText: vi.fn() }, done)).toBe(false)
    expect(done).not.toHaveBeenCalled()
  })

  it("mounted() wires the click to pushEvent", async () => {
    const listeners = {}
    const el = { dataset: { shareUrl: "https://x.test/m/games?canvas=1" }, addEventListener: (k, f) => (listeners[k] = f) }
    const writeText = vi.fn(() => Promise.resolve())
    vi.stubGlobal("navigator", { clipboard: { writeText } })
    const hook = Object.create(GameViewShare)
    hook.el = el
    hook.pushEvent = vi.fn()
    hook.mounted()
    await listeners.click()
    await Promise.resolve()
    expect(writeText).toHaveBeenCalledWith("https://x.test/m/games?canvas=1")
    expect(hook.pushEvent).toHaveBeenCalledWith("game_link_copied", {})
    vi.unstubAllGlobals()
  })
})
