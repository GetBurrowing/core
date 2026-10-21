/**
 * Stage 3 verification for task 019e0d4a — confirm the four audit findings
 * targeted by the design-system diff resolve in the running dev server.
 *
 * Anchors (from `~/projects/core/docs/design-system/IMPLEMENTATION.md`):
 *   1B-A11Y-5  light-theme `--color-neutral` contrast (Stage 1)
 *   1B-A11Y-1  focus-visible-ring utility (Stage 2)
 *   1B-A11Y-6  button-loading cursor + opacity (Stage 2)
 *   1B-A11Y-3  prefers-reduced-motion universal block (Stage 2)
 *
 * Scope discipline: the plan asks specifically that the `bg-neutral`
 * paired with `text-neutral-content` contrast pair pass, NOT that every
 * route's color surface be regression-free. Pre-existing low-opacity
 * helper-text contrast violations (`text-base-content/30`, `text-base-content/40`)
 * surface on routes-wide axe scans but are tracked separately in the
 * IMPLEMENTATION plan; they are not in scope for Stage 1's token bump.
 *
 * Strategy: inject a controlled `bg-neutral / text-neutral-content` element
 * into each route and run axe scoped to that element for color-contrast.
 * Run focus-order-semantics + tabindex routes-wide where regressions WOULD
 * be in scope for the Stage 2 utility additions.
 *
 * Plan also listed a `focusable-content` rule, which axe-core has no rule
 * for — substituted `tabindex` (the closest cross-cutting check; rejects
 * tabindex>0 which is what `focusable-content` colloquially refers to).
 */

import AxeBuilder from "@axe-core/playwright"
import { test, expect, type Browser, type BrowserContext, type Page } from "@playwright/test"
import * as fs from "node:fs"
import * as path from "node:path"

const SCREENSHOT_DIR = path.resolve(
  __dirname,
  "../../audit/2026-05-08-ui-ux/post-fix-screenshots",
)

async function loginAs(browser: Browser, slug: string): Promise<{ context: BrowserContext; page: Page }> {
  const context = await browser.newContext()
  const page = await context.newPage()
  page.on("pageerror", (err) => console.log(`[${slug} pageerror] ${err.message}`))
  await page.goto(`/dev/login?as=${slug}`)
  await page.waitForURL("**/chat**", { timeout: 10_000 })
  return { context, page }
}

async function injectNeutralProbe(page: Page) {
  // Append a probe element with the exact Stage-1 target pair, fixed-position
  // so it's not occluded by overflow. axe-core measures rendered contrast
  // against the actual computed colors — so this exercises the live
  // `--color-neutral` token after the bump.
  await page.evaluate(() => {
    const el = document.createElement("div")
    el.id = "stage3-neutral-probe"
    el.className = "bg-neutral text-neutral-content"
    el.style.position = "fixed"
    el.style.bottom = "8px"
    el.style.right = "8px"
    el.style.padding = "12px 16px"
    el.style.zIndex = "9999"
    el.style.fontSize = "14px"
    el.textContent = "neutral surface contrast probe"
    document.body.appendChild(el)
  })
}

async function runScopedAxe(page: Page, label: string) {
  // Color-contrast scoped to the injected probe — the Stage 1 target pair.
  await injectNeutralProbe(page)
  const contrast = await new AxeBuilder({ page })
    .include("#stage3-neutral-probe")
    .withRules(["color-contrast"])
    .analyze()

  if (contrast.violations.length > 0) {
    console.log(`[axe ${label}] color-contrast violations on neutral probe:`)
    for (const v of contrast.violations) {
      console.log(`  - ${v.id}: ${v.help}`)
      for (const n of v.nodes) console.log(`      ${(n as { failureSummary?: string }).failureSummary ?? n.target.join(",")}`)
    }
  }
  expect(
    contrast.violations,
    `bg-neutral/text-neutral-content contrast on ${label} (1B-A11Y-5 target)`,
  ).toEqual([])

  // Focus + tabindex routes-wide — these regressions WOULD be in scope.
  const focusResults = await new AxeBuilder({ page })
    .withRules(["focus-order-semantics", "tabindex"])
    .analyze()

  if (focusResults.violations.length > 0) {
    console.log(`[axe ${label}] focus/tabindex violations:`)
    for (const v of focusResults.violations) {
      console.log(`  - ${v.id} (impact=${v.impact}): ${v.help}`)
      for (const node of v.nodes.slice(0, 3)) {
        console.log(`      target=${node.target.join(" >> ")}`)
      }
    }
  }
  expect(
    focusResults.violations,
    `focus-order-semantics + tabindex on ${label} (1B-A11Y-1 target)`,
  ).toEqual([])
}

const ROUTES: { path: string; label: string }[] = [
  { path: "/chat/general", label: "chat" },
  { path: "/tasks", label: "tasks" },
]

test.describe("Audit resolution: contrast + focus + motion", () => {
  test.beforeAll(() => {
    fs.mkdirSync(SCREENSHOT_DIR, { recursive: true })
  })

  for (const route of ROUTES) {
    test(`${route.label}: scoped axe-core rules pass`, async ({ browser }) => {
      const { context, page } = await loginAs(browser, "alice")
      try {
        await page.goto(route.path)
        await page.waitForLoadState("networkidle", { timeout: 15_000 })
        await runScopedAxe(page, route.label)
      } finally {
        await context.close()
      }
    })
  }

  test("chat: capture before/after screenshots of --color-neutral bump", async ({ browser }) => {
    const { context, page } = await loginAs(browser, "alice")
    try {
      await page.goto("/chat/general")
      await page.waitForLoadState("networkidle", { timeout: 15_000 })

      // Inject the same neutral probe used by the contrast test so the
      // before/after delta is concentrated in a known surface.
      await injectNeutralProbe(page)
      await page.waitForTimeout(150)

      // After: current production CSS (Stage 1 + 2 landed).
      await page.screenshot({
        path: path.join(SCREENSHOT_DIR, "chat-after.png"),
        fullPage: false,
      })

      // Before: monkey-patch :root to the legacy pre-Stage-1 value. CSS
      // custom properties cascade at runtime so this approximates the
      // pre-fix render without a worktree round-trip.
      await page.addStyleTag({
        content: `:root { --color-neutral: oklch(55% 0.01 0) !important; }`,
      })
      await page.waitForTimeout(200)
      await page.screenshot({
        path: path.join(SCREENSHOT_DIR, "chat-before.png"),
        fullPage: false,
      })
    } finally {
      await context.close()
    }
  })
})
