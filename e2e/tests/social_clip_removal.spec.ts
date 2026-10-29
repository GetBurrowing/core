/** Destructive, real LiveView review flow. Seed clip_review_removal_fixture.exs
 * in a private database and set CLIP_REMOVAL_FIXTURE to its local JSON receipt.
 * Each run needs a fresh fixture; retries are deliberately disabled. */
import { test, expect, chromium } from "@playwright/test"
import { readFileSync } from "node:fs"

const fixturePath = process.env.CLIP_REMOVAL_FIXTURE
const fixture = fixturePath ? JSON.parse(readFileSync(fixturePath, "utf8")) : null

test.describe("Clip removal", () => {
  test.skip(!fixture, "Seed a fresh isolated removal fixture and set CLIP_REMOVAL_FIXTURE")
  test.describe.configure({ retries: 0 })

  test("guards references and jobs, confirms exact versions, and reloads selection and Library", async ({}, info) => {
    const browser = await chromium.connectOverCDP(process.env.CLIP_REVIEW_CDP ?? "http://127.0.0.1:9222")
    const context = await browser.newContext()
    await context.addCookies([{ name: "_platform_session", value: fixture.cookie, url: fixture.base_url }])
    const page = await context.newPage()
    try {
      await page.setViewportSize({ width: 1280, height: 650 })
      expect((await page.request.get(`${fixture.base_url}/assets/js/app.js`)).status()).toBe(200)
      await page.goto(`${fixture.base_url}/m/social?tab=clips&view=review`)
      await page.waitForFunction(() => (window as any).liveSocket?.isConnected())
      await expect(page.locator('[data-role="clips-queue-item"]')).toHaveCount(35)
      const pick = async (n: number) => {
        await page.locator(`[data-role="clips-queue-item"][data-clip-id="${fixture.clip_ids[n]}"]`).click()
        await expect(page.locator('[data-role="clips-bay"]')).toHaveAttribute("data-clip-id", fixture.clip_ids[n])
        await page.locator('[data-role="clip-manage-menu"] summary').click()
      }
      await pick(1)
      await expect(page.locator('[data-role="clip-delete"]')).toBeDisabled()
      await expect(page.locator('[data-role="clip-delete-guard"]')).toContainText("In use by a post")
      await page.screenshot({ path: info.outputPath("protected-desktop.jpg") })
      await pick(2)
      await expect(page.locator('[data-role="clip-delete"]')).toBeDisabled()
      await expect(page.locator('[data-role="clip-delete-guard"]')).toHaveText("Rendering — wait or cancel")

      await pick(0)
      await expect(page.locator('[data-role="clip-render-row"]')).toHaveCount(2)
      const current = page.locator('[data-role="clip-render-row"]').filter({ hasText: "v2 · Current" })
      await current.locator('[data-role="render-delete"]').click()
      await expect(page.locator('[data-role="clip-delete-dialog"]')).toContainText("v2?")
      await expect(page.locator('[data-role="clip-delete-dialog"]')).toContainText("Media files remain under Files retention")
      await page.keyboard.press("j")
      await expect(page.locator('[data-role="clips-bay"]')).toHaveAttribute("data-clip-id", fixture.clip_ids[0])
      await page.screenshot({ path: info.outputPath("confirm-desktop.jpg") })
      await page.keyboard.press("Escape")
      await expect(page.locator('[data-role="clip-delete-dialog"]')).toHaveCount(0)
      await expect(page.locator('[data-role="clip-render-row"]')).toHaveCount(2)
      await current.locator('[data-role="render-delete"]').click()
      await page.locator('[data-role="clip-delete-confirm"]').click()
      await expect(page.locator('[data-role="clip-render-row"]')).toHaveCount(1)
      await expect(page.locator('[data-role="clip-render-row"]')).toContainText("v1 · Current")
      const video = page.locator('[data-role="clip-player"] video')
      await expect(video).toHaveAttribute("src", /\/files\/blob\//)
      expect((await page.request.get(new URL(await video.getAttribute("src") as string, fixture.base_url).href)).status()).toBe(200)
      const footer = await page.locator('[data-role="clips-decide"]').boundingBox()
      expect(footer!.y + footer!.height).toBeLessThanOrEqual(650)

      // Remove only an old version of another clip; current v2 must stay.
      await pick(3)
      const old = page.locator('[data-role="clip-render-row"]').filter({ hasText: "v1" })
      await old.locator('[data-role="render-delete"]').click()
      await page.locator('[data-role="clip-delete-confirm"]').click()
      await expect(page.locator('[data-role="clip-render-row"]')).toHaveCount(1)
      await expect(page.locator('[data-role="clip-render-row"]')).toContainText("v2 · Current")

      // The final playable version removes the clip and selects the next row.
      await pick(0)
      await page.locator('[data-role="render-delete"]').click()
      await page.locator('[data-role="clip-delete-confirm"]').click()
      await expect(page.locator('[data-role="clips-queue-item"]')).toHaveCount(34)
      await expect(page.locator('[data-role="clips-bay"]')).toHaveAttribute("data-clip-id", fixture.clip_ids[1])
      await expect(page.locator(`[data-role="clips-queue-item"][data-clip-id="${fixture.clip_ids[1]}"]`)).toBeFocused()

      await page.locator('[phx-click="set_view"][phx-value-view="library"]').click()
      await expect(page.locator('[data-role="library-clip"]')).toHaveCount(34)
      const libraryClip = page.locator(`#library-clip-${fixture.clip_ids[4]}`)
      await libraryClip.locator('summary').click()
      await libraryClip.locator('[data-role="clip-delete"]').click()
      await page.locator('[data-role="clip-delete-confirm"]').click()
      await expect(page.locator('[data-role="library-clip"]')).toHaveCount(33)
      await expect(page.locator(`#library-clip-${fixture.clip_ids[0]}`)).toHaveCount(0)
      await page.screenshot({ path: info.outputPath("library-desktop.jpg") })

      await page.goto(`${fixture.base_url}/m/social?tab=clips&view=review`)
      await page.setViewportSize({ width: 390, height: 844 })
      await expect(page.locator('[data-role="clips-pbar"]')).toBeVisible()
      await expect(page.locator('[data-role="clip-removal"]')).toBeHidden()
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
      await page.screenshot({ path: info.outputPath("phone-unchanged.jpg") })
    } finally {
      await context.close()
      await browser.close()
    }
  })
})
