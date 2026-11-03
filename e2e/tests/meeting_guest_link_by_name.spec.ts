/**
 * Guest link by name in Add people (task 01a19ea6 stage 3), driven in a real
 * browser on the /meetings detail panel (mobile detail sheet at 375) and the
 * /calendar meeting panel, at 1280x800 and at 375x812 with touch.
 *
 * PRECONDITIONS (all from the dev server the spec points at):
 *   1. `GET /dev/login?as=<login>` once, so the viewer's user row exists.
 *   2. `mix run ../../e2e/scripts/seed-meeting-guest-link-fixture.exs` in the
 *      server's container. Its last line is `FIXTURE <json>`; pass the json
 *      as GUEST_LINK_FIXTURE.
 *   3. MEETING_GUEST_HOST set to a host Chromium can reach, passed again as
 *      GUEST_LINK_GUEST_HOST. Serve both on `localhost` (BASE_URL
 *      `http://localhost:<port>`, guest host `meet.localhost:<port>`): only
 *      then is the page a secure context, which `navigator.clipboard` needs.
 *
 * No LiveKit is needed: nothing here joins a call. The anonymous case stops
 * at the guest's landing page and reads the guest's name out of the token
 * the server issued (see `expectLandedAs`).
 *
 * Every context runs in UTC (`timezoneId`), so the app resolves the viewer's
 * zone to Etc/UTC and the expiry line reads "… UTC"; the expected sentence is
 * computed from the fixture's own timestamps, never typed in.
 *
 * Dev has no TLS, so a link is opened with its scheme swapped to http after
 * the https link itself has been asserted.
 *
 * Run with `--retries=0`: a pass that needed a retry is a red.
 */

import { test, expect, Page, Locator } from "@playwright/test"

type Meeting = { id: string; slug: string; starts_at: string; ends_at: string }
type Fixture = {
  tag: string
  login: string
  a: Meeting
  b: Meeting
  member: { id: string; name: string }
  expired: Record<string, { id: string; name: string; url: string }>
}

const FIX: Fixture | null = process.env.GUEST_LINK_FIXTURE
  ? JSON.parse(process.env.GUEST_LINK_FIXTURE)
  : null

const GUEST_HOST = process.env.GUEST_LINK_GUEST_HOST ?? "meet.localhost:4000"
const BASE_URL = process.env.BASE_URL ?? "http://localhost:4000"

const VIEWPORTS = [
  { name: "desktop", width: 1280, height: 800, touch: false },
  { name: "phone", width: 375, height: 812, touch: true },
] as const

const SURFACES = ["meetings", "calendar"] as const
type Surface = (typeof SURFACES)[number]

const HAS_CLASS = (name: string) => new RegExp(`(^|\\s)${name}(\\s|$)`)

const SHORT_LINK = new RegExp(
  `^https://${GUEST_HOST.replace(/[.]/g, "\\.")}/g/[A-Za-z0-9_-]{22}$`,
)

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

/** `Link works until Wed 4 Nov, 21:00 UTC`, in UTC, the server's format
 *  (`Calendar.strftime(local, "%a %-d %b, %H:%M")` plus the UTC suffix). */
function untilUtc(at: Date) {
  const hh = String(at.getUTCHours()).padStart(2, "0")
  const mm = String(at.getUTCMinutes()).padStart(2, "0")
  return `Link works until ${WEEKDAYS[at.getUTCDay()]} ${at.getUTCDate()} ${MONTHS[at.getUTCMonth()]}, ${hh}:${mm} UTC`
}

/** The day part only, for a choice made "now + N" (the minute can tick). */
function untilDayUtc(at: Date) {
  return `Link works until ${WEEKDAYS[at.getUTCDay()]} ${at.getUTCDate()} ${MONTHS[at.getUTCMonth()]},`
}

const isoDate = (iso: string) => iso.slice(0, 10)

function uniqueName(prefix: string) {
  return `${prefix} ${Math.random().toString(36).slice(2, 7)}`
}

// ── helpers ──────────────────────────────────────────────────────────────

async function provePageLive(page: Page) {
  await expect
    .poll(
      () =>
        page.evaluate(
          () =>
            !!(window as any).liveSocket?.isConnected() &&
            !!document.querySelector("[data-phx-main]")?.classList.contains("phx-connected"),
        ),
      { message: "liveSocket and the main view must be connected before anything is measured" },
    )
    .toBe(true)
}

async function press(locator: Locator, touch: boolean) {
  if (touch) await locator.tap()
  else await locator.click()
}

/** Opens `meeting`'s detail surface through the controls a viewer has and
 *  returns it. On /meetings the week is paged until the meeting's day is on
 *  screen, and at 375 its day is picked in the week strip; /calendar is
 *  opened on the meeting's date. Selecting the meeting is the known control:
 *  the surface must appear. */
async function openMeeting(page: Page, surface: Surface, meeting: Meeting, touch: boolean) {
  await page.goto(`/dev/login?as=${FIX!.login}`)
  const day = isoDate(meeting.starts_at)

  if (surface === "meetings") {
    await page.goto("/meetings?view=calendar")
    await provePageLive(page)
    const dayMarker = `[data-role="calendar-day-column"][data-date="${day}"], [data-role="calendar-strip-day"][data-date="${day}"]`

    for (let i = 0; i < 2 && (await page.locator(dayMarker).count()) === 0; i++) {
      const later = day > (await page.locator('[data-role="calendar-strip-day"]').first().getAttribute("data-date"))!
      await press(
        page.locator(`[phx-click="${later ? "calendar_next_week" : "calendar_prev_week"}"]:visible`).first(),
        touch,
      )
      await page.waitForTimeout(400)
    }

    if (touch) {
      await press(page.locator(`[data-role="calendar-strip-day"][data-date="${day}"]`), true)
    }

    await press(
      page.locator(`[data-role="calendar-event"][data-meeting-id="${meeting.id}"]:visible`).first(),
      touch,
    )

    const root = page.locator(
      touch ? '[data-role="meeting-detail-sheet"]' : '[data-role="meeting-detail-panel"]',
    )
    await expect(root.locator('[data-role="meeting-invite-list"]')).toBeVisible()
    return root
  }

  await page.goto(`/calendar?date=${day}`)
  await provePageLive(page)
  await press(
    page.locator(`.cal-ev[data-kind="meeting"][phx-value-id="${meeting.id}"]:visible`).first(),
    touch,
  )
  const root = page.locator('[data-role="calendar-details"]')
  await expect(root.locator('[data-role="meeting-invite-list"]')).toBeVisible()
  return root
}

async function search(page: Page, root: Locator, text: string, touch: boolean) {
  const addPeople = root.locator('[data-role="meeting-invite-add-people"]')
  if ((await root.locator('[data-role="meeting-invite-search"]').count()) === 0) {
    await press(addPeople, touch)
  }
  const field = root.locator('[data-role="meeting-invite-search"]')
  await expect(field).toBeVisible()
  await field.fill("")
  await press(field, touch)
  await page.keyboard.type(text, { delay: 20 })
}

function guestRow(root: Locator, name: string) {
  return root
    .locator('[data-role="meeting-invite-row"]')
    .filter({ has: root.page().locator('[data-role="meeting-invite-row-name"]', { hasText: name }) })
}

/** Types a name, checks the dropdown offers exactly the guest-by-name option
 *  with the canvas copy, picks it, and returns the new row. */
async function addGuestByName(page: Page, root: Locator, name: string, touch: boolean) {
  await search(page, root, name, touch)
  const options = root.locator('[data-role="meeting-invite-option"]')
  await expect(options).toHaveCount(1)
  const option = root.locator('[data-role="meeting-invite-option"][data-option="guest-name"]')
  await expect(option.locator('[data-role="meeting-invite-option-title"]')).toHaveText(
    `Add guest “${name}”`,
  )
  await expect(option.locator('[data-role="meeting-invite-option-detail"]')).toHaveText(
    "you'll share the link",
  )
  await press(option, touch)
  const row = guestRow(root, name)
  await expect(row).toHaveCount(1)
  await expect(row).toHaveAttribute("data-tag", "guest")
  return row
}

async function expiryText(row: Locator) {
  return (await row.locator('[data-role="meeting-invite-expiry-text"]').innerText())
    .replace(/\s+/g, " ")
    .trim()
}

/** The anonymous visitor landed on the guest page of `slug` AS `name`.
 *
 *  The short link 302s to `/<slug>/<token>`, and the token is minted from the
 *  invite row with the guest's name pre-provisioned in its payload, so the
 *  name is read out of the token the server issued, not out of anything this
 *  spec typed. The page itself must accept the link: on a rig with no LiveKit
 *  it says the link is fine and the CALL cannot start, while a refused link
 *  says it is not valid. (01a18d0a's review proved the full call join with a
 *  dev LiveKit; nothing in this task touches that path.) */
async function expectLandedAs(guest: Page, slug: string, name: string) {
  await expect(guest).toHaveURL(new RegExp(`/${slug}/[^/]+$`))
  const token = decodeURIComponent(new URL(guest.url()).pathname.split("/").pop()!)
  const payload = Buffer.from(token.split(".")[1], "base64url").toString("latin1")
  expect(payload, "the issued token names the guest").toContain(name)
  const body = guest.locator("body")
  await expect(body).not.toContainText("not valid")
  await expect(
    guest.locator('[data-role="guest-identity-badge"]').or(body.filter({ hasText: "Your invite link is fine" })),
  ).toBeVisible()
}

async function fitsWhole(el: Locator) {
  return el.evaluate((e) => e.scrollWidth <= e.clientWidth + 1)
}

// ── the cases ────────────────────────────────────────────────────────────

test.describe("guest link by name", () => {
  test.skip(!FIX, "seed with e2e/scripts/seed-meeting-guest-link-fixture.exs first")

  for (const vp of VIEWPORTS) {
    for (const surface of SURFACES) {
      const combo = `${surface}-${vp.name}`

      test.describe(`${surface} @ ${vp.width}x${vp.height}`, () => {
        test.use({
          viewport: { width: vp.width, height: vp.height },
          hasTouch: vp.touch,
          isMobile: vp.touch,
          deviceScaleFactor: vp.touch ? 2 : 1,
          timezoneId: "UTC",
        })

        test("a name becomes a guest row: meeting-end line, Copy link granted, the link admits that guest", async ({
          page,
          context,
          browser,
        }) => {
          await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin: BASE_URL })
          const root = await openMeeting(page, surface, FIX!.a, vp.touch)
          const name = uniqueName("Guest Alpha")
          const row = await addGuestByName(page, root, name, vp.touch)

          expect(await expiryText(row)).toBe(untilUtc(new Date(FIX!.a.ends_at)))
          expect(await fitsWhole(row.locator('[data-role="meeting-invite-row-name"]'))).toBe(true)

          const copy = row.locator('[data-role="meeting-invite-copy"]')
          const status = row.locator('[data-role="meeting-invite-copy-status"]')
          await expect(copy).toHaveText("Copy link")
          await expect(copy).toBeInViewport()
          await expect(copy).toHaveClass(HAS_CLASS("copy-ready"))
          const link = (await copy.getAttribute("data-clipboard-text"))!
          expect(link).toMatch(SHORT_LINK)

          await press(copy, vp.touch)
          await expect(copy).toHaveText("Copied")
          await expect(copy).toHaveClass(HAS_CLASS("copy-copied"))
          await expect(status).toHaveText("Link copied")
          await expect(status).toHaveAttribute("aria-live", "polite")
          expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(link)
          // About two seconds, then back.
          await expect(copy).toHaveText("Copy link", { timeout: 4_000 })
          await expect(copy).not.toHaveClass(HAS_CLASS("copy-copied"))
          await expect(status).toHaveText("")

          const anon = await browser.newContext({ viewport: { width: vp.width, height: vp.height } })
          try {
            const guest = await anon.newPage()
            await guest.goto(link.replace(/^https:/, "http:"))
            await expectLandedAs(guest, FIX!.a.slug, name)
          } finally {
            await anon.close()
          }
        })

        test("Copy link with the clipboard denied never says Copied", async ({ page }) => {
          await page.addInitScript(() => {
            const deny = () => Promise.reject(new DOMException("denied", "NotAllowedError"))
            Object.defineProperty(navigator, "clipboard", {
              value: { writeText: deny, readText: deny },
              configurable: true,
            })
            document.execCommand = () => false
          })
          const root = await openMeeting(page, surface, FIX!.a, vp.touch)
          const row = await addGuestByName(page, root, uniqueName("Guest Beta"), vp.touch)
          const copy = row.locator('[data-role="meeting-invite-copy"]')
          await expect(copy).toHaveClass(HAS_CLASS("copy-ready"))
          await press(copy, vp.touch)
          await expect(copy).toHaveClass(HAS_CLASS("copy-failed"))
          const seen: string[] = []
          for (let i = 0; i < 5; i++) {
            seen.push((await copy.innerText()).trim())
            await page.waitForTimeout(100)
          }
          expect(seen[0]).toBe("Couldn't copy")
          expect(seen).not.toContain("Copied")
          await expect(copy).not.toHaveClass(HAS_CLASS("copy-copied"))
          await expect(row.locator('[data-role="meeting-invite-copy-status"]')).toHaveText(
            "Couldn't copy",
          )
        })

        test("the expiry select moves the line to 7 days, then 24 hours", async ({ page }) => {
          const root = await openMeeting(page, surface, FIX!.a, vp.touch)
          const name = uniqueName("Guest Gamma")
          await addGuestByName(page, root, name, vp.touch)

          const row = () => guestRow(root, name)
          const select = row().locator('[data-role="meeting-invite-expiry-select"]')
          await expect(select).toHaveAttribute("aria-label", `Change link expiry for ${name}`)
          await expect(select.locator("option")).toHaveText([
            "Change",
            "Until the meeting ends",
            "24 hours",
            "7 days",
          ])

          await select.selectOption("days_7")
          const week = new Date(Date.now() + 7 * 86_400_000)
          await expect.poll(() => expiryText(row())).toContain(untilDayUtc(week))

          await row().locator('[data-role="meeting-invite-expiry-select"]').selectOption("hours_24")
          const day = new Date(Date.now() + 86_400_000)
          await expect.poll(() => expiryText(row())).toContain(untilDayUtc(day))
          expect(await expiryText(row())).not.toContain("no scheduled end")
          await expect(row().locator('[data-role="meeting-invite-copy"]')).toHaveText("Copy link")
        })

        test("a meeting with no future end: the 24-hour fallback, two choices", async ({ page }) => {
          const root = await openMeeting(page, surface, FIX!.b, vp.touch)
          const name = uniqueName("Guest Delta")
          const row = await addGuestByName(page, root, name, vp.touch)

          const text = await expiryText(row)
          expect(text).toContain(untilDayUtc(new Date(Date.now() + 86_400_000)))
          expect(text).toMatch(/ UTC · no scheduled end, 24 hours$/)
          await expect(row.locator('[data-role="meeting-invite-expiry-select"] option')).toHaveText([
            "Change",
            "24 hours",
            "7 days",
          ])
        })

        test("an expired row offers New link; the old link is refused and the new one admits", async ({
          page,
          browser,
        }) => {
          const expired = FIX!.expired[combo]
          const root = await openMeeting(page, surface, FIX!.a, vp.touch)
          const old = guestRow(root, expired.name)

          await expect(old.locator('[data-role="meeting-invite-expiry-text"]')).toHaveText(
            "Link expired",
          )
          await expect(old.locator('[data-role="meeting-invite-expiry-select"]')).toHaveCount(0)
          await expect(old.locator("[data-clipboard-text]")).toHaveCount(0)
          const renew = old.locator('[data-role="meeting-invite-renew"]')
          await expect(renew).toHaveText("New link")
          await expect(renew).toBeInViewport()
          await press(renew, vp.touch)

          const fresh = guestRow(root, expired.name)
          await expect(fresh).toHaveCount(1)
          await expect(fresh).not.toHaveAttribute("data-entry-id", expired.id)
          const copy = fresh.locator('[data-role="meeting-invite-copy"]')
          await expect(copy).toHaveText("Copy link")
          const link = (await copy.getAttribute("data-clipboard-text"))!
          expect(link).toMatch(SHORT_LINK)
          expect(link).not.toBe(expired.url)

          const anon = await browser.newContext()
          try {
            const guest = await anon.newPage()
            const refused = await guest.goto(expired.url.replace(/^https:/, "http:"))
            expect(refused!.status()).toBe(404)
            await expect(guest.locator("body")).toContainText("This invite link is not valid")

            await guest.goto(link.replace(/^https:/, "http:"))
            await expectLandedAs(guest, FIX!.a.slug, expired.name)
          } finally {
            await anon.close()
          }
        })

        test("an email still gets the email-guest option; nothing offers a meeting-wide link", async ({
          page,
        }) => {
          const root = await openMeeting(page, surface, FIX!.a, vp.touch)
          await search(page, root, `guest.${FIX!.tag}.${vp.name}@example.com`, vp.touch)
          await expect(root.locator('[data-role="meeting-invite-option"][data-option="guest"]')).toHaveCount(1)
          await expect(
            root.locator('[data-role="meeting-invite-option"][data-option="guest-name"]'),
          ).toHaveCount(0)

          // A member's name is a candidate, never a guest-by-name option.
          await search(page, root, FIX!.member.name, vp.touch)
          await expect(
            root.locator(`[data-role="meeting-invite-candidate"][data-user-id="${FIX!.member.id}"]`),
          ).toHaveCount(1)
          await expect(
            root.locator('[data-role="meeting-invite-option"][data-option="guest-name"]'),
          ).toHaveCount(0)

          // Every clipboard control is a per-row guest copy of a /g/ link.
          const clip = root.locator("[data-clipboard-text]")
          const n = await clip.count()
          expect(n).toBeGreaterThan(0)
          for (let i = 0; i < n; i++) {
            await expect(clip.nth(i)).toHaveAttribute("data-role", "meeting-invite-copy")
            expect(await clip.nth(i).getAttribute("data-clipboard-text")).toMatch(SHORT_LINK)
          }
          const text = (await root.innerText()).toLowerCase()
          expect(text).not.toMatch(/\bshare\b/)
          expect(text).not.toMatch(/\bqr\b/)
          expect(text).not.toContain("meeting link")
          await expect(root.locator('img[alt*="QR" i], canvas, [data-role*="qr" i], [data-role*="share" i]')).toHaveCount(0)
        })
      })
    }
  }
})
