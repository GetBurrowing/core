/**
 * Canvas search snippet geometry — task 01a077e6 stage 2.
 *
 * WHY THIS IS A BROWSER TEST AND NOT A LIVEVIEW ONE. A test asserting that
 * `[data-role="canvas-result-snippet"]` exists and contains a `<mark>` PASSES
 * on the broken build. `Phoenix.LiveViewTest` does no layout. Nine passing
 * LiveView tests missed this defect and a real browser caught it, so every
 * assertion here is geometric: rects off `getBoundingClientRect()` and ranges
 * off `document.createRange()`, never a class name and never a computed style.
 *
 * A class-name check would be the SAME SPECIES of assertion as the presence
 * check it replaced. `toHaveClass(/truncate/)` passes whether or not the box
 * ever clipped anything, and `getComputedStyle(el).direction === "rtl"` passes
 * on any technique that happens to set the property and FAILS on an equally
 * correct one that does not. The contract is where the pixels land.
 *
 * THE DEFECT, AS MEASURED ON THE PRE-FIX BUILD. At 375px the snippet box's
 * right edge sat at x=286 and the `<mark>` at x=317-377 — entirely outside, so
 * a phone reader got "… until their manager r…", context with the searched
 * word amputated. At 1440px the mark ended at 825 inside a box ending at 943,
 * which is why nobody reviewing on a laptop saw it.
 *
 * THE FIX BEING MEASURED. The snippet is three parts in a flex row, from the
 * brand rule that the last thing allowed to truncate is the most meaningful:
 * leading context (`min-w-0 truncate`, clipped from the LEFT so the words
 * nearest the match survive), the match (`shrink-0 whitespace-nowrap`, never
 * shrinks), trailing context (`min-w-0 truncate`).
 *
 * ── CASE 2 IS READ GEOMETRICALLY, AND HERE IS WHY ────────────────────────────
 *
 * The plan's case 2 asks that "the snippet's rendered text is strictly longer
 * at 1440px than at 375px". That clause was authored from an assumption that
 * stage 1 then disproved by measurement: the DOM text is IDENTICAL at both
 * widths, because the server emits ONE fragment and CSS does all the yielding.
 * That is the design working. A `textContent.length` reading of that clause
 * goes red on a correct build, and `plan_update` only revises draft plans, so
 * the correction could not be written into the validation itself.
 *
 * So case 2 is read against the leading run's WIDTH rather than its text. That
 * reading still does the whole job the clause was authored for. The cheap
 * wrong fix it exists to reject is a global `ts_headline` MaxWords reduction,
 * which would satisfy a 375px-only containment check and quietly cost desktop
 * the context that makes the snippet worth having. Under that mutation the
 * fragment FITS at 375px, so the leading run does not overflow there and
 * measures the same width at both viewports. Under the real fix the 18-word
 * fragment cannot fit at 375px, so the run is clipped there and grows when the
 * viewport does. The pair of clauses — overflow at 375px, growth to 1440px —
 * is what separates them, and both are asserted below with the raw numbers
 * printed.
 *
 * The text-length clause is kept, inverted: the rendered text must be the SAME
 * at both widths. That is the direct falsifier of the other rejected approach,
 * a viewport-dependent server fragment.
 *
 * ── SELECTOR DISCIPLINE ──────────────────────────────────────────────────────
 *
 * The mark is resolved as `[data-role="canvas-result-snippet"] mark`, NOT as
 * the sub-role the fix introduced. That is deliberate: the same selector has
 * to resolve on the PRE-FIX markup too, or the mutation probe would fail on a
 * missing element instead of on the geometry it is there to measure, and a
 * mutant that dies of a `SelectorAmbiguityError` has not demonstrated anything
 * about where the mark lands.
 *
 * Everything goes through `visibleRect` / `allRects` from `support/geometry.ts`
 * rather than `.first()`. A hidden copy has an all-zero rect and a zero rect
 * passes every containment test there is.
 *
 * ── RUNNING IT ───────────────────────────────────────────────────────────────
 *
 * This suite is NOT in CI (`.github/workflows/ci.yml` runs
 * `mix format --check-formatted` and `mix test` only). A green CI says nothing
 * about this file — an assertion on a since-deleted long-press overlay in
 * chat_reactions.spec.ts rotted for months for exactly that reason. It has to be run by hand, and the
 * reviewer of this stage has to run it too.
 *
 *   cd apps/platform && mix run priv/scripts/seed_canvas_search_snippet_fixture.exs
 *   scripts/run-e2e.sh tests/canvas_search_snippet_geometry.spec.ts
 *
 * Point both at the same database. The seed script prints SPACE_SLUG and
 * PHRASE; override with FIXTURE_SPACE_SLUG / FIXTURE_PHRASE if you changed
 * them.
 */

import { test, expect, Browser, BrowserContext, Page } from "@playwright/test"
import { visibleRect, allRects, clippedBy, Rect } from "./support/geometry"

const MOBILE = { width: 375, height: 812 }
const DESKTOP = { width: 1440, height: 900 }

/** Seeded by priv/scripts/seed_canvas_search_snippet_fixture.exs. */
const PHRASE = process.env.FIXTURE_PHRASE ?? "zorbling"
const SPACE_SLUG = process.env.FIXTURE_SPACE_SLUG ?? "general"

const SNIPPET = '[data-role="canvas-result-snippet"]'
/** Resolves on the pre-fix single-span markup as well — see the header. */
const MARK = '[data-role="canvas-result-snippet"] mark'
const LEADING = '[data-role="canvas-result-snippet-leading"]'
const TRAILING = '[data-role="canvas-result-snippet-trailing"]'
const SEARCH_INPUT = '[data-role="canvas-search-input"]'
const DRAWER_TOGGLE = 'button[phx-click="canvas_panel_toggle"]'

/**
 * Subpixel rounding means an exactly-flush edge can measure a hair over. Named
 * once and passed explicitly to every predicate, because `support/geometry.ts`
 * carries no default tolerance — a default is how one threshold gets loosened
 * once and then silently governs four assertions.
 */
const TOLERANCE_PX = 1

/** Text-node geometry the rect helpers do not cover: the end-anchoring case
 *  needs a Range over individual characters. */
interface RunAnchoring {
  /** The leading run's own box. */
  runRight: number
  runLeft: number
  /** Laid-out extent of ALL the run's text, clipped or not. Under left
   *  clipping this spills past the run's LEFT edge and is flush at its right;
   *  under a default right-truncation it is the other way round. Reported as
   *  corroboration for the per-character measurement below. */
  textLeft: number
  textRight: number
  /** The last character of the run's last text node, whatever it is. */
  lastChar: string
  lastCharRight: number
  /** The last NON-whitespace character, and the measured advance width of the
   *  whitespace after it. `ts_headline` hands back a verbatim slice, so the
   *  character immediately before `<mark>` is a real space — the allowance for
   *  it is MEASURED here rather than chosen, so no threshold is being tuned. */
  lastGlyph: string
  lastGlyphRight: number
  trailingWhitespaceWidth: number
  /** The precondition that makes the anchoring assertion mean anything: a run
   *  that never needed to clip is anchored at both ends at once and would pass
   *  on the right-clipping implementation this case exists to reject. */
  scrollWidth: number
  clientWidth: number
  overflows: boolean
}

async function open(
  browser: Browser,
  viewport: { width: number; height: number },
  slug: string,
): Promise<{ context: BrowserContext; page: Page }> {
  const context = await browser.newContext({ viewport })
  const page = await context.newPage()
  page.on("pageerror", (err) => console.log(`[pageerror] ${err.message}`))

  await page.goto(`/dev/login?as=${slug}`)
  await page.waitForURL("**/chat**", { timeout: 15_000 })
  await page.goto(`/chat/${SPACE_SLUG}`)

  // The toggle is in the STATIC markup before LiveView connects, so a click
  // landing before the socket is up is swallowed and the drawer never opens —
  // which reads as "the drawer is missing". This cost two of the three cases
  // on the first run of this file while the third passed, i.e. it presents as
  // flake rather than as a wiring error. Wait for the socket, then click.
  await page.waitForFunction(
    () => !!(window as unknown as { liveSocket?: { isConnected?: () => boolean } })
      .liveSocket?.isConnected?.(),
    null,
    { timeout: 30_000 },
  )

  // The drawer toggle only renders when the space HAS canvases, so its absence
  // is a fixture failure and worth failing on by name rather than on a later
  // missing snippet.
  await expect(
    page.locator(DRAWER_TOGGLE),
    `no canvases drawer toggle in /chat/${SPACE_SLUG} — seed the fixture first`,
  ).toBeVisible({ timeout: 15_000 })

  await page.locator(DRAWER_TOGGLE).click()
  await expect(page.locator(SEARCH_INPUT)).toBeVisible({ timeout: 15_000 })

  // `phx-debounce="300"` on the input (canvas_hooks.ex:282), so wait for the
  // results to render rather than asserting straight after the fill.
  await page.locator(SEARCH_INPUT).fill(PHRASE)
  await expect(page.locator(SNIPPET)).toBeVisible({ timeout: 15_000 })
  await expect(page.locator(MARK)).toBeVisible({ timeout: 15_000 })

  return { context, page }
}

/** The container and mark rects, plus the mark count. Exactly one mark is a
 *  property of the FIXTURE (one occurrence of the phrase in the body), and it
 *  is asserted rather than assumed: `MaxFragments=1` bounds fragments, not
 *  marks, so a fixture change could put two in the row and make `MARK`
 *  ambiguous — which must fail loudly, not silently measure one of them. */
async function containment(page: Page): Promise<{
  container: Rect
  mark: Rect
  markCount: number
  text: string
}> {
  const container = await visibleRect(page, SNIPPET)
  const marks = await allRects(page, MARK)
  const mark = await visibleRect(page, MARK)
  const text = ((await page.locator(SNIPPET).textContent()) ?? "")
    .replace(/\s+/g, " ")
    .trim()

  return { container, mark, markCount: marks.length, text }
}

async function anchoring(page: Page, selector: string): Promise<RunAnchoring> {
  return page.evaluate((sel) => {
    const nodes = Array.from(document.querySelectorAll(sel))
    const visible = nodes.filter((n) => {
      const r = n.getBoundingClientRect()
      return r.width > 0 && r.height > 0
    })
    if (visible.length !== 1) {
      throw new Error(
        `anchoring: selector ${sel} matched ${visible.length} visible element(s) ` +
          `of ${nodes.length} total; expected exactly one`,
      )
    }
    const el = visible[0] as HTMLElement
    const runRect = el.getBoundingClientRect()

    // Deepest last text node — the run's text sits inside a <bdi>, so the
    // element's own lastChild is an element, not the text.
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT)
    let node: Node | null = null
    let next: Node | null
    while ((next = walker.nextNode())) node = next
    if (!node) {
      throw new Error(`anchoring: ${sel} has no text node to measure`)
    }
    const data = (node as Text).data
    if (data.length === 0) {
      throw new Error(`anchoring: ${sel}'s last text node is empty`)
    }

    const range = (start: number, end: number) => {
      const r = document.createRange()
      r.setStart(node as Text, start)
      r.setEnd(node as Text, end)
      return r.getBoundingClientRect()
    }

    // Walk back over trailing whitespace and measure its advance width, so the
    // allowance the test applies is a measurement rather than a constant.
    let cut = data.length
    while (cut > 0 && /\s/.test(data[cut - 1])) cut--
    if (cut === 0) {
      throw new Error(
        `anchoring: ${sel}'s last text node is entirely whitespace ` +
          `(${JSON.stringify(data)}). This is the HEEx-formatter hazard the ` +
          `container's phx-no-format pins: an interpolation on its own line ` +
          `lands a newline inside the run.`,
      )
    }

    const all = document.createRange()
    all.selectNodeContents(el)
    const textRect = all.getBoundingClientRect()

    const lastCharRect = range(data.length - 1, data.length)
    const lastGlyphRect = range(cut - 1, cut)
    const wsWidth = cut === data.length ? 0 : range(cut, data.length).width

    return {
      runRight: runRect.right,
      runLeft: runRect.left,
      textLeft: textRect.left,
      textRight: textRect.right,
      lastChar: data[data.length - 1],
      lastCharRight: lastCharRect.right,
      lastGlyph: data[cut - 1],
      lastGlyphRight: lastGlyphRect.right,
      trailingWhitespaceWidth: wsWidth,
      scrollWidth: el.scrollWidth,
      clientWidth: el.clientWidth,
      overflows: el.scrollWidth > el.clientWidth,
    }
  }, selector)
}

test.describe("canvas search snippet geometry", () => {
  test("case 1 — at 375px the match is inside the snippet box", async ({ browser }) => {
    const { context, page } = await open(browser, MOBILE, "snipgeom-a")

    try {
      const { container, mark, markCount, text } = await containment(page)
      console.log(
        `[375px] container=${JSON.stringify(container)}\n` +
          `[375px] mark=${JSON.stringify(mark)}\n` +
          `[375px] markCount=${markCount}\n` +
          `[375px] text=${JSON.stringify(text)}`,
      )

      expect(markCount, "the fixture seeds one occurrence of the phrase").toBe(1)

      // The mark is painted, not a zero-width ghost. Without this, a mark
      // collapsed to nothing would satisfy every containment clause below.
      expect(mark.width, "the mark has a painted width").toBeGreaterThan(0)

      const clip = clippedBy(mark, container)
      console.log(`[375px] clippedBy=${JSON.stringify(clip)}`)

      expect(
        mark.right,
        `the mark's right edge (${mark.right}) must be inside the snippet box's ` +
          `(${container.right}); on the pre-fix build these were 377 and 286`,
      ).toBeLessThanOrEqual(container.right + TOLERANCE_PX)

      expect(
        mark.left,
        `the mark's left edge (${mark.left}) must be inside the snippet box's ` +
          `(${container.left})`,
      ).toBeGreaterThanOrEqual(container.left - TOLERANCE_PX)

      expect(clip.right, "no right-edge clipping of the mark").toBeLessThanOrEqual(
        TOLERANCE_PX,
      )
      expect(clip.left, "no left-edge clipping of the mark").toBeLessThanOrEqual(
        TOLERANCE_PX,
      )
    } finally {
      await context.close()
    }
  })

  test("case 2 — at 1440px the match is contained, both context runs show, and the leading run widens with the viewport", async ({
    browser,
  }) => {
    const desktop = await open(browser, DESKTOP, "snipgeom-b")

    try {
      // (a) THE CONTROL, measured and asserted FIRST and on its own. The
      // pre-fix build also passes this clause — the mark ended at 825 inside a
      // box ending at 943 — and that is the point: it is what proves case 1's
      // failure is a NARROW-WIDTH failure rather than the measurement being
      // broken at every width. It is deliberately ahead of everything that
      // needs the three-span markup, so the mutation probe gets this number
      // out of the mutant before the run dies on markup the mutant does not
      // have.
      const wide = await containment(desktop.page)
      console.log(
        `[1440px] container=${JSON.stringify(wide.container)}\n` +
          `[1440px] mark=${JSON.stringify(wide.mark)}\n` +
          `[1440px] text=${JSON.stringify(wide.text)} length=${wide.text.length}`,
      )

      expect(wide.mark.width).toBeGreaterThan(0)
      expect(wide.mark.right).toBeLessThanOrEqual(wide.container.right + TOLERANCE_PX)
      expect(wide.mark.left).toBeGreaterThanOrEqual(wide.container.left - TOLERANCE_PX)

      // (b) Context on BOTH sides of the match. A "fix" that truncated
      // everything down to the match alone would satisfy case 1 perfectly and
      // leave the row useless.
      const wideLeading = await visibleRect(desktop.page, LEADING)
      const wideTrailing = await visibleRect(desktop.page, TRAILING)
      const wideAnchor = await anchoring(desktop.page, LEADING)

      console.log(
        `[1440px] leading=${JSON.stringify(wideLeading)}\n` +
          `[1440px] trailing=${JSON.stringify(wideTrailing)}\n` +
          `[1440px] leading scrollWidth=${wideAnchor.scrollWidth} clientWidth=${wideAnchor.clientWidth}`,
      )

      expect(wideLeading.width, "leading context is shown").toBeGreaterThan(0)
      expect(wideTrailing.width, "trailing context is shown").toBeGreaterThan(0)

      const narrow = await open(browser, MOBILE, "snipgeom-c")
      try {
        const small = await containment(narrow.page)
        const smallLeading = await visibleRect(narrow.page, LEADING)
        const smallAnchor = await anchoring(narrow.page, LEADING)

        console.log(
          `[375px] leading=${JSON.stringify(smallLeading)}\n` +
            `[375px] leading scrollWidth=${smallAnchor.scrollWidth} clientWidth=${smallAnchor.clientWidth}\n` +
            `[375px] text=${JSON.stringify(small.text)} length=${small.text.length}\n` +
            `[ratio] leadingWidth 1440/375 = ${wideLeading.width}/${smallLeading.width} = ` +
            `${(wideLeading.width / smallLeading.width).toFixed(3)}`,
        )

        // (c) ONE server fragment, and CSS does the yielding. This is the
        // clause the plan wrote as "text strictly longer at 1440px"; measured
        // in the real app the text is IDENTICAL at both widths, which is the
        // design working. Kept in its true form because it is the direct
        // falsifier of a viewport-dependent server fragment — one of the four
        // approaches this ticket rejected.
        expect(
          small.text,
          "the server emits one fragment for both viewports",
        ).toBe(wide.text)

        // (d) The discriminating pair, and the geometric reading of case 2.
        // A global `ts_headline` MaxWords reduction makes the fragment FIT at
        // 375px: the leading run stops overflowing there and measures the same
        // width at both viewports. Both clauses fail on it; both hold here.
        expect(
          smallAnchor.overflows,
          `the leading run must be clipped at 375px (scrollWidth ` +
            `${smallAnchor.scrollWidth} vs clientWidth ${smallAnchor.clientWidth}); ` +
            `a run that fits is a fragment that was shortened for every viewport`,
        ).toBe(true)

        expect(
          wideLeading.width,
          `the leading run must widen with the viewport ` +
            `(375px: ${smallLeading.width}, 1440px: ${wideLeading.width})`,
        ).toBeGreaterThan(smallLeading.width * 1.5)
      } finally {
        await narrow.context.close()
      }
    } finally {
      await desktop.context.close()
    }
  })

  test("case 4 — at 375px the leading run is anchored at its END", async ({ browser }) => {
    const { context, page } = await open(browser, MOBILE, "snipgeom-d")

    try {
      const run = await anchoring(page, LEADING)
      console.log(`[375px] leading anchoring=${JSON.stringify(run, null, 2)}`)

      // The precondition. A run that never needed to clip is flush at both
      // ends and would pass this on the right-clipping implementation the case
      // exists to reject.
      expect(
        run.overflows,
        `the leading run must genuinely overflow at 375px (scrollWidth ` +
          `${run.scrollWidth} vs clientWidth ${run.clientWidth}), or this case ` +
          `is measuring a run that never had to choose a half to keep`,
      ).toBe(true)

      // The allowance is the MEASURED advance width of the whitespace after
      // the last glyph — `ts_headline` returns a verbatim slice, so the
      // character before `<mark>` is a real space. Not a tuned threshold: it
      // is whatever that run of whitespace actually occupies, plus subpixel.
      const allowance = run.trailingWhitespaceWidth + TOLERANCE_PX
      const gap = run.runRight - run.lastGlyphRight

      console.log(
        `[375px] lastGlyph=${JSON.stringify(run.lastGlyph)} at right=${run.lastGlyphRight}; ` +
          `run right=${run.runRight}; gap=${gap}; ` +
          `trailing whitespace width=${run.trailingWhitespaceWidth}; allowance=${allowance}`,
      )

      expect(
        gap,
        `the run's last glyph must not paint past its own right edge`,
      ).toBeGreaterThanOrEqual(-TOLERANCE_PX)

      expect(
        gap,
        `the run's last glyph must be FLUSH with its right edge — i.e. the ` +
          `words nearest the match are the ones that survived. A default ` +
          `right-truncating run leaves the last character hundreds of px past ` +
          `this edge (text extent here: ${run.textLeft}..${run.textRight} in a ` +
          `run at ${run.runLeft}..${run.runRight})`,
      ).toBeLessThanOrEqual(allowance)
    } finally {
      await context.close()
    }
  })
})
