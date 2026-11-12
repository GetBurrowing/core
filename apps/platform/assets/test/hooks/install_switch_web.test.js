import { describe, it, expect, vi, afterEach } from "vitest"
import NativeInstallSwitch from "../../js/hooks/native_install_switch.js"
import { __resetWebSwitchForTests } from "../../js/hooks/install_switch_web.js"
import {
  STORAGE_KEY,
  PENDING_KEY,
  TOAST_KEY,
  allowedOrigin,
  originFromInput,
  parseUnread,
  readList,
  runPool,
  applyResult,
  safeReturnPath,
  fetchUnread
} from "../../js/lib/install_switch_store.js"
import SwitcherConnected, { completeConnect } from "../../js/hooks/switcher_connected.js"
import { fakeDoc, fakeStorage, switchButton } from "../lib/switcher_fake_dom.js"

/**
 * The web path of the install switcher (task 01a1ccd4 stage 3), driven
 * through the real NativeInstallSwitch hook with a stubbed window/document.
 * Named mutations this file must catch: M5 credentials "include", M6 the
 * name rendered with innerHTML, M7 the dot on a malformed answer, M8 the web
 * path running when the native plugin exists. Stage 4: M10 the connected
 * page skipping the hop/host check, M11 the key left in the address bar (no
 * replaceState), and a Referer on a navigation to another install.
 */

const KEY_B = "bk_" + "b".repeat(43)
const KEY_C = "bk_" + "c".repeat(43)
const AS_OF = "2026-11-12T01:00:00Z"
const LATER = "2026-11-12T01:05:00Z"

const entry = (origin, extra = {}) => ({
  origin,
  name: extra.name || new URL(origin).host,
  host: new URL(origin).host,
  key: KEY_B,
  added_at: "2026-11-11T00:00:00Z",
  ...extra
})

const answer = (status, body) => ({
  status,
  ok: status >= 200 && status < 300,
  json: async () => {
    if (body instanceof Error) throw body
    return body
  }
})

const flush = async () => {
  for (let i = 0; i < 40; i++) await Promise.resolve()
}

function setup({ entries = [], fetch, plugin, native = false, session, image } = {}) {
  const doc = fakeDoc()
  const local = fakeStorage({ [STORAGE_KEY]: JSON.stringify(entries) })
  const sess = session || fakeStorage()
  const location = {
    origin: "https://a.example",
    host: "a.example",
    pathname: "/chat/general",
    search: "?x=1",
    assign: vi.fn(),
    replace: vi.fn()
  }
  const listeners = {}
  const win = {
    location,
    localStorage: local,
    sessionStorage: sess,
    fetch: fetch || vi.fn(async () => answer(200, { unread: 0, as_of: AS_OF })),
    listeners,
    addEventListener: (t, fn) => (listeners[t] ||= []).push(fn),
    removeEventListener: (t, fn) => {
      listeners[t] = (listeners[t] || []).filter(f => f !== fn)
    }
  }
  if (plugin || native) {
    win.Capacitor = {
      isNativePlatform: () => true,
      Plugins: plugin ? { SuiteNative: plugin } : {}
    }
  }
  if (image) win.Image = image
  vi.stubGlobal("window", win)
  vi.stubGlobal("document", doc)
  const { button, dot, menu } = switchButton(doc)
  const hook = Object.assign(Object.create(NativeInstallSwitch), { el: button })
  hook.mounted()
  return { doc, win, local, sess, location, button, dot, menu, hook }
}

const visible = el => !el.classList.contains("hidden")
const open = async ctx => {
  ctx.button.click()
  await flush()
  return ctx.menu.querySelector("[data-role='install-switch-panel']")
}
const rowFor = (menu, origin) =>
  menu.querySelectorAll("[data-role='install-row']").find(r => r.getAttribute("data-origin") === origin)

afterEach(() => {
  __resetWebSwitchForTests()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe("the native path is unchanged when the plugin exists (M8)", () => {
  it("never reads the list, never fetches, never draws a dropdown; a tap calls switchInstall", async () => {
    const switchInstall = vi.fn(async () => {})
    const fetch = vi.fn()
    const ctx = setup({
      entries: [entry("https://b.example")],
      fetch,
      plugin: { installBadges: async () => ({ others_unread: true }), switchInstall }
    })
    await flush()

    ctx.button.click()
    await flush()

    expect(switchInstall).toHaveBeenCalledTimes(1)
    expect(fetch).not.toHaveBeenCalled()
    expect(ctx.local.reads).toBe(0)
    expect(ctx.menu.childNodes).toHaveLength(0)
    expect(ctx.button.getAttribute("aria-expanded")).toBe(null)
    // the native dot still comes from installBadges
    expect(visible(ctx.dot)).toBe(true)
  })

  it("a native build WITHOUT installBadges keeps today's hidden, inert button", async () => {
    const fetch = vi.fn()
    const ctx = setup({ entries: [entry("https://b.example")], fetch, native: true })
    await flush()
    expect(visible(ctx.button)).toBe(false)
    expect(fetch).not.toHaveBeenCalled()
  })
})

describe("the web path", () => {
  it("reveals the button in a browser", async () => {
    const ctx = setup()
    await flush()
    expect(visible(ctx.button)).toBe(true)
    expect(ctx.button.classList.contains("flex")).toBe(true)
  })

  it("re-reveals after a LiveView patch puts the server's hidden class back", async () => {
    const ctx = setup()
    ctx.button.setAttribute("class", "hidden -ml-1")
    ctx.hook.updated()
    expect(visible(ctx.button)).toBe(true)
  })

  it("fetches each other install with the badge key, no cookie, no referrer (M5)", async () => {
    const fetch = vi.fn(async () => answer(200, { unread: 2, as_of: AS_OF }))
    setup({ entries: [entry("https://b.example")], fetch })
    await flush()

    expect(fetch).toHaveBeenCalledTimes(1)
    const [url, opts] = fetch.mock.calls[0]
    expect(url).toBe("https://b.example/api/switcher/unread")
    expect(opts.credentials).toBe("omit")
    expect(opts.referrerPolicy).toBe("no-referrer")
    expect(opts.mode).toBe("cors")
    expect(opts.redirect).toBe("error")
    expect(opts.headers).toEqual({ Authorization: "Bearer " + KEY_B })
    expect(url).not.toContain(KEY_B)
  })

  it("never fetches the current install from the list", async () => {
    const fetch = vi.fn(async () => answer(200, { unread: 2, as_of: AS_OF }))
    setup({ entries: [entry("https://a.example"), entry("https://b.example")], fetch })
    await flush()
    expect(fetch.mock.calls.map(c => c[0])).toEqual(["https://b.example/api/switcher/unread"])
  })

  it("lights the closed dot when another install has unread", async () => {
    const ctx = setup({
      entries: [entry("https://b.example")],
      fetch: vi.fn(async () => answer(200, { unread: 3, as_of: AS_OF }))
    })
    await flush()
    expect(visible(ctx.dot)).toBe(true)
    expect(ctx.button.getAttribute("aria-label")).toBe(
      "Switch install, current: Acme, other installs have unread"
    )
  })

  it("no dot when every other install is at zero", async () => {
    const ctx = setup({ entries: [entry("https://b.example")] })
    await flush()
    expect(visible(ctx.dot)).toBe(false)
    expect(ctx.button.getAttribute("aria-label")).toBe("Switch install, current: Acme")
  })

  for (const [label, body] of [
    ["a string count", { unread: "3", as_of: AS_OF }],
    ["a fractional count", { unread: 2.5, as_of: AS_OF }],
    ["a negative count", { unread: -1, as_of: AS_OF }],
    ["a missing as_of", { unread: 3 }],
    ["a non-ISO as_of", { unread: 3, as_of: "yesterday" }],
    ["an array", [3]],
    ["null", null],
    // Stage 4: a hostile install's extra fields are not a valid answer.
    ["extra fields", { unread: 4, as_of: AS_OF, name: "<img src=x onerror=alert(1)>", nested: { unread: 9 } }]
  ]) {
    it(`a malformed answer (${label}) hides the dot and the count (M7)`, async () => {
      const ctx = setup({ entries: [entry("https://b.example")], fetch: vi.fn(async () => answer(200, body)) })
      await flush()
      expect(visible(ctx.dot)).toBe(false)
      const panel = await open(ctx)
      expect(panel.querySelector("[data-role='install-row-count']")).toBe(null)
    })
  }

  it("an oversized body is refused without being read to the end (stage 4)", async () => {
    const big = new TextEncoder().encode(JSON.stringify({ unread: 5, as_of: AS_OF, pad: "x".repeat(10000) }))
    let reads = 0
    let cancelled = false
    const streamed = {
      status: 200,
      ok: true,
      headers: { get: () => null },
      body: {
        getReader: () => ({
          read: async () => {
            const at = reads++ * 1024
            return at >= big.length ? { done: true } : { done: false, value: big.slice(at, at + 1024) }
          },
          cancel: async () => {
            cancelled = true
          }
        })
      },
      json: async () => {
        throw new Error("must not buffer the whole body")
      }
    }
    expect(await fetchUnread(entry("https://b.example"), { fetch: async () => streamed })).toEqual({ kind: "rejected" })
    expect(cancelled).toBe(true)
    expect(reads).toBeLessThanOrEqual(5)

    const declared = { status: 200, ok: true, headers: { get: h => (h === "content-length" ? "5242880" : null) }, json: async () => ({ unread: 5, as_of: AS_OF }) }
    expect(await fetchUnread(entry("https://b.example"), { fetch: async () => declared })).toEqual({ kind: "rejected" })

    const small = new TextEncoder().encode(JSON.stringify({ unread: 5, as_of: AS_OF }))
    let done = false
    const ok = {
      status: 200,
      ok: true,
      headers: { get: () => String(small.length) },
      body: { getReader: () => ({ read: async () => (done ? { done: true } : ((done = true), { done: false, value: small })) }) }
    }
    expect(await fetchUnread(entry("https://b.example"), { fetch: async () => ok })).toEqual({ kind: "ok", unread: 5, as_of: AS_OF })
  })

  it("a body that is not JSON hides the dot (M7)", async () => {
    const ctx = setup({
      entries: [entry("https://b.example")],
      fetch: vi.fn(async () => answer(200, new SyntaxError("bad json")))
    })
    await flush()
    expect(visible(ctx.dot)).toBe(false)
  })

  it("a rejected answer after an 'on' one turns the dot OFF", async () => {
    const fetch = vi
      .fn()
      .mockResolvedValueOnce(answer(200, { unread: 4, as_of: AS_OF }))
      .mockResolvedValueOnce(answer(403, { error: "no" }))
    const ctx = setup({ entries: [entry("https://b.example")], fetch })
    await flush()
    expect(visible(ctx.dot)).toBe(true)

    ctx.doc.fire("visibilitychange")
    await flush()
    expect(visible(ctx.dot)).toBe(false)
  })

  it("401 marks the row reconnect: Unread paused + Reconnect, no count, no dot, key dropped", async () => {
    const ctx = setup({
      entries: [entry("https://b.example", { unread: 5, as_of: AS_OF })],
      fetch: vi.fn(async () => answer(401, { error: "unauthorized" }))
    })
    await flush()
    expect(visible(ctx.dot)).toBe(false)

    const panel = await open(ctx)
    const row = rowFor(panel, "https://b.example")
    expect(row.getAttribute("data-status")).toBe("reconnect")
    expect(row.querySelector("[data-role='install-row-sub']").textContent).toBe("Unread paused")
    expect(row.querySelector("[data-role='install-row-count']")).toBe(null)
    expect(panel.querySelector("[data-role='install-row-reconnect']").textContent).toBe("Reconnect")
    expect(readList(ctx.local)[0].key).toBe(null)
  })

  it("a network failure keeps the last count, marks it stale, and the stale count still lights the dot", async () => {
    const fetch = vi
      .fn()
      .mockResolvedValueOnce(answer(200, { unread: 7, as_of: AS_OF }))
      .mockRejectedValueOnce(new TypeError("Failed to fetch"))
    const ctx = setup({ entries: [entry("https://b.example")], fetch })
    await flush()
    ctx.doc.fire("visibilitychange")
    await flush()

    expect(visible(ctx.dot)).toBe(true)
    const panel = await open(ctx)
    const row = rowFor(panel, "https://b.example")
    expect(row.getAttribute("data-status")).toBe("stale")
    expect(row.querySelector("[data-role='install-row-sub']").textContent).toBe("Could not update")
    expect(row.querySelector("[data-role='install-row-count']").textContent).toBe("7")
  })

  it("a failure with no count known is unreachable: 'Can't reach. Click to retry.', no dot; a click retries", async () => {
    const fetch = vi
      .fn()
      .mockRejectedValueOnce(new TypeError("Failed to fetch"))
      .mockResolvedValueOnce(answer(200, { unread: 1, as_of: AS_OF }))
    const ctx = setup({ entries: [entry("https://b.example")], fetch })
    await flush()
    expect(visible(ctx.dot)).toBe(false)

    const panel = await open(ctx)
    const row = rowFor(panel, "https://b.example")
    expect(row.getAttribute("data-status")).toBe("unreachable")
    expect(row.querySelector("[data-role='install-row-sub']").textContent).toBe("Can't reach. Click to retry.")
    expect(row.querySelector("[data-role='install-row-unreachable']")).not.toBe(null)

    row.click()
    await flush()
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(ctx.location.assign).not.toHaveBeenCalled()
    expect(visible(ctx.dot)).toBe(true)
  })

  it("a fetch that never answers is cut at 5 s and counts as a failure", async () => {
    vi.useFakeTimers()
    const result = fetchUnread(entry("https://b.example"), { fetch: () => new Promise(() => {}) })
    await vi.advanceTimersByTimeAsync(4999)
    let settled = false
    result.then(() => (settled = true))
    await Promise.resolve()
    expect(settled).toBe(false)
    await vi.advanceTimersByTimeAsync(1)
    expect(await result).toEqual({ kind: "stale" })
  })

  it("5xx is a failure (stale), any other 4xx a refusal", async () => {
    const e = entry("https://b.example")
    expect(await fetchUnread(e, { fetch: async () => answer(503, {}) })).toEqual({ kind: "stale" })
    expect(await fetchUnread(e, { fetch: async () => answer(404, {}) })).toEqual({ kind: "rejected" })
    expect(await fetchUnread(e, { fetch: async () => answer(401, {}) })).toEqual({ kind: "reconnect" })
  })

  it("a newer as_of wins; an older answer arriving later does not", () => {
    const first = applyResult(null, { kind: "ok", unread: 3, as_of: LATER })
    const older = applyResult(first, { kind: "ok", unread: 9, as_of: AS_OF })
    expect(older.unread).toBe(3)
    expect(older.as_of).toBe(LATER)
    const newer = applyResult(first, { kind: "ok", unread: 0, as_of: "2026-11-12T02:00:00Z" })
    expect(newer.unread).toBe(0)
  })

  it("a stored newer count is not overwritten by an older answer", async () => {
    const ctx = setup({
      entries: [entry("https://b.example", { unread: 4, as_of: LATER })],
      fetch: vi.fn(async () => answer(200, { unread: 0, as_of: AS_OF }))
    })
    await flush()
    expect(readList(ctx.local)[0].unread).toBe(4)
    expect(visible(ctx.dot)).toBe(true)
  })

  it("keeps at most 4 fetches in flight", async () => {
    let inFlight = 0
    let peak = 0
    const resolvers = []
    const fetch = vi.fn(
      () =>
        new Promise(resolve => {
          inFlight++
          peak = Math.max(peak, inFlight)
          resolvers.push(() => {
            inFlight--
            resolve(answer(200, { unread: 0, as_of: AS_OF }))
          })
        })
    )
    const entries = Array.from({ length: 9 }, (_, i) => entry(`https://i${i}.example`))
    setup({ entries, fetch })
    await flush()
    expect(fetch).toHaveBeenCalledTimes(4)
    while (resolvers.length) {
      resolvers.shift()()
      await flush()
    }
    expect(fetch).toHaveBeenCalledTimes(9)
    expect(peak).toBe(4)
  })

  it("runPool never exceeds its limit", async () => {
    let live = 0
    let peak = 0
    await runPool([1, 2, 3, 4, 5, 6, 7], async () => {
      live++
      peak = Math.max(peak, live)
      await Promise.resolve()
      live--
    }, 4)
    expect(peak).toBe(4)
  })

  it("refreshes when the page becomes visible and every 60 s while visible, not while hidden", async () => {
    vi.useFakeTimers()
    const fetch = vi.fn(async () => answer(200, { unread: 0, as_of: AS_OF }))
    const ctx = setup({ entries: [entry("https://b.example")], fetch })
    await vi.advanceTimersByTimeAsync(0)
    expect(fetch).toHaveBeenCalledTimes(1)

    await vi.advanceTimersByTimeAsync(60000)
    expect(fetch).toHaveBeenCalledTimes(2)

    ctx.doc.visibilityState = "hidden"
    ctx.doc.fire("visibilitychange")
    await vi.advanceTimersByTimeAsync(60000)
    expect(fetch).toHaveBeenCalledTimes(2)

    ctx.doc.visibilityState = "visible"
    ctx.doc.fire("visibilitychange")
    await vi.advanceTimersByTimeAsync(0)
    expect(fetch).toHaveBeenCalledTimes(3)
  })
})

describe("entries and rendering", () => {
  it("drops entries whose origin is not https (or http on localhost) on read", () => {
    const local = fakeStorage({
      [STORAGE_KEY]: JSON.stringify([
        entry("https://b.example"),
        { ...entry("https://c.example"), origin: "http://c.example" },
        { ...entry("https://d.example"), origin: "javascript:alert(1)" },
        { ...entry("https://e.example"), origin: "https://e.example/path" },
        { ...entry("https://f.example"), origin: "https://user@f.example" },
        { ...entry("https://g.example"), origin: "data:text/html,hi" },
        { ...entry("https://h.example"), origin: "http://localhost:4000" },
        { ...entry("https://h.example"), origin: "http://burrow.localhost" }
      ])
    })
    expect(readList(local).map(e => e.origin)).toEqual([
      "https://b.example",
      "http://localhost:4000",
      "http://burrow.localhost"
    ])
  })

  it("a dropped entry is never fetched and never shown", async () => {
    const fetch = vi.fn(async () => answer(200, { unread: 1, as_of: AS_OF }))
    const ctx = setup({ entries: [{ ...entry("https://b.example"), origin: "http://evil.example" }], fetch })
    await flush()
    expect(fetch).not.toHaveBeenCalled()
    const panel = await open(ctx)
    expect(panel.querySelectorAll("[data-role='install-row']")).toHaveLength(1)
  })

  it("the origin rule mirrors stage 2", () => {
    expect(allowedOrigin("https://b.example")).toBe("https://b.example")
    expect(allowedOrigin("https://b.example:8443")).toBe("https://b.example:8443")
    expect(allowedOrigin("http://127.0.0.1:4000")).toBe("http://127.0.0.1:4000")
    expect(allowedOrigin("http://b.example")).toBe(null)
    expect(allowedOrigin("https://b.example/")).toBe(null)
    expect(allowedOrigin("https://B.example")).toBe(null)
    expect(allowedOrigin(" https://b.example")).toBe(null)
    expect(originFromInput("burrow.team.com/chat")).toBe("https://burrow.team.com")
    expect(originFromInput("http://team.com")).toBe(null)
    expect(originFromInput("javascript:alert(1)")).toBe(null)
  })

  it("renders a stored name as text, never markup (M6)", async () => {
    const evil = `<img src=x onerror="alert(1)">`
    const ctx = setup({ entries: [entry("https://b.example", { name: evil })] })
    await flush()
    const panel = await open(ctx)
    const name = rowFor(panel, "https://b.example").querySelector("[data-role='install-row-name']")
    expect(name.textContent).toBe(evil)
    expect(name.childNodes.every(n => n.nodeType === 3)).toBe(true)
    expect(name.innerHTMLWrites).toBe(0)
  })

  it("current install first with its check and own count; others after", async () => {
    const ctx = setup({ entries: [entry("https://b.example", { name: "Bravo" })] })
    ctx.button.setAttribute("data-current-unread", "120")
    await flush()
    const panel = await open(ctx)
    const rows = panel.querySelectorAll("[data-role='install-row']")
    expect(rows[0].getAttribute("data-origin")).toBe("https://a.example")
    expect(rows[0].getAttribute("data-status")).toBe("current")
    expect(rows[0].querySelector("[data-role='install-row-count']").textContent).toBe("99+")
    expect(rows[1].querySelector("[data-role='install-row-name']").textContent).toBe("Bravo")
    expect(panel.querySelector("[data-role='install-switch-manage']").textContent).toBe("Manage installs")
  })

  it("empty state when only this install, with the canvas copy verbatim and no Manage", async () => {
    const ctx = setup()
    const panel = await open(ctx)
    const empty = panel.querySelector("[data-role='install-switch-empty']")
    expect(empty.textContent).toBe(
      "Switch between Burrow installs" +
        "Add another install, like a second team, a client's Burrow or a friend's server, and jump to it from here. Each install keeps its own spaces and sign-in. When one has unread, a dot shows next to this name."
    )
    expect(panel.querySelector("[data-role='install-switch-add']").textContent).toBe("Add an install")
    expect(panel.querySelector("[data-role='install-switch-manage']")).toBe(null)
  })

  it("the find field shows at 8+ installs and filters", async () => {
    const entries = Array.from({ length: 7 }, (_, i) => entry(`https://loc${i}.example`, { name: `Location ${i}` }))
    const ctx = setup({ entries })
    const panel = await open(ctx)
    const find = panel.querySelector("[data-role='install-switch-find']")
    expect(find.getAttribute("placeholder")).toBe("Find an install")
    find.fire("input", { target: { value: "location 3" } })
    expect(ctx.menu.querySelectorAll("[data-role='install-row']")).toHaveLength(1)
  })

  it("no find field below 8", async () => {
    const ctx = setup({ entries: [entry("https://b.example")] })
    const panel = await open(ctx)
    expect(panel.querySelector("[data-role='install-switch-find']")).toBe(null)
  })

  it("clicking another install navigates top-level to its origin, nothing in the URL", async () => {
    const ctx = setup({ entries: [entry("https://b.example")] })
    const panel = await open(ctx)
    const policyAtNavigation = []
    ctx.location.assign.mockImplementation(() =>
      policyAtNavigation.push(
        ctx.doc.head.querySelector("meta[data-role='install-switch-referrer']")?.getAttribute("content")
      )
    )
    rowFor(panel, "https://b.example").click()
    expect(ctx.location.assign).toHaveBeenCalledWith("https://b.example/")
    // Stage 4: the navigation carries no Referer (policy set before leaving).
    expect(policyAtNavigation).toEqual(["no-referrer"])
    expect(ctx.doc.head.querySelector("meta[name='referrer']").getAttribute("content")).toBe("no-referrer")
    const modal = ctx.doc.body.querySelector("[data-role='install-switch-modal']")
    expect(modal.getAttribute("data-kind")).toBe("switching")
    expect(modal.textContent).toContain("Already signed in with the same account? You go straight in.")
  })

  it("Escape closes the dropdown", async () => {
    const ctx = setup()
    await open(ctx)
    expect(ctx.button.getAttribute("aria-expanded")).toBe("true")
    ctx.doc.fire("keydown", { key: "Escape" })
    expect(ctx.menu.childNodes).toHaveLength(0)
    expect(ctx.button.getAttribute("aria-expanded")).toBe("false")
  })
})

describe("add and remove", () => {
  function fakeImage(ok) {
    return class {
      set src(v) {
        this._src = v
        queueMicrotask(() => (ok ? this.onload?.() : this.onerror?.()))
      }
      get src() {
        return this._src
      }
    }
  }

  it("not found: the canvas error copy, no navigation", async () => {
    const ctx = setup({ image: fakeImage(false) })
    const panel = await open(ctx)
    panel.querySelector("[data-role='install-switch-add']").click()
    const input = ctx.doc.body.querySelector("[data-role='install-switch-address']")
    expect(input.getAttribute("placeholder")).toBe("burrow.yourteam.com")
    input.fire("input", { target: { value: "nope.example" } })
    ctx.doc.body.querySelector("[data-role='install-switch-check']").click()
    expect(ctx.doc.body.querySelector("[data-role='install-switch-check']").textContent).toBe("Checking")
    await flush()
    expect(ctx.doc.body.querySelector("[data-role='install-switch-notfound']").textContent).toBe(
      "Couldn't find Burrow at this address. Check the spelling, or ask your admin for the link."
    )
    expect(ctx.location.assign).not.toHaveBeenCalled()
  })

  it("found: remembers the hop and navigates to B's connect page with only A's origin", async () => {
    vi.useFakeTimers()
    const ctx = setup({ image: fakeImage(true) })
    ctx.button.click()
    ctx.menu.querySelector("[data-role='install-switch-add']").click()
    const input = ctx.doc.body.querySelector("[data-role='install-switch-address']")
    input.fire("input", { target: { value: "  Burrow.Team.example/chat " } })
    ctx.doc.body.querySelector("[data-role='install-switch-check']").click()
    await vi.advanceTimersByTimeAsync(0)

    const modal = ctx.doc.body.querySelector("[data-role='install-switch-modal']")
    expect(modal.getAttribute("data-kind")).toBe("hop")
    expect(modal.textContent).toContain("Opening burrow.team.example")
    expect(modal.textContent).toContain("You'll come back to Acme when that's done.")

    expect(ctx.doc.head.querySelector("meta[name='referrer']")).toBe(null)
    await vi.advanceTimersByTimeAsync(1000)
    // Stage 4: the hop to B carries no Referer either.
    expect(ctx.doc.head.querySelector("meta[name='referrer']").getAttribute("content")).toBe("no-referrer")
    expect(ctx.location.assign).toHaveBeenCalledWith(
      "https://burrow.team.example/switcher/connect?origin=https%3A%2F%2Fa.example"
    )
    const pending = JSON.parse(ctx.sess.getItem(PENDING_KEY))
    expect(pending.origin).toBe("https://burrow.team.example")
    expect(pending.return).toBe("/chat/general?x=1")
  })

  it("Remove deletes the entry and its key, best-effort revokes on B, and toasts", async () => {
    const fetch = vi.fn(async (url, opts) =>
      opts.method === "DELETE" ? Promise.reject(new TypeError("offline")) : answer(200, { unread: 0, as_of: AS_OF })
    )
    const ctx = setup({
      entries: [entry("https://b.example", { name: "Bravo" }), entry("https://c.example", { key: KEY_C })],
      fetch
    })
    await flush()
    const panel = await open(ctx)
    panel.querySelector("[data-role='install-switch-manage']").click()
    const body = ctx.doc.body
    expect(body.querySelector("[data-role='install-manage-title']").textContent).toBe("Manage installs")
    body
      .querySelectorAll("[data-role='install-manage-remove']")
      .find(b => b.getAttribute("data-origin") === "https://b.example")
      .click()
    expect(body.querySelector("[data-role='install-remove-title']").textContent).toBe(
      "Remove Bravo from this switcher?"
    )
    body.querySelector("[data-role='install-remove-confirm']").click()
    await flush()

    expect(readList(ctx.local).map(e => e.origin)).toEqual(["https://c.example"])
    expect(ctx.local.getItem(STORAGE_KEY)).not.toContain(KEY_B)
    const revoke = fetch.mock.calls.find(c => c[1].method === "DELETE")
    expect(revoke[0]).toBe("https://b.example/api/switcher/key")
    expect(revoke[1].credentials).toBe("omit")
    expect(revoke[1].referrerPolicy).toBe("no-referrer")
    expect(revoke[1].headers).toEqual({ Authorization: "Bearer " + KEY_B })
    expect(body.querySelector("[data-role='install-switch-toast']").textContent).toBe("Removed Bravo")
  })

  it("shows the toast the connected page left, once", async () => {
    const session = fakeStorage({ [TOAST_KEY]: "Added Bravo" })
    const ctx = setup({ session })
    expect(ctx.doc.body.querySelector("[data-role='install-switch-toast']").textContent).toBe("Added Bravo")
    expect(session.getItem(TOAST_KEY)).toBe(null)
  })
})

describe("/switcher/connected", () => {
  const pending = (over = {}) =>
    fakeStorage({
      [PENDING_KEY]: JSON.stringify({ origin: "https://b.example", return: "/tasks", at: 1000, ...over })
    })

  it("saves the install for the hop this browser started and returns", () => {
    const session = pending()
    const local = fakeStorage()
    const r = completeConnect({ hash: `#host=b.example&key=${KEY_B}&name=Bravo`, session, local, now: 2000 })
    expect(r.ok).toBe(true)
    expect(r.returnTo).toBe("/tasks")
    expect(r.toast).toBe("Added Bravo")
    expect(readList(local)).toMatchObject([{ origin: "https://b.example", name: "Bravo", key: KEY_B }])
    expect(session.getItem(PENDING_KEY)).toBe(null)
  })

  it("Cancel on B adds it without its unread", () => {
    const local = fakeStorage()
    const r = completeConnect({ hash: "#host=b.example&name=Bravo", session: pending(), local, now: 2000 })
    expect(r.toast).toBe("Added Bravo without its unread")
    expect(readList(local)[0].key).toBe(null)
  })

  it("refuses with no pending hop, a host that is not the hop's, a bad key, or an old hop", () => {
    const local = fakeStorage()
    const hash = `#host=b.example&key=${KEY_B}&name=B`
    expect(completeConnect({ hash, session: fakeStorage(), local, now: 2000 }).ok).toBe(false)
    expect(completeConnect({ hash: `#host=evil.example&key=${KEY_B}`, session: pending(), local, now: 2000 }).ok).toBe(false)
    expect(completeConnect({ hash: "#host=b.example&key=nope", session: pending(), local, now: 2000 }).ok).toBe(false)
    expect(completeConnect({ hash, session: pending(), local, now: 1000 + 31 * 60 * 1000 }).ok).toBe(false)
    expect(completeConnect({ hash, session: pending({ origin: "http://b.example" }), local, now: 2000 }).ok).toBe(false)
    expect(readList(local)).toEqual([])
  })

  // Stage 4 (M11): the key must leave the address bar and the history entry
  // before anything else runs, on success and on refusal alike.
  function mountConnected({ hash, session }) {
    const doc = fakeDoc()
    const root = doc.createElement("div")
    const working = doc.createElement("div")
    working.setAttribute("data-role", "connected-working")
    const invalid = doc.createElement("div")
    invalid.setAttribute("data-role", "connected-invalid")
    invalid.classList.add("hidden")
    root.appendChild(working)
    root.appendChild(invalid)
    const calls = []
    const location = {
      origin: "https://a.example",
      pathname: "/switcher/connected",
      hash,
      replace: vi.fn(url => calls.push(["replace", url]))
    }
    const history = {
      replaceState: vi.fn((state, title, url) => {
        calls.push(["replaceState", url])
        location.hash = ""
      })
    }
    vi.stubGlobal("window", { location, history, sessionStorage: session, localStorage: fakeStorage() })
    const hook = Object.assign(Object.create(SwitcherConnected), { el: root })
    hook.mounted()
    return { root, calls, history, location }
  }

  it("strips the fragment with replaceState before returning (M11)", () => {
    const { calls, history, root } = mountConnected({
      hash: `#host=b.example&key=${KEY_B}&name=Bravo`,
      session: pending({ at: Date.now() })
    })
    expect(history.replaceState).toHaveBeenCalledWith(null, "", "/switcher/connected")
    expect(calls.map(c => c[0])).toEqual(["replaceState", "replace"])
    expect(calls.flat().join(" ")).not.toContain(KEY_B)
    expect(root.getAttribute("data-state")).toBe("added")
  })

  it("strips the fragment even when it refuses the link (M11)", () => {
    const { calls, root } = mountConnected({
      hash: `#host=evil.example&key=${KEY_B}&name=Evil`,
      session: pending({ at: Date.now() })
    })
    expect(calls).toEqual([["replaceState", "/switcher/connected"]])
    expect(root.getAttribute("data-state")).toBe("invalid")
  })

  it("never returns off-site", () => {
    expect(safeReturnPath("//evil.example")).toBe("/")
    expect(safeReturnPath("https://evil.example")).toBe("/")
    expect(safeReturnPath("/\\evil.example")).toBe("/")
    expect(safeReturnPath("/switcher/connected")).toBe("/")
    expect(safeReturnPath("/chat?x=1")).toBe("/chat?x=1")
  })

  it("parseUnread is strict", () => {
    expect(parseUnread({ unread: 3, as_of: AS_OF })).toEqual({ unread: 3, as_of: AS_OF })
    expect(parseUnread({ unread: 3, as_of: "2026-11-12" })).toBe(null)
  })
})
