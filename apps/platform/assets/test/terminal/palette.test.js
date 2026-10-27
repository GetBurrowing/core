import { describe, it, expect } from "vitest"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, resolve } from "node:path"
import {
  ANSI,
  FOREGROUND,
  GROUND,
  LIFTED,
  MIN_CONTRAST,
  SELECTION,
  THEME,
  XTERM_DEFAULT_ANSI,
  contrast,
} from "../../js/terminal/palette.js"

const css = readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), "../../css/app.css"), "utf8")
const darkBlock = css.slice(css.indexOf('name: "dark"'), css.indexOf('name: "dark"') + 4000)

describe("fixed dark palette", () => {
  it("is the dark theme's base-100, base-content and base-300, read from app.css", () => {
    expect(darkBlock).toContain(`--color-base-100: ${GROUND}`)
    expect(darkBlock).toContain(`--color-base-content: ${FOREGROUND}`)
    expect(darkBlock).toContain(`--color-base-300: ${SELECTION}`)
    expect(css).toMatch(/\.terminal-ground\s*\{[^}]*background-color:\s*#191b20/)
  })

  it("every one of the 16 ANSI colours clears 4.5:1 on the ground", () => {
    expect(ANSI).toHaveLength(16)
    for (const [i, c] of ANSI.entries()) {
      expect(contrast(c, GROUND), `ansi ${i} ${c}`).toBeGreaterThanOrEqual(MIN_CONTRAST)
    }
  })

  it("names exactly the colours it lifted", () => {
    const failing = XTERM_DEFAULT_ANSI.flatMap((c, i) => (contrast(c, GROUND) < MIN_CONTRAST ? [i] : []))
    expect(LIFTED).toEqual(failing)
    // black, red, blue, magenta, bright black, bright red
    expect(LIFTED).toEqual([0, 1, 4, 5, 8, 9])
    for (const i of LIFTED) expect(ANSI[i]).not.toBe(XTERM_DEFAULT_ANSI[i])
  })

  it("text, cursor and selection clear their own bars", () => {
    expect(contrast(FOREGROUND, GROUND)).toBeGreaterThanOrEqual(7)
    expect(contrast(FOREGROUND, SELECTION)).toBeGreaterThanOrEqual(MIN_CONTRAST)
    expect(THEME.cursor).toBe(FOREGROUND)
    expect(THEME.background).toBe(GROUND)
    expect(THEME.selectionBackground).toBe(SELECTION)
    for (const k of ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white", "brightBlack", "brightWhite"]) {
      expect(THEME[k]).toBeTruthy()
    }
  })
})
