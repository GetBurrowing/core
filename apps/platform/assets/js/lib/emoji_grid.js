/**
 * The emoji grid: sectioning, row geometry, roving-tabindex movement, and the
 * one tile builder both of the picker's containers share.
 *
 * Extracted from `hooks/reaction_picker.js` in task 019e0814 stage 4. Stage 3
 * had one grid, so its builder could live inline in the hook. Stage 4 has TWO
 * containers inside the same ignored host — a categorised inventory built once
 * and a flat ranked result list rebuilt per query — and both emit the same
 * tile, the same `role="row"` wrappers and the same geometry. Two copies of
 * that would drift, and the tile is the element that cannot afford to: it
 * carries the `data-emoji` the react push reads and the `aria-label` a screen
 * reader announces.
 *
 * Everything above the hook boundary is pure or takes its container as an
 * argument, so it is testable in vitest's default `node` environment. See
 * `test/hooks/reaction_picker.test.js`.
 */

/**
 * The 32 emoji that were `@reaction_picker_emojis` in `messages_hooks.ex`
 * before stage 3, byte for byte, in their original order.
 *
 * THEY LIVE HERE AND NOT IN THE ISLAND ON PURPOSE. This file is part of
 * `app.js`, which is already loaded when the picker opens; the island is
 * fetched. When the fetch fails — usually offline — COMMON is the fallback the
 * error state renders underneath the retry, so a reaction is still possible.
 * An island-resident COMMON would be missing in exactly the case it exists for.
 *
 * Written as `\u{...}` escapes so the variation selectors are visible. The
 * heart is `\u{2764}\u{FE0F}` and MUST keep its FE0F: reactions are grouped by
 * exact string match (`Chat.list_reactions_grouped/1` uses
 * `Enum.group_by(& &1.emoji)`), so a bare `\u{2764}` here would split every
 * heart reaction in the product into a second pill and no migration repairs it.
 */
export const COMMON_EMOJI = [
  "\u{1F44D}",
  "\u{1F44E}",
  "\u{2764}\u{FE0F}",
  "\u{1F525}",
  "\u{1F389}",
  "\u{1F680}",
  "\u{2705}",
  "\u{274C}",
  "\u{1F600}",
  "\u{1F602}",
  "\u{1F605}",
  "\u{1F60A}",
  "\u{1F60D}",
  "\u{1F914}",
  "\u{1F62E}",
  "\u{1F622}",
  "\u{1F64F}",
  "\u{1F44F}",
  "\u{1F64C}",
  "\u{1F4AA}",
  "\u{1F440}",
  "\u{1F4A1}",
  "\u{2B50}",
  "\u{2728}",
  "\u{1F973}",
  "\u{1F92F}",
  "\u{1F4AF}",
  "\u{1FAF6}",
  "\u{1F91D}",
  "\u{2615}",
  "\u{1F355}",
  "\u{1F41B}",
]

/** Slug of the synthetic first section. */
export const COMMON_SLUG = "common"

/**
 * Human labels for the dataset's category slugs, plus COMMON.
 *
 * "Common", never "Frequently used" or "Recently used". The set is static and
 * system-wide (the designer's no-personalisation decision, recorded in stage 1), so a
 * label implying it learned from this user's behaviour would be a lie. The
 * uppercase rendering is `text-transform` in CSS, not the string.
 */
export const CATEGORY_LABELS = {
  [COMMON_SLUG]: "Common",
  "smileys-emotion": "Smileys & Emotion",
  "people-body": "People & Body",
  "animals-nature": "Animals & Nature",
  "food-drink": "Food & Drink",
  "travel-places": "Travel & Places",
  activities: "Activities",
  objects: "Objects",
  symbols: "Symbols",
  flags: "Flags",
}

/**
 * The accessible name for one tile, from the CLDR short name.
 *
 * `React with 😭` was adequate for 32 curated emoji. At ~1,850, including
 * several hundred obscure symbols and 269 flags, the raw character is unusable.
 * Falls back to the character when no name is known, which happens only in the
 * offline COMMON fallback where the inventory never loaded.
 */
export function ariaLabelFor(entry) {
  return `React with ${entry.n || entry.e}`
}

/**
 * The ordered sections the grid renders.
 *
 * COMMON FIRST, above Smileys & Emotion. Without it the everyday case gets
 * measurably slower than the 32-emoji picker being replaced: the same three
 * emoji a person always uses would now require finding them in an 1,800-item
 * inventory. Its entries are looked up in the dataset so they carry real CLDR
 * names; a lookup miss degrades to the bare character rather than dropping the
 * tile.
 */
export function buildSections(emoji, categories, common = COMMON_EMOJI) {
  const byChar = new Map(emoji.map((entry) => [entry.e, entry]))
  const commonEntries = common.map((e) => byChar.get(e) || { e, n: "", k: [], c: COMMON_SLUG })

  const sections = [
    { slug: COMMON_SLUG, label: CATEGORY_LABELS[COMMON_SLUG], entries: commonEntries },
  ]

  for (const slug of categories) {
    const entries = emoji.filter((entry) => entry.c === slug)
    if (entries.length === 0) continue
    sections.push({ slug, label: CATEGORY_LABELS[slug] || slug, entries })
  }

  return sections
}

/**
 * Split a section's entries into rows of `perRow`.
 *
 * `role="grid"` REQUIRES `role="row"` children — a flat container of
 * `role="gridcell"` tiles is what an implementer writes by default and screen
 * readers then report a malformed grid. The row size must equal the VISUAL
 * column count or the announced geometry is a lie, which is why the column
 * count is measured off the laid-out CSS grid rather than assumed.
 */
export function chunkRows(entries, perRow) {
  if (!Number.isFinite(perRow) || perRow < 1) return entries.length ? [entries.slice()] : []
  const rows = []
  for (let i = 0; i < entries.length; i += perRow) rows.push(entries.slice(i, i + perRow))
  return rows
}

/**
 * Count the columns in a computed `grid-template-columns` value.
 *
 * Computed style resolves `repeat(8, minmax(0, 1fr))` and `repeat(auto-fit,
 * minmax(48px, 1fr))` alike into a space-separated list of used track sizes, so
 * counting tokens is exact at every breakpoint AND on coarse pointers, where
 * the auto-fit track count depends on the panel's actual width. Reading the
 * real layout is the only way JS and CSS cannot drift.
 */
export function countColumns(templateValue) {
  if (!templateValue || templateValue === "none") return 0

  // AN UNRESOLVED TEMPLATE IS NOT A COLUMN COUNT. `getComputedStyle` on a
  // `display: none` element has no layout to report, so it hands back the
  // SPECIFIED value — "repeat(auto-fit, minmax(48px, 1fr))" — and counting its
  // whitespace-separated tokens returns 3. That would build rows of three and
  // announce a geometry no sighted user sees. The caller must not measure a
  // hidden grid; this refuses to guess if it ever does.
  if (/repeat\(|minmax\(|auto-fit|auto-fill/.test(templateValue)) return 0

  const tokens = templateValue.trim().split(/\s+/).filter(Boolean)
  return tokens.length
}

/**
 * Roving-tabindex movement over the row grid. Pure: rows in, position out.
 *
 * A plain focus trap over ~1,850 buttons is unusable rather than merely slow —
 * a keyboard user tabs in and walks the whole inventory one tile at a time.
 * Exactly one tile is tabbable; these keys move that tile. Left/Right cross a
 * row boundary so the grid reads as one sequence; Home/End stay WITHIN the
 * current row, which is what makes them useful. Returns null for a key this
 * grid does not handle, so the caller leaves the event alone.
 */
export function moveFocus(rows, pos, key) {
  if (!rows.length) return null
  const r = Math.min(Math.max(pos.r, 0), rows.length - 1)
  const c = Math.min(Math.max(pos.c, 0), Math.max(rows[r].length - 1, 0))

  switch (key) {
    case "ArrowRight":
      if (c + 1 < rows[r].length) return { r, c: c + 1 }
      if (r + 1 < rows.length) return { r: r + 1, c: 0 }
      return { r, c }
    case "ArrowLeft":
      if (c > 0) return { r, c: c - 1 }
      if (r > 0) return { r: r - 1, c: rows[r - 1].length - 1 }
      return { r, c }
    case "ArrowDown":
      if (r + 1 < rows.length) return { r: r + 1, c: Math.min(c, rows[r + 1].length - 1) }
      return { r, c }
    case "ArrowUp":
      if (r > 0) return { r: r - 1, c: Math.min(c, rows[r - 1].length - 1) }
      return { r, c }
    case "Home":
      return { r, c: 0 }
    case "End":
      return { r, c: rows[r].length - 1 }
    default:
      return null
  }
}

/**
 * Roving movement along the single-row category chip bar.
 *
 * Nine categories plus Common would otherwise insert ten tab stops between the
 * search field and the grid. One chip is tabbable and Left/Right move it, the
 * same contract the grid uses, so the two behave alike under the same hand.
 * Ends clamp rather than wrap, matching `moveFocus`.
 */
export function moveChip(count, index, key) {
  if (count <= 0) return null
  const i = Math.min(Math.max(index, 0), count - 1)
  switch (key) {
    case "ArrowRight":
      return Math.min(i + 1, count - 1)
    case "ArrowLeft":
      return Math.max(i - 1, 0)
    case "Home":
      return 0
    case "End":
      return count - 1
    default:
      return null
  }
}

/**
 * One emoji tile. The single place the tile's contract is written down.
 *
 * `tabindex="-1"` on every tile by default; the caller promotes exactly one.
 * `data-emoji` is what the click handler pushes to the server, and it must be
 * the fully-qualified character byte for byte — see COMMON_EMOJI on the heart's
 * variation selector.
 */
export function buildTile(doc, entry) {
  const tile = doc.createElement("button")
  tile.type = "button"
  tile.className = "reaction-picker-tile"
  tile.setAttribute("role", "gridcell")
  tile.setAttribute("tabindex", "-1")
  tile.setAttribute("data-emoji", entry.e)
  tile.setAttribute("aria-label", ariaLabelFor(entry))
  if (entry.n) tile.title = entry.n
  tile.textContent = entry.e
  return tile
}

/**
 * Fill a `role="grid"` element with `role="row"` wrappers of `columns` tiles
 * and return the rows as arrays of elements, ready to seed a roving tabindex.
 *
 * RETURNING THE ROWS IS THE CONTRACT, not a convenience. Every rebuild — a
 * breakpoint change, and now every settled query — replaces these nodes, and a
 * roving tabindex still pointing at the previous build is pointing at a
 * detached element. Focus then goes nowhere and keyboard navigation dies
 * silently in the middle of a search, which is the failure this signature
 * exists to make hard to write.
 */
export function fillGrid(doc, grid, entries, columns) {
  const rows = []
  for (const rowEntries of chunkRows(entries, columns)) {
    const row = doc.createElement("div")
    row.className = "reaction-picker-row"
    row.setAttribute("role", "row")
    const tiles = []
    for (const entry of rowEntries) {
      const tile = buildTile(doc, entry)
      row.appendChild(tile)
      tiles.push(tile)
    }
    grid.appendChild(row)
    rows.push(tiles)
  }
  return rows
}
