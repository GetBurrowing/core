import UIKit
import XCTest

@testable import App

/// The native tab bar's model, rendering, document contract and material
/// (task 01a1557b stages 1 and 2), and its glyphs, label font and inks
/// (task 01a174e8 stage 2).
@MainActor
final class NativeTabBarTests: XCTestCase {
    private let five = ["chat", "voice", "tasks", "meetings", "more"]

    private func state(_ payload: [String: Any], from start: NativeTabBarState = NativeTabBarState()) -> NativeTabBarState {
        start.applying(payload, log: { _ in })
    }

    func testCatalogDrawsTheFiveWebKeys() {
        XCTAssertEqual(NativeTab.catalog.map(\.key), five)
        XCTAssertEqual(NativeTab.catalog.map(\.title), ["Chat", "Voice", "Tasks", "Meetings", "More"])
        XCTAssertEqual(NativeTab.maxItems, 5)
    }

    /// Task 01a174e8 stage 2: one bundled glyph per tab, the same image
    /// selected and unselected, drawn as a template; the label in Public Sans.
    func testItemsUseTheBundledGlyphSelectedAndUnselected() {
        for (index, tab) in NativeTab.catalog.enumerated() {
            let item = NativeTabBarFactory.item(tab, index: index)
            let image = try? XCTUnwrap(item.image, tab.image)
            XCTAssertEqual(image?.renderingMode, .alwaysTemplate, tab.image)
            // Compare pixels, not identity: UIKit may hand back a different
            // UIImage object for the same glyph (iOS 27.0 runtime does).
            let pixels = image?.pngData()
            XCTAssertNotNil(pixels, tab.image)
            XCTAssertEqual(item.selectedImage?.pngData(), pixels, "\(tab.key): one glyph for both states")
            XCTAssertEqual(item.largeContentSizeImage?.pngData(), pixels, "\(tab.key): the Large Content Viewer shows the glyph")
            for state in [UIControl.State.normal, .selected] {
                let font = item.titleTextAttributes(for: state)?[.font] as? UIFont
                XCTAssertEqual(font?.familyName, "Public Sans", "\(tab.key) \(state)")
                XCTAssertNil(item.titleTextAttributes(for: state)?[.foregroundColor], "the bar's inks paint the label")
            }
        }
    }

    func testLabelFontIsPublicSans11AtWeight550() throws {
        let font = NativeTabLabel.font(compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        XCTAssertEqual(font.familyName, "Public Sans")
        XCTAssertEqual(font.pointSize, 11, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(NativeTabLabel.variationWeight(of: font)), 550, accuracy: 0.5)
    }

    /// Dynamic Type grows the label, the weight holds, and the cap stops it
    /// at 13pt (NativeTabLabel.maximumPointSize: "Meetings" in a fifth of a
    /// 375pt bar).
    func testLabelFontScalesWithDynamicTypeUpToTheCap() throws {
        XCTAssertEqual(NativeTabLabel.maximumPointSize, 13)
        let small = NativeTabLabel.font(compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
        let larger = NativeTabLabel.font(compatibleWith: UITraitCollection(preferredContentSizeCategory: .extraLarge)).pointSize
        XCTAssertGreaterThan(larger, small)
        for category in [UIContentSizeCategory.extraExtraExtraLarge, .accessibilityMedium, .accessibilityExtraExtraExtraLarge] {
            let font = NativeTabLabel.font(compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
            XCTAssertEqual(font.pointSize, 13, accuracy: 0.01, "\(category.rawValue)")
            XCTAssertEqual(try XCTUnwrap(NativeTabLabel.variationWeight(of: font)), 550, accuracy: 0.5, "\(category.rawValue)")
        }
    }

    func testAContentSizeChangeReappliesTheLabelFont() {
        let parent = UIViewController()
        let host = StandaloneTabBarHost()
        host.install(in: parent)
        host.render(state(["items": five, "visible": true]))
        let before = host.bar.items?.first?.titleTextAttributes(for: .normal)?[.font] as? UIFont
        XCTAssertEqual(before?.pointSize ?? 0, 11, accuracy: 0.01)
        // The trait registration in install, not a direct call.
        host.bar.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
        host.bar.updateTraitsIfNeeded()
        for item in host.bar.items ?? [] {
            for control in [UIControl.State.normal, .selected] {
                let font = item.titleTextAttributes(for: control)?[.font] as? UIFont
                XCTAssertEqual(font?.pointSize ?? 0, 13, accuracy: 0.01, item.title ?? "")
            }
        }
    }

    // MARK: Ink and scheme (task 01a174e8 stage 2)

    private func rgba(_ colour: UIColor, _ style: UIUserInterfaceStyle = .light) -> [Int] {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        _ = colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { Int(($0 * 255).rounded()) }
    }

    func testInkParsesRrggbbaaOnly() {
        XCTAssertEqual(NativeTabInk.colour("#ad4b07ff").map { rgba($0) }, [0xad, 0x4b, 0x07, 0xff])
        XCTAssertEqual(NativeTabInk.colour("#EEEFF18C").map { rgba($0) }, [0xee, 0xef, 0xf1, 0x8c])
        for bad in [nil, "", "#ad4b07", "ad4b07ff", "#ad4b07ff0", "#ad4b0gff", "#+d4b07ff", "orange", "#ａd4b07ff", "rgb(0,0,0)"] {
            XCTAssertNil(NativeTabInk.colour(bad), bad ?? "nil")
        }
    }

    func testInkFallsBackToTheBurrowSlotsAndAMalformedValueKeepsThePrevious() {
        let fallback = NativeTabInkColors.fallback
        XCTAssertEqual(rgba(fallback.selected), rgba(BurrowColor.primary.uiColor))
        XCTAssertEqual(rgba(fallback.unselected), rgba(BurrowColor.muted.uiColor))
        XCTAssertEqual(rgba(fallback.selected, .dark), rgba(BurrowColor.primary.uiColor, .dark))
        XCTAssertEqual(fallback.applying(NativeTabInk()), fallback, "no ink received: the slots")
        XCTAssertEqual(fallback.applying(NativeTabInk(selected: "orange", unselected: "#12")), fallback, "malformed before any good one")

        let web = fallback.applying(NativeTabInk(selected: "#ad4b07ff", unselected: "#0000008c"))
        XCTAssertEqual(rgba(web.selected), [0xad, 0x4b, 0x07, 0xff])
        XCTAssertEqual(rgba(web.unselected), [0, 0, 0, 0x8c])
        let kept = web.applying(NativeTabInk(selected: "not-a-colour", unselected: "#eeeff18c"))
        XCTAssertEqual(rgba(kept.selected), [0xad, 0x4b, 0x07, 0xff], "a malformed value keeps the previous ink")
        XCTAssertEqual(rgba(kept.unselected), [0xee, 0xef, 0xf1, 0x8c])
    }

    func testSchemeSetsTheInterfaceStyle() {
        XCTAssertEqual(NativeTabBarState().interfaceStyle, .unspecified)
        XCTAssertEqual(state(["scheme": "dark"]).interfaceStyle, .dark)
        XCTAssertEqual(state(["scheme": "light"]).interfaceStyle, .light)
        XCTAssertEqual(state(["scheme": "sepia"], from: state(["scheme": "dark"])).interfaceStyle, .dark)
    }

    /// The host paints what the web sent, keeps the last good ink across a
    /// malformed one, and repaints on a theme change with no restart.
    func testHostPaintsTheWebInksAndSchemeAndRepaintsOnAThemeChange() throws {
        let parent = UIViewController()
        let host = StandaloneTabBarHost()
        host.install(in: parent)
        XCTAssertEqual(rgba(host.bar.tintColor), rgba(BurrowColor.primary.uiColor), "the fallback before any state")
        XCTAssertEqual(rgba(try XCTUnwrap(host.bar.unselectedItemTintColor)), rgba(BurrowColor.muted.uiColor))
        XCTAssertEqual(host.bar.overrideUserInterfaceStyle, .unspecified)

        var next = state(["items": five, "visible": true, "ink": ["selected": "#ad4b07ff", "unselected": "#0000008c"], "scheme": "light"])
        host.render(next)
        XCTAssertEqual(rgba(host.bar.tintColor), [0xad, 0x4b, 0x07, 0xff])
        XCTAssertEqual(rgba(try XCTUnwrap(host.bar.unselectedItemTintColor)), [0, 0, 0, 0x8c])
        XCTAssertEqual(host.bar.overrideUserInterfaceStyle, .light)

        next = state(["ink": ["selected": "#f47721ff", "unselected": "#eeeff18c"], "scheme": "dark"], from: next)
        host.render(next)
        XCTAssertEqual(rgba(host.bar.tintColor), [0xf4, 0x77, 0x21, 0xff])
        XCTAssertEqual(rgba(try XCTUnwrap(host.bar.unselectedItemTintColor)), [0xee, 0xef, 0xf1, 0x8c])
        XCTAssertEqual(host.bar.overrideUserInterfaceStyle, .dark)

        next = state(["ink": ["selected": "bogus"], "scheme": "sepia"], from: next)
        host.render(next)
        XCTAssertEqual(rgba(host.bar.tintColor), [0xf4, 0x77, 0x21, 0xff], "malformed keeps the previous ink")
        XCTAssertEqual(host.bar.overrideUserInterfaceStyle, .dark)
        XCTAssertNil(host.bar.backgroundColor, "the material stays stock")
    }

    // MARK: Adaptive bar (task 01a174e8 stage 3, option 1)

    private func flat(_ grey: UInt8) throws -> CGImage {
        var pixels = [UInt8](repeating: grey, count: 4 * 4 * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        let data = Data(pixels) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        return try XCTUnwrap(
            CGImage(
                width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent))
    }

    func testBackdropLuminanceChoosesTheStyle() throws {
        XCTAssertEqual(try XCTUnwrap(NativeTabBarBackdrop.luminance(of: flat(255))), 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(NativeTabBarBackdrop.luminance(of: flat(0))), 0, accuracy: 0.01)
        XCTAssertEqual(NativeTabBarBackdrop.style(forLuminance: 1), .light)
        XCTAssertEqual(NativeTabBarBackdrop.style(forLuminance: 0), .dark)
        // Inside the hysteresis band the current style stays.
        XCTAssertEqual(NativeTabBarBackdrop.style(forLuminance: 0.19, current: .dark), .dark)
        XCTAssertEqual(NativeTabBarBackdrop.style(forLuminance: 0.17, current: .light), .light)
    }

    func testTheBarTakesTheBackdropStyleAndTheSystemInkWhenItCrossesTheWebScheme() throws {
        let web = NativeTabInkColors(selected: BurrowColor.primary.uiColor, unselected: BurrowColor.muted.uiColor)
        let same = NativeTabBarBackdrop.adapted(web, webStyle: .light, backdrop: .light)
        XCTAssertEqual(same.ink, web)
        XCTAssertEqual(same.style, .light)
        let unsampled = NativeTabBarBackdrop.adapted(web, webStyle: .dark, backdrop: nil)
        XCTAssertEqual(unsampled.ink, web)
        XCTAssertEqual(unsampled.style, .dark)
        let crossed = NativeTabBarBackdrop.adapted(web, webStyle: .dark, backdrop: .light)
        XCTAssertEqual(crossed.style, .light)
        XCTAssertEqual(crossed.ink.selected, BurrowColor.onSurface.uiColor)
        XCTAssertEqual(crossed.ink.unselected, BurrowColor.onSurface.uiColor)

        let parent = UIViewController()
        let host = StandaloneTabBarHost()
        host.install(in: parent)
        host.render(state(["items": five, "visible": true, "ink": ["selected": "#f47721ff", "unselected": "#eeeff1ff"], "scheme": "dark"]))
        XCTAssertEqual(host.bar.overrideUserInterfaceStyle, .dark)
        host.applyBackdrop(.light)
        XCTAssertEqual(host.bar.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(host.bar.tintColor, BurrowColor.onSurface.uiColor)
        host.applyBackdrop(nil)
        XCTAssertEqual(host.bar.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(rgba(host.bar.tintColor), [0xf4, 0x77, 0x21, 0xff])
    }

    func testStateStartsHiddenWithNoItemsAndNoBadge() {
        let start = NativeTabBarState()
        XCTAssertFalse(start.visible)
        XCTAssertFalse(start.shown)
        XCTAssertEqual(start.items, [])
        XCTAssertNil(start.selected)
        XCTAssertNil(NativeTabBarFactory.moreBadge(start))
    }

    func testFullPayloadDecodes() {
        let next = state(["items": five, "selected": "tasks", "more_dot": true, "visible": true])
        XCTAssertEqual(next, NativeTabBarState(items: five, selected: "tasks", moreDot: true, visible: true))
        XCTAssertTrue(next.shown)
        XCTAssertEqual(NativeTabBarFactory.moreBadge(next), "")
    }

    func testMissingOrGarbageFieldsLeaveTheStateUnchanged() {
        let start = state(["items": five, "selected": "tasks", "more_dot": true, "visible": true])
        XCTAssertEqual(state([:], from: start), start)
        XCTAssertEqual(state(["selected": "nope", "more_dot": "yes", "visible": 3, "items": "chat"], from: start), start)
        XCTAssertEqual(state(["selected": 7, "items": [1, 2]], from: start), start)
        XCTAssertNil(state(["selected": NSNull()], from: start).selected)
    }

    /// `ink` (task 01a174e8 stage 1): stored as sent, per key; a key the web
    /// left out, or a value of the wrong type, keeps the previous ink.
    func testInkIsStoredPerKeyAndAWrongTypeLeavesItUnchanged() {
        XCTAssertEqual(NativeTabBarState().ink, NativeTabInk(selected: nil, unselected: nil))
        var next = state(["ink": ["selected": "#ad4b07ff", "unselected": "#0000008c"]])
        XCTAssertEqual(next.ink, NativeTabInk(selected: "#ad4b07ff", unselected: "#0000008c"))
        next = state(["ink": ["selected": "#f47721ff"]], from: next)
        XCTAssertEqual(next.ink, NativeTabInk(selected: "#f47721ff", unselected: "#0000008c"), "a dropped key keeps its ink")
        XCTAssertEqual(state(["ink": [:] as [String: Any]], from: next).ink, next.ink)
        XCTAssertEqual(state(["ink": "#ffffffff"], from: next).ink, next.ink)
        XCTAssertEqual(state(["ink": ["selected": 7, "unselected": NSNull()] as [String: Any]], from: next).ink, next.ink)
        XCTAssertEqual(state(["items": five], from: next).ink, next.ink, "a payload without ink keeps it")
    }

    /// `scheme`: "light" or "dark"; anything else keeps the previous value.
    func testSchemeIsLightOrDarkAndAnythingElseLeavesItUnchanged() {
        XCTAssertNil(NativeTabBarState().scheme)
        var next = state(["scheme": "dark"])
        XCTAssertEqual(next.scheme, "dark")
        next = state(["scheme": "light"], from: next)
        XCTAssertEqual(next.scheme, "light")
        XCTAssertEqual(state(["scheme": "sepia"], from: next).scheme, "light")
        XCTAssertEqual(state(["scheme": true], from: next).scheme, "light")
        XCTAssertEqual(state(["scheme": NSNull()], from: next).scheme, "light")
        XCTAssertEqual(state(["visible": true], from: next).scheme, "light")
    }

    func testReducerCoversSelectionDotAndVisibility() {
        var next = state(["items": five, "selected": "chat", "visible": true])
        next = state(["selected": "meetings"], from: next)
        XCTAssertEqual(next.selected, "meetings")
        next = state(["more_dot": true], from: next)
        XCTAssertEqual(NativeTabBarFactory.badge(for: "more", next), "")
        XCTAssertNil(NativeTabBarFactory.badge(for: "chat", next), "Chat never carries a native badge")
        next = state(["more_dot": false], from: next)
        XCTAssertNil(NativeTabBarFactory.moreBadge(next))
        next = state(["visible": false], from: next)
        XCTAssertFalse(next.shown)
        XCTAssertEqual(next.items, five, "hiding keeps the items")
        next = state(["visible": true], from: next)
        XCTAssertTrue(next.shown)
    }

    func testVisibleWithNoItemsEverStaysHidden() {
        let next = state(["selected": "chat", "visible": true])
        XCTAssertTrue(next.visible)
        XCTAssertFalse(next.shown, "native never invents a tab")
    }

    func testAReselectIsDetected() {
        let next = state(["items": five, "selected": "tasks", "visible": true])
        XCTAssertTrue(next.isReselect("tasks"))
        XCTAssertFalse(next.isReselect("voice"))
        XCTAssertFalse(state(["selected": NSNull()], from: next).isReselect("tasks"))
    }

    func testAnUnknownKeyIsDropped() {
        let next = state(["items": ["chat", "games", "voice", "tasks", "meetings", "more"], "visible": true])
        XCTAssertEqual(next.items, five)
        XCTAssertNil(state(["selected": "games"], from: next).selected)
    }

    func testARepeatedKeyIsDroppedAfterItsFirstPlace() {
        XCTAssertEqual(state(["items": ["chat", "voice", "chat", "more"]]).items, ["chat", "voice", "more"])
    }

    func testAReorderedListRendersInTheNewOrder() {
        let start = state(["items": five, "visible": true])
        let reordered = ["more", "meetings", "tasks", "voice", "chat"]
        XCTAssertEqual(state(["items": reordered], from: start).items, reordered)
        XCTAssertEqual(state(["items": ["tasks", "chat"]], from: start).items, ["tasks", "chat"])
    }

    func testEmptyMissingOrAllUnknownItemsKeepThePreviousItems() {
        let start = state(["items": ["tasks", "chat", "more"], "visible": true])
        XCTAssertEqual(state(["items": [String]()], from: start).items, start.items)
        XCTAssertEqual(state(["selected": "chat"], from: start).items, start.items)
        XCTAssertEqual(state(["items": ["games", "store"]], from: start).items, start.items)
        XCTAssertEqual(state(["items": NSNull()], from: start).items, start.items)
    }

    func testMoreThanFiveKeysAreTruncatedWithALogLine() {
        let wide = NativeTab.catalog + ["games", "store"].map { NativeTab(key: $0, title: $0, image: "tab-more") }
        var lines: [String] = []
        let next = NativeTabBarState().applying(
            ["items": five + ["games", "store"], "visible": true], catalog: wide, log: { lines.append($0) })
        XCTAssertEqual(next.items, five)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("7 items, keeping the first 5") ?? false, "\(lines)")
        var quiet: [String] = []
        _ = NativeTabBarState().applying(["items": five], log: { quiet.append($0) })
        XCTAssertEqual(quiet, [], "five keys log nothing")
    }

    func testHostRendersExactlyTheWebsKeysInOrder() {
        let parent = UIViewController()
        let host = StandaloneTabBarHost()
        host.install(in: parent)
        XCTAssertTrue(host.bar.isHidden, "hidden before the first state")
        XCTAssertEqual(host.bar.items?.count ?? 0, 0)

        var next = state(["items": ["more", "chat", "games", "tasks"], "selected": "chat", "more_dot": true, "visible": true])
        host.render(next)
        XCTAssertFalse(host.bar.isHidden)
        XCTAssertEqual(host.renderedKeys, ["more", "chat", "tasks"])
        XCTAssertEqual(host.bar.items?.map(\.title), ["More", "Chat", "Tasks"])
        XCTAssertEqual(host.bar.items?.map(\.accessibilityIdentifier), ["native-tab-more", "native-tab-chat", "native-tab-tasks"])
        XCTAssertEqual(host.bar.selectedItem, host.bar.items?[1])
        XCTAssertEqual(host.bar.items?.map(\.badgeValue), ["", nil, nil])

        var taps: [String] = []
        host.onTap = { taps.append($0) }
        host.tabBar(host.bar, didSelect: host.bar.items![2])
        XCTAssertEqual(taps, ["tasks"])
        XCTAssertEqual(host.bar.selectedItem, host.bar.items?[1], "a tap does not move the selection")

        next = state(["selected": NSNull(), "more_dot": false], from: next)
        host.render(next)
        XCTAssertNil(host.bar.selectedItem)
        XCTAssertEqual(host.bar.items?.compactMap(\.badgeValue), [])
    }

    #if DEBUG
        func testRenderedProbeReadsActualHiddenState() {
            let bar = UITabBar()
            bar.isHidden = false
            XCTAssertTrue(NativeTabBarProbe.rendered(bar: bar, keys: []).contains("hidden=false "))
            bar.isHidden = true
            XCTAssertTrue(NativeTabBarProbe.rendered(bar: bar, keys: []).contains("hidden=true "))
        }
    #endif

    func testHeightAboveTheSafeArea() {
        XCTAssertEqual(NativeTabBarFactory.heightAboveSafeArea(barHeight: 96, safeAreaBottom: 34), 62)
        XCTAssertEqual(NativeTabBarFactory.heightAboveSafeArea(barHeight: 20, safeAreaBottom: 34), 0)
    }

    func testDocumentScriptMarksOnlyTheInstallHost() {
        let source = NativeTabBarDocument.script(host: "example.test", height: 62)
        XCTAssertTrue(source.contains(#"location.host.toLowerCase() !== ["example.test"][0]"#), source)
        XCTAssertTrue(source.contains(#"setAttribute("data-native-tab-bar", "")"#), source)
        XCTAssertTrue(source.contains(#"setProperty("--native-tab-bar-height", "62px")"#), source)
        XCTAssertTrue(source.contains("messageHandlers.burrowNativeDocument"), source)
        let quoted = NativeTabBarDocument.script(host: #"a"b"#, height: 1)
        XCTAssertTrue(quoted.contains(#"["a\"b"][0]"#), "the host is a JSON string literal: \(quoted)")
        XCTAssertTrue(NativeTabBarDocument.heightUpdate(49).contains(#"hasAttribute("data-native-tab-bar")"#))
        XCTAssertEqual(NativeTabBarDocument.tapEvent, "burrowNativeTab")
    }

    /// iOS 26+: nothing is set, so the system draws Liquid Glass.
    func testLiquidGlassPathSetsNoAppearance() {
        let bar = UITabBar()
        NativeTabBarMaterial.apply(to: bar, liquidGlass: true)
        XCTAssertNil(bar.scrollEdgeAppearance)
        XCTAssertNil(bar.backgroundColor)
    }

    /// iOS 17-25 (`#available` false): the default background on both
    /// appearances, never transparent and never a custom colour.
    func testPreGlassFallbackUsesTheSystemDefaultMaterial() {
        let bar = UITabBar()
        NativeTabBarMaterial.apply(to: bar, liquidGlass: false)
        let reference = UITabBarAppearance()
        reference.configureWithDefaultBackground()
        XCTAssertNotNil(bar.scrollEdgeAppearance)
        for appearance in [bar.standardAppearance, bar.scrollEdgeAppearance].compactMap({ $0 }) {
            XCTAssertNotNil(appearance.backgroundEffect)
            XCTAssertEqual(appearance.backgroundColor, reference.backgroundColor)
            XCTAssertNil(appearance.backgroundImage)
        }
        XCTAssertNil(bar.backgroundColor)
    }

    func testAvailabilityMatchesTheRuntime() {
        if #available(iOS 26, *) {
            XCTAssertTrue(NativeTabBarMaterial.liquidGlassAvailable)
        } else {
            XCTAssertFalse(NativeTabBarMaterial.liquidGlassAvailable)
        }
    }
}
