/**
 * Sidebar-collapse scroll stability (task 019f51d1).
 *
 * Collapsing the desktop rail animates a 168px width change; the chat pane
 * reflows, text rewraps, and — before the fix — the browser clamped or
 * re-anchored scrollTop, silently discarding the user's reading position
 * (observed in prod as a snap to bottom). The ScrollToBottom hook now holds
 * the user's distance-from-bottom constant through the width transition.
 *
 * These tests measure scroll geometry around the toggle rather than
 * eyeballing it:
 *
 *   1. Mid-history: distance-from-bottom survives collapse AND expand.
 *   2. At-bottom: the pane stays pinned to the bottom through a toggle.
 *
 * Each run logs in with a unique slug and seeds its own long messages into
 * #general so the scroller genuinely overflows regardless of dev-DB state.
 * Long wrapped bodies are deliberate — width-dependent line wrapping is
 * exactly what makes the reflow move content.
 */

import { test, expect, Browser, BrowserContext, Page } from "@playwright/test"

const SPACE = "general"

interface Peer {
  slug: string
  context: BrowserContext
  page: Page
}

async function login(browser: Browser, slug: string): Promise<Peer> {
  const context = await browser.newContext()
  const page = await context.newPage()
  page.on("pageerror", (err) => console.log(`[${slug} pageerror] ${err.message}`))
  await page.goto(`/dev/login?as=${slug}`)
  await page.waitForURL("**/chat**", { timeout: 10_000 })
  await page.goto(`/chat/${SPACE}`)
  await expect(page.locator("#message-list")).toBeAttached({ timeout: 10_000 })
  // Let the ComposeInput hook finish mounting + draft restore before any
  // typing starts — keystrokes that land during the mount window get
  // clobbered by the hook's first sync (observed as an eaten prefix).
  await expect(page.locator('#compose-form textarea[name="compose[text]"]')).toBeVisible()
  await page.waitForTimeout(750)
  return { slug, context, page }
}

async function compose(peer: Peer, body: string) {
  // Same submit discipline as chat_reactions.spec.ts: pressSequentially so
  // phx-change syncs before phx-submit, then click the send pill. Clear
  // first and retry once — the ComposeInput hook can clobber early
  // keystrokes if a LV patch lands mid-typing.
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
    peer.page.locator("#message-list").getByText(body.slice(0, 40), { exact: false }).first(),
  ).toBeVisible({ timeout: 5_000 })
}

interface ScrollMetrics {
  top: number
  height: number
  client: number
  fromBottom: number
}

async function scrollMetrics(page: Page): Promise<ScrollMetrics> {
  return page.evaluate(() => {
    const el = document.getElementById("chat-message-scroller")!
    return {
      top: el.scrollTop,
      height: el.scrollHeight,
      client: el.clientHeight,
      fromBottom: el.scrollHeight - el.scrollTop - el.clientHeight,
    }
  })
}

async function seedOverflow(peer: Peer, runTag: string) {
  const filler =
    "the quick brown fox jumps over the lazy dog and keeps going until the line wraps at least twice on a desktop viewport "
  for (let i = 0; i < 14; i++) {
    await compose(peer, `[${runTag} seed ${i}] ${filler}${filler}`)
  }
  // Ensure the pane actually overflows enough for a meaningful mid-history
  // offset — otherwise the assertions below are vacuous.
  const m = await scrollMetrics(peer.page)
  expect(m.height - m.client).toBeGreaterThan(1200)
}

// The toggle button is desktop-only (`hidden lg:flex`); Playwright's default
// 1280×720 viewport is above the lg breakpoint so it is interactable.
const TOGGLE = '[phx-click="toggle_sidebar"]'

// 200ms width transition + 400ms hold window in scroll_to_bottom.js, plus
// settle margin.
const SETTLE_MS = 700

test("mid-history reading position survives collapse and expand", async ({ browser }) => {
  const runTag = `scrollfix-${Date.now().toString(36)}`
  const peer = await login(browser, `${runTag}-reader`)
  await seedOverflow(peer, runTag)

  // Scroll up into history well past the 150px near-bottom threshold.
  await peer.page.evaluate(() => {
    const el = document.getElementById("chat-message-scroller")!
    el.scrollTop = el.scrollTop - 700
  })
  await peer.page.waitForTimeout(300)

  const before = await scrollMetrics(peer.page)
  expect(before.fromBottom).toBeGreaterThan(500)

  // Collapse.
  await peer.page.locator(TOGGLE).click()
  await peer.page.waitForTimeout(SETTLE_MS)
  const afterCollapse = await scrollMetrics(peer.page)
  console.log(
    `[measure] before: fromBottom=${before.fromBottom} scrollTop=${before.top} | ` +
      `after collapse: fromBottom=${afterCollapse.fromBottom} scrollTop=${afterCollapse.top}`,
  )
  expect(Math.abs(afterCollapse.fromBottom - before.fromBottom)).toBeLessThanOrEqual(2)

  // Expand back.
  await peer.page.locator(TOGGLE).click()
  await peer.page.waitForTimeout(SETTLE_MS)
  const afterExpand = await scrollMetrics(peer.page)
  console.log(
    `[measure] after expand: fromBottom=${afterExpand.fromBottom} scrollTop=${afterExpand.top}`,
  )
  expect(Math.abs(afterExpand.fromBottom - before.fromBottom)).toBeLessThanOrEqual(2)

  await peer.context.close()
})

test("at-bottom stays pinned to bottom through a toggle", async ({ browser }) => {
  const runTag = `scrollpin-${Date.now().toString(36)}`
  const peer = await login(browser, `${runTag}-reader`)
  await seedOverflow(peer, runTag)

  await peer.page.evaluate(() => {
    const el = document.getElementById("chat-message-scroller")!
    el.scrollTop = el.scrollHeight
  })
  await peer.page.waitForTimeout(300)

  const before = await scrollMetrics(peer.page)
  expect(before.fromBottom).toBeLessThanOrEqual(2)

  await peer.page.locator(TOGGLE).click()
  await peer.page.waitForTimeout(SETTLE_MS)
  const after = await scrollMetrics(peer.page)
  console.log(
    `[measure] at-bottom: before fromBottom=${before.fromBottom} | after fromBottom=${after.fromBottom}`,
  )
  expect(after.fromBottom).toBeLessThanOrEqual(2)

  await peer.context.close()
})
