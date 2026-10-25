import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { EVENT, ATTR, DESKTOP_QUERY, stateOf } from "../../js/hooks/native_tab_bar.js"

/**
 * CONTRACT SOURCE SCAN, web side (task 01a1557b stage 4). The native tab bar
 * is two clients agreeing on a handful of strings: the plugin method
 * (`tabBarState`), its payload keys, the tap event (`burrowNativeTab`) and
 * its detail keys, the document attribute (`data-native-tab-bar`), the CSS
 * variable (`--native-tab-bar-height`) and the five tab keys. This reads the
 * Swift sources and fails when one side renames a string the other still
 * uses. The mirror is clients/ios/ios/App/AppTests/NativeTabBarContractTests.swift,
 * which reads this hook from the iOS CI run.
 */

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../../..")
const read = (rel) => fs.readFileSync(path.join(root, rel), "utf8")

const ios = "clients/ios/ios/App/App"
const tabBarSwift = read(`${ios}/NativeTabBar.swift`)
const bridgeSwift = read(`${ios}/BurrowBridgeViewController.swift`)
const pluginSwift = read(`${ios}/Plugins/BurrowNativePlugin.swift`)
const hookJs = read("apps/platform/assets/js/hooks/native_tab_bar.js")
const appCss = read("apps/platform/assets/css/app.css")
const iconRail = read("apps/platform/lib/platform_web/components/icon_rail.ex")

function swiftConst(src, name) {
  const m = src.match(new RegExp(`static let ${name} = "([^"]*)"`))
  return m && m[1]
}

describe("native tab bar contract: Swift sources vs the hook", () => {
  it("the tap event name matches NativeTabBarDocument.tapEvent", () => {
    expect(EVENT).toBe("burrowNativeTab")
    expect(swiftConst(bridgeSwift, "tapEvent")).toBe(EVENT)
    expect(bridgeSwift).toContain("eventName: NativeTabBarDocument.tapEvent")
  })

  it("the document attribute matches NativeTabBarDocument.attribute, and app.css keys off it", () => {
    expect(ATTR).toBe("data-native-tab-bar")
    expect(swiftConst(bridgeSwift, "attribute")).toBe(ATTR)
    expect(appCss).toContain(`:root[${ATTR}]`)
  })

  it("the height variable native sets is the one app.css reads", () => {
    const variable = swiftConst(bridgeSwift, "heightVariable")
    expect(variable).toBe("--native-tab-bar-height")
    expect(appCss).toContain(`var(${variable}`)
  })

  it("tabBarState is a promise method on the plugin the hook looks up", () => {
    expect(pluginSwift).toContain('CAPPluginMethod(name: "tabBarState", returnType: CAPPluginReturnPromise)')
    expect(pluginSwift).toMatch(/@objc func tabBarState\(_ call: CAPPluginCall\)/)
    const jsName = pluginSwift.match(/jsName = "(\w+)"/)[1]
    expect(jsName).toBe("SuiteNative")
    expect(hookJs).toContain(`cap.Plugins?.${jsName}`)
    expect(hookJs).toContain("plugin.tabBarState(state)")
  })

  it("the payload keys the hook sends are exactly the ones NativeTabBarState.applying reads", () => {
    const span = { getAttribute: () => null }
    const win = { matchMedia: () => ({ matches: false }) }
    const doc = { documentElement: { matches: () => false }, querySelector: () => null }
    const sent = Object.keys(stateOf(span, win, doc)).sort()
    const read = [...tabBarSwift.matchAll(/payload\["(\w+)"\]/g)].map((m) => m[1])
    expect(sent).toEqual(["items", "more_dot", "selected", "visible"])
    expect([...new Set(read)].sort()).toEqual(sent)
  })

  it("the tap detail native sends carries the key and reselect the hook reads", () => {
    expect(bridgeSwift).toContain('let detail: [String: Any] = ["key": key, "reselect": tabBarState.isReselect(key)]')
    expect(bridgeSwift).toContain('["detail": detail]')
    expect(hookJs).toContain("detail.key")
    expect(hookJs).toContain("detail.reselect !== true")
  })

  it("native's catalog is IconRail.mobile_tab_keys/0 ++ [:more], in order", () => {
    const m = iconRail.match(/def mobile_tab_keys, do: \[([^\]]*)\]/)
    expect(m).not.toBeNull()
    const webKeys = m[1].split(",").map((k) => k.trim().replace(/^:/, ""))
    expect(iconRail).toContain('<> ",more"')
    const nativeKeys = [...tabBarSwift.matchAll(/NativeTab\(key: "(\w+)"/g)].map((k) => k[1])
    expect(webKeys).toEqual(["chat", "voice", "tasks", "meetings"])
    expect(nativeKeys).toEqual([...webKeys, "more"])
    expect(hookJs).toContain('detail.key === "more"')
  })

  it("the hook hides at the width where the web shows its desktop rail (Tailwind lg, 1024px)", () => {
    expect(DESKTOP_QUERY).toBe("(min-width: 1024px)")
    // The web bar (and the bridge span inside it) is `lg:hidden`: at lg and
    // up the desktop rail replaces it, so the native bar must not show either.
    expect(iconRail).toMatch(/id="bottom-nav"\s+class="bottom-nav lg:hidden"/)
  })
})
