// Real-browser regression for the Ideas tab's view navigation (not part of `mix test`).
//
// The defect it guards: the view buttons used `history.pushState` through a hook,
// so Back / Forward changed the address while the page kept the old view. The
// view buttons are now ordinary links (a full page load per view), and this
// script drives a LOCAL dev server through Chromium to prove the address and
// the visible view agree after every step.
//
// Setup (see scripts/ideas_navigation_seed.exs for the data):
//
//   export MIX_ENV=dev PLATFORM_DEV_DATABASE=<unique db>
//   mix ecto.create -r Platform.Repo && mix ecto.setup
//   mix run scripts/ideas_navigation_seed.exs seed.json
//   # core's JS/CSS with Social's hooks (the stock build aliases @extensions to
//   # nothing): `mix platform.extensions.assets --out gen`, then esbuild js/app.js
//   # with --alias:@extensions=gen/extensions.js, into STATIC_DIR/assets/js
//   PORT=4466 perl -e 'alarm shift; exec @ARGV' 1200 mix phx.server
//
//   BASE=http://localhost:4466 SEED=seed.json STATIC_DIR=<dir with assets/> \
//   PLAYWRIGHT_DIR=<dir whose node_modules holds playwright> \
//   node test/browser/ideas_navigation.browser.mjs
//
// Chromium must launch with --single-process --no-zygote in the agent sandbox,
// which also returns empty bodies from Plug.Static: /assets, /images and /fonts
// are therefore served here from disk through `context.route`.
//
// Exit code 0 when every check passes, 1 otherwise.

import fs from "node:fs"
import path from "node:path"
import { createRequire } from "node:module"

const BASE = process.env.BASE || "http://localhost:4466"
const SEED = JSON.parse(fs.readFileSync(process.env.SEED, "utf8"))
const STATIC_DIR = process.env.STATIC_DIR
const CORE_STATIC = process.env.CORE_STATIC // optional: core's priv/static for /images and /fonts
const require = createRequire((process.env.PLAYWRIGHT_DIR || process.cwd()) + "/")
const { chromium } = require("playwright")

const [ALPHA, BRAVO] = SEED.brands
const LABEL = { all: "All ideas", voted: "With votes", selected: "Selected for research" }
const MIME = { ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".woff2": "font/woff2", ".woff": "font/woff", ".ttf": "font/ttf", ".json": "application/json" }

let failures = 0
let checks = 0
const log = (m) => console.log(m)

function check(ok, label, detail = "") {
  checks++
  if (ok) log(`  PASS ${label}`)
  else {
    failures++
    log(`  FAIL ${label} ${detail}`)
  }
  return ok
}

async function serveStatic(context) {
  await context.route(/\/(assets|images|fonts)\//, async (route) => {
    const url = new URL(route.request().url())
    for (const root of [STATIC_DIR, CORE_STATIC].filter(Boolean)) {
      const file = path.join(root, decodeURIComponent(url.pathname))
      if (file.startsWith(root) && fs.existsSync(file) && fs.statSync(file).isFile()) {
        return route.fulfill({ status: 200, body: fs.readFileSync(file), contentType: MIME[path.extname(file)] || "application/octet-stream" })
      }
    }
    return route.fulfill({ status: 404, body: "" })
  })
}

// The address and what the page shows, read together.
async function snapshot(page) {
  const url = new URL(page.url())
  const dom = await page.evaluate(() => {
    const active = document.querySelector("[data-role='ideas-view-tab'][aria-current='page']")
    const heading = document.querySelector("#ideas-view-heading")
    const list = document.querySelector("#ideas-list")
    const titles = [...document.querySelectorAll("#ideas-list [data-role='idea-card-title'], #ideas-list li")].map((el) => el.textContent.trim())
    return {
      activeView: active ? active.dataset.view : null,
      heading: heading ? heading.textContent.trim() : null,
      listView: list ? list.dataset.view : null,
      text: document.querySelector("#ideas-list") ? document.querySelector("#ideas-list").textContent : "",
      titles,
    }
  })
  const shownBrands = [ALPHA, BRAVO].filter((b) => dom.text.includes(b.name)).map((b) => b.name)
  return { search: url.search, view: url.searchParams.get("view"), profile: url.searchParams.get("profile"), tab: url.searchParams.get("tab"), ...dom, shownBrands }
}

// Wait until the page has an Ideas tab with a connected LiveView; a link click is a
// full load, so this also covers the new document.
async function ready(page) {
  await page.waitForSelector("#social-ideas", { state: "attached", timeout: 15000 })
  await page.waitForFunction(() => document.querySelector(".phx-connected") !== null, null, { timeout: 15000 })
}

// Poll until the visible view equals `want` (or time out), then assert agreement
// between the address and the page.
async function expectView(page, label, want, brandScope) {
  const deadline = Date.now() + 4000
  let s
  do {
    s = await snapshot(page).catch(() => ({ activeView: null }))
    if (s.activeView === want) break
    await page.waitForTimeout(150)
  } while (Date.now() < deadline)
  const addressView = s.view || "all"
  check(s.activeView === want, `${label}: visible view is ${want}`, `(active=${s.activeView} address=${s.search})`)
  check(s.listView === want && s.heading === LABEL[want], `${label}: heading and list say ${want}`, `(heading=${s.heading} list=${s.listView})`)
  check(addressView === want, `${label}: address view agrees (${want})`, `(address=${s.search})`)
  if (brandScope === "all") {
    check(s.profile === "all", `${label}: address profile=all`, `(address=${s.search})`)
    check(s.shownBrands.length === 2, `${label}: both brands shown`, `(shown=${s.shownBrands})`)
  } else if (brandScope) {
    check(s.profile === brandScope.id, `${label}: address profile is ${brandScope.name}`, `(address=${s.search})`)
    check(s.shownBrands.length === 1 && s.shownBrands[0] === brandScope.name, `${label}: only ${brandScope.name} shown`, `(shown=${s.shownBrands})`)
  }
  return s
}

async function clickView(page, view) {
  await page.click(`[data-role='ideas-view-tab'][data-view='${view}']`)
  await ready(page).catch(() => {})
}

async function back(page) {
  await page.goBack({ waitUntil: "load" }).catch(() => {})
  await ready(page).catch(() => {})
}

async function forward(page) {
  await page.goForward({ waitUntil: "load" }).catch(() => {})
  await ready(page).catch(() => {})
}

async function open(page, query) {
  await page.goto(`${BASE}/m/social?${query}`, { waitUntil: "load" })
  await ready(page)
}

// All -> With votes -> Selected, Back, Back, Forward; reload; the same URL in a new page.
async function walk(context, page, label, query, scope) {
  log(`\n== ${label} (${query})`)
  await open(page, query)
  await expectView(page, `${label}: load`, "all", scope)
  await clickView(page, "voted")
  await expectView(page, `${label}: click With votes`, "voted", scope)
  await clickView(page, "selected")
  await expectView(page, `${label}: click Selected`, "selected", scope)
  await back(page)
  await expectView(page, `${label}: Back`, "voted", scope)
  await back(page)
  await expectView(page, `${label}: Back again`, "all", scope)
  await forward(page)
  await expectView(page, `${label}: Forward`, "voted", scope)

  const url = page.url()
  await page.reload({ waitUntil: "load" })
  await ready(page)
  await expectView(page, `${label}: reload keeps the view`, "voted", scope)

  const other = await context.newPage()
  await other.goto(url, { waitUntil: "load" })
  await ready(other)
  await expectView(other, `${label}: same URL in a new page`, "voted", scope)
  await other.close()
}

let browser
try {
  // A single-process Chromium cannot open a second context after closing one, so
  // every session launches its own browser.
  const newSession = async () => {
    if (browser) await browser.close().catch(() => {})
    browser = await chromium.launch({ args: ["--single-process", "--no-zygote"] })
    const context = await browser.newContext({ viewport: { width: 1100, height: 900 } })
    await serveStatic(context)
    const page = await context.newPage()
    page.on("pageerror", (e) => log(`  (page error: ${e.message})`))
    await page.goto(`${BASE}/dev/login?as=ideasnav`, { waitUntil: "load" })
    check(!page.url().includes("/dev/login"), "signed in via /dev/login")
    return { context, page }
  }

  // 1. One brand. Repeated, each try in a fresh browser context (a single-process
  // Chromium holds one context at a time): the old defect was a race.
  const REPEAT = Number(process.env.REPEAT || 5)
  for (let i = 1; i <= REPEAT; i++) {
    const { context, page } = await newSession()
    await walk(context, page, `one brand #${i}`, `tab=ideas&profile=${ALPHA.id}`, ALPHA)
  }

  const { context, page } = await newSession()

  // 2. All brands (profile=all).
  await walk(context, page, "all brands", "tab=ideas&profile=all", "all")

  // 3. Back / Forward after a brand change. The brand switcher is in-page (it
  // writes no address), so the links rendered afterwards must carry the brand
  // that is SHOWN: the next click's address is then truthful.
  {
    const label = "brand change"
    log(`\n== ${label}`)
    await open(page, `tab=ideas&profile=${ALPHA.id}&view=voted`)
    await expectView(page, `${label}: Alpha, With votes`, "voted", ALPHA)
    await page.selectOption("#social-profile-select", BRAVO.id)
    await page.waitForFunction((n) => document.querySelector("#ideas-list")?.textContent.includes(n), BRAVO.name, { timeout: 8000 }).catch(() => {})
    const mid = await snapshot(page)
    check(mid.shownBrands.length === 1 && mid.shownBrands[0] === BRAVO.name, `${label}: switcher shows Bravo`, `(shown=${mid.shownBrands})`)
    await clickView(page, "selected")
    await expectView(page, `${label}: Selected after the switch`, "selected", BRAVO)
    await back(page)
    await expectView(page, `${label}: Back`, "voted", ALPHA)
    await forward(page)
    await expectView(page, `${label}: Forward`, "selected", BRAVO)
  }

  // 4. Ideas -> Queue -> Ideas. The shell's tab buttons are server-side and
  // write no address (the same on main); the Ideas tab must not write one either.
  {
    const label = "tabs"
    log(`\n== ${label}`)
    await open(page, `tab=ideas&profile=${ALPHA.id}&view=voted`)
    const before = page.url()
    await page.click("[data-role='social-tab-button'][data-tab='queue']")
    await page.waitForFunction(() => document.querySelector("[data-role='social-tab-button'][data-tab='queue'][aria-selected='true']"), null, { timeout: 8000 }).catch(() => {})
    const queueActive = await page.evaluate(() => document.querySelector("[data-role='social-tab-button'][data-tab='queue']")?.getAttribute("aria-selected"))
    check(queueActive === "true", `${label}: Queue is the active tab`)
    check(page.url() === before, `${label}: leaving Ideas writes no address`, `(before=${before} after=${page.url()})`)
    log(`  INFO address while on Queue: ${page.url()} (main behaves the same for Clips)`)
    await page.click("[data-role='social-tab-button'][data-tab='ideas']")
    await page.waitForFunction(() => document.querySelector("#ideas-list"), null, { timeout: 8000 }).catch(() => {})
    await expectView(page, `${label}: back on Ideas keeps With votes`, "voted", ALPHA)
    await clickView(page, "selected")
    await expectView(page, `${label}: Selected after Queue`, "selected", ALPHA)
    await back(page)
    await expectView(page, `${label}: Back`, "voted", ALPHA)
  }
} finally {
  if (browser) await browser.close().catch(() => {})
}

log(`\n${checks - failures}/${checks} checks passed`)
process.exit(failures === 0 ? 0 : 1)
