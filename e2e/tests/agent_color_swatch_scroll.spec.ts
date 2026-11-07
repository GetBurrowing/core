/**
 * Agent colour swatch click must not scroll the app shell away (task 01a1b34f).
 *
 * THE DEFECT. On /control/<slug>, clicking a Color family swatch blanked the
 * pane and the colour could not be saved. Not a LiveView crash: each swatch
 * radio is `sr-only peer`, and `sr-only` is `position: absolute`. With no
 * positioned label around it, the radio's containing block is the shell's
 * `<main data-scroll-container>` (overflow-hidden). The radio's static
 * position sits deep inside the inner control-center scroller, so it
 * overflows that main; clicking the label focuses the radio and the browser
 * scrolls the overflow-hidden main to reveal it. The pane slides out of view
 * and the user cannot scroll it back. The fix is `relative` on the label.
 *
 * WHAT THIS MEASURES, per agent (native: the deepest identity form; external)
 * and per viewport (1280x800 mouse click; 375x812 isMobile+hasTouch tap):
 *   1. main[data-scroll-container].scrollTop is still 0 after the click,
 *   2. the clicked radio is :checked,
 *   3. the form's "Update identity" submit button is inside the viewport,
 *   4. submitting shows the "Updated <name>." flash, and a reload keeps it.
 * Each case logs one `SWATCH_MEASURE {json}` line before asserting, so a red
 * run still records the scrollTop it reached.
 *
 * FIXTURE. Agents are seeded per run with a `mix run` snippet against a
 * PRIVATE dev database (never the shared one), after the viewer has logged
 * in once so its user row exists:
 *
 *     curl -s -o /dev/null "$BASE_URL/dev/login?as=swatchviewer"
 *     cd apps/platform && PLATFORM_DEV_DATABASE=<private dev db> \
 *       mix run ../../e2e/scripts/seed-agent-color-swatch-fixture.exs
 *
 * The seed's last line is `FIXTURE <json>`; pass the json as SWATCH_FIXTURE:
 *
 *     cd e2e && BASE_URL=http://localhost:<port> SWATCH_FIXTURE='<json>' \
 *       npx playwright test tests/agent_color_swatch_scroll.spec.ts \
 *       --project=chromium --retries=0
 *
 * Both agents start at "teal". Each case picks a swatch other than the saved
 * one ("indigo", or back to "teal" when the previous case saved "indigo"), so
 * a no-op save cannot pass.
 */

import { test, expect, Browser } from "@playwright/test"

interface Fixture {
  native: { slug: string; name: string }
  external: { slug: string; name: string }
  from: string
  to: string
}

const RAW = process.env.SWATCH_FIXTURE
const LOGIN = process.env.SWATCH_LOGIN ?? "swatchviewer"

const VIEWPORTS = [
  { label: "1280x800", width: 1280, height: 800, touch: false },
  { label: "375x812", width: 375, height: 812, touch: true },
] as const

const AGENTS = ["native", "external"] as const

test.describe("agent colour swatch keeps the shell in place", () => {
  test.skip(!RAW, "SWATCH_FIXTURE unset: run the seed snippet in the header first")
  const fixture: Fixture = RAW ? JSON.parse(RAW) : ({} as Fixture)

  for (const kind of AGENTS) {
    for (const vp of VIEWPORTS) {
      test(`${kind} agent at ${vp.label}`, async ({ browser }) => {
        await runCase(browser, fixture, kind, vp)
      })
    }
  }
})

async function runCase(
  browser: Browser,
  fixture: Fixture,
  kind: (typeof AGENTS)[number],
  vp: (typeof VIEWPORTS)[number],
) {
  const agent = fixture[kind]
  const context = await browser.newContext({
    viewport: { width: vp.width, height: vp.height },
    isMobile: vp.touch,
    hasTouch: vp.touch,
  })
  const page = await context.newPage()
  page.on("pageerror", (err) => console.log(`[pageerror] ${err.message}`))

  try {
    await page.goto(`/dev/login?as=${LOGIN}`)
    // Lands on /chat or /start depending on the viewer; either is logged in.
    await page.waitForURL((url) => !url.pathname.startsWith("/dev/login"), { timeout: 15_000 })
    await page.goto(`/control/${agent.slug}`)
    await page.waitForFunction(() => (window as any).liveSocket?.isConnected?.() === true)
    // Settle: on the rig a click in the first moments after connect was seen
    // reverted by a post-mount re-render of the form (a separate race, not
    // this defect), which would read as "radio not :checked".
    await page.waitForTimeout(1_000)

    const formSel = (await page.locator("#federated-identity-form").count())
      ? "#federated-identity-form"
      : "#agent-config-form"
    const form = page.locator(formSel)
    await expect(form).toBeVisible()

    // A DIFFERENT swatch from the saved one: cases share an agent, so the
    // second viewport finds the first one's save and flips back.
    const current = await form
      .locator('input[name="config[color]"]:checked')
      .evaluate((el) => (el as HTMLInputElement).value)
    const target = current === fixture.to ? fixture.from : fixture.to
    const radioSel = `input[name="config[color]"][value="${target}"]`
    const radio = form.locator(radioSel)
    const swatch = form.locator(`label:has(> ${radioSel})`)
    await expect(radio).not.toBeChecked()

    const main = page.locator("main[data-scroll-container]")
    const scrollTop = () => main.evaluate((el) => el.scrollTop)

    // Bring the swatch row AND its submit button into view by scrolling the
    // inner control-center scroller to the button (the swatches sit just above
    // it). Both are in-flow, so this never needs to move the shell's main.
    const submit = form.getByRole("button", { name: "Update identity" })
    // Centre, not end: on a phone the bottom tab bar covers the last ~76px.
    await submit.evaluate((el) => el.scrollIntoView({ block: "center", behavior: "instant" }))
    await swatch.scrollIntoViewIfNeeded()
    const before = await scrollTop()

    if (vp.touch) {
      await swatch.tap()
    } else {
      await swatch.click()
    }
    // Let the focus scroll and the phx-change round trip settle.
    await page.waitForTimeout(400)

    const after = await scrollTop()
    const checked = await radio.evaluate((el) => (el as HTMLInputElement).matches(":checked"))
    const box = await submit.boundingBox()
    const inViewport =
      !!box &&
      box.y >= 0 &&
      box.x >= 0 &&
      box.y + box.height <= vp.height &&
      box.x + box.width <= vp.width

    console.log(
      "SWATCH_MEASURE " +
        JSON.stringify({ kind, viewport: vp.label, current, target, before, after, checked, submitBox: box, inViewport }),
    )

    expect(before, "main must not be scrolled before the click").toBe(0)
    expect(after, "main[data-scroll-container] scrolled by the swatch click").toBe(0)
    expect(checked, "clicked swatch radio is :checked").toBe(true)
    expect(inViewport, "Update identity is inside the viewport").toBe(true)

    if (vp.touch) {
      await submit.tap()
    } else {
      await submit.click()
    }
    await expect(page.getByText(`Updated ${agent.name}.`)).toBeVisible()

    await page.reload()
    await page.waitForFunction(() => (window as any).liveSocket?.isConnected?.() === true)
    await expect(
      page.locator(`${formSel} input[name="config[color]"][value="${target}"]`),
    ).toBeChecked()
  } finally {
    await context.close()
  }
}
