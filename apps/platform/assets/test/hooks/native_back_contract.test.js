import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { EVENT, ATTR, MARKER, DRAWN_ATTR, METHOD, KINDS, stateOf } from "../../js/hooks/native_back.js"

/**
 * CONTRACT SOURCE SCAN, web side (task 01a1fa7c stage 3). The Duo side
 * strip's Back is two clients agreeing on a few strings: the plugin method
 * (`navBarState`), its payload (`{back: {kind, label} | null}`), the tap
 * event (`burrowNativeBack`), the document attribute native sets while it
 * draws the item (`data-native-vertical-bar`) and the control marker
 * (`data-native-back`). This pins the web half; the native half lands in
 * stage 4, and the Swift assertions here apply once the plugin names the
 * method.
 */

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../../..")
const read = (rel) => fs.readFileSync(path.join(root, rel), "utf8")

const hookJs = read("apps/platform/assets/js/hooks/native_back.js")
const tabBarJs = read("apps/platform/assets/js/hooks/native_tab_bar.js")
const appJs = read("apps/platform/assets/js/app.js")
const appCss = read("apps/platform/assets/css/app.css")
const pluginSwift = read("clients/ios/ios/App/App/Plugins/BurrowNativePlugin.swift")

function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((d) => {
    const p = path.join(dir, d.name)
    return d.isDirectory() ? walk(p) : /\.(ex|heex)$/.test(d.name) ? [p] : []
  })
}

describe("native back contract", () => {
  it("pins the method, event and attribute names", () => {
    expect(METHOD).toBe("navBarState")
    expect(EVENT).toBe("burrowNativeBack")
    expect(MARKER).toBe("data-native-back")
    expect(DRAWN_ATTR).toBe("data-native-vertical-bar")
    expect(KINDS).toEqual(["back", "close"])
    expect(hookJs).toContain("plugin.navBarState(state)")
  })

  it("feature-tests the same plugin and document attribute as the tab bar", () => {
    expect(ATTR).toBe("data-native-tab-bar")
    expect(tabBarJs).toContain(`export const ATTR = "${ATTR}"`)
    expect(hookJs).toContain("cap.Plugins?.BurrowNative || cap.Plugins?.SuiteNative")
  })

  it("the payload is exactly {back} and back is {kind, label}", () => {
    const control = { getAttribute: (n) => (n === MARKER ? "back" : null), hidden: false, parentElement: null }
    const win = { matchMedia: () => ({ matches: false }), getComputedStyle: () => ({ display: "block" }) }
    const doc = { documentElement: { hasAttribute: () => false }, querySelectorAll: () => [control] }
    const state = stateOf(win, doc)
    expect(Object.keys(state)).toEqual(["back"])
    expect(Object.keys(state.back).sort()).toEqual(["kind", "label"])
    const empty = { ...doc, querySelectorAll: () => [] }
    expect(stateOf(win, empty)).toEqual({ back: null })
  })

  it("app.css hides every marked control only while native draws, with display:none", () => {
    expect(appCss).toContain(`:root[${DRAWN_ATTR}] [${MARKER}] {\n  display: none !important;\n}`)
  })

  it("app.js installs the bridge globally", () => {
    expect(appJs).toContain('import {installNativeBack} from "./hooks/native_back"')
    expect(appJs).toMatch(/\ninstallNativeBack\(window, document\)\n/)
  })

  it("every marker in the templates names a known kind", () => {
    const files = walk(path.join(root, "apps/platform/lib/platform_web"))
    const kinds = files.flatMap((f) => [...fs.readFileSync(f, "utf8").matchAll(/data-native-back="(\w+)"/g)].map((m) => m[1]))
    expect(kinds.length).toBeGreaterThan(0)
    for (const k of kinds) expect(KINDS).toContain(k)
    expect(kinds).toContain("back")
    expect(kinds).toContain("close")
  })

  it("once the plugin names navBarState, it is a promise method", () => {
    if (!pluginSwift.includes(METHOD)) return
    expect(pluginSwift).toContain(`CAPPluginMethod(name: "${METHOD}", returnType: CAPPluginReturnPromise)`)
  })
})
