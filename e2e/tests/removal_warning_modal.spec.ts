/**
 * Removal-warning modal — browser-level coverage for the Policy 4 gate.
 *
 * Closes the test gap surfaced by Task 6 Stage 6 e2e_review (2026-05-13):
 * the existing edit_policies_test.exs unit tests drive `render_hook(view,
 * "save_edit", %{removes_content: "true"})` directly, bypassing the JS
 * hook entirely. That meant the buggy 5-character-window heuristic
 * could over-trigger the modal on additive edits and the test suite would
 * still pass green. This spec exercises the actual JS hook in a real
 * browser, locking in the fix from Stage 2 (task 019e1eaf).
 *
 * Test scenarios (numbered from the Task 6 e2e_review evaluation_payload):
 *
 *   (1) Additive edit with boundary-punctuation move →
 *       "Hey can we talk about the API tomorrow?"
 *       → "Hey can we talk about the API tomorrow at 10am?"
 *       Expected: NO modal opens; the edit saves silently. This is the
 *       canonical bug case (the `?` moves from after "tomorrow" to after
 *       "10am", so the old 5-char window heuristic flagged "rrow?" as
 *       removed).
 *
 *   (3) Substring removal →
 *       "Hey can we talk about the API tomorrow?"
 *       → "Hey can we talk tomorrow?"
 *       Expected: modal opens with the locked Policy-4 copy ("Edit removes
 *       text." / "Agents that already read this still have the original in
 *       their memory."), Cancel keeps the editor open with the draft, Edit
 *       anyway fires the save and the body updates.
 *
 * KNOWN DEPENDENCY (test.fixme): both tests are currently marked fixme
 * pending the deadclick fix in task 019e1e78. The audit document
 * `audit/01-deadclick-finding.md` (lines 139–190 on the Task 6 branch)
 * documents that `phx-click="edit_message_clicked"` does not propagate
 * the `:editing_message_id` socket assign into existing stream rows,
 * so the inline editor never renders — neither via the pencil click,
 * the 3-dot → Edit menu, nor via Playwright-pushed events that hit the
 * same code path. The deadclick fix is a 5-LOC change in
 * `chat_live.ex:265` to `stream_insert` the targeted message after
 * setting the assign. Once 019e1e78 lands and `stream_insert` re-renders
 * the row, simply delete the `test.fixme()` line at the top of each
 * test body and the bodies run unchanged.
 */

import { test, expect, Browser, BrowserContext, Page } from "@playwright/test"

const SPACE = "general"
const ORIGINAL_BODY = "Hey can we talk about the API tomorrow?"

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
  return { slug, context, page }
}

async function compose(peer: Peer, body: string) {
  const textarea = peer.page.locator('#compose-form textarea[name="compose[text]"]')
  await expect(textarea).toBeVisible()
  await textarea.click()
  await textarea.pressSequentially(body, { delay: 5 })
  await expect(textarea).toHaveValue(body, { timeout: 5_000 })
  const sendBtn = peer.page.locator(".compose-pill-send")
  await expect(sendBtn).toBeEnabled({ timeout: 5_000 })
  await sendBtn.click()
  await expect(
    peer.page.locator("#message-list").getByText(body, { exact: false }).first(),
  ).toBeVisible({ timeout: 5_000 })
}

// Locate the message bubble carrying the given body, then click its
// pencil edit affordance. Returns the editor's textarea locator.
//
// Currently broken upstream (task 019e1e78 — deadclick LV streams bug):
// the pencil-click handler at chat_live.ex:265 sets :editing_message_id
// on the socket but does not stream_insert the targeted row, so the
// :if={@editing_message_id == @msg.id} inline-editor render never
// evaluates true on the existing row. Once that's fixed, this helper
// works as-is.
async function openEditor(peer: Peer, body: string) {
  const bubble = peer.page
    .locator(`[data-message-id]`)
    .filter({ hasText: body })
    .first()
  await bubble.scrollIntoViewIfNeeded()
  await bubble.hover()
  const pencil = bubble.locator('button[phx-click="edit_message_clicked"]').first()
  await expect(pencil).toBeVisible({ timeout: 5_000 })
  await pencil.click()
  const editorTextarea = peer.page.locator(
    `form[phx-hook="MessageEditor"][data-message-id] textarea[name="body"]`,
  )
  await expect(editorTextarea).toBeVisible({ timeout: 5_000 })
  await expect(editorTextarea).toBeFocused()
  return editorTextarea
}

async function replaceEditorBody(textarea: ReturnType<Page["locator"]>, next: string) {
  // Select-all-and-type via the keyboard so the JS hook's input event
  // fires per change — `Locator.fill()` skips the input event sequence
  // that the MessageEditor hook listens to for shortenedOrRemoved.
  await textarea.click()
  await textarea.press("ControlOrMeta+A")
  await textarea.press("Delete")
  await textarea.pressSequentially(next, { delay: 5 })
  await expect(textarea).toHaveValue(next, { timeout: 5_000 })
}

test.describe("removal-warning modal (Policy 4)", () => {
  test("additive edit with boundary-punctuation move saves silently — no modal", async ({
    browser,
  }) => {
    test.fixme(
      true,
      "Blocked on task 019e1e78 (deadclick LV streams fix). Once edit_message_clicked stream_inserts the targeted message, this test runs unchanged.",
    )
    const alice = await login(browser, `rw-additive-${Date.now()}`)
    try {
      await compose(alice, ORIGINAL_BODY)
      const textarea = await openEditor(alice, ORIGINAL_BODY)
      await replaceEditorBody(
        textarea,
        "Hey can we talk about the API tomorrow at 10am?",
      )
      // Submit via Cmd/Ctrl+Enter (the MessageEditor hook's shortcut).
      await textarea.press("ControlOrMeta+Enter")
      // The removal-warning modal MUST NOT appear.
      await expect(alice.page.locator("#edit-removal-warning")).toHaveCount(0)
      // The message body updates in place.
      await expect(
        alice.page
          .locator("#message-list")
          .getByText("Hey can we talk about the API tomorrow at 10am?", { exact: false })
          .first(),
      ).toBeVisible({ timeout: 5_000 })
      // The editor closes (textarea no longer attached).
      await expect(textarea).toHaveCount(0)
    } finally {
      await alice.context.close()
    }
  })

  test("substring removal opens modal; Cancel keeps draft; Edit anyway saves", async ({
    browser,
  }) => {
    test.fixme(
      true,
      "Blocked on task 019e1e78 (deadclick LV streams fix). Once edit_message_clicked stream_inserts the targeted message, this test runs unchanged.",
    )
    const alice = await login(browser, `rw-removal-${Date.now()}`)
    try {
      await compose(alice, ORIGINAL_BODY)
      const textarea = await openEditor(alice, ORIGINAL_BODY)
      await replaceEditorBody(textarea, "Hey can we talk tomorrow?")
      // Submit — modal should open because "about", "the", "API" are
      // dropped tokens.
      await textarea.press("ControlOrMeta+Enter")
      const modal = alice.page.locator("#edit-removal-warning")
      await expect(modal).toBeVisible({ timeout: 5_000 })
      await expect(modal.getByText("Edit removes text.")).toBeVisible()
      await expect(
        modal.getByText(
          "Agents that already read this still have the original in their memory.",
        ),
      ).toBeVisible()

      // Click Cancel — modal closes, editor stays open with the draft.
      await modal.getByRole("button", { name: "Cancel" }).click()
      await expect(modal).toHaveCount(0)
      await expect(textarea).toBeVisible()
      await expect(textarea).toHaveValue("Hey can we talk tomorrow?")
      // The original message body is still the original (no save fired).
      await expect(
        alice.page
          .locator("#message-list")
          .getByText(ORIGINAL_BODY, { exact: false })
          .first(),
      ).toBeVisible()

      // Re-submit and click Edit anyway → save fires, body updates.
      await textarea.press("ControlOrMeta+Enter")
      await expect(modal).toBeVisible({ timeout: 5_000 })
      await modal.getByRole("button", { name: "Edit anyway" }).click()
      await expect(modal).toHaveCount(0)
      await expect(
        alice.page
          .locator("#message-list")
          .getByText("Hey can we talk tomorrow?", { exact: false })
          .first(),
      ).toBeVisible({ timeout: 5_000 })
      // The pre-edit text is gone.
      await expect(
        alice.page.locator("#message-list").getByText(ORIGINAL_BODY, { exact: true }),
      ).toHaveCount(0)
    } finally {
      await alice.context.close()
    }
  })
})
