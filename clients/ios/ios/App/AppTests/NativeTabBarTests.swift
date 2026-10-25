import UIKit
import XCTest

@testable import App

/// The native tab bar's model, rendering, document contract and material
/// (task 01a1557b stages 1 and 2).
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

    func testSymbolPairsMatchTheMasters() {
        let pairs = NativeTab.catalog.map { "\($0.symbol)|\($0.selectedSymbol)" }
        XCTAssertEqual(
            pairs, ["ellipsis.bubble|ellipsis.bubble.fill", "mic|mic.fill", "checklist|checklist", "video|video.fill", "ellipsis|ellipsis"])
    }

    func testEverySymbolResolves() {
        for tab in NativeTab.catalog {
            XCTAssertNotNil(UIImage(systemName: tab.symbol), tab.symbol)
            XCTAssertNotNil(UIImage(systemName: tab.selectedSymbol), tab.selectedSymbol)
        }
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
        let wide = NativeTab.catalog + ["games", "store"].map { NativeTab(key: $0, title: $0, symbol: "star", selectedSymbol: "star.fill") }
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
