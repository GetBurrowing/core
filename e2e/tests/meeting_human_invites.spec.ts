/**
 * The name-first Invite control inside a live call's HUMANS list
 * (task 01a18d0a-ec37 stage 3), driven in a real browser on both call
 * surfaces (`/meetings/<slug>` and the in-chat quickmeet) at 1280x800 and
 * at 375x812 with touch.
 *
 * PRECONDITIONS (all from the dev server the spec points at):
 *   1. `GET /dev/login?as=<login>` once, so the viewer's user row exists.
 *   2. `mix run ../../e2e/scripts/seed-meeting-human-invite-fixture.exs` in
 *      the server's container. Its last line is `FIXTURE <json>`; pass the
 *      json as HUMAN_INVITE_FIXTURE.
 *   3. A reachable LiveKit (LIVEKIT_URL / KEY / SECRET on the server). The
 *      quickmeet rail exists only while `:in_meeting`, and "the call stays
 *      connected" is read off `#meeting-client[data-room-state]`.
 *   4. MEETING_GUEST_HOST set to a host Chromium can reach. Pass the same
 *      host as HUMAN_INVITE_GUEST_HOST and, when it has no DNS, a
 *      HUMAN_INVITE_HOST_RULES value for `--host-resolver-rules`
 *      (e.g. `MAP meet.e2e.test 192.0.2.10`).
 *
 * Dev has no TLS, so the anonymous case opens the short link with its
 * scheme swapped to http, after asserting the full https link as shown.
 *
 * CLIPBOARD. Both origins are marked secure for Chromium
 * (`--unsafely-treat-insecure-origin-as-secure`), so `navigator.clipboard`
 * exists. "Granted" grants clipboard-read/write and reads the copied text
 * back. "Denied" makes `writeText` reject and the `execCommand` fallback
 * fail, which is what a browser that refuses both looks like to the hook.
 *
 * Run with `--retries=0`: a pass that needed a retry is a red.
 */

import { test, expect, Page, Locator, BrowserContext } from "@playwright/test"

type Fixture = {
  tag: string
  login: string
  meeting_slug: string
  space_slug: string
  users: Record<"first" | "second" | "long", { id: string; name: string; email: string }>
}

const FIX: Fixture | null = process.env.HUMAN_INVITE_FIXTURE
  ? JSON.parse(process.env.HUMAN_INVITE_FIXTURE)
  : null

const BASE_URL = process.env.BASE_URL ?? "http://localhost:4000"
const GUEST_HOST = process.env.HUMAN_INVITE_GUEST_HOST ?? "meet.localhost:4000"
const HOST_RULES = process.env.HUMAN_INVITE_HOST_RULES

const secureOrigins = [BASE_URL, `http://${GUEST_HOST}`].join(",")

test.use({
  launchOptions: {
    args: [
      "--use-fake-device-for-media-stream",
      "--use-fake-ui-for-media-stream",
      "--autoplay-policy=no-user-gesture-required",
      `--unsafely-treat-insecure-origin-as-secure=${secureOrigins}`,
      ...(HOST_RULES ? [`--host-resolver-rules=${HOST_RULES}`] : []),
    ],
  },
})

const VIEWPORTS = [
  { name: "desktop", width: 1280, height: 800, touch: false },
  { name: "phone", width: 375, height: 812, touch: true },
] as const

const SURFACES = ["meetings", "quickmeet"] as const
type Surface = (typeof SURFACES)[number]

const SHORT_LINK = (host: string) =>
  new RegExp(`^https://${host.replace(/[.]/g, "\\.")}/g/[A-Za-z0-9_-]{22}$`)

// ── helpers ──────────────────────────────────────────────────────────────

async function provePageLive(page: Page) {
  await expect
    .poll(() => page.evaluate(() => !!(window as any).liveSocket?.isConnected()), {
      message: "liveSocket must be connected before anything is measured",
    })
    .toBe(true)
}

async function roomState(page: Page): Promise<string | null> {
  return page.evaluate(
    () => document.querySelector<HTMLElement>("#meeting-client")?.dataset.roomState ?? null,
  )
}

async function expectConnected(page: Page) {
  await expect.poll(() => roomState(page), { timeout: 45_000 }).toBe("connected")
}

/** Signs in, opens the surface, presses Join (the known control), proves the
 *  call connected, and returns the rail the control lives in. */
async function openSurface(page: Page, surface: Surface, phone: boolean): Promise<Locator> {
  const fix = FIX!
  await page.goto(`/dev/login?as=${fix.login}`)

  if (surface === "meetings") {
    await page.goto(`/meetings/${fix.meeting_slug}?no_autojoin=true`)
    await provePageLive(page)
    await page.locator('[data-role="meeting-join"]:visible').first().click()
  } else {
    await page.goto(`/chat/${fix.space_slug}`)
    await provePageLive(page)
    await page.locator('[phx-click="meeting_join"]:visible').first().click()
  }

  await expectConnected(page)

  const rail = page.locator(surface === "meetings" ? "#meeting-call-rail" : "#quickmeet-call-rail")
  if (phone) await openPhoneSheet(page, surface)
  await expect(rail.locator('[data-role="meeting-human-invite-search"]')).toBeVisible()
  return rail
}

async function openPhoneSheet(page: Page, surface: Surface) {
  const toggle =
    surface === "meetings"
      ? page.locator('[phx-click="toggle_call_rail"]:visible').first()
      : page.locator('[data-role="quickmeet-rail-toggle"]:visible').first()
  await toggle.tap()
}

async function closePhoneSheet(page: Page, surface: Surface) {
  const close =
    surface === "meetings"
      ? page.locator("#meeting-rail-sheet .sheet-close-button:visible").first()
      : page.locator('[data-role="quickmeet-rail-close"]:visible').first()
  await close.tap()
}

async function typeName(page: Page, rail: Locator, text: string, touch: boolean) {
  const field = rail.locator('[data-role="meeting-human-invite-search"]')
  if (touch) await field.tap()
  else await field.click()
  await page.keyboard.type(text, { delay: 25 })
}

async function choose(locator: Locator, touch: boolean) {
  if (touch) await locator.tap()
  else await locator.click()
}

async function createGuest(page: Page, rail: Locator, name: string, touch: boolean) {
  await typeName(page, rail, name, touch)
  const guest = rail.locator('[data-role="meeting-human-invite-guest"]')
  await expect(guest).toContainText(`Invite "${name}" as guest`)
  await choose(guest, touch)
  const result = rail.locator('[data-role="meeting-human-invite-result"]')
  await expect(result).toBeVisible()
  const link = (await rail.locator('[data-role="meeting-human-invite-link"]').innerText()).trim()
  return { result, link }
}

/** True when an element's text fits without truncation or clipping. */
async function fitsWhole(el: Locator) {
  return el.evaluate((e) => e.scrollWidth <= e.clientWidth + 1)
}

function uniqueName(prefix: string) {
  return `${prefix} ${Math.random().toString(36).slice(2, 7)}`
}

// ── cases ────────────────────────────────────────────────────────────────

test.describe("human invite control", () => {
  test.skip(!FIX, "seed with e2e/scripts/seed-meeting-human-invite-fixture.exs first")

  for (const vp of VIEWPORTS) {
    for (const surface of SURFACES) {
      test.describe(`${surface} @ ${vp.width}x${vp.height}`, () => {
        test.use({
          viewport: { width: vp.width, height: vp.height },
          hasTouch: vp.touch,
          isMobile: vp.touch,
          deviceScaleFactor: vp.touch ? 2 : 1,
        })

        test("user rows then the guest row; a user invite; long name stays whole", async ({
          page,
        }) => {
          const fix = FIX!
          const rail = await openSurface(page, surface, vp.touch)

          // The control is nested in the humans section.
          await expect(
            rail.locator('[data-section="humans"] [data-role="meeting-human-invite"]'),
          ).toHaveCount(1)

          await typeName(page, rail, fix.tag, vp.touch)
          const dropdown = rail.locator('[data-role="meeting-human-invite-dropdown"]')
          await expect(dropdown).toBeVisible()

          const rows = dropdown.locator(":scope > button")
          await expect(rows.last()).toHaveAttribute("data-role", "meeting-human-invite-guest")
          for (const key of ["first", "second", "long"] as const) {
            await expect(
              dropdown.locator(
                `[data-role="meeting-human-invite-user"][data-user-id="${fix.users[key].id}"]`,
              ),
            ).toHaveCount(1)
          }
          await expect(rows.last()).toContainText(`Invite "${fix.tag}" as guest`)
          await expect(rows.last()).toContainText("email optional")

          // Truncation order: the long name is whole, the long email is cut.
          const longRow = dropdown.locator(
            `[data-role="meeting-human-invite-user"][data-user-id="${fix.users.long.id}"]`,
          )
          const longName = longRow.locator('[data-role="meeting-human-invite-user-name"]')
          const longEmail = longRow.locator('[data-role="meeting-human-invite-user-email"]')
          await expect(longName).toHaveText(fix.users.long.name)
          expect(await fitsWhole(longName), "the name must not be truncated").toBe(true)
          expect(await fitsWhole(longEmail), "the email must truncate first").toBe(false)

          // A user invite through the existing path. Only invite the first
          // user once per surface: the resolver drops them afterwards.
          const firstRow = dropdown.locator(
            `[data-role="meeting-human-invite-user"][data-user-id="${fix.users.first.id}"]`,
          )
          if ((await firstRow.count()) === 1) {
            await choose(firstRow, vp.touch)
            await expect(dropdown).toHaveCount(0)
            await typeName(page, rail, fix.tag, vp.touch)
            await expect(rail.locator('[data-role="meeting-human-invite-dropdown"]')).toBeVisible()
            await expect(
              rail.locator(
                `[data-role="meeting-human-invite-user"][data-user-id="${fix.users.first.id}"]`,
              ),
            ).toHaveCount(0)
            // Already invited: the guest row is still offered.
            await expect(rail.locator('[data-role="meeting-human-invite-guest"]')).toBeVisible()
          }

          await expectConnected(page)
        })

        test("guest link: full link, Copy granted, optional email valid and invalid", async ({
          page,
          context,
        }) => {
          await context.grantPermissions(["clipboard-read", "clipboard-write"], {
            origin: BASE_URL,
          })
          const rail = await openSurface(page, surface, vp.touch)
          const name = uniqueName("Visitor")
          const { link } = await createGuest(page, rail, name, vp.touch)

          expect(link).toMatch(SHORT_LINK(GUEST_HOST))
          const linkEl = rail.locator('[data-role="meeting-human-invite-link"]')
          await expect(linkEl).toBeInViewport()
          expect(
            await linkEl.evaluate((e) => getComputedStyle(e).textOverflow),
            "the link is never ellipsized",
          ).not.toBe("ellipsis")
          expect(await fitsWhole(linkEl), "the whole link is shown").toBe(true)
          // The field cleared after the invite.
          await expect(rail.locator('[data-role="meeting-human-invite-search"]')).toHaveValue("")

          const copy = rail.locator('[data-role="meeting-human-invite-copy"]')
          await choose(copy, vp.touch)
          await expect(copy).toHaveText("Copied")
          await expect(copy).toHaveAttribute("data-copy-state", "copied")
          expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(link)

          // Optional email: invalid first, then valid.
          await choose(rail.locator('[data-role="meeting-human-invite-add-email"]'), vp.touch)
          const email = rail.locator('[data-role="meeting-human-invite-email"]')
          await email.fill("not an address")
          await choose(rail.locator('[data-role="meeting-human-invite-email-save"]'), vp.touch)
          await expect(rail.locator('[data-role="meeting-human-invite-email-error"]')).toBeVisible()
          await expect(linkEl).toHaveText(link)

          await email.fill("visitor@example.com")
          await choose(rail.locator('[data-role="meeting-human-invite-email-save"]'), vp.touch)
          await expect(rail.locator('[data-role="meeting-human-invite-email-saved"]')).toHaveText(
            "visitor@example.com",
          )
          await expect(rail.locator('[data-role="meeting-human-invite-email-error"]')).toHaveCount(0)

          await choose(rail.locator('[data-role="meeting-human-invite-dismiss"]'), vp.touch)
          await expect(rail.locator('[data-role="meeting-human-invite-result"]')).toHaveCount(0)
          await expectConnected(page)
        })

        test("Copy link with the clipboard denied never says Copied and keeps the link", async ({
          page,
        }) => {
          await page.addInitScript(() => {
            const deny = () => Promise.reject(new DOMException("denied", "NotAllowedError"))
            Object.defineProperty(navigator, "clipboard", {
              value: { writeText: deny, readText: deny },
              configurable: true,
            })
            document.execCommand = () => false
          })
          const rail = await openSurface(page, surface, vp.touch)
          const { link } = await createGuest(page, rail, uniqueName("Visitor"), vp.touch)

          const copy = rail.locator('[data-role="meeting-human-invite-copy"]')
          const seen: string[] = []
          await choose(copy, vp.touch)
          await expect(copy).toHaveAttribute("data-copy-state", "failed")
          for (let i = 0; i < 5; i++) {
            seen.push((await copy.innerText()).trim())
            await page.waitForTimeout(100)
          }
          expect(seen).not.toContain("Copied")
          expect(seen[0]).toBe("Couldn't copy")
          await expect(rail.locator('[data-role="meeting-human-invite-link"]')).toHaveText(link)
        })

        if (vp.touch) {
          test("the participant sheet opens and closes with the call still connected", async ({
            page,
          }) => {
            const rail = await openSurface(page, surface, true)
            const field = rail.locator('[data-role="meeting-human-invite-search"]')
            await closePhoneSheet(page, surface)
            await expect(field).not.toBeInViewport()
            await expectConnected(page)
            await openPhoneSheet(page, surface)
            await expect(field).toBeVisible()
            await expectConnected(page)
          })
        }

        test("the short link lands an anonymous browser in the meeting as the named guest", async ({
          page,
          browser,
        }) => {
          const rail = await openSurface(page, surface, vp.touch)
          const name = uniqueName("Visitor")
          const { link } = await createGuest(page, rail, name, vp.touch)
          expect(link).toMatch(SHORT_LINK(GUEST_HOST))

          const anon: BrowserContext = await browser.newContext({
            viewport: { width: vp.width, height: vp.height },
          })
          try {
            const guest = await anon.newPage()
            await guest.goto(link.replace(/^https:/, "http:"))
            await expect(guest).toHaveURL(new RegExp(`/${FIX!.meeting_slug}/[^/]+$`))
            await provePageLive(guest)
            await expect
              .poll(
                () =>
                  guest.evaluate(() => {
                    const room = (window as any).__livekitRoom
                    return room?.state === "connected" ? room.localParticipant?.name : null
                  }),
                { timeout: 45_000 },
              )
              .toBe(`${name} (guest)`)
          } finally {
            await anon.close()
          }
          await expectConnected(page)
        })
      })
    }
  }
})
