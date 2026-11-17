import { test, expect } from "@playwright/test"

// Real LiveView and CSS geometry: the notification prompt used to precede
// an h-full chat pane, putting the composer one banner-height below main.
// Run without retries so a clipped first-sign-in composer is never waived.
test.describe("chat notification prompt preserves the composer viewport", () => {
  test.describe.configure({ retries: 0 })

  for (const viewport of [
    { width: 1440, height: 900 },
    { width: 1024, height: 600 },
    { width: 390, height: 844 },
    { width: 844, height: 390 },
  ]) {
    test(`${viewport.width}x${viewport.height}: prompt, typing and dismissal`, async ({ page }) => {
      await page.setViewportSize(viewport)
      await page.goto(`/dev/login?as=notification-layout-${Date.now()}-${viewport.width}`)
      await page.goto("/chat/general")
      await page.waitForFunction(() => (window as any).liveSocket?.isConnected())
      const composer = page.locator("#compose-form .compose-field")
      await expect(composer).toBeVisible()

      const permission = async (state: string) => {
        await page.evaluate((state) => {
          const socket = (window as any).liveSocket
          socket.main.pushHookEvent(
            document.querySelector("#push-subscribe"), null,
            "push_permission_state", { state }, () => {},
          )
        }, state)
      }
      const assertInside = async () => {
        const geometry = await page.evaluate(() => {
          const main = document.querySelector("main[data-scroll-container]")!.getBoundingClientRect()
          const form = document.querySelector("#compose-form")!.getBoundingClientRect()
          const field = document.querySelector("#compose-form .compose-field")!.getBoundingClientRect()
          return { main: { top: main.top, bottom: main.bottom }, form: { top: form.top, bottom: form.bottom }, field: { top: field.top, bottom: field.bottom }, viewport: innerHeight }
        })
        expect(geometry.form.top).toBeGreaterThanOrEqual(geometry.main.top)
        expect(geometry.form.bottom).toBeLessThanOrEqual(geometry.main.bottom + 1)
        expect(geometry.field.bottom).toBeLessThanOrEqual(geometry.viewport)
      }

      await permission("granted")
      await expect(page.locator("[data-role=chat-notification-banner]")).toHaveCount(0)
      await assertInside()
      await composer.click()
      await composer.pressSequentially("still typing")

      await permission("prompt")
      if (viewport.width >= 1024) {
        await expect(page.locator("[data-role=chat-notification-banner]")).toBeVisible()
      }
      await assertInside()
      // Inserting the prompt must not move/recreate the editable and lose focus.
      await expect(composer).toBeFocused()
      await composer.pressSequentially(" with notifications")
      await expect(composer).toContainText("still typing with notifications")

      if (viewport.width >= 1024) {
        await page.locator("[data-role=chat-notification-dismiss]").click()
        await expect(page.locator("[data-role=chat-notification-banner]")).toHaveCount(0)
      } else {
        await permission("denied")
      }
      await assertInside()
      await composer.click()
      await expect(composer).toBeFocused()
    })
  }
})
