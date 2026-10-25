import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

/**
 * SOURCE GUARD for cross-frame messaging (task 01a1557a-fe9b stage 2).
 *
 * Fails when any script under assets/js posts with targetOrigin "*", or
 * listens for "message" without checking event.origin against its own
 * origin. The theme editor posts a draft palette into frames of this app and
 * the receiver writes it onto <html>; "*" would hand the draft to whatever
 * the frame has navigated to, and a missing origin check would let any
 * window repaint the app.
 *
 * ONE EXEMPTION, named and checked: hooks/canvas_room_bridge.js talks to a
 * canvas embed in a sandboxed iframe with no allow-same-origin, whose origin
 * is opaque ("null"), so no targetOrigin but "*" can reach it. It instead
 * answers only `event.source === this.iframe.contentWindow`. The guard
 * asserts that check is still there, and that the exemption is not stale.
 *
 * Anti-vacuity: the scan must find the theme editor's postMessage and the
 * receiver's listener; a scan that finds nothing passes nothing.
 */

const here = path.dirname(fileURLToPath(import.meta.url))
const jsRoot = path.resolve(here, "../js")

const EXEMPT = {
  "hooks/canvas_room_bridge.js": /event\.source !== this\.iframe\.contentWindow/,
}

function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) return entry.name === "node_modules" ? [] : walk(full)
    return entry.name.endsWith(".js") ? [full] : []
  })
}

// Blank // and /* */ comments so prose cannot satisfy or trip a check.
function code(text) {
  return text.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " ")).replace(/(^|[^:"'])\/\/.*$/gm, "$1")
}

// The argument list of every `postMessage(` call, balanced on parens.
function postMessageArgs(src) {
  const out = []
  let i = src.indexOf("postMessage(")
  while (i !== -1) {
    let depth = 0
    let j = i + "postMessage".length
    const start = j + 1
    for (; j < src.length; j++) {
      if (src[j] === "(") depth++
      else if (src[j] === ")" && --depth === 0) break
    }
    out.push(src.slice(start, j))
    i = src.indexOf("postMessage(", j)
  }
  return out
}

// The last top-level argument: the targetOrigin.
function lastArg(args) {
  let depth = 0
  let cut = 0
  for (let k = 0; k < args.length; k++) {
    const ch = args[k]
    if ("([{".includes(ch)) depth++
    else if (")]}".includes(ch)) depth--
    else if (ch === "," && depth === 0) cut = k + 1
  }
  return args.slice(cut).trim()
}

const STAR = /^(["'`])\*\1$/
const LISTENS = /addEventListener\(\s*(["'])message\1/
const ORIGIN_CHECK = /\.origin\s*[!=]==\s*(?:[\w.]*\.)?origin\b|\borigin\s*[!=]==\s*\w+\.origin\b/

const files = walk(jsRoot).map((full) => ({
  rel: path.relative(jsRoot, full).split(path.sep).join("/"),
  src: code(fs.readFileSync(full, "utf8")),
}))

describe("postMessage targetOrigin", () => {
  it("anti-vacuity: the theme editor's post is found", () => {
    const editor = files.find((f) => f.rel === "hooks/theme_editor.js")
    expect(editor).toBeTruthy()
    expect(postMessageArgs(editor.src).length).toBeGreaterThan(0)
  })

  it("no script posts to '*' (one named exemption)", () => {
    const offenders = []
    for (const { rel, src } of files) {
      for (const args of postMessageArgs(src)) {
        if (STAR.test(lastArg(args)) && !EXEMPT[rel]) offenders.push(`${rel}: postMessage(${args})`)
      }
    }
    expect(offenders).toEqual([])
  })

  it("the theme editor names no '*' anywhere and posts with the page origin", () => {
    const { src } = files.find((f) => f.rel === "hooks/theme_editor.js")
    expect(src).not.toMatch(/(["'`])\*\1/)
    // Call sites only, not the definition.
    const calls = [...src.matchAll(/(?<!function )postPreview\(([^)]*)\)/g)].map((m) => m[1])
    expect(calls.length).toBeGreaterThan(0)
    for (const args of calls) expect(lastArg(args)).toBe("window.location.origin")
    // The definition passes its origin parameter straight through.
    const [definition] = postMessageArgs(src)
    expect(lastArg(definition)).toBe("origin")
  })

  it("the exemption is not stale: canvas_room_bridge still posts '*'", () => {
    const bridge = files.find((f) => f.rel === "hooks/canvas_room_bridge.js")
    expect(postMessageArgs(bridge.src).some((a) => STAR.test(lastArg(a)))).toBe(true)
  })
})

describe("message listeners check the origin", () => {
  it("anti-vacuity: the receiver listens", () => {
    const receiver = files.find((f) => f.rel === "hooks/theme_preview_receiver.js")
    expect(receiver.src).toMatch(LISTENS)
  })

  it("every listener compares event.origin with its own origin (one named exemption)", () => {
    const offenders = []
    for (const { rel, src } of files) {
      if (!LISTENS.test(src)) continue
      if (EXEMPT[rel]) {
        if (!EXEMPT[rel].test(src)) offenders.push(`${rel}: exempt, but its source check is gone`)
        continue
      }
      if (!ORIGIN_CHECK.test(src)) offenders.push(`${rel}: listens for "message" with no origin check`)
    }
    expect(offenders).toEqual([])
  })

  it("the receiver is handed this window's own origin", () => {
    const { src } = files.find((f) => f.rel === "hooks/theme_preview_receiver.js")
    expect(src).toMatch(/event\.origin !== origin/)
    expect(src).toMatch(/origin: win\.location\.origin/)
  })

  it("app.js installs the receiver", () => {
    const { src } = files.find((f) => f.rel === "app.js")
    expect(src).toMatch(/installThemePreviewReceiver\(window\)/)
  })
})
