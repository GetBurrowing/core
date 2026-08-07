import { describe, it, expect, beforeEach, afterEach } from "vitest"

/**
 * Tests for `js/lib/load_excalidraw.js` — the idempotent loader for the
 * Excalidraw island.
 *
 * The load-bearing invariant is that exactly ONE <script> is ever injected,
 * however many callers race. The island is ~4.7 MB; a second injection is a
 * second 4.7 MB fetch and a second evaluation of a module that assigns a
 * global.
 *
 * Like the other hook tests here, these run in vitest's default `node` env, so
 * `document` and `window` are hand-built fakes rather than jsdom. That is
 * deliberate: the loader touches four DOM methods and nothing else, and a fake
 * lets each test drive `onload` / `onerror` directly instead of waiting on a
 * real network stack that would never resolve for `/assets/js/...` anyway.
 *
 * The module caches its promise in module scope, so every test clears that
 * cache through the module's own test seam before running.
 */

import {
  loadExcalidraw,
  ISLAND_SRC,
  ISLAND_CSS,
  __resetExcalidrawLoaderForTest,
} from "../../js/lib/load_excalidraw.js"

// ── Fake DOM ─────────────────────────────────────────────────────────────

function installFakeDom() {
  const injected = []
  const head = {
    appendChild(node) {
      injected.push(node)
      return node
    },
  }

  globalThis.document = {
    head,
    createElement(tag) {
      return { tagName: tag.toUpperCase(), onload: null, onerror: null }
    },
    // The loader queries for an already-present stylesheet link. Answer from
    // whatever has actually been injected so the "no duplicate" path is real
    // rather than hard-coded.
    querySelector(selector) {
      const match = /^link\[href="(.*)"\]$/.exec(selector)
      if (!match) return null
      return injected.find((n) => n.tagName === "LINK" && n.href === match[1]) || null
    },
  }

  globalThis.window = {}

  return {
    injected,
    scripts: () => injected.filter((n) => n.tagName === "SCRIPT"),
    links: () => injected.filter((n) => n.tagName === "LINK"),
  }
}

// ── Tests ────────────────────────────────────────────────────────────────

describe("loadExcalidraw", () => {
  let dom

  beforeEach(() => {
    dom = installFakeDom()
    __resetExcalidrawLoaderForTest()
  })

  afterEach(() => {
    __resetExcalidrawLoaderForTest()
    delete globalThis.document
    delete globalThis.window
  })

  it("injects exactly one <script> when called three times concurrently", async () => {
    const promises = [loadExcalidraw(), loadExcalidraw(), loadExcalidraw()]

    expect(dom.scripts()).toHaveLength(1)
    expect(dom.scripts()[0].src).toBe(ISLAND_SRC)

    const island = { Excalidraw: () => null }
    globalThis.window.__suite_excalidraw = island
    dom.scripts()[0].onload()

    const results = await Promise.all(promises)
    // All three callers get the same object, and still only one script.
    expect(results).toEqual([island, island, island])
    expect(dom.scripts()).toHaveLength(1)
  })

  it("injects the island stylesheet alongside the script, once", async () => {
    loadExcalidraw()
    loadExcalidraw()

    expect(dom.links()).toHaveLength(1)
    expect(dom.links()[0].href).toBe(ISLAND_CSS)
    expect(dom.links()[0].rel).toBe("stylesheet")
  })

  it("resolves with the global once onload fires", async () => {
    const promise = loadExcalidraw()
    const island = { version: "0.18.1" }
    globalThis.window.__suite_excalidraw = island
    dom.scripts()[0].onload()

    await expect(promise).resolves.toBe(island)
  })

  it("rejects when the script loads but publishes no global", async () => {
    const promise = loadExcalidraw()
    dom.scripts()[0].onload()

    // A silent `undefined` here would surface much later as an unrelated
    // crash in the caller, so the loader must reject loudly instead.
    await expect(promise).rejects.toThrow(/did not define window.__suite_excalidraw/)
  })

  it("rejects on onerror", async () => {
    const promise = loadExcalidraw()
    dom.scripts()[0].onerror()

    await expect(promise).rejects.toThrow(`Failed to load ${ISLAND_SRC}`)
  })

  it("a second call after success resolves without injecting another script", async () => {
    const first = loadExcalidraw()
    const island = { version: "0.18.1" }
    globalThis.window.__suite_excalidraw = island
    dom.scripts()[0].onload()
    await first

    const second = await loadExcalidraw()

    expect(second).toBe(island)
    expect(dom.scripts()).toHaveLength(1)
  })

  it("retries after a failed load rather than caching the rejection forever", async () => {
    const first = loadExcalidraw()
    dom.scripts()[0].onerror()
    await expect(first).rejects.toThrow()

    // Give the internal `.catch()` that clears the cache a turn to run.
    await Promise.resolve()

    const second = loadExcalidraw()
    expect(dom.scripts()).toHaveLength(2)

    const island = { version: "0.18.1" }
    globalThis.window.__suite_excalidraw = island
    dom.scripts()[1].onload()
    await expect(second).resolves.toBe(island)
  })
})
