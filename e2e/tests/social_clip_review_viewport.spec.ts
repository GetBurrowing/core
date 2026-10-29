/** Real box geometry, not class assertions. Seed 35 clips + 12 episode
 * outcomes using apps/social/priv/scripts/clip_review_viewport_fixture.exs.
 * CLIP_REVIEW_FIXTURE is its local JSON output. Browser-rig CDP defaults to
 * loopback 9222; each test owns a new context and never touches shared tabs.
 */
import { test, expect, chromium, Browser, BrowserContext, Page } from "@playwright/test"
import { readFileSync } from "node:fs"

const fixturePath = process.env.CLIP_REVIEW_FIXTURE
const fixture = fixturePath ? JSON.parse(readFileSync(fixturePath, "utf8")) : null
let browser: Browser
let context: BrowserContext
let page: Page

test.describe("Clip Review viewport", () => {
  test.skip(!fixture, "Seed the isolated Social fixture and set CLIP_REVIEW_FIXTURE")
  test.describe.configure({ retries: 0 })

  test.beforeAll(async () => {
    browser = await chromium.connectOverCDP(process.env.CLIP_REVIEW_CDP ?? "http://127.0.0.1:9222")
  })
  test.afterAll(async () => { await browser?.close() })
  test.beforeEach(async () => {
    context = await browser.newContext()
    await context.addCookies([{ name: "_platform_session", value: fixture.cookie,
      url: fixture.base_url }])
    page = await context.newPage()
  })
  test.afterEach(async () => { await context?.close() })

  async function open(width: number, height: number) {
    await page.setViewportSize({ width, height })
    expect((await page.request.get(`${fixture.base_url}/assets/js/app.js`)).status()).toBe(200)
    await page.goto(`${fixture.base_url}/m/social?tab=clips&view=review`)
    await expect(page.locator('[data-role="clips-queue-item"]')).toHaveCount(35)
    await expect(page.locator('[data-role="episode-job"]')).toHaveCount(12)
    await page.waitForFunction(() => (window as any).liveSocket?.isConnected())
    // An observed LiveView round trip proves the fixture can interact.
    await page.locator('[data-role="clips-next"]').click({ force: width <= 760 })
    await expect(page.locator('[data-role="clips-position"]')).toHaveText("2 of 35")
  }

  for (const viewport of [{ width: 1440, height: 900 }, { width: 1280, height: 650 }]) {
    test(`video and decisions stay visible at ${viewport.width}x${viewport.height}`, async ({}, info) => {
      await open(viewport.width, viewport.height)
      const measure = () => page.evaluate(() => {
        const box = (role: string) => {
          const el = document.querySelector<HTMLElement>(`[data-role="${role}"]`)!
          const rect = el.getBoundingClientRect()
          return { top: rect.top, bottom: rect.bottom, width: rect.width, height: rect.height,
            client: el.clientHeight, scroll: el.scrollHeight, scrollTop: el.scrollTop }
        }
        return { height: innerHeight, bay: box("clips-bay"), queue: box("clips-queue"),
          body: box("clips-details-body"), footer: box("clips-decide"),
          player: box("clip-frame"), scrub: box("clip-scrub"), episodes: box("episode-jobs") }
      })
      await expect.poll(async () => (await measure()).bay.bottom).toBeLessThanOrEqual(viewport.height)
      const before = await measure()
      expect(before.queue.scroll).toBeGreaterThan(before.queue.client + 100)
      expect(before.body.scroll).toBeGreaterThan(before.body.client + 100)
      expect(before.episodes.scroll).toBeGreaterThan(before.episodes.client)
      expect(before.footer.top).toBeGreaterThan(before.bay.top)
      expect(before.footer.bottom).toBeLessThanOrEqual(before.height)
      expect(before.player.height).toBeGreaterThan(90)
      expect(before.player.width / before.player.height).toBeCloseTo(9 / 16, 2)
      expect(before.player.top).toBeGreaterThanOrEqual(before.bay.top)
      expect(before.player.bottom).toBeLessThanOrEqual(before.height)
      expect(before.scrub.bottom).toBeLessThanOrEqual(before.height)
      await page.evaluate(() => {
        for (const role of ["clips-queue", "clips-details-body", "episode-jobs"]) {
          const el = document.querySelector<HTMLElement>(`[data-role="${role}"]`)!
          el.scrollTop = el.scrollHeight
        }
      })
      const after = await measure()
      expect(after.body.scrollTop).toBeGreaterThan(0)
      expect(after.queue.scrollTop).toBeGreaterThan(0)
      expect(after.footer.bottom).toBeCloseTo(before.footer.bottom, 0)
      expect(after.player.top).toBeCloseTo(before.player.top, 0)
      // Note input remains reachable in the scrolling body, and its event
      // enables the pinned rejection control without changing the clip.
      await page.locator('[data-role="clip-note"]').fill("Try another cut")
      await expect(page.locator('[data-role="clip-reject"]')).toBeEnabled()
      await page.locator('[data-role="clip-note"]').press("j")
      await expect(page.locator('[data-role="clips-position"]')).toHaveText("2 of 35")
      await page.screenshot({ path: info.outputPath(`desktop-${viewport.width}.jpg`) })
      // Resize the same mounted bay: no reload to mask a missing listener.
      await page.setViewportSize({ width: viewport.width, height: 600 })
      await expect.poll(async () => (await measure()).bay.bottom).toBeLessThanOrEqual(600)
      expect((await measure()).footer.bottom).toBeLessThanOrEqual(600)
    })
  }

  test("phone keeps its decision bar, flow and keyboard navigation", async ({}, info) => {
    await page.setViewportSize({ width: 390, height: 844 })
    await page.goto(`${fixture.base_url}/m/social?tab=clips&view=review`)
    await page.waitForFunction(() => (window as any).liveSocket?.isConnected())
    await expect(page.locator('[data-role="clips-pbar"]')).toBeVisible()
    await expect(page.locator('[data-role="clips-decide"]')).toBeHidden()
    await expect(page.locator('[data-role="clips-queue"]')).toBeHidden()
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    const bar = await page.locator('[data-role="clips-pbar"]').boundingBox()
    expect(bar!.y + bar!.height).toBeLessThanOrEqual(844)
    await page.locator('[data-role="clip-note"]').fill("Phone review note")
    await expect(page.locator('[data-role="clips-pbar-reject"]')).toBeEnabled()
    await page.locator('[data-role="clip-note"]').press("j")
    await expect(page.locator('[data-role="clips-position"]')).toHaveText("1 of 35")
    await page.locator('[data-role="clip-note"]').blur()
    await page.keyboard.press("j")
    await expect(page.locator('[data-role="clips-position"]')).toHaveText("2 of 35")
    await page.screenshot({ path: info.outputPath("phone-390.jpg") })
  })
})
