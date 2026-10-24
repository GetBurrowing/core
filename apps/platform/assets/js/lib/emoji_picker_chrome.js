/**
 * The reaction picker's chrome: the search field, the swapping row that holds
 * either the category jump bar or the result count, the category chips, and
 * the results container.
 *
 * Pure DOM construction, no hook state and no event wiring — every function
 * takes a `doc` and returns the elements it built, and the hook connects them.
 * That keeps `hooks/reaction_picker.js` about behaviour and puts every
 * attribute decision on this surface in one readable place, which matters here
 * because most of them are load-bearing for a reason that is not visible from
 * the element itself.
 *
 * Task 019e0814 stage 4.
 */

/**
 * The search field.
 *
 * `type="text"`, NOT `type="search"`. A search input draws the browser's own
 * clear affordance beside the designed one, and Safari binds Escape inside it
 * to "clear the field", which collides with the picker's Escape-to-close. The
 * inputmode/enterkeyhint pair gets the right soft keyboard and the right return
 * key without either of those.
 *
 * Markup shape is `external_recovery_live.ex:366-376` — a `relative` wrapper
 * with an absolutely-positioned magnifying glass and an `aria-label`. What is
 * NOT copied is its `input-sm` sizing: a sub-16px input auto-zooms on iOS
 * Safari, and `root.html.heex:6-7` locks `maximum-scale=1`, so the user cannot
 * pinch back out. `.reaction-picker-search-input` is 15px and exactly 16px
 * under `@media (hover: none)`, the mitigation `app.css:2297-2307` already uses
 * for the composer. `core_components.ex`'s `input/1` is deliberately not used
 * either: its clause is form-oriented and wraps the control in a fieldset and a
 * label.
 *
 * The CLEAR BUTTON ships `hidden` and appears at one character. The input's
 * `padding-right` reserves its width PERMANENTLY in every state, so the text
 * does not shift sideways when the first character lands.
 */
export function buildSearchField(doc) {
  const wrap = doc.createElement("div")
  wrap.className = "reaction-picker-search"
  wrap.setAttribute("data-role", "reaction-picker-search")

  const icon = doc.createElement("span")
  icon.className = "reaction-picker-search-icon hero-magnifying-glass"
  icon.setAttribute("aria-hidden", "true")
  wrap.appendChild(icon)

  const input = doc.createElement("input")
  input.type = "text"
  input.className = "reaction-picker-search-input"
  input.setAttribute("data-role", "reaction-picker-search-input")
  input.placeholder = "Search emoji"
  input.setAttribute("aria-label", "Search emoji")
  input.setAttribute("inputmode", "search")
  input.setAttribute("enterkeyhint", "search")
  input.setAttribute("autocapitalize", "none")
  input.setAttribute("autocorrect", "off")
  input.setAttribute("autocomplete", "off")
  input.setAttribute("spellcheck", "false")
  wrap.appendChild(input)

  const clear = doc.createElement("button")
  clear.type = "button"
  clear.className = "reaction-picker-search-clear"
  clear.setAttribute("data-role", "reaction-picker-search-clear")
  clear.setAttribute("aria-label", "Clear search")
  clear.hidden = true
  const glyph = doc.createElement("span")
  glyph.className = "hero-x-mark"
  glyph.setAttribute("aria-hidden", "true")
  clear.appendChild(glyph)
  wrap.appendChild(clear)

  return { wrap, input, clear }
}

/**
 * The row that holds the jump bar OR the count, never both.
 *
 * It swaps contents, not size — the height is fixed in CSS. Anything below it
 * moving on the first keystroke is a defect: on mobile that is the whole grid
 * jumping while the user is mid-word.
 *
 * The count is `aria-hidden`. The number reaches a screen reader through the
 * hook's separate live region, which was mounted before there was anything to
 * announce; a live region on THIS row would be destroyed and recreated by the
 * swap and would announce nothing (the same rule the Chat list's reorder
 * announcer follows).
 */
export function buildModeBar(doc) {
  const bar = doc.createElement("div")
  bar.className = "reaction-picker-modebar"
  bar.setAttribute("data-role", "reaction-picker-modebar")

  const jumpBar = doc.createElement("div")
  jumpBar.className = "reaction-picker-jumpbar"
  jumpBar.setAttribute("data-role", "reaction-picker-jumpbar")
  jumpBar.setAttribute("role", "toolbar")
  jumpBar.setAttribute("aria-label", "Jump to category")
  bar.appendChild(jumpBar)

  const count = doc.createElement("div")
  count.className = "reaction-picker-count"
  count.setAttribute("data-role", "reaction-picker-count")
  count.setAttribute("aria-hidden", "true")
  count.hidden = true
  bar.appendChild(count)

  return { bar, jumpBar, count }
}

/**
 * One chip per section, COMMON included — it is a category like any other here.
 *
 * SINGLE TAB STOP: the first chip is tabbable and every other is `-1`, with
 * Left/Right moving the tabbable one. Ten categories would otherwise insert ten
 * tab stops between the search field and the grid, which is the same problem
 * the roving tabindex solves for the ~1,850 tiles.
 */
export function buildCategoryChips(doc, jumpBar, sections) {
  jumpBar.textContent = ""
  return sections.map((section, i) => {
    const chip = doc.createElement("button")
    chip.type = "button"
    chip.className = "reaction-picker-chip"
    chip.setAttribute("data-category", section.slug)
    chip.setAttribute("tabindex", i === 0 ? "0" : "-1")
    chip.textContent = section.label
    jumpBar.appendChild(chip)
    return chip
  })
}

/**
 * The results container: a flat `role="grid"` and the empty state, both hidden
 * until a query settles.
 *
 * It is a SEPARATE container from the inventory rather than a filter over it.
 * Toggling `.hidden` on non-matching tiles — the `channel_picker.js:65-78`
 * precedent — returns matches in dataset order, which silently discards the
 * ranking while still looking correct.
 *
 * No sticky headers and no category labels: results are ranked, not
 * categorised, and a "Food & Drink" heading over the third and seventh best
 * matches would be stating something untrue.
 */
export function buildResults(doc) {
  const results = doc.createElement("div")
  results.className = "reaction-picker-results"
  results.setAttribute("data-role", "reaction-picker-results")
  results.hidden = true

  const grid = doc.createElement("div")
  grid.className = "reaction-picker-grid"
  grid.setAttribute("role", "grid")
  grid.setAttribute("aria-label", "Search results")
  grid.setAttribute("data-role", "reaction-picker-results-grid")
  results.appendChild(grid)

  const empty = doc.createElement("p")
  empty.className = "reaction-picker-empty"
  empty.setAttribute("data-role", "reaction-picker-empty")
  empty.hidden = true
  results.appendChild(empty)

  return { results, grid, empty }
}
