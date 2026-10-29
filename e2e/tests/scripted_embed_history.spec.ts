/**
 * Scripted embed versions, history previews and fullscreen (task 01a18834).
 *
 * Stages 1 and 2 put a `scripts: true` embed behind the shared PrototypeFrame
 * bar (version stamp, version list, Pin), and made a canvas history preview
 * render prototype frames SEALED: pinned to the previewed version, with no
 * canvas-room bridge and no bar controls. This spec drives both in a real
 * browser against the seeded fixture, and proves the rig can produce BOTH
 * outcomes before it trusts a negative one.
 *
 * CASES (run in order: `describe.serial`, so a red case skips the rest)
 *
 *   (a) editor, chat: the embed bar reads v3 with three version rows; Pin v2
 *       moves the frame to /proto/<id>/2/ and the frame shows VERSION=2, with
 *       no v4 published (still three rows). Pin v3 then restores the fixture.
 *   (b) viewer (an org member who is not a participant), /canvases/<id>: the
 *       version list opens with three rows and NO Pin button, hidden rather
 *       than disabled.
 *   (c) POSITIVE CONTROL, chat: a click on #bump inside the live frame in
 *       window A changes the room counter that window B (a second editor
 *       session) shows. This is what makes (d)'s "nothing changed" mean
 *       something: the click, the room and window B's readout all work.
 *   (d) /canvases/<id> in window A, History, the revision holding v2: the
 *       preview iframe is /proto/<id>/2/ and `#canvas-historical-document`
 *       holds no `[data-role=canvas-room-bridge]`. A click at #bump's
 *       coordinates inside the preview leaves window B's counter, the room
 *       state B's frame paints, and the canvas revision stamp unchanged.
 *       Window B is then shown to be still live (its own bump moves it).
 *   (e) the same preview renders the node pinned to the retention-removed
 *       version as `[data-role=prototype-removed]` with no iframe, while the
 *       follow-latest node beside it renders its v2 iframe; no request is
 *       ever made for the removed version. In chat the same removed node
 *       shows the panel with "View v2".
 *   (f) iPhone viewport (390x844, hasTouch): the fullscreen button on the
 *       scripted embed AND on the prototype node makes
 *       `[data-role=prototype-canvas][data-fullscreen=true]`'s rect equal the
 *       viewport; Close returns `data-fullscreen=false` with the frame back
 *       inline in the chat canvas.
 *
 * VIEWPORTS. (c), (d) and (f) run at 390x844 with touch (their frames are
 * the evidence screenshots). (a), (b) and (e) run at 1280x800. They need the
 * version list, and on a phone that list is a `fixed` bottom sheet inside the
 * chat row, so (a) cannot run there; see the finding below.
 *
 * FINDING (pre-existing on main, not introduced by this task). At 390x844 in
 * Playwright WebKit, a click on "Pin this version" in the version list
 * sheet of a frame inside a chat message never reaches the server: no `pin`
 * event is logged. The press puts `.message-row-inner` into `:active`, its
 * `active:scale-[0.99]` turns the row into the containing block of the
 * `fixed` sheet, and the release then lands elsewhere. This is the trap task
 * 01a1389f fixed for the fullscreen overlay only. With
 * `.message-row-inner { scale: none }` injected, the same click pins. The
 * spec does not paper over it, so (a) stays on desktop.
 *
 * THE VIEWER NEVER OPENS /chat. ChatLive adds a participant row for an org
 * member browsing a public channel, and a participant is a canvas writer, so
 * the "non-editor" would become an editor. The seed removes any such row on
 * re-run. On /canvases/<id> no viewer reaches PrototypeFrame, so Pin is
 * hidden there for every reader; (b) asserts the hidden-not-disabled shape,
 * and (a) is the case that shows Pin exists for an editor.
 *
 * Seed the fixture first, in the dev container, from apps/platform:
 *   mix run priv/scripts/seed_scripted_embed_history_fixture.exs
 * It prints KEY=value lines; export each as FIXTURE_<KEY>. Runs only under
 * the `webkit-iphone` project (WebKit); every context is made here with an
 * explicit viewport.
 */

import { test, expect, Browser, BrowserContext, Page, Locator, TestInfo, devices } from "@playwright/test"
import * as fs from "fs"
import * as path from "path"

const env = (key: string, fallback = "") => process.env[`FIXTURE_${key}`] ?? fallback

const CANVAS_ID = env("CANVAS_ID")
const SPACE_SLUG = env("SPACE_SLUG", "embedhist-fixture")
const EDITOR_SLUG = env("EDITOR_SLUG", "embedhist-editor")
const VIEWER_SLUG = env("VIEWER_SLUG", "embedhist-viewer")
const EMBED_ID = env("EMBED_PROTOTYPE_ID")
const RETENTION_ID = env("RETENTION_PROTOTYPE_ID")
const REMOVED_VERSION = Number(env("REMOVED_VERSION", "1"))
const REV_V2 = Number(env("REV_V2", "2"))
/** Optional: also copy every screenshot here (outside test-results). */
const SHOT_DIR = process.env.EMBED_HISTORY_SHOT_DIR ?? ""

const PHONE = { ...devices["iPhone 15"], viewport: { width: 390, height: 844 } }
const DESKTOP = { viewport: { width: 1280, height: 800 } }
const RECT_TOLERANCE_PX = 1

const INLINE = `[id^="inline-canvas-"][data-canvas-id="${CANVAS_ID}"]`
const ROOT = '[data-role="prototype-canvas"]'
const ROOT_FS = '[data-role="prototype-canvas"][data-fullscreen="true"]'
const scripted = (scope: string) => `${scope} ${ROOT}[id^="embed-canvas-scripted-se-"]`
const protoNode = (scope: string, node: string) => `${scope} ${ROOT}[id^="prototype-${node}-"]`
const PREVIEW = "#canvas-historical-document"
const embedSrc = (v: number) => `/proto/${EMBED_ID}/${v}/`
const retentionSrc = (v: number) => `/proto/${RETENTION_ID}/${v}/`

/** Shared across the serial cases: (c) proves window B live, (d) reuses it. */
let shared: { a: BrowserContext; b: BrowserContext; pageA: Page; pageB: Page } | null = null

async function newPage(browser: Browser, opts: object, slug: string): Promise<{ ctx: BrowserContext; page: Page }> {
  const ctx = await browser.newContext({ ...opts, baseURL: test.info().project.use.baseURL })
  // iPhone Safari has no element Fullscreen API, which is why the in-app
  // overlay exists; remove whatever this engine exposes so the hook takes the
  // overlay path a phone takes (as prototype_fullscreen_touch.spec.ts does).
  await ctx.addInitScript(() => {
    for (const name of ["requestFullscreen", "webkitRequestFullscreen"]) {
      try {
        Object.defineProperty(Element.prototype, name, { value: undefined, configurable: true })
      } catch (_) {}
    }
    for (const name of ["fullscreenEnabled", "webkitFullscreenEnabled"]) {
      try {
        Object.defineProperty(Document.prototype, name, { get: () => false, configurable: true })
      } catch (_) {}
    }
  })
  const page = await ctx.newPage()
  page.on("pageerror", (err) => console.log(`[pageerror ${slug}] ${err.message}`))
  await page.goto(`/dev/login?as=${slug}`)
  await page.waitForURL("**/chat**", { timeout: 20_000 })
  return { ctx, page }
}

/** The page's LiveView socket is connected: clicks reach the server. */
async function expectLive(page: Page, label: string) {
  await page.waitForFunction(
    () => !!(window as unknown as { liveSocket?: { isConnected?: () => boolean } }).liveSocket?.isConnected?.(),
    null,
    { timeout: 20_000 },
  )
  const live = await page.evaluate(
    () => !!(window as unknown as { liveSocket?: { isConnected?: () => boolean } }).liveSocket?.isConnected?.(),
  )
  console.log(`[live] ${label}: liveSocket.isConnected() = ${live}`)
  expect(live, `${label}: LiveView socket not connected`).toBe(true)
}

/** Open the fixture channel and wait for the inline canvas's scripted frame. */
async function openChat(page: Page, label: string): Promise<Locator> {
  await page.goto(`/chat/${SPACE_SLUG}`)
  await expectLive(page, label)
  const inline = page.locator(INLINE).first()
  await expect(inline).toBeAttached({ timeout: 20_000 })
  await inline.scrollIntoViewIfNeeded()
  const root = page.locator(scripted(INLINE)).first()
  await expect(root).toBeAttached({ timeout: 20_000 })
  return root
}

async function openCanvasPage(page: Page, label: string) {
  await page.goto(`/canvases/${CANVAS_ID}`)
  await expectLive(page, label)
  await expect(page.locator('[data-role="canvas-body"]')).toBeAttached({ timeout: 20_000 })
}

async function revisionStamp(page: Page): Promise<number> {
  const text = (await page.locator('[data-role="canvas-revision-stamp"]').innerText()).trim()
  const m = /^rev (\d+)/.exec(text)
  expect(m, `revision stamp reads "${text}"`).not.toBeNull()
  return Number(m![1])
}

async function openHistoryPreview(page: Page, revision: number) {
  await page.locator("#canvas-history-open").click()
  await page.locator(`#canvas-history-select-${revision}`).click()
  await expect(page.locator(`${PREVIEW}[data-preview-revision="${revision}"]`)).toBeAttached({
    timeout: 10_000,
  })
}

/** Room state as window B's live frame paints it: `count=N · connected`. */
async function frameState(page: Page, root: string) {
  const frame = page.frameLocator(`${root} iframe`)
  return {
    count: Number(await frame.locator("#count").innerText()),
    conn: (await frame.locator("#conn").innerText()).trim(),
  }
}

async function shot(page: Page, testInfo: TestInfo, name: string) {
  const file = testInfo.outputPath(`${name}.png`)
  await page.screenshot({ path: file })
  await testInfo.attach(name, { path: file, contentType: "image/png" })
  if (SHOT_DIR) {
    fs.mkdirSync(SHOT_DIR, { recursive: true })
    fs.copyFileSync(file, path.join(SHOT_DIR, `${name}.png`))
  }
}

test.describe.serial("scripted embed versions, history previews and fullscreen", () => {
  test.skip(!CANVAS_ID || !EMBED_ID || !RETENTION_ID, "FIXTURE_* not set — seed the fixture first")

  test.afterAll(async () => {
    if (shared) {
      await shared.a.close()
      await shared.b.close()
      shared = null
    }
  })

  test("(a) the embed bar reads v3 of three, and Pin v2 serves v2 without publishing v4", async ({
    browser,
  }) => {
    const { ctx, page } = await newPage(browser, DESKTOP, EDITOR_SLUG)
    try {
      const root = await openChat(page, "(a) editor chat")
      const stamp = root.locator('[data-role="prototype-version-stamp"]')
      const frame = page.frameLocator(`${scripted(INLINE)} iframe`)
      const rows = root.locator('[data-role="prototype-version-row"]')

      await expect(stamp).toContainText("v3")
      await expect(root.locator("iframe")).toHaveAttribute("src", embedSrc(3))
      await expect(frame.locator("#ver")).toHaveText("VERSION=3", { timeout: 20_000 })

      await stamp.click()
      await expect(rows).toHaveCount(3)
      await expect(root.locator('[data-role="prototype-pin"]')).toHaveCount(2)
      await root.locator('[data-role="prototype-version-row"][data-version="2"] [data-role="prototype-pin"]').click()

      await expect(root.locator("iframe")).toHaveAttribute("src", embedSrc(2), { timeout: 15_000 })
      await expect(frame.locator("#ver")).toHaveText("VERSION=2", { timeout: 20_000 })
      await expect(stamp).toContainText("v2")
      await expect(root.locator('[data-role="prototype-pinned-chip"]')).toContainText("latest v3")
      if ((await root.locator('[data-role="prototype-versions-panel"]').count()) === 0) await stamp.click()
      await expect(rows, "pinning v2 published a new version").toHaveCount(3)

      // Restore the fixture: Pin v3 reuses v3 by its sha.
      await root.locator('[data-role="prototype-version-row"][data-version="3"] [data-role="prototype-pin"]').click()
      await expect(root.locator("iframe")).toHaveAttribute("src", embedSrc(3), { timeout: 15_000 })
      await expect(frame.locator("#ver")).toHaveText("VERSION=3", { timeout: 20_000 })
      await expect(root.locator('[data-role="prototype-pinned-chip"]')).toHaveCount(0)
      if ((await root.locator('[data-role="prototype-versions-panel"]').count()) === 0) await stamp.click()
      await expect(rows, "re-pinning v3 published a new version").toHaveCount(3)
    } finally {
      await ctx.close()
    }
  })

  test("(b) a non-participant sees the version list with no Pin, hidden not disabled", async ({ browser }) => {
    const { ctx, page } = await newPage(browser, DESKTOP, VIEWER_SLUG)
    try {
      await openCanvasPage(page, "(b) viewer /canvases")
      const root = page.locator(scripted('[data-role="canvas-body"]')).first()
      await expect(root).toBeAttached({ timeout: 20_000 })
      await root.locator('[data-role="prototype-version-stamp"]').click()
      const panel = root.locator('[data-role="prototype-versions-panel"]')
      await expect(panel).toBeVisible({ timeout: 10_000 })
      await expect(panel.locator('[data-role="prototype-version-row"]')).toHaveCount(3)
      await expect(root.locator('[data-role="prototype-pin"]')).toHaveCount(0)
      await expect(panel.getByText("Pin this version")).toHaveCount(0)
      await expect(panel.locator("button[disabled], [aria-disabled=true]")).toHaveCount(0)
    } finally {
      await ctx.close()
    }
  })

  test("(c) POSITIVE CONTROL: #bump in window A moves the room counter window B shows", async ({
    browser,
  }, testInfo) => {
    const a = await newPage(browser, PHONE, EDITOR_SLUG)
    const b = await newPage(browser, PHONE, EDITOR_SLUG)
    shared = { a: a.ctx, b: b.ctx, pageA: a.page, pageB: b.page }

    await openChat(a.page, "(c) window A chat")
    await openChat(b.page, "(c) window B chat")
    const frameA = a.page.frameLocator(`${scripted(INLINE)} iframe`)
    const frameB = b.page.frameLocator(`${scripted(INLINE)} iframe`)
    await expect(frameA.locator("#conn")).toHaveText("connected", { timeout: 20_000 })
    await expect(frameB.locator("#conn")).toHaveText("connected", { timeout: 20_000 })

    const before = await frameState(b.page, scripted(INLINE))
    console.log(`[room] (c) window B before: ${JSON.stringify(before)}`)
    await frameA.locator("#bump").click()
    await expect(frameB.locator("#count")).toHaveText(String(before.count + 1), { timeout: 15_000 })
    await expect(frameA.locator("#count")).toHaveText(String(before.count + 1), { timeout: 15_000 })
    console.log(`[room] (c) window B after: ${JSON.stringify(await frameState(b.page, scripted(INLINE)))}`)

    await a.page.locator(scripted(INLINE)).first().scrollIntoViewIfNeeded()
    await shot(a.page, testInfo, "c-window-a-after-bump")
    await b.page.locator(scripted(INLINE)).first().scrollIntoViewIfNeeded()
    await shot(b.page, testInfo, "c-window-b-counter")
  })

  test("(d) the v2 history preview is sealed: no bridge, and a click in it changes nothing", async ({}, testInfo) => {
    expect(shared, "(c) did not leave its two windows; it must pass in the same run").not.toBeNull()
    const { pageA, pageB } = shared!
    const rootB = scripted(INLINE)
    const frameB = pageB.frameLocator(`${rootB} iframe`)

    // Window B is still live and its frame still connected to the room.
    await expectLive(pageB, "(d) window B")
    await expect(frameB.locator("#conn")).toHaveText("connected")
    const roomBefore = await frameState(pageB, rootB)

    await openCanvasPage(pageA, "(d) window A /canvases")
    const revisionBefore = await revisionStamp(pageA)
    await openHistoryPreview(pageA, REV_V2)
    await expectLive(pageA, "(d) window A with the preview open")

    const preview = pageA.locator(PREVIEW)
    const previewFrame = preview.locator(`iframe[src="${embedSrc(2)}"]`)
    await expect(previewFrame).toHaveCount(1)
    await expect(previewFrame).toHaveAttribute("sandbox", "allow-scripts")
    await expect(preview.locator('[data-role="canvas-room-bridge"]')).toHaveCount(0)
    await expect(preview.locator('[phx-hook="CanvasRoomBridge"]')).toHaveCount(0)
    for (const role of ["prototype-pin", "prototype-fullscreen", "prototype-open", "prototype-menu-button"]) {
      await expect(preview.locator(`[data-role="${role}"]`), `${role} in the preview`).toHaveCount(0)
    }
    const inPreview = pageA.frameLocator(`${PREVIEW} iframe[src="${embedSrc(2)}"]`)
    await expect(inPreview.locator("#ver")).toHaveText("VERSION=2", { timeout: 20_000 })
    // No room answers a preview frame's hello; the bridge settles offline.
    await expect(inPreview.locator("#conn")).toHaveText("offline", { timeout: 10_000 })

    await previewFrame.scrollIntoViewIfNeeded()
    const box = await inPreview.locator("#bump").boundingBox()
    expect(box, "no #bump box inside the preview frame").not.toBeNull()
    const x = box!.x + box!.width / 2
    const y = box!.y + box!.height / 2
    console.log(`[preview] clicking at #bump ${x},${y}`)
    await pageA.mouse.click(x, y)
    await pageA.touchscreen.tap(x, y)
    await shot(pageA, testInfo, "d-preview-v2-after-click")
    await pageA.waitForTimeout(2_000)

    expect(await inPreview.locator("#count").innerText(), "the preview frame counted a click").toBe("0")
    const roomAfter = await frameState(pageB, rootB)
    console.log(`[room] (d) window B before ${JSON.stringify(roomBefore)} after ${JSON.stringify(roomAfter)}`)
    expect(roomAfter, "a click in the preview reached the room").toEqual(roomBefore)

    await pageA.locator("#canvas-history-back-current").click()
    await expect(pageA.locator(PREVIEW)).toHaveCount(0)
    expect(await revisionStamp(pageA), "a click in the preview wrote a canvas revision").toBe(revisionBefore)

    // And B was able to see a change all along: its own bump moves it.
    await frameB.locator("#bump").click()
    await expect(frameB.locator("#count")).toHaveText(String(roomBefore.count + 1), { timeout: 15_000 })
  })

  test("(e) a retention-removed version renders the removed panel, never a frame", async ({ browser }) => {
    const { ctx, page } = await newPage(browser, DESKTOP, EDITOR_SLUG)
    const removedRequests: string[] = []
    page.on("request", (req) => {
      if (req.url().includes(retentionSrc(REMOVED_VERSION))) removedRequests.push(req.url())
    })
    try {
      await openCanvasPage(page, "(e) /canvases")
      await openHistoryPreview(page, REV_V2)
      const preview = page.locator(PREVIEW)
      const gone = page.locator(protoNode(PREVIEW, "pgone")).first()
      await expect(gone.locator('[data-role="prototype-removed"]')).toBeVisible()
      await expect(gone.locator("iframe")).toHaveCount(0)
      await expect(gone.locator("button, a")).toHaveCount(0)
      // Control: the follow-latest node beside it does render a frame.
      await expect(page.locator(protoNode(PREVIEW, "plive")).first().locator("iframe")).toHaveAttribute(
        "src",
        retentionSrc(2),
      )
      await expect(preview.locator(`iframe[src="${retentionSrc(REMOVED_VERSION)}"]`)).toHaveCount(0)

      await openChat(page, "(e) editor chat")
      const live = page.locator(protoNode(INLINE, "pgone")).first()
      await expect(live.locator('[data-role="prototype-removed"]')).toBeVisible()
      await expect(live.locator("iframe")).toHaveCount(0)
      await expect(live.locator('[data-role="prototype-removed"]')).toContainText("View v2")
      expect(removedRequests, "a request was made for the removed version").toEqual([])
    } finally {
      await ctx.close()
    }
  })

  test("(f) iPhone: fullscreen fills the viewport and Close puts the frame back, for both kinds", async ({
    browser,
  }, testInfo) => {
    const { ctx, page } = await newPage(browser, PHONE, EDITOR_SLUG)
    try {
      await openChat(page, "(f) editor chat, 390x844")
      for (const [label, sel] of [
        ["scripted-embed", scripted(INLINE)],
        ["prototype-node", protoNode(INLINE, "plive")],
      ] as const) {
        const root = page.locator(sel).first()
        const id = await root.getAttribute("id")
        const src = await root.locator("iframe").getAttribute("src")
        await root.locator('[data-role="prototype-fullscreen"]').scrollIntoViewIfNeeded()
        await root.locator('[data-role="prototype-fullscreen"]').tap()
        const overlay = page.locator(ROOT_FS)
        await expect(overlay).toHaveCount(1, { timeout: 10_000 })
        await expect(overlay).toHaveAttribute("id", id!)
        await page.waitForTimeout(450)

        const m = await page.evaluate((rootFs) => {
          const r = document.querySelector(rootFs)!.getBoundingClientRect()
          return { top: r.top, left: r.left, width: r.width, height: r.height, w: innerWidth, h: innerHeight }
        }, ROOT_FS)
        console.log(`[fullscreen] ${label} ${JSON.stringify(m)}`)
        expect(Math.abs(m.top), `${label} top`).toBeLessThanOrEqual(RECT_TOLERANCE_PX)
        expect(Math.abs(m.left), `${label} left`).toBeLessThanOrEqual(RECT_TOLERANCE_PX)
        expect(Math.abs(m.width - m.w), `${label} width vs viewport`).toBeLessThanOrEqual(RECT_TOLERANCE_PX)
        expect(Math.abs(m.height - m.h), `${label} height vs viewport`).toBeLessThanOrEqual(RECT_TOLERANCE_PX)
        await expect(overlay.locator("iframe")).toHaveAttribute("src", src!)
        await shot(page, testInfo, `f-${label}-fullscreen`)

        await overlay.locator('[data-role="prototype-fullscreen-close"]').tap()
        await expect(root).toHaveAttribute("data-fullscreen", "false", { timeout: 10_000 })
        await expect(page.locator(ROOT_FS)).toHaveCount(0)
        const back = await root.evaluate(
          (el, inline) => {
            const r = el.getBoundingClientRect()
            return { inInline: !!el.closest(inline), width: r.width, height: r.height, vw: innerWidth, vh: innerHeight }
          },
          INLINE,
        )
        console.log(`[fullscreen] ${label} after Close ${JSON.stringify(back)}`)
        expect(back.inInline, `${label} is no longer inside the chat canvas`).toBe(true)
        expect(back.height, `${label} still covers the viewport after Close`).toBeLessThan(back.vh)
        await expect(root.locator("iframe")).toHaveAttribute("src", src!)
      }
    } finally {
      await ctx.close()
    }
  })
})
