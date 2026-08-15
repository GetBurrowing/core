/**
 * Linked-canvas chip geometry — regression guard for task 01a002bd.
 *
 * The task detail panel's Canvases strip renders each attached canvas as a
 * daisyUI `.badge`. That rule sets a FIXED `height: var(--size)` with
 * `align-items: center` and no `white-space: nowrap`, so a title too long for
 * one line wraps freely inside a box that never grows. The overflow escapes
 * symmetrically through the top and bottom borders, and because the border is
 * painted on the box, it crosses the text.
 *
 * The visible result is a line through the title, which reads as a
 * STRIKETHROUGH — i.e. the panel states that a live canvas has been deleted or
 * superseded. That false statement, not the untidy layout, is why this is worth
 * a guard: the reporter and the first investigator both misread it that way
 * before a wider screenshot showed the line was the chip's own border.
 *
 * WHAT THIS ASSERTS, and why each piece is here:
 *
 *   1. CONTAINMENT is the acceptance bar. The title's bounding box must sit
 *      inside the chip's. That is the measurable form of "no border crosses
 *      the text". Asserting a class name instead would pass whether or not the
 *      box actually grew, which is the specific way this test could be born
 *      useless.
 *
 *   2. THE FIXTURE TITLE MUST GENUINELY WRAP. A short title is contained even
 *      in the broken build, so a test seeded with one passes against the bug
 *      and proves nothing. The long fixture is a real design-direction title.
 *
 *   3. A SHORT CHIP MUST STAY SHORT. A "fix" that gives every chip room to
 *      breathe satisfies containment perfectly and wrecks a dense panel. Only
 *      the paired control catches it, so it lives in the same file.
 *
 *   4. THE CLAMP HOLDS AND THE TITLE SURVIVES IT. A pathological title is held
 *      to two lines, and the full string stays recoverable from the element
 *      rather than being merely clipped.
 *
 *   5. THE SOFT-DELETED BRANCH IS COVERED TOO. The strip renders two different
 *      elements — a live `<a>` and a soft-deleted `<span>` — inside the same
 *      `.badge` box, so both were susceptible to the same defect and a
 *      live-only guard leaves half the fix unpinned. That case also holds the
 *      two properties which make the deleted branch a different thing from the
 *      live one: error colour, and not a link.
 *
 * Seed the fixture first, from apps/platform:
 *   mix run priv/scripts/seed_canvas_chip_fixture.exs
 * It prints TASK_ID=<uuid>; pass it as FIXTURE_TASK_ID.
 */

import { test, expect, Browser, BrowserContext, Page } from "@playwright/test"

const DESKTOP = { width: 1440, height: 900 }

const TASK_ID = process.env.FIXTURE_TASK_ID ?? ""

/** Titles seeded by priv/scripts/seed_canvas_chip_fixture.exs. */
const LONG_TITLE = "Design direction — the ruling belongs on the document, not in a queue"
const SHORT_TITLE = "Sprint notes"
const PATHOLOGICAL_PREFIX = "Design direction — an extremely long title that keeps going"

/**
 * What the SOFT-DELETED branch actually renders — and it is not the seeded
 * title. `load_attached_canvases/1` builds `title: canvas && canvas.title`
 * from an envelope that `CanvasAttachments.canvas_envelope/1` collapses to
 * `nil` for a soft-deleted row, so the title is gone by the time the template
 * runs and the `||` fallback in the heex supplies this literal instead. The
 * fixture seeds a long title on that canvas anyway; the server drops it.
 *
 * MEASURED, not assumed: this string stays on one line at every viewport from
 * 1440px down to 340px, because the chip is only ~106px wide and never gets
 * squeezed by the panel. So the soft-deleted branch cannot be made to wrap
 * through the UI at any width a person would use — which is exactly why the
 * case below injects a long title client-side. See the comment there.
 */
const DELETED_PLACEHOLDER = "(deleted canvas)"

/**
 * Injected, not seeded. Deliberately PATHOLOGICAL rather than merely long, for
 * a reason worth keeping: an earlier version of this constant was exactly two
 * lines, and with it, deleting `canvas-chip-title` from the soft-deleted branch
 * changed no geometry at all. The chip is `height: auto`, so without the clamp
 * it simply grew to fit and stayed perfectly contained — the mutation survived
 * every measurement and only the class-name check noticed, which is the weak
 * kind of assertion this file's header warns about.
 *
 * At this length the clamp has to do real work to hold two lines, so its
 * absence is visible as geometry.
 */
const INJECTED_LONG_TITLE =
  "Superseded evidence sheet — the upstream canvas was removed after the ruling " +
  "landed, and this row is now only a detach affordance, kept in the strip so " +
  "the stale attachment can be cleared rather than silently disappearing from " +
  "a panel that never explained where it went"

/** Subpixel rounding means an exactly-flush edge can measure a hair over. */
const CONTAINMENT_TOLERANCE_PX = 1

interface ChipGeometry {
  title: string
  titleResolved: boolean
  chipTop: number
  chipBottom: number
  chipHeight: number
  textTop: number
  textBottom: number
  lineCount: number
  renderedLines: number
  clipped: boolean
  declaredRadius: number
  effectiveRadius: number
  isPill: boolean
  fullTitleRecoverable: boolean
  /** Tag of the resolved title element — `A` on the live branch, `SPAN` on the
   *  soft-deleted one. */
  tagName: string
  /** A real destination, not merely an anchor tag. */
  isLink: boolean
  /** True when the title element carries the shared `.canvas-chip-title`
   *  class, i.e. the clamp + wrap rules apply to it at all. */
  hasTitleClass: boolean
  /** Computed colour, and the same theme's resolved `--color-error`, so a
   *  caller can compare the two without hardcoding a palette value. */
  color: string
  errorColor: string
  isErrorColour: boolean
}

async function open(browser: Browser, slug: string): Promise<{ context: BrowserContext; page: Page }> {
  const context = await browser.newContext({ viewport: DESKTOP })
  const page = await context.newPage()
  page.on("pageerror", (err) => console.log(`[pageerror] ${err.message}`))
  await page.goto(`/dev/login?as=${slug}`)
  await page.waitForURL("**/chat**", { timeout: 15_000 })
  await page.goto(`/tasks/${TASK_ID}`)
  await expect(page.locator('[data-role="linked-canvases-strip"]')).toBeAttached({
    timeout: 15_000,
  })
  return { context, page }
}

/**
 * Measure every chip in the strip straight off getBoundingClientRect() — the
 * geometry the reader's eye actually receives, after the stylesheet has had
 * its say. The text box is measured via a Range over the title element's own
 * contents rather than the element box, because the element could be styled to
 * report a tidy box while its glyphs paint outside it.
 */
async function chipGeometry(page: Page): Promise<ChipGeometry[]> {
  return page.evaluate(() => {
    const px = (v: string) => parseFloat(v)
    const chips = Array.from(document.querySelectorAll('[data-role="linked-canvas-chip"]'))
    return chips.map((chip) => {
      // `.canvas-chip-title` is carried by BOTH branches — the live `<a>` and
      // the soft-deleted `<span>` — so this measures the deleted branch too
      // rather than silently skipping it.
      //
      // The fallbacks matter more than they look. Resolving to the CHIP when
      // no title element is found would compare the chip against itself and
      // every containment assertion would pass vacuously — which is exactly
      // what happened when an earlier mutation run reverted the markup and
      // took the class with it. So this never falls back to `chip`, and a
      // failure to resolve is reported rather than silently measured.
      const titleEl =
        chip.querySelector(
          '.canvas-chip-title, [data-role="linked-canvas-chip-link"], [data-role="linked-canvas-chip-deleted"]',
        ) ?? Array.from(chip.children).find((el) => el.tagName !== "BUTTON") ?? null

      if (!titleEl) {
        return {
          title: "(title element not resolved)",
          titleResolved: false,
          chipTop: 0,
          chipBottom: 0,
          chipHeight: 0,
          textTop: 0,
          textBottom: 0,
          lineCount: 0,
          renderedLines: 0,
          clipped: false,
          declaredRadius: 0,
          effectiveRadius: 0,
          isPill: false,
          fullTitleRecoverable: false,
          tagName: "",
          isLink: false,
          hasTitleClass: false,
          color: "",
          errorColor: "",
          isErrorColour: false,
        }
      }

      // Resolve `--color-error` THROUGH THE CHIP rather than comparing against
      // a hardcoded oklch string: the value is a theme token, and a test that
      // pins the literal would fail on a palette change that broke nothing.
      // Probed and removed before anything is measured, so the temporary node
      // cannot perturb the geometry read below.
      const probe = document.createElement("span")
      probe.style.color = "var(--color-error)"
      chip.appendChild(probe)
      const errorColor = getComputedStyle(probe).color
      probe.remove()

      const chipRect = chip.getBoundingClientRect()
      const titleRect = titleEl.getBoundingClientRect()

      // Two different questions need two different measurements, and using
      // either one alone makes this test unable to see one of the two states.
      //
      //   range rects   every line box the text was LAID OUT into. Correct
      //                 for "did it wrap", and correct for painted extent
      //                 while nothing clips — which is the broken build,
      //                 where an inline title spills past a fixed-height
      //                 badge and the glyphs really are drawn outside it.
      //                 Wrong once a clamp exists: it keeps reporting lines
      //                 that `overflow: hidden` never paints.
      //
      //   element box   what is actually painted once the element clips.
      //                 Wrong on the broken build: for an inline box it
      //                 under-reports the spill, which made an earlier
      //                 version of this test fail its own wrap precondition
      //                 instead of its containment assertion — i.e. pass for
      //                 the wrong reason.
      const range = document.createRange()
      range.selectNodeContents(titleEl)
      const rects = Array.from(range.getClientRects()).filter((r) => r.height > 0)
      const rangeTop = rects.length ? Math.min(...rects.map((r) => r.top)) : titleRect.top
      const rangeBottom = rects.length ? Math.max(...rects.map((r) => r.bottom)) : titleRect.bottom

      const clipped = titleEl.scrollHeight > titleEl.clientHeight + 1

      // Painted extent: clipped content cannot be seen, unclipped content can.
      const textTop = clipped ? titleRect.top : Math.min(titleRect.top, rangeTop)
      const textBottom = clipped ? titleRect.bottom : Math.max(titleRect.bottom, rangeBottom)

      const lineHeight =
        parseFloat(getComputedStyle(titleEl).lineHeight) ||
        parseFloat(getComputedStyle(titleEl).fontSize) * 1.5

      const text = (titleEl.textContent ?? "").replace(/\s+/g, " ").trim()
      const titleAttr =
        titleEl.getAttribute("title") ??
        chip.getAttribute("title") ??
        titleEl.getAttribute("aria-label") ??
        ""

      return {
        title: text,
        titleResolved: true,
        chipTop: chipRect.top,
        chipBottom: chipRect.bottom,
        chipHeight: chipRect.height,
        textTop,
        textBottom,
        // Lines the text was laid out into, clipped or not. This is the
        // honest answer to "did the fixture wrap", which is the precondition
        // that makes containment mean anything.
        lineCount: rects.length,
        // Lines actually painted, derived from the rendered box. Under a
        // clamp this is the clamped count.
        renderedLines: lineHeight > 0 ? Math.round(titleRect.height / lineHeight) : 0,
        // True when content was clipped away — i.e. the clamp did work. Used
        // to prove the pathological case is genuinely being held back rather
        // than just happening to fit.
        clipped,
        // Corner geometry. `effective` is the radius after the CSS
        // corner-overlap rule scales it down to at most half the box — which
        // is the number the eye actually receives, and the whole mechanism
        // the pill-versus-block split rests on.
        declaredRadius: px(getComputedStyle(chip).borderTopLeftRadius),
        effectiveRadius:
          Math.round(Math.min(px(getComputedStyle(chip).borderTopLeftRadius), chipRect.height / 2) * 10) / 10,
        isPill:
          Math.abs(Math.min(px(getComputedStyle(chip).borderTopLeftRadius), chipRect.height / 2) - chipRect.height / 2) < 0.6,
        // The clamp may cut the visible text; the full string must remain
        // reachable somewhere on the element, not merely clipped.
        fullTitleRecoverable: titleAttr.length >= text.length && titleAttr.length > 0,
        tagName: titleEl.tagName,
        // An `<a>` with no href is not a link either, so this asks for a
        // destination rather than for a tag name.
        isLink: titleEl.tagName === "A" && !!titleEl.getAttribute("href"),
        hasTitleClass: titleEl.classList.contains("canvas-chip-title"),
        color: getComputedStyle(titleEl).color,
        errorColor,
        isErrorColour: getComputedStyle(titleEl).color === errorColor,
      }
    })
  })
}

function find(chips: ChipGeometry[], needle: string): ChipGeometry {
  const unresolved = chips.filter((c) => !c.titleResolved)
  if (unresolved.length) {
    throw new Error(
      `${unresolved.length} chip(s) had no resolvable title element. Measuring ` +
        `the chip against itself would make containment vacuously true, so this ` +
        `is reported instead.`,
    )
  }
  const hit = chips.find((c) => c.title.startsWith(needle.slice(0, 40)))
  if (!hit) {
    throw new Error(
      `fixture chip not found for "${needle.slice(0, 40)}…". Seeded chips: ` +
        JSON.stringify(chips.map((c) => c.title)),
    )
  }
  return hit
}

test.describe("linked-canvas chip geometry", () => {
  test.skip(!TASK_ID, "FIXTURE_TASK_ID not set — seed the fixture first")

  test("a wrapped canvas title stays inside its chip", async ({ browser }) => {
    const { context, page } = await open(browser, "chipgeom-a")

    try {
      const chips = await chipGeometry(page)
      console.log(`[measure] ${JSON.stringify(chips, null, 2)}`)

      // Guard the guard: an empty strip would let every assertion below
      // iterate nothing and pass green.
      expect(chips.length).toBeGreaterThanOrEqual(3)

      const long = find(chips, LONG_TITLE)

      // The fixture must actually wrap, or containment is trivially true and
      // this test proves nothing about the defect.
      expect(
        long.lineCount,
        `the long fixture rendered on ${long.lineCount} line(s); it must wrap for ` +
          `this assertion to mean anything`,
      ).toBeGreaterThan(1)

      // THE ACCEPTANCE BAR: no border crosses the text.
      expect(
        long.textTop,
        `title top ${long.textTop} is above chip top ${long.chipTop} — the chip's ` +
          `border is drawing through the text, which reads as a strikethrough`,
      ).toBeGreaterThanOrEqual(long.chipTop - CONTAINMENT_TOLERANCE_PX)
      expect(
        long.textBottom,
        `title bottom ${long.textBottom} is below chip bottom ${long.chipBottom} — ` +
          `the chip did not grow to fit its wrapped title`,
      ).toBeLessThanOrEqual(long.chipBottom + CONTAINMENT_TOLERANCE_PX)
    } finally {
      await context.close()
    }
  })

  test("a short canvas title still renders on one line", async ({ browser }) => {
    const { context, page } = await open(browser, "chipgeom-b")

    try {
      const chips = await chipGeometry(page)
      const short = find(chips, SHORT_TITLE)
      const long = find(chips, LONG_TITLE)
      console.log(`[measure] short=${short.chipHeight}px long=${long.chipHeight}px`)

      // The control. A fix that makes every chip tall passes the containment
      // test above and ruins a dense panel; this is the only thing that sees it.
      expect(short.lineCount, "the short fixture wrapped; it is not a valid control").toBe(1)
      expect(short.renderedLines).toBe(1)
      expect(
        short.chipHeight,
        `short chip is ${short.chipHeight}px but the wrapped chip is ` +
          `${long.chipHeight}px — chips grew unconditionally rather than to fit`,
      ).toBeLessThan(long.chipHeight)
      expect(short.textTop).toBeGreaterThanOrEqual(short.chipTop - CONTAINMENT_TOLERANCE_PX)
      expect(short.textBottom).toBeLessThanOrEqual(short.chipBottom + CONTAINMENT_TOLERANCE_PX)
    } finally {
      await context.close()
    }
  })

  test("a pathological title is clamped at two lines and stays recoverable", async ({
    browser,
  }) => {
    const { context, page } = await open(browser, "chipgeom-c")

    try {
      const chips = await chipGeometry(page)
      const huge = find(chips, PATHOLOGICAL_PREFIX)
      console.log(`[measure] pathological: ${JSON.stringify(huge)}`)

      expect(
        huge.renderedLines,
        `pathological title paints ${huge.renderedLines} lines; the two-line clamp ` +
          `is missing and one chip can take over the strip`,
      ).toBeLessThanOrEqual(2)
      // The clamp must be doing real work here, not merely coinciding with a
      // title that happened to fit. Without this, a build that silently
      // dropped the clamp AND the fixture would both read as "<= 2 lines".
      expect(
        huge.clipped,
        "nothing was clipped — the pathological fixture is not long enough to " +
          "exercise the clamp, so this case proves nothing",
      ).toBe(true)
      expect(huge.textTop).toBeGreaterThanOrEqual(huge.chipTop - CONTAINMENT_TOLERANCE_PX)
      expect(huge.textBottom).toBeLessThanOrEqual(huge.chipBottom + CONTAINMENT_TOLERANCE_PX)
      expect(
        huge.fullTitleRecoverable,
        "the clamped title is not recoverable from the element — it is visually " +
          "clipped with no accessible full text",
      ).toBe(true)
    } finally {
      await context.close()
    }
  })

  test("the corner is a pill at one line and a block at two", async ({ browser }) => {
    const { context, page } = await open(browser, "chipgeom-d")

    try {
      const chips = await chipGeometry(page)
      const short = find(chips, SHORT_TITLE)
      const long = find(chips, LONG_TITLE)
      console.log(
        `[measure] short h=${short.chipHeight} eff=${short.effectiveRadius} pill=${short.isPill} | ` +
          `long h=${long.chipHeight} eff=${long.effectiveRadius} pill=${long.isPill}`,
      )

      // Stage 2 ships NO border-radius rule: the split falls out of the CSS
      // corner-overlap clamp against the inherited --radius-selector. These
      // two assertions are the only thing protecting that, because there is
      // no rule in the stylesheet for a reviewer to notice.
      expect(
        short.isPill,
        `one-line chip is ${short.chipHeight}px with an effective radius of ` +
          `${short.effectiveRadius}px; it must clamp to half its height to read ` +
          `as a pill. Declaring --radius-field here is the edit that breaks this.`,
      ).toBe(true)

      expect(
        long.isPill,
        `two-line chip is ${long.chipHeight}px with an effective radius of ` +
          `${long.effectiveRadius}px; a pill radius on a two-line box is the ` +
          `lozenge the design direction cut.`,
      ).toBe(false)

      // Both states come from ONE declared value. If someone splits them with
      // a second rule, this is the assertion that says so.
      expect(short.declaredRadius).toBe(long.declaredRadius)
    } finally {
      await context.close()
    }
  })

  test("a soft-deleted chip stays unlinked, error-coloured, and contains a wrapped title", async ({
    browser,
  }) => {
    const { context, page } = await open(browser, "chipgeom-e")

    try {
      const chips = await chipGeometry(page)
      const deleted = find(chips, DELETED_PLACEHOLDER)
      const live = find(chips, LONG_TITLE)
      console.log(
        `[measure] deleted tag=${deleted.tagName} link=${deleted.isLink} ` +
          `colour=${deleted.color} error=${deleted.errorColor} | ` +
          `live tag=${live.tagName} link=${live.isLink} colour=${live.color}`,
      )

      // ── The two properties that make this branch a different thing ──
      //
      // Each is asserted against the LIVE chip as well. Asserting only the
      // deleted side would pass just as happily if someone collapsed the two
      // branches into one element, which is the realistic way these get lost.

      expect(
        deleted.isLink,
        `the soft-deleted chip is a link to ${deleted.tagName}; its target canvas ` +
          `no longer exists, so the chip is a detach affordance, not a destination`,
      ).toBe(false)
      expect(live.isLink, "the live chip stopped being a link — the control no longer discriminates").toBe(
        true,
      )

      expect(
        deleted.isErrorColour,
        `the soft-deleted chip renders ${deleted.color}, not the theme's error ` +
          `colour ${deleted.errorColor} — nothing marks the row as stale`,
      ).toBe(true)
      expect(
        live.isErrorColour,
        `the LIVE chip renders in the error colour too, so "is it error-coloured" ` +
          `no longer distinguishes a deleted row from a healthy one`,
      ).toBe(false)

      // ── Containment on this branch ──
      //
      // As rendered, this assertion is WEAK and is not load-bearing: the
      // placeholder is one short line, and a one-line chip is contained in the
      // broken build too. It is kept because it is free and because it fails
      // loudly if the placeholder ever grows.
      expect(deleted.lineCount, "the placeholder wrapped — re-read the comment above").toBe(1)
      expect(deleted.textTop).toBeGreaterThanOrEqual(deleted.chipTop - CONTAINMENT_TOLERANCE_PX)
      expect(deleted.textBottom).toBeLessThanOrEqual(deleted.chipBottom + CONTAINMENT_TOLERANCE_PX)

      // The load-bearing half. The server never sends a long title down this
      // branch (see DELETED_PLACEHOLDER), and the string it does send cannot be
      // made to wrap at any usable viewport, so there is no way to reach the
      // wrapped state through the data. The text is therefore replaced IN THE
      // RENDERED ELEMENT and re-measured.
      //
      // What that does and does not prove: the element, its classes and the
      // whole cascade are the real ones, so this is an honest test of the CSS
      // geometry on the deleted branch — the thing that was broken. It is NOT
      // a test of the server path, and it would not notice a change to how the
      // title is passed down. That gap is the placeholder itself, and it is a
      // product question (three stale rows are three identical chips), not a
      // geometry one.
      await page.evaluate(
        ({ text }) => {
          const el = document.querySelector('[data-role="linked-canvas-chip-deleted"]')
          if (!el) throw new Error("no soft-deleted chip in the strip to inject into")
          el.textContent = text
          el.setAttribute("title", text)
        },
        { text: INJECTED_LONG_TITLE },
      )

      const injected = find(await chipGeometry(page), INJECTED_LONG_TITLE)
      console.log(`[measure] injected: ${JSON.stringify(injected)}`)

      // Precondition, same as the live case: no wrap, nothing proved.
      expect(
        injected.lineCount,
        `the injected title rendered on ${injected.lineCount} line(s); it must wrap ` +
          `for the containment assertion below to mean anything`,
      ).toBeGreaterThan(1)

      // The class is what carries the clamp and the wrap rules. Dropping it
      // from this branch's class list is a one-token edit that leaves the live
      // branch perfectly green.
      //
      // This check is NOT what makes that mutation fail — the clamp geometry
      // below catches it on its own, which was verified by disabling this line
      // and re-running the mutation. It is kept only because it names the cause
      // directly instead of leaving a reader to infer it from a line count.
      expect(
        injected.hasTitleClass,
        "the soft-deleted title element does not carry .canvas-chip-title, so the " +
          "clamp and wrap rules never apply to it",
      ).toBe(true)

      // THE ACCEPTANCE BAR, on the branch the live case cannot reach.
      expect(
        injected.textTop,
        `title top ${injected.textTop} is above chip top ${injected.chipTop} — the ` +
          `border is drawing through the text of a deleted-canvas chip`,
      ).toBeGreaterThanOrEqual(injected.chipTop - CONTAINMENT_TOLERANCE_PX)
      expect(
        injected.textBottom,
        `title bottom ${injected.textBottom} is below chip bottom ${injected.chipBottom} — ` +
          `the deleted chip did not grow to fit its wrapped title`,
      ).toBeLessThanOrEqual(injected.chipBottom + CONTAINMENT_TOLERANCE_PX)

      // And the clamp holds here too, or one stale row can take the strip.
      // Paired with `clipped` for the same reason as the live pathological
      // case: "<= 2 lines" is also what a title that simply fit would report,
      // and the pair is what distinguishes a clamp doing work from a clamp
      // that is not there. This pair is the geometry that catches the class
      // being dropped from this branch — see INJECTED_LONG_TITLE.
      expect(
        injected.renderedLines,
        `the deleted chip paints ${injected.renderedLines} lines; the two-line clamp ` +
          `does not reach this branch`,
      ).toBeLessThanOrEqual(2)
      expect(
        injected.clipped,
        "nothing was clipped on the soft-deleted branch — the injected title is no " +
          "longer long enough to exercise the clamp, so this case has lost its teeth",
      ).toBe(true)

      // Still not a link, still error-coloured, after all that.
      expect(injected.isLink).toBe(false)
      expect(injected.isErrorColour).toBe(true)
    } finally {
      await context.close()
    }
  })
})
