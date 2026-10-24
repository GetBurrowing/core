/**
 * The edit removal guard — browser-level coverage for Policy 4 (redesign
 * rung 9 stage 4; masters MM `startEdit`, direction canvas 01a1666e node m3
 * rule 8).
 *
 * An edit that keeps UNDER half of the original text asks with the NATIVE
 * `window.confirm('This edit removes most of the text. Save anyway?')`,
 * raised by the MessageEditor hook on submit. There is no custom modal.
 * Dismissing the dialog keeps the editor open with the draft and sends
 * nothing; accepting saves. Any other edit saves with no dialog at all.
 * The pure threshold (55% asks, 50% and 40% do not) is unit-tested in
 * assets/test/hooks/message_editor.test.js; this spec drives the real hook.
 *
 * The editor is opened the way a desktop user opens it: hover the message
 * (the pill shows), ⋯ More actions, then Edit in the popover.
 */

import { test, expect, Browser, BrowserContext, Page, Dialog } from "@playwright/test"

const SPACE = "general"
const CONFIRM = "This edit removes most of the text. Save anyway?"

interface Peer {
  slug: string
  context: BrowserContext
  page: Page
  dialogs: string[]
}

async function login(browser: Browser, slug: string): Promise<Peer> {
  const context = await browser.newContext()
  const page = await context.newPage()
  page.on("pageerror", (err) => console.log(`[${slug} pageerror] ${err.message}`))
  await page.goto(`/dev/login?as=${slug}`)
  await page.waitForURL("**/chat**", { timeout: 10_000 })
  await page.goto(`/chat/${SPACE}`)
  await expect(page.locator("#message-list")).toBeAttached({ timeout: 10_000 })
  return { slug, context, page, dialogs: [] }
}

async function compose(peer: Peer, body: string) {
  // Since rung 10 the field is a contenteditable (`.compose-field`) that
  // ComposeInput mirrors into the hidden `compose[text]` input. Two
  // attempts: a keystroke that lands before the hook mounts is eaten.
  const field = peer.page.locator("#compose-form .compose-field")
  const value = peer.page.locator('#compose-form input[name="compose[text]"]')
  await expect(field).toBeVisible()
  for (let attempt = 0; attempt < 2; attempt++) {
    await field.fill("")
    await field.click()
    await field.pressSequentially(body, { delay: 5 })
    try {
      await expect(value).toHaveValue(body, { timeout: 5_000 })
      break
    } catch (err) {
      if (attempt === 1) throw err
    }
  }
  const send = peer.page.locator(".compose-pill-send")
  await expect(send).toBeEnabled({ timeout: 5_000 })
  await send.click()
  await expect(
    peer.page.locator("#message-list").getByText(body, { exact: false }).first(),
  ).toBeVisible({ timeout: 5_000 })
}

function bubble(peer: Peer, body: string) {
  return peer.page
    .locator(`[phx-hook="MessageGestures"][data-message-id]`)
    .filter({ hasText: body })
    .first()
}

async function openEditor(peer: Peer, body: string) {
  const row = bubble(peer, body)
  await row.scrollIntoViewIfNeeded()
  await row.hover()
  await row.locator('[data-role="message-pill"] button[aria-label="More actions"]').click()
  const edit = peer.page.locator('#message-actions-popover [data-role="message-actions-edit"]')
  await expect(edit).toBeVisible({ timeout: 5_000 })
  await edit.click()
  const textarea = peer.page.locator('form[phx-hook="MessageEditor"] textarea[name="body"]')
  await expect(textarea).toBeVisible({ timeout: 5_000 })
  await expect(textarea).toBeFocused()
  return textarea
}

async function replaceBody(textarea: ReturnType<Page["locator"]>, next: string) {
  await textarea.fill(next)
  await expect(textarea).toHaveValue(next, { timeout: 5_000 })
}

test.describe("edit removal guard (native confirm)", () => {
  test("an additive edit saves with no dialog", async ({ browser }) => {
    const alice = await login(browser, `rc-additive-${Date.now()}`)
    alice.page.on("dialog", (d: Dialog) => {
      alice.dialogs.push(d.message())
      void d.dismiss()
    })
    try {
      const original = `Hey can we talk about the API tomorrow? ${Date.now()}`
      await compose(alice, original)
      const textarea = await openEditor(alice, original)
      const next = `${original} at 10am`
      await replaceBody(textarea, next)
      await textarea.press("Enter")
      await expect(textarea).toHaveCount(0, { timeout: 5_000 })
      await expect(bubble(alice, next)).toBeVisible({ timeout: 5_000 })
      expect(alice.dialogs).toEqual([])
      // No custom modal exists any more.
      await expect(alice.page.locator("#edit-removal-warning")).toHaveCount(0)
    } finally {
      await alice.context.close()
    }
  })

  test("removing most asks natively; dismiss keeps the draft, accept saves", async ({
    browser,
  }) => {
    const alice = await login(browser, `rc-removal-${Date.now()}`)
    let accept = false
    alice.page.on("dialog", (d: Dialog) => {
      alice.dialogs.push(`${d.type()}:${d.message()}`)
      void (accept ? d.accept() : d.dismiss())
    })
    try {
      const stamp = Date.now()
      const original = `This is a long message with well over forty characters of text in it ${stamp}.`
      const short = `Short ${stamp}.`
      await compose(alice, original)
      const textarea = await openEditor(alice, original)
      await replaceBody(textarea, short)

      await textarea.press("Enter")
      await expect.poll(() => alice.dialogs.length).toBe(1)
      expect(alice.dialogs[0]).toBe(`confirm:${CONFIRM}`)
      // Dismissed: the editor stays open with the draft, the message is unchanged.
      await expect(textarea).toBeVisible()
      await expect(textarea).toHaveValue(short)
      await expect(alice.page.locator("#edit-removal-warning")).toHaveCount(0)

      accept = true
      await textarea.press("Enter")
      await expect.poll(() => alice.dialogs.length).toBe(2)
      await expect(textarea).toHaveCount(0, { timeout: 5_000 })
      const saved = bubble(alice, short)
      await expect(saved).toBeVisible({ timeout: 5_000 })
      await expect(saved.locator('[data-role="message-edited"]')).toHaveText("(edited)")
    } finally {
      await alice.context.close()
    }
  })
})
