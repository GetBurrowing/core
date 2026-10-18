/**
 * Chat message density — regression guards for task 019ffe5e.
 *
 * PR #733 reclaimed the blank strip every message reserved for a "+" that
 * only appears on hover: a grouped one-line row went from 66px to 31px at
 * 1440x900. Two things about that fix are easy to undo by accident, and
 * neither is visible in a unit test, because both are decided by the
 * stylesheet against a real layout:
 *
 *   1. THE HEIGHT COMES BACK. Reinflating rows is the tempting wrong move
 *      for any future "the messages feel cramped" complaint — hand back a
 *      little padding here, un-collapse an avatar there, and the 35px is
 *      quietly gone. So this asserts a CEILING near the measured value
 *      (34px against a measured 31px) rather than "smaller than it used to
 *      be". A test asserting only "< 66px" would sit green at 60px, which
 *      is the entire regression.
 *
 *   2. THE TOUCH PATH BREAKS. The collapse used to be scoped to
 *      `@media (hover: hover) and (pointer: fine)`, because on touch the
 *      always-visible "+" was the ONLY way to add a reaction.
 *
 * Each case carries its own opposite as a control. The desktop height test
 * measures the run-opening row too, and that one is expected to stay tall.
 * Without the pair, a stylesheet that failed to load at all would pass
 * whichever half happened to expect zero.
 *
 * UPDATED BY TASK 01a000c0 (stages 3-4). The mechanism behind (1) changed
 * completely and the subject of (2) no longer exists:
 *
 *   · The "+" moved out of the reaction row and into the header action row,
 *     which is revealed by OPACITY and costs no vertical space. The reaction
 *     row is now pills and nothing else, and a message with no reactions
 *     does not render one at all — so there is no empty box left to collapse
 *     on hover, and no `data-empty` attribute to read. "Fully collapsed" as
 *     a property is replaced by "not rendered", which is stronger.
 *
 *   · The `@media (hover: hover) and (pointer: fine)` collapse rule is gone,
 *     which means the guard in (2) is guarding nothing as written. Its
 *     replacement — that a coarse pointer still has SOME add-reaction path —
 *     is the double-tap actions sheet, and that is what it now asserts. Read
 *     the note on that test before touching it: the path was reported as a
 *     FAILED gate at stage 2 and does not reproduce as failing.
 */

import { test, expect, devices, Browser, BrowserContext, Page } from "@playwright/test"

const SPACE = "general"

/** Ceiling for a grouped one-line row. Measured 31px after #733; the 3px
 *  band absorbs font-rendering variance between machines and headless
 *  builds. Deliberately NOT a generous bound — see the header note. */
const GROUPED_ROW_MAX_PX = 34

/** The viewport the 31px measurement was taken at. */
const DESKTOP = { width: 1440, height: 900 }

/* ── Task 01a000c0 stage 5: the run's geometry, pinned on BOTH sides ──────
 *
 * The ceiling above says a continuation row may not get taller. It says
 * nothing about the opening row, and nothing about a continuation row that
 * collapses to nothing — a stylesheet that failed to load entirely sails
 * through it. These two constants pin the SHAPE of a run: an opener that
 * stays tall enough to carry an avatar and a header, and a continuation that
 * stays at the height #733 reclaimed it to.
 *
 * THE NUMBERS ARE MEASURED ON THIS BRANCH, NOT INHERITED. The ticket's prose
 * (b71c66e7's commit message) says 63px for an opener; against this
 * stylesheet an opener measures 67px.
 *
 * UPDATED BY TASK 01a000c0 (v2 plan, stage 1). 67px stopped being the right
 * number the moment `.message-action-row` became `position: absolute`
 * unconditionally (commit `1d009294`) instead of only on grouped rows — the
 * opener's action row now leaves the header's flex line the same way a
 * continuation row's always has, and the opener measures 63px, not 67px.
 *
 * The paragraph this replaced argued "do not correct 67 back to 63" because
 * the only known way to get 63px was `hidden` (`display: none`), which also
 * breaks keyboard focus — so a 63px opener used to mean add-reaction had
 * gone unreachable. That inference no longer holds: `position: absolute`
 * removes the row from flow WITHOUT `display: none`, so it stays focusable.
 * Verified by pressing Tab, not by reading this file, on the OPENER row
 * specifically (the committed guard for this walk targets a grouped row —
 * see below — so this needed its own check): Shift+Tab from the compose box
 * reaches "Add reaction" on an ungrouped row in 8 presses, same as a grouped
 * row, `.message-action-row` opacity reads `1` while it holds focus, and
 * Enter opens `#reaction-picker`. 63px is the correct figure for a row whose
 * action row is out of flow AND still in the tab order — which is what every
 * row now is, not a distinct pre-accessibility-fix state.
 *
 * TOLERANCE — why ±3px, and why symmetric:
 *
 *   · It is the band the existing ceiling already uses (34px against a
 *     measured 31px), chosen there to absorb font-rendering variance across
 *     machines and headless builds. Reusing it keeps one story about how
 *     much drift is noise rather than inventing a second.
 *   · It is far tighter than any real regression. Every way the reclaimed
 *     space comes back is worth much more than 3px: restoring the avatar's
 *     box is +36px, giving `.message-row-inner` back its opener padding is
 *     +12px, rendering an empty reaction row is +20px. There is no plausible
 *     "we handed a little back" that lands inside this band.
 *   · Symmetric, not a ceiling, on purpose. A one-sided bound is how the
 *     opener assertion would have been satisfied by a row that collapsed to
 *     zero, and how the continuation assertion is satisfied by a
 *     `display: none` row. Each row now has to land ON its number.
 *
 * It is deliberately NOT a percentage: 5% of 31px and 5% of 63px are
 * different licences to drift, and the noise being absorbed is the same
 * couple of pixels of glyph rounding in both cases.
 */
const OPENER_ROW_PX = 63
const GROUPED_ROW_PX = 31
const ROW_HEIGHT_TOL_PX = 3

/** Task 01a000c0 stage 2: the three widths the sponsor's regression was
 *  reported at ("at least in mobile") and the guard now runs at. Not
 *  emulated-touch widths — plain `browser.newContext({ viewport })` with no
 *  device descriptor, because stage 1 established this reproduces under
 *  `(hover: hover)` and `(pointer: fine)` both true. Narrowing the viewport
 *  is the whole mechanism; touch is not involved. */
const NARROW_WIDTHS = [320, 375, 414]

/** Shift+Tab presses from the compose box to the add-reaction control on a
 *  grouped continuation row. Stage 4 measured 8 and recorded that the same
 *  walk did not reach it at all in 60 presses beforehand. The ceiling is set
 *  a little above the measurement so a genuinely reachable control does not
 *  go red over one extra button landing in the row, while the "it is not in
 *  the tab order at all" regression — which is unbounded — still fails. */
const ADD_REACTION_MAX_TABS = 14

interface Peer {
  slug: string
  context: BrowserContext
  page: Page
}

async function login(
  browser: Browser,
  slug: string,
  mobile = false,
  viewport?: { width: number; height: number },
): Promise<Peer> {
  const context = await browser.newContext(
    viewport ? { viewport } : mobile ? { ...devices["iPhone 12"] } : { viewport: DESKTOP },
  )
  const page = await context.newPage()
  page.on("pageerror", (err) => console.log(`[${slug} pageerror] ${err.message}`))
  await page.goto(`/dev/login?as=${slug}`)
  await page.waitForURL("**/chat**", { timeout: 10_000 })
  await page.goto(`/chat/${SPACE}`)
  await expect(page.locator("#message-list")).toBeAttached({ timeout: 10_000 })
  // Same mount discipline as sidebar_scroll_stability.spec.ts: let the
  // ComposeInput hook finish mounting before any keystroke lands, or the
  // first sync eats the prefix.
  await expect(page.locator('#compose-form textarea[name="compose[text]"]')).toBeVisible()
  // Every assertion in this file is a pixel measurement, and a row measured
  // before the webfont swaps is measured with fallback metrics — on the first
  // cold load against a fresh dev DB that was observed as a 67px row reading
  // 115.5px (task 01a000c0 stage 5). Waiting on `document.fonts` removes the
  // variance at its source rather than absorbing it into a tolerance.
  await page.evaluate(() => document.fonts.ready)
  await page.waitForTimeout(750)
  return { slug, context, page }
}

async function compose(peer: Peer, body: string) {
  const textarea = peer.page.locator('#compose-form textarea[name="compose[text]"]')
  await expect(textarea).toBeVisible()
  for (let attempt = 0; attempt < 2; attempt++) {
    await textarea.fill("")
    await textarea.click()
    await textarea.pressSequentially(body, { delay: 3 })
    try {
      await expect(textarea).toHaveValue(body, { timeout: 3_000 })
      break
    } catch (err) {
      if (attempt === 1) throw err
    }
  }
  const sendBtn = peer.page.locator(".compose-pill-send")
  await expect(sendBtn).toBeEnabled({ timeout: 5_000 })
  await sendBtn.click()
  await expect(
    peer.page.locator("#message-list").getByText(body, { exact: false }).first(),
  ).toBeVisible({ timeout: 5_000 })
}

/**
 * Park the cursor in the top-left corner. Every rule under test is gated on
 * `.group:hover` or `.group:focus-within`, so a cursor left sitting over the
 * last-clicked send pill — or over a row — would re-expand the reaction row
 * and the measurement would be of the hovered state. This is the single
 * most likely way for these tests to go quietly wrong.
 */
async function unhover(page: Page) {
  await page.mouse.move(0, 0)
  await page.waitForTimeout(250) // 140ms opacity transition + settle
}

/** Same gesture the LongpressMenu hook listens for, driven the same way
 *  chat_reactions.spec.ts drives it: two real touchscreen taps at the
 *  bubble's centre. `locator.tap()` twice is not equivalent — it re-resolves
 *  and re-scrolls between taps, which can move the point out from under the
 *  second one and break the pair. */
async function doubleTap(page: Page, bubble: ReturnType<Page["locator"]>) {
  await bubble.scrollIntoViewIfNeeded()
  const box = await bubble.boundingBox()
  if (!box) throw new Error("bubble has no bounding box (still off-screen?)")
  const cx = box.x + box.width / 2
  const cy = box.y + box.height / 2
  await page.touchscreen.tap(cx, cy)
  await page.waitForTimeout(50)
  await page.touchscreen.tap(cx, cy)
}

interface RowGeometry {
  text: string
  grouped: boolean
  runEnd: boolean
  height: number
  /** -1 when no reaction row is rendered, which is the expected state for a
   *  message nobody has reacted to (task 01a000c0 stage 4). */
  reactionRowHeight: number
  reactionRowPresent: boolean
  addReactionInHeader: boolean
  /** Pills, i.e. actual reactions. Distinct from `reactionRowPresent`, which
   *  is about the BOX: whether an empty one is rendered is a separate
   *  property owned by the ceiling test above. */
  reactionPillCount: number
  bodyHeight: number
  /** The day-bucket separator is rendered INSIDE the stream item, so the
   *  first message of a day measures ~40px taller than the same message
   *  posted a minute later. Any test that pins an absolute row height has to
   *  confirm it did not measure one of those (task 01a000c0 stage 5). */
  hasDaySeparator: boolean
}

/** One line of `text-sm` body copy measures ~20px; 24px allows for
 *  font-rendering variance without admitting a second line. */
const ONE_LINE_BODY_MAX_PX = 24

/**
 * Read computed geometry for every row whose text carries `tag`, straight
 * off `getBoundingClientRect()` — the number a user's eye actually gets,
 * after every stylesheet, media query and hook has had its say.
 */
async function rowGeometry(page: Page, tag: string): Promise<RowGeometry[]> {
  return page.evaluate((tag) => {
    const rows = Array.from(
      document.querySelectorAll("#message-list > [data-message-id][data-participant-id]"),
    )
    return rows
      .filter((row) => (row.textContent ?? "").includes(tag))
      .map((row) => {
        const reactionRow = row.querySelector(".reaction-row")
        const body = row.querySelector(".chat-markdown")
        return {
          text: (row.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 60),
          grouped: row.classList.contains("message-row--grouped"),
          runEnd: row.classList.contains("message-row--run-end"),
          height: row.getBoundingClientRect().height,
          reactionRowHeight: reactionRow
            ? reactionRow.getBoundingClientRect().height
            : -1,
          reactionRowPresent: !!reactionRow,
          // The "+" lives in the header action row now. On a continuation
          // row that header is stripped to nothing but this — so finding it
          // here is what proves the strip did not take it with it.
          addReactionInHeader: !!row.querySelector(
            '.message-header .message-action-row [aria-label="Add reaction"]',
          ),
          // A wrapped row is legitimately taller than 34px, so the ceiling
          // only means anything if we confirm we measured a ONE-LINE row.
          reactionPillCount: row.querySelectorAll(".reaction-pill").length,
          bodyHeight: body ? body.getBoundingClientRect().height : -1,
          hasDaySeparator: !!row.querySelector(".js-date-separator"),
        }
      })
  }, tag)
}

/** Height of one element, straight off the box the user's eye gets. */
async function heightOf(locator: ReturnType<Page["locator"]>): Promise<number> {
  return locator.evaluate((el) => el.getBoundingClientRect().height)
}

/**
 * How many line boxes an element's text actually renders as. This is the
 * property task 01a000c0 stage 2's regression guard exists to protect —
 * see the block comment above `NARROW_WIDTHS` for why it is measured this
 * way and not by height or by class name.
 */
async function lineBoxCount(locator: ReturnType<Page["locator"]>): Promise<number> {
  return locator.evaluate((el) => {
    const range = document.createRange()
    range.selectNodeContents(el)
    return range.getClientRects().length
  })
}

/**
 * Post one message from a throwaway author so the DAY SEPARATOR lands on
 * that row instead of on the row a height assertion is about to measure,
 * and so the first tagged message opens a run rather than continuing one.
 * Returns the peer so the caller can close its context.
 */
async function warmUpDay(browser: Browser, slug: string): Promise<Peer> {
  const warm = await login(browser, slug)
  await compose(warm, `warmup ${Date.now().toString(36)}`)
  return warm
}

test.describe("chat message density", () => {
  test("a grouped one-line row stays at or below 34px at 1440x900", async ({ browser }) => {
    const tag = `dens-${Date.now().toString(36)}`
    const peer = await login(browser, `${tag}-a`)

    try {
      // Five consecutive one-line messages from ONE author: row 1 opens the
      // run, rows 2-5 are continuations. Short bodies so nothing wraps.
      for (let i = 0; i < 5; i++) {
        await compose(peer, `${tag} line ${i}`)
      }

      // applyGrouping runs off a MutationObserver; give the last batch a
      // frame to be classed before measuring.
      await peer.page.waitForTimeout(500)
      await unhover(peer.page)

      const rows = await rowGeometry(peer.page, tag)
      console.log(`[measure] ${JSON.stringify(rows, null, 2)}`)

      // Guard the guard: if the seed silently failed, the assertions below
      // would iterate an empty list and pass green.
      expect(rows.length).toBe(5)

      const grouped = rows.filter((r) => r.grouped)
      expect(grouped.length).toBe(4)

      // The run-opening row is expected to stay TALL (it carries the avatar
      // and header). Asserting that here is what proves the ceiling below is
      // measuring a real distinction and not a collapsed-everything list.
      const opener = rows.find((r) => !r.grouped)!
      expect(opener.height).toBeGreaterThan(GROUPED_ROW_MAX_PX)

      for (const row of grouped) {
        // Only a one-line row is in scope for the ceiling.
        expect(
          row.bodyHeight,
          `row body is ${row.bodyHeight}px — it wrapped, so the ceiling does ` +
            `not apply and this measurement is meaningless: ${row.text}`,
        ).toBeGreaterThan(0)
        expect(row.bodyHeight).toBeLessThanOrEqual(ONE_LINE_BODY_MAX_PX)
        // The reaction row is the reclaimed space. These messages have no
        // reactions, so since task 01a000c0 stage 4 there is no row at all —
        // asserted as absence rather than as `height: 0`, because absence is
        // what the markup now promises and a zero-height box would mean the
        // collapse rule had come back.
        expect(row.reactionRowPresent).toBe(false)
        expect(row.reactionRowHeight).toBe(-1)
        // …and the control it used to hold is still reachable, in its new
        // home. Without this the assertion above is satisfied by having
        // deleted add-reaction from continuation rows entirely, which is
        // exactly the regression stage 4 was fixing.
        expect(
          row.addReactionInHeader,
          `no add-reaction control in the action row of a grouped row: ${row.text}`,
        ).toBe(true)
        // The property this whole stage exists to protect.
        expect(
          row.height,
          `grouped one-line row is ${row.height}px, ceiling is ${GROUPED_ROW_MAX_PX}px ` +
            `(measured 31px after #733). Height came back.`,
        ).toBeLessThanOrEqual(GROUPED_ROW_MAX_PX)
        // Non-zero, or a display:none row would sail past the ceiling.
        expect(row.height).toBeGreaterThan(10)
      }
    } finally {
      await peer.context.close()
    }
  })

  // THE TOUCH PATH, REWRITTEN AROUND ITS NEW MECHANISM (task 01a000c0 stage 4).
  //
  // This case used to assert that `.reaction-row` keeps real height under a
  // coarse pointer, because the always-visible "+" inside it was the only
  // way to add a reaction on a phone. Stage 3 moved that "+" into the
  // hover/focus action row and stage 4 stopped rendering an empty reaction
  // row at all, so both halves of the old assertion are now false BY DESIGN
  // and its subject cannot be restored without undoing the ticket. What
  // survives is the question it was really asking — can a phone user still
  // get a reaction onto a message — so that is what it asks now, of the
  // mechanism that actually answers it: the double-tap actions sheet.
  //
  // ⚠️ READ THIS BEFORE "FIXING" A FAILURE HERE. Stage 2 of this task was an
  // explicit gate on exactly this path and reported GATE FAILS —
  // `#message-actions-sheet` never rendering after a double-tap under
  // iPhone 12 emulation, with every layer (hook registration, attachment,
  // server handler, sheet markup) verified correct. Stages 3 and 4 shipped
  // over that open gate.
  //
  // Stage 4 re-ran it and CANNOT REPRODUCE the failure. Against HEAD, before
  // any stage-4 edit, `chat_reactions.spec.ts` cases 4 and 5 — the two that
  // stage 2 called failing — both pass, and so does this one after the
  // rewrite. The difference that matters is most likely concurrency: this was
  // run `--workers=1`, and the note above the bottom-sheet case in
  // chat_reactions.spec.ts already records that mobile cases starve the
  // single dev-server worker under `--workers=4 --fully-parallel`, which
  // looks exactly like "the sheet never opens".
  //
  // So: the gate is GREEN under emulation, not waived. A human double-tapping
  // a real phone is still the only thing that can close the original
  // question, because emulation was never the thing in doubt.
  //
  // If this DOES go red, the two cheap fixes are both wrong and both were
  // ruled out by the plan: do not make the action row permanently visible on
  // a coarse pointer, and do not relax the assertions. Either one turns
  // "phone users cannot react at all" green.
  test("a coarse pointer can still reach a reaction", async ({ browser }) => {
    const tag = `touch-${Date.now().toString(36)}`
    const alice = await login(browser, `${tag}-a`)
    const bob = await login(browser, `${tag}-b`, true)

    try {
      // Assert the emulation before relying on it. Playwright's iPhone 12
      // descriptor (hasTouch + isMobile) is what flips Chromium's primary
      // pointer/hover types, and the collapse rule is gated on exactly
      // these media features — so this is a faithful test of the gate. If a
      // future Playwright stops emulating them, this fails loudly instead
      // of turning the rest of the test into a tautology.
      const media = await bob.page.evaluate(() => ({
        coarse: matchMedia("(hover: none) and (pointer: coarse)").matches,
        fine: matchMedia("(hover: hover) and (pointer: fine)").matches,
      }))
      console.log(`[media] touch context: ${JSON.stringify(media)}`)
      expect(
        media.coarse,
        "coarse-pointer emulation is not in effect; this test would assert nothing",
      ).toBe(true)
      expect(media.fine).toBe(false)

      // Alice (desktop) authors it. A PEER's message: reacting to your own
      // carries edit semantics on the same gesture.
      const body = `${tag} react to me`
      await compose(alice, body)

      const bobRow = bob.page
        .locator("#message-list > [data-message-id][data-participant-id]")
        .filter({ hasText: tag })
        .first()
      await expect(bobRow).toBeVisible({ timeout: 10_000 })
      await bobRow.scrollIntoViewIfNeeded()

      // The desktop reveal is hover/focus-driven, so on a coarse pointer the
      // action row is present in the DOM but never revealed. Asserting that
      // is what makes the sheet load-bearing rather than a second option.
      const opacity = await bobRow
        .locator(".message-action-row")
        .evaluate((el) => getComputedStyle(el).opacity)
      console.log(`[measure] touch action-row opacity: ${opacity}`)
      expect(
        opacity,
        "the hover action row is visible on a coarse pointer — if this is how " +
          "touch users reach add-reaction, it was not designed, it leaked",
      ).toBe("0")

      // So the sheet is the path, and this is the assertion stage 2 reported
      // as failing. It passes — see the note above the test.
      await doubleTap(bob.page, bobRow)
      const sheet = bob.page.locator("#message-actions-sheet")
      await expect(sheet).toBeVisible({ timeout: 5_000 })

      // One deliberate tap, no picker hop.
      await sheet
        .locator('#message-actions-quick-reactions button[phx-value-emoji="🎉"]')
        .tap()
      await expect(bobRow.locator('.reaction-pill[data-emoji="🎉"]')).toBeVisible({
        timeout: 5_000,
      })

      // Control: the same message on a fine pointer renders NO reaction row
      // until it has a reaction, which is what proves the pill above is a
      // real persisted reaction and not a box that was always there.
      const aliceRow = alice.page
        .locator("#message-list > [data-message-id][data-participant-id]")
        .filter({ hasText: tag })
        .first()
      await expect(aliceRow).toBeVisible({ timeout: 10_000 })
      await aliceRow.scrollIntoViewIfNeeded()
      await unhover(alice.page)
      await expect(aliceRow.locator('.reaction-pill[data-emoji="🎉"]')).toBeVisible({
        timeout: 5_000,
      })
    } finally {
      await alice.context.close()
      await bob.context.close()
    }
  })

  /* ═══ Task 01a000c0 stage 5 ═══════════════════════════════════════════
   *
   * WHAT WAS HERE BEFORE THIS STAGE: nothing. The ticket talks about
   * "#733's 31px grouped-row height guard" as if it were a test that had
   * been holding the line. It was not. #733 (7b3ae9f1) changed
   * `assets/test/hooks/scroll_to_bottom.test.js` and
   * `assets/test/scroll_to_bottom_unit_test.mjs`, and both of those assert
   * only WHICH rows get the `--grouped` class — the geometry was left
   * entirely to the stylesheet. The 63px and 31px figures live in a commit
   * message and nowhere else. Every automated height guard on this behaviour
   * is in this file, and all of it was written at stage 4 or later.
   *
   * NOT IN CI. `.github/workflows/ci.yml` runs `mix format --check-formatted`
   * and `mix test`; there is no Playwright step, so nothing below runs unless
   * a person runs it (see e2e/README.md). Treat a green CI as saying nothing
   * about any of it.
   */

  // GUARD 1 — HOVER MUST NOT RESIZE A MESSAGE.
  //
  // The bug this whole ticket exists to remove: putting the cursor on a
  // message grew the message, which pushed its own text and every row below
  // it down the list. The mechanism was an empty `.reaction-row` collapsed to
  // `height: 0` at rest and handed back `height: auto` under `.group:hover`.
  //
  // Asserting EQUALITY rather than a ceiling is the point. "Stays under
  // 40px hovered" would sit green through a 6px jump, and 6px of reflow under
  // the cursor is the complaint. Exact equality is safe to demand because
  // hover changes only `background-color` and `opacity` today; neither
  // reflows, so the two boxes are the same box.
  //
  // BOTH CASES MATTER AND THEY FAIL DIFFERENTLY. On a message with no
  // reactions there is no row to grow, and the regression is a row coming
  // back. On a message that HAS reactions the row is really there, and the
  // regression is a rule that re-collapses or re-expands it. A guard that
  // only checked the empty case would be green while every reacted message
  // in the list jumped.
  test("hovering a message row does not change its height", async ({ browser }) => {
    const tag = `hov-${Date.now().toString(36)}`
    const warm = await warmUpDay(browser, `${tag}-w`)
    const peer = await login(browser, `${tag}-a`)

    try {
      await compose(peer, `${tag} no reactions`)
      await peer.page.waitForTimeout(400)

      const row = peer.page
        .locator("#message-list > [data-message-id][data-participant-id]")
        .filter({ hasText: tag })
        .first()
      await expect(row).toBeVisible({ timeout: 10_000 })
      await row.scrollIntoViewIfNeeded()

      // The measurement is meaningless on a row carrying a day separator.
      const [geom] = await rowGeometry(peer.page, tag)
      console.log(`[measure] hover subject ${JSON.stringify(geom)}`)
      expect(geom.hasDaySeparator, "measured the first row of a day").toBe(false)
      // "No reactions" means no PILLS. Deliberately not asserting that the
      // reaction-row box is absent: that is stage 4's separate property and
      // the ceiling test above owns it. Asserting it here would abort this
      // case before its own equality ever ran, so the one guard that exists
      // to catch hover-driven reflow could never demonstrate catching it.
      expect(geom.reactionPillCount, "seed message already has reactions").toBe(0)
      // A row still settling — webfont not swapped, layout not final — is a
      // row whose two measurements agree for the wrong reason. Confirm the
      // subject is the ordinary one-line opener it is meant to be.
      expect(geom.bodyHeight).toBeGreaterThan(0)
      expect(geom.bodyHeight).toBeLessThanOrEqual(ONE_LINE_BODY_MAX_PX)
      expect(
        Math.abs(geom.height - OPENER_ROW_PX),
        `hover subject is ${geom.height}px, not the ${OPENER_ROW_PX}px opener ` +
          `this case means to measure — the page had not settled`,
      ).toBeLessThanOrEqual(ROW_HEIGHT_TOL_PX)

      // ── No reactions ───────────────────────────────────────────────
      await unhover(peer.page)
      const restEmpty = await heightOf(row)

      await row.hover()
      await peer.page.waitForTimeout(300)

      // ANTI-VACUITY. If the hover never landed, both measurements are of
      // the resting state and the equality below is a tautology that stays
      // green through any regression. The action row's opacity is the
      // cheapest proof that `.group:hover` actually matched.
      const hoveredOpacity = await row
        .locator(".message-action-row")
        .evaluate((el) => getComputedStyle(el).opacity)
      expect(
        hoveredOpacity,
        "hover did not take effect, so the equality below proves nothing",
      ).toBe("1")

      const hoverEmpty = await heightOf(row)
      console.log(
        `[measure] no reactions: rest ${restEmpty}px, hovered ${hoverEmpty}px`,
      )
      expect(restEmpty).toBeGreaterThan(10)
      expect(
        hoverEmpty,
        `hovering grew the row from ${restEmpty}px to ${hoverEmpty}px. This is ` +
          `the reflow-under-the-cursor bug the ticket removed.`,
      ).toBe(restEmpty)

      // ── Already has reactions ──────────────────────────────────────
      // Click from the hovered state: the action row is `pointer-events-none`
      // until `.group:hover`, so a cold click fails its hit test.
      await row.locator('button[phx-click="react"][phx-value-emoji="👍"]').first().click()
      await expect(row.locator('.reaction-pill[data-emoji="👍"]')).toBeVisible({
        timeout: 5_000,
      })

      await unhover(peer.page)
      const restReacted = await heightOf(row)

      // CONTROL. A reacted row must be genuinely TALLER than the same row was
      // without reactions — otherwise the reaction row is not rendering and
      // the equality below is measuring the empty case a second time.
      expect(
        restReacted,
        "the reacted row is not taller than the un-reacted one, so no reaction " +
          "row rendered and the hovered/unhovered pair below tests nothing",
      ).toBeGreaterThan(restEmpty)

      await row.hover()
      await peer.page.waitForTimeout(300)
      const hoverReacted = await heightOf(row)
      console.log(
        `[measure] with reactions: rest ${restReacted}px, hovered ${hoverReacted}px`,
      )
      expect(
        hoverReacted,
        `hovering a message that already has reactions grew it from ` +
          `${restReacted}px to ${hoverReacted}px.`,
      ).toBe(restReacted)
    } finally {
      await peer.context.close()
      await warm.context.close()
    }
  })

  // GUARD 2 — THE RUN'S GEOMETRY, PINNED ON BOTH SIDES.
  //
  // This is the guard the ticket believed already existed. It pins #733's
  // reclaim as a two-sided band around a measured value rather than as a
  // ceiling, so neither "the height came back" nor "the row disappeared"
  // can pass. See the constants at the top of this file for the tolerance
  // and why it is ±3px rather than a percentage.
  //
  // The opener is not decoration here. Measuring only the continuation row
  // cannot tell a working collapse from a stylesheet that never loaded; the
  // pair can, because a missing stylesheet moves BOTH numbers and no single
  // failure mode lands both inside their bands.
  test("a run holds its measured geometry: opening row and continuation row", async ({
    browser,
  }) => {
    const tag = `geom-${Date.now().toString(36)}`
    const warm = await warmUpDay(browser, `${tag}-w`)
    const peer = await login(browser, `${tag}-a`)

    try {
      for (let i = 0; i < 4; i++) {
        await compose(peer, `${tag} line ${i}`)
      }

      // applyGrouping runs off a MutationObserver.
      await peer.page.waitForTimeout(500)
      await unhover(peer.page)

      const rows = await rowGeometry(peer.page, tag)
      console.log(`[measure] run geometry ${JSON.stringify(rows, null, 2)}`)

      // Guard the guard: an empty list iterates zero assertions and passes.
      expect(rows.length).toBe(4)
      for (const row of rows) {
        expect(
          row.hasDaySeparator,
          `row carries a day separator, so its height is not comparable: ${row.text}`,
        ).toBe(false)
        expect(
          row.bodyHeight,
          `row body is ${row.bodyHeight}px — it wrapped, so these bands do not ` +
            `apply: ${row.text}`,
        ).toBeGreaterThan(0)
        expect(row.bodyHeight).toBeLessThanOrEqual(ONE_LINE_BODY_MAX_PX)
      }

      const opener = rows.find((r) => !r.grouped)
      expect(opener, "no run-opening row in the seed").toBeTruthy()
      const grouped = rows.filter((r) => r.grouped)
      expect(grouped.length).toBe(3)

      expect(
        Math.abs(opener!.height - OPENER_ROW_PX),
        `run-opening row is ${opener!.height}px; expected ` +
          `${OPENER_ROW_PX}±${ROW_HEIGHT_TOL_PX}px`,
      ).toBeLessThanOrEqual(ROW_HEIGHT_TOL_PX)

      for (const row of grouped) {
        expect(
          Math.abs(row.height - GROUPED_ROW_PX),
          `continuation row is ${row.height}px; expected ` +
            `${GROUPED_ROW_PX}±${ROW_HEIGHT_TOL_PX}px. Above the band, #733's ` +
            `reclaim has been given back; below it, the row has collapsed to ` +
            `nothing: ${row.text}`,
        ).toBeLessThanOrEqual(ROW_HEIGHT_TOL_PX)
      }

      // The distinction is real, not two numbers that happen to be close.
      expect(opener!.height).toBeGreaterThan(GROUPED_ROW_PX + ROW_HEIGHT_TOL_PX)
    } finally {
      await peer.context.close()
      await warm.context.close()
    }
  })

  // GUARD 3 — KEYBOARD REACH ON A CONTINUATION ROW.
  //
  // Stage 3 moved add-reaction into a row that used to be `hidden`, and
  // `hidden` is `display: none`: nothing inside it could take focus, so no
  // amount of Tab reached it. Stage 4 then found the same hole a second way,
  // because `.message-row--grouped .message-header` was `display: none` —
  // which put the control out of reach on the MAJORITY of rows in a real
  // conversation while a test on a run-opening row stayed green.
  //
  // So this walks to it on a GROUPED row, with the mouse parked away from the
  // list. Focus-within has to be what reveals the row; if the walk succeeds
  // only because the cursor is sitting on the message, this guard is testing
  // hover a second time and nothing is testing the keyboard.
  //
  // "Visible and clickable when focused" is checked as three separate things
  // because they fail separately: opacity (can it be seen), pointer-events
  // (would a click reach it), and hit-testing at its own centre (is something
  // else on top). Then it is actually activated, by keyboard, and the picker
  // has to open — the only check that proves the whole path works rather than
  // that the pixels look right.
  test("Tab reaches add-reaction on a grouped row, visible and clickable", async ({
    browser,
  }) => {
    const tag = `kbd-${Date.now().toString(36)}`
    const warm = await warmUpDay(browser, `${tag}-w`)
    const peer = await login(browser, `${tag}-a`)

    try {
      await compose(peer, `${tag} opens the run`)
      await compose(peer, `${tag} continues it`)
      await peer.page.waitForTimeout(500)
      await unhover(peer.page)

      const rows = await rowGeometry(peer.page, tag)
      expect(rows.length).toBe(2)
      expect(
        rows.filter((r) => r.grouped).length,
        "no continuation row in the seed, so this would test the easy case",
      ).toBe(1)

      const groupedRow = peer.page
        .locator("#message-list > .message-row--grouped[data-message-id]")
        .filter({ hasText: tag })
        .first()
      await expect(groupedRow).toBeAttached()
      await groupedRow.scrollIntoViewIfNeeded()

      // Park the cursor before touching the keyboard, and keep it parked.
      // Everything below has to be produced by focus alone.
      await unhover(peer.page)
      await expect(
        groupedRow.locator(".message-action-row"),
        "the action row is already revealed before any key is pressed",
      ).toHaveCSS("opacity", "0")

      await peer.page.locator('#compose-form textarea[name="compose[text]"]').focus()

      const addBtn = groupedRow.locator('[aria-label="Add reaction"]')
      let presses = 0
      let reached = false
      while (presses < 60 && !reached) {
        await peer.page.keyboard.press("Shift+Tab")
        presses++
        reached = await groupedRow.evaluate((row) => {
          const active = document.activeElement
          return (
            !!active &&
            row.contains(active) &&
            active.getAttribute("aria-label") === "Add reaction"
          )
        })
      }
      console.log(`[measure] add-reaction reached in ${presses} Shift+Tab presses`)
      expect(
        reached,
        "60 Shift+Tab presses back from the compose box never landed on " +
          "add-reaction inside a grouped row — it is not in the tab order",
      ).toBe(true)
      expect(
        presses,
        `add-reaction took ${presses} Shift+Tab presses; ceiling is ` +
          `${ADD_REACTION_MAX_TABS}`,
      ).toBeLessThanOrEqual(ADD_REACTION_MAX_TABS)

      // Visible — by focus, with the cursor still parked at the origin.
      await expect(groupedRow.locator(".message-action-row")).toHaveCSS("opacity", "1")
      await expect(addBtn).toBeVisible()

      // Clickable — a real click at its centre would reach IT, not the
      // message text underneath it. The action row floats over the body on a
      // continuation row, so "on top of the right thing" is a live question
      // here rather than a formality.
      const clickable = await addBtn.evaluate((el) => {
        const cs = getComputedStyle(el)
        const rowCs = getComputedStyle(el.closest(".message-action-row")!)
        const r = el.getBoundingClientRect()
        const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2)
        return {
          pointerEvents: cs.pointerEvents,
          rowPointerEvents: rowCs.pointerEvents,
          rowDisplay: rowCs.display,
          width: r.width,
          height: r.height,
          hitsSelf: !!hit && (el === hit || el.contains(hit)),
        }
      })
      console.log(`[measure] focused add-reaction: ${JSON.stringify(clickable)}`)
      expect(clickable.rowDisplay).not.toBe("none")
      expect(clickable.rowPointerEvents).not.toBe("none")
      expect(clickable.pointerEvents).not.toBe("none")
      expect(clickable.width).toBeGreaterThan(0)
      expect(clickable.height).toBeGreaterThan(0)
      expect(
        clickable.hitsSelf,
        "a click at the focused control's own centre would land on something " +
          "else — it is revealed but occluded",
      ).toBe(true)

      // …and it works. Activated from the keyboard, still unhovered.
      await peer.page.keyboard.press("Enter")
      await expect(peer.page.locator("#reaction-picker")).toBeVisible({
        timeout: 5_000,
      })
    } finally {
      await peer.context.close()
      await warm.context.close()
    }
  })

  /* ═══ Task 01a000c0 stage 2 ═══════════════════════════════════════════
   *
   * DURABLE FORM OF STAGE 1'S ADVERSARIAL CHECK. Stage 1 fixed a real bug:
   * `.message-action-row` was an ordinary in-flow flex child reserving its
   * full min-content width (324px for 7 buttons) on every render — so on a
   * run-opening (ungrouped) row at narrow widths, the flex-shrinkable
   * sender-name span got squeezed below its own content width and wrapped
   * onto a second line, unhovered, at rest. Reported by the sponsor as
   * "the username now splits across two lines... at least in mobile"; stage
   * 1 confirmed it is not actually touch/mobile-specific — it reproduces
   * under plain `(hover: hover)` + `(pointer: fine)`, purely from viewport
   * width — and fixed it by generalizing `.message-header { position:
   * relative }` / `.message-action-row { position: absolute; ... }` from
   * `.message-row--grouped`-only to every row, so the action row can never
   * again reserve header width.
   *
   * Stage 1's own verification of that fix was a one-off measurement at
   * 375x812. This is the same check, kept alive as a committed test at the
   * three widths the sponsor's report spans, so a future change to
   * `.message-header` / `.message-action-row` that reopens the gap between
   * "space available" and "space the action row reserves" gets caught
   * automatically instead of waiting for another bug report.
   *
   * LINE BOXES, NOT HEIGHT. `getBoundingClientRect().height` on the name
   * span would pass on a wrapped name if the line-height arithmetic happened
   * to land on a value under whatever ceiling the assertion used — that
   * would make the guard vacuous in exactly the case it exists for. Reading
   * `document.createRange().selectNodeContents(el)` then
   * `range.getClientRects().length` counts the actual rendered fragments of
   * the text, which is the one thing "did it wrap" can mean.
   *
   * EACH MESSAGE CARRIES BOTH SHAPES. The seed composes two consecutive
   * messages from one author: the first opens the run (ungrouped, has its
   * own header) and the second is a same-author continuation (grouped,
   * header stripped to just the action row). The assertion is only about
   * the ungrouped row's name — the grouped row's name span is not rendered
   * at all (`display: none`, task 01a000c0 stage 4) — but seeding both
   * confirms this stage's fix did not have to trade one shape for the
   * other, and mirrors how `#message-list` actually looks in a real
   * conversation rather than a single isolated row.
   *
   * NO CUSTOM PARTICIPANT NAME NEEDED. `/dev/login?as=<slug>` names every
   * dev user `Dev <Capitalized-slug>` (`auth_controller.ex`), which is
   * already a two-token name with a space between "Dev" and the rest —
   * exactly the shape the sponsor's report and stage 1's e2e_behavior case
   * both use ("Sam Moreno" / "any two-word name"). The bug is about
   * available width against reserved width, not about English word count,
   * so the ordinary login fixture reproduces it without a special seed.
   */
  for (const width of NARROW_WIDTHS) {
    test(`sender name on an ungrouped row is one line box at ${width}px, unhovered`, async ({
      browser,
    }) => {
      const tag = `wrap${width}-${Date.now().toString(36)}`
      // Deliberately NOT `${tag}-a`: the login slug becomes the sender name
      // (`Dev <Capitalized-slug>`), and `tag` alone is long enough (18-20
      // chars) to overflow 320px on its own content width, independent of
      // whether the action-row bug is present — that produced a false
      // failure at 320px (and only 320px) with the real fix applied, caught
      // by the anti-vacuity mutation step below reproducing on-topic but a
      // control run against the FIX also going red for the wrong reason.
      // A short slug keeps the fixture in the same length class as the
      // sponsor's report and stage 1's e2e_behavior case ("Sam Moreno",
      // 13 chars): width + 6 base36 chars of the timestamp, ~9-12 chars,
      // still unique per test run without being long enough to wrap on its
      // own. The message body keeps the full `tag` for row filtering below.
      const loginSlug = `${width}${Date.now().toString(36).slice(-6)}`
      const peer = await login(browser, loginSlug, false, { width, height: 812 })

      try {
        // First message opens the run (ungrouped); second is a same-author
        // continuation (grouped) — see the block comment above.
        await compose(peer, `${tag} opens the run`)
        await compose(peer, `${tag} continues it`)

        // applyGrouping runs off a MutationObserver; give the last batch a
        // frame to be classed before measuring.
        await peer.page.waitForTimeout(500)
        await unhover(peer.page)

        // Guard the guard: if the seed silently failed or grouping never
        // ran, the assertions below would measure the wrong row (or none)
        // and pass for the wrong reason.
        const rows = await rowGeometry(peer.page, tag)
        expect(rows.length, `expected 2 seeded rows, found ${rows.length}`).toBe(2)
        expect(
          rows.filter((r) => !r.grouped).length,
          "no ungrouped (run-opening) row in the seed",
        ).toBe(1)
        expect(
          rows.filter((r) => r.grouped).length,
          "no grouped (continuation) row in the seed",
        ).toBe(1)

        const openerRow = peer.page
          .locator("#message-list > [data-message-id][data-participant-id]")
          .filter({ hasText: tag })
          .filter({ hasNot: peer.page.locator(".message-row--grouped") })
          .first()
        await expect(openerRow).toBeVisible()

        // Confirmed unhovered: a hovered action row's `--color-base-100`
        // backing is a separate, already-flagged finding at 375px (task
        // 01a000c0 stage 1) and out of scope here — this asserts the resting
        // state only.
        const actionRowOpacity = await openerRow
          .locator(".message-action-row")
          .evaluate((el) => getComputedStyle(el).opacity)
        expect(
          actionRowOpacity,
          "the action row is already revealed — this would measure the hovered " +
            "state, which is explicitly out of scope for this guard",
        ).toBe("0")

        const nameSpan = openerRow.locator(".message-header > span").first()
        await expect(nameSpan).toBeVisible()
        const nameText = (await nameSpan.textContent())?.trim() ?? ""
        // Two tokens with a break opportunity between them, or the wrap
        // this test exists to catch has nowhere to happen.
        expect(
          nameText.includes(" "),
          `sender name "${nameText}" has no space — no break opportunity for ` +
            "the wrap this guard exists to catch",
        ).toBe(true)

        const lineBoxes = await lineBoxCount(nameSpan)
        console.log(
          `[measure] ${width}px sender name "${nameText}": ${lineBoxes} line box(es)`,
        )
        expect(
          lineBoxes,
          `sender name "${nameText}" rendered as ${lineBoxes} line boxes at ` +
            `${width}px, unhovered — the header action row is reserving width ` +
            "against it again",
        ).toBe(1)
      } finally {
        await peer.context.close()
      }
    })
  }
})
