import { describe, it, expect } from "vitest"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"

// Task 01a0fe45 stage 5. The portrait rule ([data-gs-well][data-gs-tall])
// sets properties that are wrong in fullscreen; fullscreen's well rule must
// reset every one of them. It did not reset margin-inline, and a tall well
// went 0 px wide in fullscreen (measured in headless Chrome 153 at 1280x800:
// videoRect width 0). jsdom has no layout, so this guards the property set.
const css = readFileSync(fileURLToPath(new URL("../css/game_stream.css", import.meta.url)), "utf8")
  .replace(/\/\*[\s\S]*?\*\//g, "")

const props = selector => {
  const at = css.indexOf(selector + " {")
  if (at < 0) return null
  const body = css.slice(at + selector.length + 2, css.indexOf("}", at))
  return Object.fromEntries(
    body.split(";").map(d => d.trim()).filter(Boolean).map(d => {
      const i = d.indexOf(":")
      return [d.slice(0, i).trim(), d.slice(i + 1).trim()]
    }),
  )
}

describe("game_stream.css fullscreen vs the portrait well", () => {
  const tall = props("[data-gs-well][data-gs-tall]")
  const fs = props(".game-stream-frame:fullscreen [data-gs-well]")

  it("finds both rules (the guard can fire)", () => {
    expect(tall).not.toBeNull()
    expect(fs).not.toBeNull()
    expect(Object.keys(tall).length).toBeGreaterThan(0)
  })

  it("resets every property the portrait rule sets", () => {
    const missing = Object.keys(tall).filter(p => !(p in fs))
    expect(missing).toEqual([])
  })

  it("lets the fullscreen well span the frame", () => {
    expect(fs["margin-inline"]).toBe("0")
    expect(fs["max-height"]).toBe("none")
    expect(fs["aspect-ratio"]).toBe("auto")
  })
})
