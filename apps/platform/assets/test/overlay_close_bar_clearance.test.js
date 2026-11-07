import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { CLOSE_BAR_CLASS, CLOSE_CONTROL_CLASS } from "../js/lib/dismissable_overlay.js"

/**
 * TOP CLEARANCE for overlay exits (task 01a1b67d stage 1).
 *
 * The back / close control of a full-window overlay must sit wholly below
 * env(safe-area-inset-top). The iOS shell is edge to edge
 * (contentInsetAdjustmentBehavior = .never) and draws no scrim or top bar over
 * the web view, so the status bar is the only native chrome on top and the
 * inset is the whole clearance.
 *
 * The old bar was `safe-area-top h-14` under border-box: a 59px inset ate the
 * 56px height and the button sat half under the status bar. This test
 * evaluates the real `.overlay-close-bar` / `.overlay-close-control` rules in
 * app.css at several insets (0, 34, 47, 59: no notch, home-indicator-only
 * landscape, notch, Dynamic Island) and lays the control out the way the bar
 * does (a flex row, items-center, in the content box) to assert its top edge
 * is at or below the inset and the row still fits the 44px control.
 *
 * ANTI-VACUITY: both rules must exist at top level (a missing rule would read
 * as 0 everywhere and fail the clearance on its own), and dropping the
 * inset from padding-top or from height turns this red.
 */

const here = path.dirname(fileURLToPath(import.meta.url))
const CSS = fs.readFileSync(path.resolve(here, "../css/app.css"), "utf8")
const REM = 16

function stripComments(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "))
}

/** Declarations of the one top-level rule whose prelude is exactly `selector`. */
function topLevelRule(selector) {
  const clean = stripComments(CSS)
  let depth = 0
  let prelude = ""
  const found = []
  for (let i = 0; i < clean.length; i++) {
    const c = clean[i]
    if (c === "{") {
      if (depth === 0 && prelude.trim() === selector) {
        const end = clean.indexOf("}", i)
        found.push(clean.slice(i + 1, end))
      }
      depth++
      prelude = ""
    } else if (c === "}") {
      depth--
      prelude = ""
    } else if (c === ";" && depth === 0) {
      prelude = ""
    } else {
      prelude += c
    }
  }
  expect(found, `${selector} must be one top-level rule in app.css`).toHaveLength(1)
  const decls = {}
  for (const part of found[0].split(";")) {
    const idx = part.indexOf(":")
    if (idx === -1) continue
    decls[part.slice(0, idx).trim()] = part.slice(idx + 1).trim()
  }
  return decls
}

/** px value of a length expression, with the top inset set to `inset`. */
function px(expr, inset) {
  if (!expr) return 0
  let e = expr
    .replace(/env\(\s*safe-area-inset-top\s*(?:,[^)]*)?\)/g, `${inset}px`)
    .replace(/env\(\s*safe-area-inset-[a-z]+\s*(?:,[^)]*)?\)/g, "0px")
    .replace(/calc\(/g, "(")
  e = e.replace(/max\(([^()]*)\)/g, (_, args) => `Math.max(${args})`)
  e = e.replace(/(-?\d*\.?\d+)rem/g, (_, n) => String(Number(n) * REM))
  e = e.replace(/(-?\d*\.?\d+)px/g, "$1")
  if (!/^[\d\s.+\-*/(),Mathax]*$/.test(e)) throw new Error(`unparsed length: ${expr}`)
  return Function(`return (${e})`)()
}

describe("overlay close bar clearance", () => {
  const bar = topLevelRule(`.${CLOSE_BAR_CLASS}`)
  const control = topLevelRule(`.${CLOSE_CONTROL_CLASS}`)

  it("is border-box, so the inset is padding inside the bar's own height", () => {
    expect(bar["box-sizing"]).toBe("border-box")
  })

  for (const inset of [0, 34, 47, 59]) {
    it(`at a ${inset}px top inset the control's top edge is at or below the inset`, () => {
      const height = px(bar.height, inset)
      const padTop = px(bar["padding-top"], inset)
      const controlH = px(control["min-height"], inset)
      const rowH = height - padTop
      // items-center in the content box.
      const controlTop = padTop + (rowH - controlH) / 2

      expect(controlH).toBeGreaterThanOrEqual(44)
      expect(rowH).toBeGreaterThanOrEqual(controlH)
      expect(rowH).toBe(3.5 * REM)
      expect(controlTop).toBeGreaterThanOrEqual(inset)
    })
  }

  it("the close control is at least 44x44", () => {
    expect(px(control["min-width"], 0)).toBeGreaterThanOrEqual(44)
    expect(px(control["min-height"], 0)).toBeGreaterThanOrEqual(44)
  })
})
