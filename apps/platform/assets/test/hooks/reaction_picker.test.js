// Unit tests for the pure logic behind the ReactionPicker hook.
//
// THERE IS NO VITEST CONFIG IN THIS REPO, so vitest runs on defaults: the
// environment is `node` and JSDOM IS NOT A DEPENDENCY (assets/package.json
// devDependencies are `esbuild` and `vitest`, nothing else). So this file tests
// the exported pure functions directly and never touches the hook lifecycle —
// the same shape as app_badge.test.js, which imports named helpers rather than
// mounting anything.

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import ReactionPicker, {
  ariaLabelFor,
  buildSections,
  chunkRows,
  countColumns,
  moveFocus,
  CATEGORY_LABELS,
  COMMON_EMOJI,
  COMMON_SLUG,
} from "../../js/hooks/reaction_picker"
import { EMOJI, CATEGORIES } from "../../emoji/data.js"

describe("COMMON_EMOJI", () => {
  it("is the 32 emoji the server-rendered picker used to carry", () => {
    expect(COMMON_EMOJI).toHaveLength(32)
    expect(new Set(COMMON_EMOJI).size).toBe(32)
  })

  // THE VARIATION-SELECTOR TRAP. Reactions are grouped by exact string match
  // (Chat.list_reactions_grouped/1 uses Enum.group_by(& &1.emoji)), so a bare
  // U+2764 here would render a SECOND heart pill on every message that already
  // has one, splitting the count. No migration repairs that.
  it("keeps the heart's FE0F variation selector", () => {
    expect(COMMON_EMOJI).toContain("\u{2764}\u{FE0F}")
    expect(COMMON_EMOJI).not.toContain("\u{2764}")
  })

  // Every COMMON entry has to resolve in the inventory or its tile loses its
  // CLDR name and announces as the raw character.
  it("every entry exists byte-identically in the shipped dataset", () => {
    const byChar = new Set(EMOJI.map((entry) => entry.e))
    const missing = COMMON_EMOJI.filter((e) => !byChar.has(e))
    expect(missing).toEqual([])
  })
})

describe("buildSections", () => {
  it("puts COMMON first, above Smileys & Emotion", () => {
    const sections = buildSections(EMOJI, CATEGORIES)
    expect(sections[0].slug).toBe(COMMON_SLUG)
    expect(sections[1].slug).toBe("smileys-emotion")
  })

  // The set is static and system-wide — Robin's no-personalisation decision —
  // so a label implying it learned from this user would be a lie.
  it("labels the first section Common, never a recency claim", () => {
    const [first] = buildSections(EMOJI, CATEGORIES)
    expect(first.label).toBe("Common")
    expect(first.label.toLowerCase()).not.toContain("frequent")
    expect(first.label.toLowerCase()).not.toContain("recent")
  })

  it("carries every category in dataset order with nothing lost", () => {
    const sections = buildSections(EMOJI, CATEGORIES)
    expect(sections.map((s) => s.slug).slice(1)).toEqual(CATEGORIES)

    const inSections = sections
      .slice(1)
      .reduce((total, section) => total + section.entries.length, 0)
    expect(inSections).toBe(EMOJI.length)
  })

  it("resolves COMMON entries to their CLDR names", () => {
    const [first] = buildSections(EMOJI, CATEGORIES)
    const heart = first.entries.find((entry) => entry.e === "\u{2764}\u{FE0F}")
    expect(heart.n).toBe("red heart")
  })

  // The offline fallback path: the island never loaded, so nothing resolves.
  // Tiles must still render rather than the section coming back empty.
  it("degrades an unresolvable entry to the bare character instead of dropping it", () => {
    const sections = buildSections([], [], ["\u{1F44D}", "\u{1F41B}"])
    expect(sections[0].entries).toEqual([
      { e: "\u{1F44D}", n: "", k: [], c: COMMON_SLUG },
      { e: "\u{1F41B}", n: "", k: [], c: COMMON_SLUG },
    ])
  })

  it("gives every dataset category a human label", () => {
    for (const slug of CATEGORIES) {
      expect(CATEGORY_LABELS[slug], `no label for ${slug}`).toBeTruthy()
      expect(CATEGORY_LABELS[slug]).not.toBe(slug)
    }
  })
})

describe("ariaLabelFor", () => {
  // "React with 😭" was adequate for 32 curated emoji. At ~1,850, including
  // 269 flags and several hundred symbols, the raw character is unusable.
  it("names the emoji from its CLDR short name", () => {
    expect(ariaLabelFor({ e: "\u{1F63A}", n: "grinning cat" })).toBe(
      "React with grinning cat"
    )
  })

  it("falls back to the character when no name is known", () => {
    expect(ariaLabelFor({ e: "\u{1F44D}", n: "" })).toBe("React with \u{1F44D}")
  })
})

describe("chunkRows", () => {
  it("splits into rows of exactly the column count", () => {
    expect(chunkRows([1, 2, 3, 4, 5], 2)).toEqual([[1, 2], [3, 4], [5]])
  })

  it("returns no rows for an empty section", () => {
    expect(chunkRows([], 8)).toEqual([])
  })

  // A zero or NaN column count would otherwise loop forever building rows.
  it("degrades to a single row rather than hanging on a bad column count", () => {
    expect(chunkRows([1, 2, 3], 0)).toEqual([[1, 2, 3]])
    expect(chunkRows([1, 2, 3], NaN)).toEqual([[1, 2, 3]])
  })
})

describe("countColumns", () => {
  // Computed style resolves both `repeat(8, minmax(0,1fr))` and
  // `repeat(auto-fit, minmax(48px,1fr))` into used track sizes, which is why
  // the hook measures the laid-out grid instead of duplicating the breakpoints.
  it("counts used tracks in a computed template", () => {
    expect(countColumns("44px 44px 44px 44px 44px 44px 44px 44px")).toBe(8)
    expect(countColumns("52.5px 52.5px 52.5px 52.5px 52.5px 52.5px")).toBe(6)
  })

  it("reports zero when the element is not a grid", () => {
    expect(countColumns("none")).toBe(0)
    expect(countColumns("")).toBe(0)
    expect(countColumns(undefined)).toBe(0)
  })

  // THE TRAP THIS GUARDS. `getComputedStyle` on a `display: none` element has
  // no layout to report, so it hands back the SPECIFIED value. Counting tokens
  // in "repeat(auto-fit, minmax(48px, 1fr))" returns 3, which would build rows
  // of three and announce a geometry nobody sees. The hook must not measure a
  // hidden grid; a token count is not allowed to guess when it does.
  it("refuses an unresolved template rather than counting its tokens", () => {
    expect(countColumns("repeat(auto-fit, minmax(48px, 1fr))")).toBe(0)
    expect(countColumns("repeat(8, minmax(0, 1fr))")).toBe(0)
  })
})

describe("moveFocus", () => {
  const rows = [
    ["a1", "a2", "a3"],
    ["b1", "b2", "b3"],
    ["c1", "c2"],
  ]

  it("moves within a row", () => {
    expect(moveFocus(rows, { r: 0, c: 0 }, "ArrowRight")).toEqual({ r: 0, c: 1 })
    expect(moveFocus(rows, { r: 0, c: 1 }, "ArrowLeft")).toEqual({ r: 0, c: 0 })
  })

  it("crosses row boundaries horizontally so the grid reads as one sequence", () => {
    expect(moveFocus(rows, { r: 0, c: 2 }, "ArrowRight")).toEqual({ r: 1, c: 0 })
    expect(moveFocus(rows, { r: 1, c: 0 }, "ArrowLeft")).toEqual({ r: 0, c: 2 })
  })

  it("moves between rows vertically", () => {
    expect(moveFocus(rows, { r: 0, c: 1 }, "ArrowDown")).toEqual({ r: 1, c: 1 })
    expect(moveFocus(rows, { r: 1, c: 1 }, "ArrowUp")).toEqual({ r: 0, c: 1 })
  })

  // The last row of a section is usually short. Landing on nothing is the
  // stale-focus bug: focus goes to a cell that does not exist and keyboard
  // navigation dies.
  it("clamps into a short row rather than landing on nothing", () => {
    expect(moveFocus(rows, { r: 1, c: 2 }, "ArrowDown")).toEqual({ r: 2, c: 1 })
  })

  it("stays put at the ends instead of wrapping", () => {
    expect(moveFocus(rows, { r: 0, c: 0 }, "ArrowLeft")).toEqual({ r: 0, c: 0 })
    expect(moveFocus(rows, { r: 0, c: 0 }, "ArrowUp")).toEqual({ r: 0, c: 0 })
    expect(moveFocus(rows, { r: 2, c: 1 }, "ArrowRight")).toEqual({ r: 2, c: 1 })
    expect(moveFocus(rows, { r: 2, c: 1 }, "ArrowDown")).toEqual({ r: 2, c: 1 })
  })

  // Home and End are row-local. A Home that jumped to the first tile of the
  // whole inventory would be a scroll, not a navigation.
  it("Home and End stay within the current row", () => {
    expect(moveFocus(rows, { r: 1, c: 2 }, "Home")).toEqual({ r: 1, c: 0 })
    expect(moveFocus(rows, { r: 1, c: 0 }, "End")).toEqual({ r: 1, c: 2 })
    expect(moveFocus(rows, { r: 2, c: 0 }, "End")).toEqual({ r: 2, c: 1 })
  })

  // Returning null is what lets the hook leave the event alone: Escape must
  // still reach the picker root's phx-window-keydown, and Tab must reach the
  // trap.
  it("returns null for keys the grid does not handle", () => {
    expect(moveFocus(rows, { r: 0, c: 0 }, "Escape")).toBeNull()
    expect(moveFocus(rows, { r: 0, c: 0 }, "Tab")).toBeNull()
    expect(moveFocus(rows, { r: 0, c: 0 }, "a")).toBeNull()
  })

  it("returns null when there is no grid yet", () => {
    expect(moveFocus([], { r: 0, c: 0 }, "ArrowRight")).toBeNull()
  })
})

// Direction canvas 01a1666e node m3 rule 5 (redesign rung 9 stage 2): the
// picker opens with its search field focused, on a phone as on a desktop.
// The field used to be focused only on a fine pointer at 640px and up.
describe("focus on open", () => {
  let savedDocument, savedWindow
  beforeEach(() => {
    savedDocument = globalThis.document
    savedWindow = globalThis.window
    globalThis.document = { activeElement: null }
  })
  afterEach(() => {
    globalThis.document = savedDocument
    globalThis.window = savedWindow
  })

  const focusable = () => {
    const el = { focus: vi.fn(() => (globalThis.document.activeElement = el)) }
    return el
  }

  for (const [label, desktop] of [
    ["a phone (coarse pointer, narrow)", false],
    ["a desktop (fine pointer, wide)", true],
  ]) {
    it(`the search input is document.activeElement after open on ${label}`, () => {
      globalThis.window = { matchMedia: () => ({ matches: desktop }) }
      const hook = Object.create(ReactionPicker)
      hook.searchInput = focusable()
      hook.panel = focusable()

      hook._focusOnOpen()

      expect(globalThis.document.activeElement).toBe(hook.searchInput)
      expect(hook.panel.focus).not.toHaveBeenCalled()
    })
  }

  it("moves focus from the panel to the field once a first open builds it", () => {
    globalThis.window = { matchMedia: () => ({ matches: false }) }
    const hook = Object.create(ReactionPicker)
    hook.searchInput = null
    hook.panel = focusable()
    hook._focusOnOpen()
    expect(globalThis.document.activeElement).toBe(hook.panel)

    hook.searchInput = focusable()
    hook._focusFieldOnceBuilt()
    expect(globalThis.document.activeElement).toBe(hook.searchInput)
  })

  it("does not steal focus the user already moved off the panel", () => {
    const hook = Object.create(ReactionPicker)
    hook.panel = focusable()
    hook.searchInput = focusable()
    const elsewhere = {}
    globalThis.document.activeElement = elsewhere
    hook._focusFieldOnceBuilt()
    expect(globalThis.document.activeElement).toBe(elsewhere)
  })

  it("falls back to the panel before the field is built", () => {
    globalThis.window = { matchMedia: () => ({ matches: false }) }
    const hook = Object.create(ReactionPicker)
    hook.searchInput = null
    hook.panel = focusable()

    hook._focusOnOpen()

    expect(globalThis.document.activeElement).toBe(hook.panel)
  })
})
