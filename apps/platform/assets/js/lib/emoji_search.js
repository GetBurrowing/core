/**
 * Emoji search: ranking and the strings the two search modes render.
 * Task 019e0814 stage 4.
 *
 * PURE BY DESIGN, AND THAT IS THE POINT. vitest runs in this repo with NO
 * config, which means the `node` environment and no JSDOM (assets/package.json
 * carries `esbuild` and `vitest` and nothing else). Anything here that touched
 * the DOM would be untestable, so the ranking lives in named exports taking a
 * query and a prebuilt index and returning an ordered list — the same shape
 * app_badge.test.js tests.
 *
 * ## WHY RANKING IS A SEPARATE THING FROM FILTERING
 *
 * The obvious implementation of emoji search is a substring filter, and it
 * looks correct in a screenshot: every result really does contain the query.
 * It is still wrong. Typing "cat" against this dataset returns `identification
 * card` and `grinning cat` at the same rank as `cat`, because "cat" is a
 * substring of "identification" and of every one of the nine cat faces. The
 * emoji the user meant is somewhere in the middle of ~30 results.
 *
 * So matching is TIERED. A match records WHY it matched, and the tier orders
 * the output:
 *
 *   0  the name IS the query          "cat"    → cat
 *   1  the name STARTS WITH it        "cat"    → cat face, cat with wry smile
 *   2  a keyword or a name WORD
 *      starts with it                 "cat"    → grinning cat, black cat
 *   3  it appears anywhere at all     "cat"    → identification card
 *
 * The hidden-toggle filter that `channel_picker.js:65-78` uses cannot express
 * this: toggling `.hidden` on non-matches leaves the survivors in DATASET
 * order, so the ranking is computed and then silently discarded. That is why
 * the picker builds a separate results container from a fragment instead.
 *
 * ## MULTI-WORD IS AN AND
 *
 * "red heart" must NARROW. Every term has to match the entry somewhere, and
 * the entry's tier is the WORST tier any of its terms achieved — a result that
 * only just scraped in on one term should not outrank one that matched both
 * cleanly. The whole query is then re-checked against the name as a unit, so
 * "red hea" still ranks `red heart` as a name prefix rather than as two
 * separate word matches.
 *
 * ## SKIN TONE
 *
 * The dataset ships neutral forms only (the designer's no-personalisation decision,
 * recorded in stage 1), but the generator KEPT the CLDR tone keywords on the
 * 300 tone-capable emoji: 👍 carries "light skin tone" … "dark skin tone".
 * So "thumbs up medium skin tone" still lands on the neutral 👍 through the
 * substring tier rather than falling into the empty state, which is what the
 * design asks for — a term the user can see is real must not return nothing.
 * No query rewriting is needed and none should be added; the behaviour comes
 * from the data.
 */

/** The name is exactly the query. */
export const TIER_EXACT_NAME = 0
/** The name begins with the query. */
export const TIER_NAME_PREFIX = 1
/** A CLDR keyword, or a word inside the name, begins with the query. */
export const TIER_KEYWORD_PREFIX = 2
/** The query appears somewhere in the name or a keyword. */
export const TIER_SUBSTRING = 3

/** Longest term rendered in the empty state before it is truncated. */
export const EMPTY_TERM_MAX = 24

/**
 * Lowercase, trim, and collapse runs of whitespace to single spaces.
 *
 * ONLY THE QUERY IS NORMALISED. `data.js` documents that every `n` and every
 * `k` is already lowercased and trimmed at generation time; re-normalising the
 * haystack would mean ~9,000 `toLowerCase()` calls per keystroke for no change
 * in the result.
 */
export function normalizeQuery(raw) {
  return String(raw == null ? "" : raw)
    .toLowerCase()
    .trim()
    .replace(/\s+/g, " ")
}

/**
 * Precompute the shape ranking reads, once per inventory load.
 *
 * `i` preserves dataset order as the final tiebreak, so two equally-ranked
 * results always come back in the order they sit in the grid. Splitting the
 * name into words here rather than per keystroke is the only real optimisation
 * in this file: it turns ~1,850 splits per query into ~1,850 splits per page.
 */
export function buildSearchIndex(emoji) {
  return (emoji || []).map((entry, i) => {
    const n = entry.n || ""
    return {
      entry,
      i,
      n,
      words: n.split(" ").filter(Boolean),
      k: entry.k || [],
    }
  })
}

/**
 * The best tier a single term achieves against one indexed entry, or null when
 * the term does not match it at all. A null anywhere excludes the entry: the
 * multi-word contract is AND.
 */
function termTier(row, term) {
  if (row.n === term) return TIER_EXACT_NAME
  if (row.n.startsWith(term)) return TIER_NAME_PREFIX

  for (const keyword of row.k) {
    if (keyword.startsWith(term)) return TIER_KEYWORD_PREFIX
  }
  // A word inside the name ranks with the keyword prefixes rather than with
  // the substrings: "cat" should reach `grinning cat` before it reaches
  // `identification card`, and only a word boundary distinguishes those two.
  for (const word of row.words) {
    if (word.startsWith(term)) return TIER_KEYWORD_PREFIX
  }

  if (row.n.includes(term)) return TIER_SUBSTRING
  for (const keyword of row.k) {
    if (keyword.includes(term)) return TIER_SUBSTRING
  }
  return null
}

/**
 * Ranked, flat match list for a query. Empty query returns no results, which
 * is what puts the picker back into inventory mode rather than into a
 * zero-results empty state.
 *
 * Ties break on name length and then dataset order: for "grinning", `grinning
 * face` should arrive before `grinning face with big eyes`, and the shorter
 * name is a reliable proxy for the more general emoji.
 */
export function rankEmoji(rawQuery, index) {
  const query = normalizeQuery(rawQuery)
  if (query === "") return []

  const terms = query.split(" ")
  const hits = []

  for (const row of index) {
    let tier

    if (row.n === query) {
      tier = TIER_EXACT_NAME
    } else {
      let worst = TIER_EXACT_NAME
      let matched = true

      for (const term of terms) {
        const t = termTier(row, term)
        if (t === null) {
          matched = false
          break
        }
        if (t > worst) worst = t
      }

      if (!matched) continue

      // The whole query as a unit outranks the per-term verdict. Without this,
      // "red hea" scores `red heart` on its worst term ("hea" is only a word
      // prefix) and lands it below entries that matched both terms exactly.
      if (worst > TIER_NAME_PREFIX && row.n.startsWith(query)) worst = TIER_NAME_PREFIX

      tier = worst
    }

    hits.push({ tier, length: row.n.length, i: row.i, entry: row.entry })
  }

  hits.sort((a, b) => a.tier - b.tier || a.length - b.length || a.i - b.i)
  return hits.map((hit) => hit.entry)
}

/**
 * The result count for the swapping row and for the live region.
 *
 * Zero is worded, not numbered. "0 RESULTS" beside an empty state already
 * naming the term repeats the same fact twice in two registers, and the design
 * asks the empty state to carry it alone.
 */
export function countLabel(n) {
  if (n === 0) return "No results"
  return n === 1 ? "1 result" : `${n} results`
}

/**
 * The searched term as the empty state prints it: never wrapped, so it is
 * truncated rather than allowed to run to a second line.
 */
export function truncateTerm(raw, max = EMPTY_TERM_MAX) {
  const term = String(raw == null ? "" : raw).trim()
  if (term.length <= max) return term
  return `${term.slice(0, max)}…`
}

/**
 * The one line the empty state renders. It NAMES THE TERM: a bare "no results"
 * leaves the user unsure whether they mistyped or whether the inventory simply
 * does not have it.
 */
export function emptyStateText(raw, max = EMPTY_TERM_MAX) {
  return `No emoji matches "${truncateTerm(raw, max)}"`
}

/**
 * Keyboard height from the two viewports, or 0 when nothing is up.
 *
 * THE 120px FLOOR IS NOT A ROUNDING GUARD. iOS Safari fires
 * `visualViewport.resize` when the URL bar collapses during a scroll, which
 * moves the two heights apart by roughly 40-90px with no keyboard anywhere.
 * Treating that as a keyboard resizes the sheet mid-scroll. No soft keyboard
 * on any current phone is under 120px, so the floor separates the two cases
 * cleanly.
 */
export function keyboardInset(innerHeight, viewportHeight, minPx = 120) {
  const delta = Math.round((innerHeight || 0) - (viewportHeight || 0))
  return delta >= minPx ? delta : 0
}
