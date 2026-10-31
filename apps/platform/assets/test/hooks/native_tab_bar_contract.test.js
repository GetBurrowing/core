import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { EVENT, ATTR, DESKTOP_QUERY, INK_KEYS, stateOf } from "../../js/hooks/native_tab_bar.js"

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
    expect(sent).toEqual(["inbox_dot", "ink", "items", "scheme", "selected", "visible"])
    expect([...new Set(read)].sort()).toEqual(sent)
  })

  it("the ink sub-keys the hook sends are the ones applying reads from payload[\"ink\"]", () => {
    expect(INK_KEYS).toEqual(["selected", "unselected"])
    const block = tabBarSwift.match(/if let ink = payload\["ink"\] as\? \[String: Any\] \{([\s\S]*?)\n {8}\}/)
    expect(block).not.toBeNull()
    const read = [...block[1].matchAll(/ink\["(\w+)"\] as\? String/g)].map((m) => m[1])
    expect(read).toEqual(INK_KEYS)
    expect(tabBarSwift).toMatch(/payload\["scheme"\] as\? String, scheme == "light" \|\| scheme == "dark"/)
  })

  it("the ink probes are in the bridge span, NOT bottom-nav-tab, and app.css paints them from tokens", () => {
    const bridge = iconRail.match(/<span\s+id="native-tab-bridge"[\s\S]*?<\/span>\s*<\/span>/)
    expect(bridge).not.toBeNull()
    for (const key of INK_KEYS) {
      expect(bridge[0]).toContain(`<span data-native-ink="${key}"></span>`)
      expect(hookJs).toContain('el.querySelector(`[data-native-ink="${key}"]`)')
    }
    expect(bridge[0]).not.toMatch(/data-native-ink[^>]*bottom-nav-tab/)
    expect(appCss).toContain('.bottom-nav [data-native-ink="selected"] {\n  color: var(--native-tab-selected, var(--color-primary));\n}')
    expect(appCss).toContain('.bottom-nav [data-native-ink="unselected"] {\n  color: var(--native-tab-unselected, var(--tab-ink));\n}')
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
    expect(webKeys).toEqual(["chat", "calendar", "meetings", "inbox"])
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

// Task 01a174e8 stage 2: the masters' glyphs, bundled. The same table and
// SVG text NativeTabBarContractTests.swift pins, read from the Swift source
// and the asset catalog so it runs without Xcode.
const MASTERS_GLYPHS = {
  "tab-chat":
    '<path d="M4 12a8 8 0 1 1 3.3 6.5L4 20l1.3-3.2A8 8 0 0 1 4 12z"/><path d="M9 11.5h.01M12 11.5h.01M15 11.5h.01"/>',
  // Task 01a18d9f stage 5: prototype 01a178d2 v4's tabbar glyphs (index.html .tabbar).
  "tab-calendar": '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>',
  "tab-meetings": '<rect x="3" y="6" width="13" height="12" rx="2"/><path d="m16 10 5-3v10l-5-3"/>',
  "tab-inbox": '<path d="M3 4h18v16H3zM3 14h5l2 3h4l2-3h5"/>',
  "tab-more": '<circle cx="5" cy="12" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="19" cy="12" r="1.5"/>',
}
const SVG_ATTRIBUTES =
  'xmlns="http://www.w3.org/2000/svg" width="25" height="25" viewBox="0 0 24 24" fill="none" stroke="#000000" ' +
  'stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"'
const assets = `${ios}/Assets.xcassets`

describe("native tab bar glyphs: NativeTab.catalog vs the asset catalog", () => {
  it("the catalog is chat:tab-chat:Chat, calendar, meetings, inbox, more, in order", () => {
    const table = [...tabBarSwift.matchAll(/NativeTab\(key: "(\w+)", title: "(\w+)", image: "([\w-]+)"\)/g)].map(
      (m) => `${m[1]}:${m[3]}:${m[2]}`,
    )
    expect(table).toEqual([
      "chat:tab-chat:Chat",
      "calendar:tab-calendar:Calendar",
      "meetings:tab-meetings:Meetings",
      "inbox:tab-inbox:Inbox",
      "more:tab-more:More",
    ])
    expect(tabBarSwift).not.toMatch(/systemName:/)
    expect(tabBarSwift).toContain("UITabBarItem(title: tab.title, image: glyph, selectedImage: glyph)")
    expect(tabBarSwift).toContain(".withRenderingMode(.alwaysTemplate)")
  })

  it("every tab image is a single-scale vector template imageset holding the masters' SVG verbatim", () => {
    const images = [...tabBarSwift.matchAll(/image: "(tab-[\w-]+)"\)/g)].map((m) => m[1])
    expect(images.sort()).toEqual(Object.keys(MASTERS_GLYPHS).sort())
    const imagesets = fs
      .readdirSync(path.join(root, assets))
      .filter((d) => d.startsWith("tab-"))
      .sort()
    expect(imagesets).toEqual(images.map((i) => `${i}.imageset`).sort())
    for (const image of images) {
      const dir = `${assets}/${image}.imageset`
      expect(fs.readdirSync(path.join(root, dir)).sort()).toEqual(["Contents.json", `${image}.svg`])
      const contents = JSON.parse(read(`${dir}/Contents.json`))
      expect(contents.properties).toEqual({
        "preserves-vector-representation": true,
        "template-rendering-intent": "template",
      })
      expect(contents.images).toEqual([{ filename: `${image}.svg`, idiom: "universal" }])
      const svg = read(`${dir}/${image}.svg`).match(/^<svg ([^>]*)>([\s\S]*)<\/svg>\n?$/)
      expect(svg, image).not.toBeNull()
      expect(svg[1]).toBe(SVG_ATTRIBUTES)
      expect(svg[2], image).toBe(MASTERS_GLYPHS[image])
    }
  })
})

describe("native tab bar inks: the fixture vs the Burrow preset tokens in app.css", () => {
  const fixture = read("clients/ios/www/tabbar-fixture.html")

  // A daisyUI theme block from app.css, by name.
  function themeBlock(name) {
    const blocks = appCss.split('@plugin "../vendor/daisyui-theme" {').slice(1)
    const block = blocks.find((b) => b.includes(`name: "${name}";`))
    expect(block, name).toBeDefined()
    return block.split("@plugin ")[0]
  }
  const token = (block, name) => block.match(new RegExp(`\\n\\s*${name}:\\s*([^;]+);`))?.[1].trim()

  // The token layer's --native-tab-* slots (task 01a174e8 stage 3): light
  // selected is --color-interactive (from :root), dark selected stays
  // --color-primary, unselected is opaque --color-base-content.
  const rootInteractive = appCss.match(/\n {2}--color-interactive: (#[0-9a-f]{6});/)?.[1]

  // What the hook's 1x1-canvas normaliser sends for a token: '#rrggbbaa'.
  function expected(name) {
    const block = themeBlock(name)
    const primary = token(block, "--color-primary")
    const content = token(block, "--color-base-content")
    expect(primary).toMatch(/^#[0-9a-f]{6}$/)
    expect(content).toMatch(/^#[0-9a-f]{6}$/)
    expect(rootInteractive).toMatch(/^#[0-9a-f]{6}$/)
    const selected = name === "light" ? rootInteractive : primary
    return { selected: `${selected}ff`, unselected: `${content}ff` }
  }

  it("BURROW_INK is the token layer's --native-tab-selected and --native-tab-unselected", () => {
    const m = fixture.match(/var BURROW_INK = (\{[\s\S]*?\n {8}\});/)
    expect(m).not.toBeNull()
    const ink = Function(`"use strict"; return (${m[1]})`)()
    expect(ink).toEqual({ light: expected("light"), dark: expected("dark") })
    // The pinned values, so a token edit shows up here as well.
    expect(ink).toEqual({
      light: { selected: "#8b3b04ff", unselected: "#000000ff" },
      dark: { selected: "#f47721ff", unselected: "#eeeff1ff" },
    })
    // The slots live at the token layer: :root sets both, each dark selector
    // puts selected back on --color-primary; never a .bottom-nav* rule.
    expect(appCss).toMatch(/:root \{[^}]*--native-tab-selected: var\(--color-interactive\);[^}]*--native-tab-unselected: var\(--color-base-content\);/)
    expect(appCss).toMatch(/\[data-theme="dark"\] \{[^}]*--native-tab-selected: var\(--color-primary\);/)
    expect(appCss).toMatch(/:root:not\(\[data-theme="light"\]\) \{[^}]*--native-tab-selected: var\(--color-primary\);/)
    expect(appCss).not.toMatch(/\.bottom-nav[^{]*\{[^}]*--native-tab-(selected|unselected):/)
  })

  it("the fixture sends ink and scheme in the hook's shape", () => {
    expect(fixture).toContain('<button data-ink="auto" data-state=')
    expect(fixture).toContain("state.ink = BURROW_INK[scheme];")
    expect(fixture).toContain("state.scheme = scheme;")
    expect(INK_KEYS).toEqual(["selected", "unselected"])
  })
})
