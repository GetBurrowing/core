import XCTest

@testable import App

/// CONTRACT SOURCE SCAN, native side (task 01a1557b stage 4). Reads the web
/// hook (apps/platform/assets/js/hooks/native_tab_bar.js), app.css and
/// icon_rail.ex from the checkout and asserts they still use the strings this
/// app defines, so a rename on either side fails CI. The mirror is
/// apps/platform/assets/test/hooks/native_tab_bar_contract.test.js, which
/// reads the Swift sources. Runs on a simulator, which reads the host's files.
final class NativeTabBarContractTests: XCTestCase {
    /// The repo root: this file is clients/ios/ios/App/AppTests/<file>.
    private static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()

    private func read(_ relative: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let url = Self.root.appendingPathComponent(relative)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            XCTFail("cannot read \(url.path): \(error)", file: file, line: line)
            throw error
        }
    }

    private var hook: String { get throws { try read("apps/platform/assets/js/hooks/native_tab_bar.js") } }

    func testTapEventNameMatchesTheHook() throws {
        XCTAssertEqual(NativeTabBarDocument.tapEvent, "burrowNativeTab")
        XCTAssertTrue(try hook.contains("export const EVENT = \"\(NativeTabBarDocument.tapEvent)\""))
    }

    func testDocumentAttributeMatchesTheHookAndTheStylesheet() throws {
        let attribute = NativeTabBarDocument.attribute
        XCTAssertEqual(attribute, "data-native-tab-bar")
        XCTAssertTrue(try hook.contains("export const ATTR = \"\(attribute)\""))
        XCTAssertTrue(try read("apps/platform/assets/css/app.css").contains(":root[\(attribute)]"))
    }

    func testHeightVariableIsTheOneTheStylesheetReads() throws {
        let variable = NativeTabBarDocument.heightVariable
        XCTAssertEqual(variable, "--native-tab-bar-height")
        XCTAssertTrue(try read("apps/platform/assets/css/app.css").contains("var(\(variable)"))
    }

    func testPluginMethodIsTheOneTheHookCalls() throws {
        // Fails to compile if the method is renamed.
        let method = NSStringFromSelector(#selector(BurrowNativePlugin.tabBarState(_:)))
        XCTAssertEqual(method, "tabBarState:")
        let source = try hook
        XCTAssertTrue(source.contains("plugin.tabBarState(state)"))
        XCTAssertTrue(source.contains("typeof plugin.tabBarState !== \"function\""))
        XCTAssertTrue(source.contains("cap.Plugins?.SuiteNative"))
    }

    /// The four keys the hook's `stateOf` sends are the ones `applying` reads:
    /// each one, applied alone, changes the state.
    func testPayloadKeysMatchTheHook() throws {
        let source = try hook
        for field in ["items: itemsOf(el)", "selected: active ? active : null", "more_dot: el.getAttribute(", "visible: barVisible("] {
            XCTAssertTrue(source.contains(field), field)
        }
        let start = NativeTabBarState()
        let quiet: (String) -> Void = { _ in }
        XCTAssertEqual(start.applying(["items": ["chat", "more"]], log: quiet).items, ["chat", "more"])
        XCTAssertEqual(start.applying(["selected": "voice"], log: quiet).selected, "voice")
        XCTAssertTrue(start.applying(["more_dot": true], log: quiet).moreDot)
        XCTAssertTrue(start.applying(["visible": true], log: quiet).visible)
    }

    func testTapDetailKeysMatchTheHook() throws {
        let source = try hook
        XCTAssertTrue(source.contains("detail.key"))
        XCTAssertTrue(source.contains("detail.reselect !== true"))
        XCTAssertTrue(source.contains("detail.key === \"more\""))
    }

    /// Items come from `IconRail.mobile_tab_keys/0 ++ [:more]` (data-items on
    /// `#native-tab-bridge`); native's catalog draws exactly those, in order.
    func testCatalogIsTheWebTabKeysPlusMore() throws {
        let rail = try read("apps/platform/lib/platform_web/components/icon_rail.ex")
        let pattern = try NSRegularExpression(pattern: #"def mobile_tab_keys, do: \[([^\]]*)\]"#)
        let match = try XCTUnwrap(pattern.firstMatch(in: rail, range: NSRange(rail.startIndex..., in: rail)))
        let list = String(rail[try XCTUnwrap(Range(match.range(at: 1), in: rail))])
        let webKeys = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "") }
        XCTAssertTrue(rail.contains("id=\"native-tab-bridge\""))
        XCTAssertTrue(rail.contains("<> \",more\""))
        XCTAssertEqual(NativeTab.catalog.map(\.key), webKeys + ["more"])
    }

    /// The web hides the native bar at the width where it shows its desktop
    /// rail (wide iPads); native shows whatever the web says.
    func testHookHidesAtTheDesktopRailWidth() throws {
        XCTAssertTrue(try hook.contains("export const DESKTOP_QUERY = \"(min-width: 1024px)\""))
    }
}
