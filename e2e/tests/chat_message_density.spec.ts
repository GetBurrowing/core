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
 *   2. THE TOUCH PATH BREAKS. The collapse is deliberately scoped to
 *      `@media (hover: hover) and (pointer: fine)`, because on touch the
 *      always-visible "+" is the ONLY way to add a reaction — the
 *      double-tap sheet offers Reply/Pin/Edit and nothing else. Widening
 *      that media query, or dropping it while "simplifying" the rule,
 *      leaves phone users with no way to react at all and looks like a
 *      tidy-up in review. So this asserts the row still has real height
 *      under coarse-pointer emulation.
 *
 * Each case carries its own opposite as a control. The desktop height test
 * measures the run-opening row too, and that one is expected to stay tall;
 * the touch test asserts the same message collapses on a desktop context in
 * the same run. Without the pair, a stylesheet that failed to load at all
 * would pass whichever half happened to expect zero.
 */

import { test, expect, devices, Browser, BrowserContext, Page } from "@playwright/test"

const SPACE = "general"

/** Ceiling for a grouped one-line row. Measured 31px after #733; the 3px
 *  band absorbs font-rendering variance between machines and headless
 *  builds. Deliberately NOT a generous bound — see the header note. */
const GROUPED_ROW_MAX_PX = 34

/** The viewport the 31px measurement was taken at. */
const DESKTOP = { width: 1440, height: 900 }

interface Peer {
  slug: string
  context: BrowserContext
  page: Page
}

async function login(browser: Browser, slug: string, mobile = false): Promise<Peer> {
  const context = await browser.newContext(
    mobile ? { ...devices["iPhone 12"] } : { viewport: DESKTOP },
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

interface RowGeometry {
  text: string
  grouped: boolean
  runEnd: boolean
  height: number
  reactionRowHeight: number
  reactionRowEmpty: string | null
  bodyHeight: number
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
          reactionRowEmpty: reactionRow ? reactionRow.getAttribute("data-empty") : null,
          // A wrapped row is legitimately taller than 34px, so the ceiling
          // only means anything if we confirm we measured a ONE-LINE row.
          bodyHeight: body ? body.getBoundingClientRect().height : -1,
        }
      })
  }, tag)
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
        // The reaction row is the reclaimed space. Unhovered on a fine
        // pointer it must be fully collapsed.
        expect(row.reactionRowEmpty).toBe("true")
        expect(row.reactionRowHeight).toBe(0)
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

  test("the reaction row keeps its height under a coarse pointer", async ({ browser }) => {
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

      // Alice (desktop) authors it. A message with NO reactions is the case
      // that collapses, and it must not collapse for bob.
      const body = `${tag} react to me`
      await compose(alice, body)

      const bobRow = bob.page
        .locator("#message-list > [data-message-id][data-participant-id]")
        .filter({ hasText: tag })
        .first()
      await expect(bobRow).toBeVisible({ timeout: 10_000 })
      await bobRow.scrollIntoViewIfNeeded()

      const bobReactionRow = bobRow.locator(".reaction-row")
      await expect(bobReactionRow).toHaveAttribute("data-empty", "true")

      const bobBox = await bobReactionRow.boundingBox()
      console.log(`[measure] touch reaction row: ${JSON.stringify(bobBox)}`)
      expect(bobBox).not.toBeNull()
      // The whole point: on touch this row still occupies space, because
      // the "+" inside it is the only add-reaction affordance there is.
      expect(
        bobBox!.height,
        "reaction row collapsed on a coarse pointer — touch users cannot react",
      ).toBeGreaterThan(0)

      // And the "+" itself is actually reachable, not merely boxed.
      const addBtn = bobRow.locator(".reaction-add-btn")
      await expect(addBtn).toBeVisible()
      const addBox = await addBtn.boundingBox()
      expect(addBox).not.toBeNull()
      expect(addBox!.height).toBeGreaterThanOrEqual(32) // coarse-pointer min-height
      expect(await addBtn.evaluate((el) => getComputedStyle(el).opacity)).toBe("1")

      // Control: the SAME message on a fine pointer, unhovered, is
      // collapsed. This is what makes the assertions above a statement
      // about the media query rather than about the stylesheet existing.
      const aliceRow = alice.page
        .locator("#message-list > [data-message-id][data-participant-id]")
        .filter({ hasText: tag })
        .first()
      await expect(aliceRow).toBeVisible({ timeout: 10_000 })
      await aliceRow.scrollIntoViewIfNeeded()
      await unhover(alice.page)
      const desktopHeight = await aliceRow
        .locator(".reaction-row")
        .evaluate((el) => el.getBoundingClientRect().height)
      console.log(`[measure] desktop reaction row: ${desktopHeight}`)
      expect(
        desktopHeight,
        "desktop reaction row is not collapsed; the touch assertion proves nothing",
      ).toBe(0)
    } finally {
      await alice.context.close()
      await bob.context.close()
    }
  })
})
