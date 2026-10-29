/** Real LiveView appearance flow with deterministic real-CLI rendered fixture
 * videos. Seed clip_review_caption_fixture.exs on a private test database.
 * File commands are fixture-only, never an application endpoint. */
import { test, expect, chromium } from "@playwright/test"
import { readFileSync, writeFileSync, existsSync, unlinkSync } from "node:fs"

const path = process.env.CLIP_CAPTION_FIXTURE
const fixture = path ? JSON.parse(readFileSync(path, "utf8")) : null

test("caption styles enqueue exact look, retain playback, complete and fail safely on desktop and phone", async ({}, info) => {
  test.skip(!fixture, "Seed private caption fixture and set CLIP_CAPTION_FIXTURE")
  test.setTimeout(120_000)
  const browser = await chromium.connectOverCDP(process.env.CLIP_REVIEW_CDP ?? "http://127.0.0.1:9222")
  const context = await browser.newContext()
  await context.addCookies([{ name: "_platform_session", value: fixture.cookie, url: fixture.base_url }])
  const page = await context.newPage()
  try {
    await page.setViewportSize({ width: 1280, height: 650 })
    await page.goto(`${fixture.base_url}/m/social?tab=clips&view=review`)
    await page.waitForFunction(() => (window as any).liveSocket?.isConnected())
    await expect(page.locator('[data-role="caption-style"]')).toHaveCount(3)
    const video = page.locator('[data-role="clip-player"] video')
    const before = await video.getAttribute("src")
    await page.locator('[data-role="caption-style"][data-style="plain"]').click()
    await expect(page.locator('[data-role="caption-dirty"]')).toBeVisible()
    await expect(page.locator('[data-role="clip-approve"]')).toBeDisabled()
    await page.screenshot({ path: info.outputPath("caption-draft-desktop.jpg") })
    await page.locator('[data-role="caption-render"]').click()
    await expect(page.locator('[data-role="caption-pending"]')).toBeVisible()
    await expect(video).toHaveAttribute("src", before!)
    await expect(page.locator('[data-role="caption-style"]').first()).toBeDisabled()
    writeFileSync(path + ".command", JSON.stringify({ action: "complete" }))
    await expect.poll(() => existsSync(path + ".receipt")).toBe(true)
    const receipt = JSON.parse(readFileSync(path + ".receipt", "utf8"))
    unlinkSync(path + ".receipt")
    expect(receipt.payload.clip_overrides.mapped["captions.style"]).toBe("plain")
    expect(receipt.payload.base_render_id).toBeTruthy()
    await expect(page.locator('[data-role="caption-applied"]')).toHaveText("Applied: plain")
    await expect(video).not.toHaveAttribute("src", before!)
    await expect(page.locator('[data-role="caption-dirty"]')).toHaveCount(0)
    await expect(page.locator('[data-role="clip-approve"]')).toBeEnabled()
    const footer = await page.locator('[data-role="clips-decide"]').boundingBox()
    expect(footer!.y + footer!.height).toBeLessThanOrEqual(650)
    await page.screenshot({ path: info.outputPath("caption-applied-desktop.jpg") })

    await page.setViewportSize({ width: 390, height: 844 })
    await page.locator('[data-role="caption-style"][data-style="karaoke"]').click()
    await expect(page.locator('[data-role="clips-pbar-approve"]')).toBeDisabled()
    const applied = await video.getAttribute("src")
    await page.locator('[data-role="caption-render"]').click()
    writeFileSync(path + ".command", JSON.stringify({ action: "fail" }))
    await expect(page.locator('[data-role="caption-failure"]')).toBeVisible()
    await expect(video).toHaveAttribute("src", applied!)
    await expect(page.locator('[data-role="caption-render"]')).toBeEnabled()
    await expect(page.locator('[data-role="clips-pbar"]')).toBeVisible()
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    await page.screenshot({ path: info.outputPath("caption-failed-phone.jpg") })
  } finally {
    await context.close()
    await browser.close()
  }
})
