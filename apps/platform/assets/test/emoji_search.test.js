// Unit tests for emoji search ranking, the strings the two modes render, and
// the grid builder both containers share. Task 019e0814 stage 4.
//
// THERE IS NO VITEST CONFIG IN THIS REPO, so vitest runs on defaults: the
// environment is `node` and JSDOM IS NOT A DEPENDENCY (assets/package.json
// devDependencies are `esbuild` and `vitest`, nothing else). Everything under
// test here is therefore either pure, or takes its `document` as an argument —
// which is why `fillGrid` has the signature it has.

import { describe, it, expect } from "vitest"
import {
  buildSearchIndex,
  countLabel,
  emptyStateText,
  keyboardInset,
  normalizeQuery,
  rankEmoji,
  truncateTerm,
} from "../js/lib/emoji_search"
import { fillGrid, moveChip } from "../js/lib/emoji_grid"
import { EMOJI } from "../emoji/data.js"

const REAL = buildSearchIndex(EMOJI)

// DELIBERATELY IN THE WRONG ORDER. Dataset order here is worst-match first, so
// any implementation that returns matches in the order it walked the inventory
// — which is what `.hidden`-toggling and a plain `String.contains?` filter both
// do — returns exactly the reverse of what these tests expect. That is the
// point of the fixture: the ranking has to be observable in the OUTPUT, not
// merely computed and then discarded.
const TIERS = [
  { e: "\u{1FAAA}", n: "identification card", k: ["document"], c: "objects" },
  { e: "\u{1F4A5}", n: "collision", k: ["scatter", "boom"], c: "smileys-emotion" },
  { e: "\u{1F638}", n: "grinning cat", k: ["cat", "smile"], c: "smileys-emotion" },
  { e: "\u{1F63A}", n: "cat face", k: ["grinning"], c: "smileys-emotion" },
  { e: "\u{1F431}", n: "cat", k: ["pet"], c: "animals-nature" },
]
const TIER_INDEX = buildSearchIndex(TIERS)

const names = (entries) => entries.map((entry) => entry.n)

describe("normalizeQuery", () => {
  it("lowercases, trims and collapses whitespace", () => {
    expect(normalizeQuery("  Red   HEART ")).toBe("red heart")
  })

  it("treats null and undefined as empty", () => {
    expect(normalizeQuery(null)).toBe("")
    expect(normalizeQuery(undefined)).toBe("")
  })
})

describe("rankEmoji tiers", () => {
  // THE ASSERTION THAT FAILS AGAINST A PLAIN SUBSTRING FILTER. Every one of
  // these five entries matches "cat"; only a tiered implementation orders them.
  it("orders exact name, then name prefix, then keyword prefix, then substring", () => {
    expect(names(rankEmoji("cat", TIER_INDEX))).toEqual([
      "cat",
      "cat face",
      "grinning cat",
      "collision",
      "identification card",
    ])
  })

  it("does not return matches in dataset order", () => {
    const ranked = names(rankEmoji("cat", TIER_INDEX))
    expect(ranked).not.toEqual(names(TIERS))
  })

  // The design's own example: without ranking, "cat" puts words that merely
  // contain the letters above the animal the user asked for.
  it("ranks the cat face above a keyword that only contains the query", () => {
    const ranked = names(rankEmoji("cat", TIER_INDEX))
    expect(ranked.indexOf("cat face")).toBeLessThan(ranked.indexOf("collision"))
  })

  it("breaks ties on the shorter name", () => {
    const ranked = names(rankEmoji("cat", TIER_INDEX))
    expect(ranked.indexOf("collision")).toBeLessThan(ranked.indexOf("identification card"))
  })
})

describe("rankEmoji against the shipped dataset", () => {
  it("puts the exact name first for a one-word query", () => {
    const [first] = rankEmoji("cat", REAL)
    expect(first.n).toBe("cat")
    expect(first.e).toBe("\u{1F408}")
  })

  it("ranks names beginning with the query above names merely containing it", () => {
    const ranked = names(rankEmoji("cat", REAL))
    const firstPrefix = ranked.findIndex((n) => n.startsWith("cat"))
    const firstSubstringOnly = ranked.findIndex((n) => !n.startsWith("cat") && n.includes("cat"))
    expect(firstPrefix).toBeGreaterThanOrEqual(0)
    expect(firstSubstringOnly).toBeGreaterThan(firstPrefix)
  })

  // MULTI-WORD IS AN AND. "red heart" must be a narrower query than "heart",
  // never a wider one.
  it("narrows on a second word instead of widening", () => {
    const heart = rankEmoji("heart", REAL)
    const redHeart = rankEmoji("red heart", REAL)
    expect(redHeart.length).toBeGreaterThan(0)
    expect(redHeart.length).toBeLessThan(heart.length)
    expect(redHeart[0].n).toBe("red heart")
    expect(redHeart[0].e).toBe("\u{2764}\u{FE0F}")
  })

  it("returns nothing for a query nothing matches", () => {
    expect(rankEmoji("xyzzy", REAL)).toEqual([])
  })

  it("returns nothing for an empty or whitespace-only query", () => {
    expect(rankEmoji("", REAL)).toEqual([])
    expect(rankEmoji("   ", REAL)).toEqual([])
  })

  // SKIN TONE. The inventory ships neutral forms only (Marlowe's
  // no-personalisation decision, stage 1), but the generator kept the CLDR tone
  // keywords, so a tone term the user can see is real must land on the neutral
  // emoji rather than on the empty state.
  it("answers a tone-qualified query with the neutral emoji", () => {
    const ranked = rankEmoji("thumbs up medium skin tone", REAL)
    expect(ranked.length).toBeGreaterThan(0)
    expect(ranked[0].e).toBe("\u{1F44D}")
  })

  it("never returns a skin-tone modifier form, because none is in the dataset", () => {
    const ranked = rankEmoji("light skin tone", REAL)
    expect(ranked.length).toBeGreaterThan(0)
    const modifiers = /[\u{1F3FB}-\u{1F3FF}]/u
    expect(ranked.filter((entry) => modifiers.test(entry.e))).toEqual([])
  })
})

describe("countLabel", () => {
  it("is worded at zero and numbered above it", () => {
    expect(countLabel(0)).toBe("No results")
    expect(countLabel(1)).toBe("1 result")
    expect(countLabel(7)).toBe("7 results")
  })
})

describe("truncateTerm and emptyStateText", () => {
  it("names the term the user searched", () => {
    expect(emptyStateText("xyzzy")).toBe('No emoji matches "xyzzy"')
  })

  it("truncates past 24 characters rather than wrapping to a second line", () => {
    const long = "abcdefghijklmnopqrstuvwxyz0123456789"
    expect(truncateTerm(long)).toBe("abcdefghijklmnopqrstuvwx…")
    expect(truncateTerm(long)).toHaveLength(25)
  })

  it("leaves a term at exactly the limit alone", () => {
    const exact = "a".repeat(24)
    expect(truncateTerm(exact)).toBe(exact)
  })
})

describe("keyboardInset", () => {
  // THE FLOOR IS NOT A ROUNDING GUARD. iOS fires visualViewport `resize` when
  // the URL bar collapses during a scroll, which separates the two heights by
  // roughly 40-90px with no keyboard anywhere. Treating that as a keyboard
  // resizes the sheet mid-flick.
  it("ignores a URL-bar collapse", () => {
    expect(keyboardInset(844, 764)).toBe(0)
  })

  it("reports a real keyboard", () => {
    expect(keyboardInset(844, 508)).toBe(336)
  })

  it("is zero when nothing is up", () => {
    expect(keyboardInset(844, 844)).toBe(0)
  })
})

describe("moveChip", () => {
  it("moves along the bar and clamps at both ends", () => {
    expect(moveChip(10, 0, "ArrowRight")).toBe(1)
    expect(moveChip(10, 9, "ArrowRight")).toBe(9)
    expect(moveChip(10, 3, "ArrowLeft")).toBe(2)
    expect(moveChip(10, 0, "ArrowLeft")).toBe(0)
    expect(moveChip(10, 4, "Home")).toBe(0)
    expect(moveChip(10, 4, "End")).toBe(9)
  })

  it("returns null for keys the bar does not handle, so the event is left alone", () => {
    expect(moveChip(10, 0, "Escape")).toBeNull()
    expect(moveChip(10, 0, "ArrowDown")).toBeNull()
    expect(moveChip(0, 0, "ArrowRight")).toBeNull()
  })
})

// The smallest `document` fillGrid needs. Written out rather than reached for
// via JSDOM because JSDOM is not a dependency here and adding one for four
// methods would be a heavier change than the code under test.
function fakeDocument() {
  const make = (tag) => ({
    tag,
    children: [],
    attrs: {},
    className: "",
    type: "",
    title: "",
    textContent: "",
    appendChild(child) {
      this.children.push(child)
      return child
    },
    setAttribute(k, v) {
      this.attrs[k] = v
    },
  })
  return { createElement: make }
}

describe("fillGrid", () => {
  const entries = [
    { e: "a", n: "alpha", k: [] },
    { e: "b", n: "bravo", k: [] },
    { e: "c", n: "charlie", k: [] },
    { e: "d", n: "delta", k: [] },
    { e: "e", n: "echo", k: [] },
  ]

  it("wraps tiles in role=row groups of exactly the column count", () => {
    const doc = fakeDocument()
    const grid = doc.createElement("div")
    const rows = fillGrid(doc, grid, entries, 2)

    expect(rows.map((r) => r.length)).toEqual([2, 2, 1])
    expect(grid.children).toHaveLength(3)
    for (const row of grid.children) expect(row.attrs.role).toBe("row")
  })

  it("names every tile from CLDR and carries the exact character", () => {
    const doc = fakeDocument()
    const grid = doc.createElement("div")
    const [[first]] = fillGrid(doc, grid, entries, 8)

    expect(first.attrs["aria-label"]).toBe("React with alpha")
    expect(first.attrs["data-emoji"]).toBe("a")
    expect(first.attrs.role).toBe("gridcell")
    expect(first.attrs.tabindex).toBe("-1")
  })

  // THE REBUILD CONTRACT. Every settled query replaces the result tiles, and a
  // roving tabindex still pointing at the previous build points at a detached
  // node — focus goes nowhere and the arrow keys die mid-search. Returning the
  // fresh rows is what lets the caller re-seed, so two builds must never hand
  // back the same elements.
  it("returns fresh elements on every build", () => {
    const doc = fakeDocument()
    const gridA = doc.createElement("div")
    const gridB = doc.createElement("div")
    const a = fillGrid(doc, gridA, entries, 2)
    const b = fillGrid(doc, gridB, entries, 2)
    expect(a[0][0]).not.toBe(b[0][0])
  })

  it("builds nothing from no entries", () => {
    const doc = fakeDocument()
    const grid = doc.createElement("div")
    expect(fillGrid(doc, grid, [], 8)).toEqual([])
    expect(grid.children).toHaveLength(0)
  })
})
