import UIKit
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

    /// The six keys the hook's `stateOf` sends are the ones `applying` reads:
    /// each one, applied alone, changes the state. `ink` carries the two
    /// probe keys the hook reads (`INK_KEYS`).
    func testPayloadKeysMatchTheHook() throws {
        let source = try hook
        for field in [
            "items: itemsOf(el)", "selected: active ? active : null", "more_dot: el.getAttribute(", "visible: barVisible(",
            "ink: inksOf(el, win, normalise)", "scheme: schemeOf(win, doc)",
            "export const INK_KEYS = [\"selected\", \"unselected\"]",
        ] {
            XCTAssertTrue(source.contains(field), field)
        }
        let start = NativeTabBarState()
        let quiet: (String) -> Void = { _ in }
        XCTAssertEqual(start.applying(["items": ["chat", "more"]], log: quiet).items, ["chat", "more"])
        XCTAssertEqual(start.applying(["selected": "voice"], log: quiet).selected, "voice")
        XCTAssertTrue(start.applying(["more_dot": true], log: quiet).moreDot)
        XCTAssertTrue(start.applying(["visible": true], log: quiet).visible)
        let ink = start.applying(["ink": ["selected": "#00000001", "unselected": "#00000002"]], log: quiet).ink
        XCTAssertEqual(ink, NativeTabInk(selected: "#00000001", unselected: "#00000002"))
        XCTAssertEqual(start.applying(["scheme": "dark"], log: quiet).scheme, "dark")
    }

    /// The probes the hook reads exist in the bridge span, and app.css paints
    /// them with the bar's own inks behind the stage 3 token slots.
    func testInkProbesExistAndReadTheBarTokens() throws {
        let rail = try read("apps/platform/lib/platform_web/components/icon_rail.ex")
        let css = try read("apps/platform/assets/css/app.css")
        XCTAssertTrue(rail.contains("<span data-native-ink=\"selected\"></span>"))
        XCTAssertTrue(rail.contains("<span data-native-ink=\"unselected\"></span>"))
        XCTAssertTrue(css.contains("color: var(--native-tab-selected, var(--color-primary));"))
        XCTAssertTrue(css.contains("color: var(--native-tab-unselected, var(--tab-ink));"))
        XCTAssertTrue(try hook.contains("el.querySelector(`[data-native-ink=\"${key}\"]`)"))
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

    // MARK: The masters' glyphs (task 01a174e8 stage 2)

    /// master-mobile.html lines 704-708, verbatim: the five tab glyphs'
    /// SVG bodies (viewBox 0 0 24 24, fill none, stroke-width 1.7, round
    /// caps and joins). The vitest mirror pins the same text.
    static let mastersGlyphs: [String: String] = [
        "tab-chat": #"<path d="M4 12a8 8 0 1 1 3.3 6.5L4 20l1.3-3.2A8 8 0 0 1 4 12z"/><path d="M9 11.5h.01M12 11.5h.01M15 11.5h.01"/>"#,
        "tab-voice": #"<rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3M9 21h6"/>"#,
        "tab-tasks": #"<path d="m4 12 2 2 4-4M4 6l2 2 4-4M4 18l2 2 4-4M13 6h7M13 12h7M13 18h7"/>"#,
        "tab-meetings": #"<rect x="3" y="6" width="13" height="12" rx="2"/><path d="m16 10 5-3v10l-5-3"/>"#,
        "tab-more": #"<circle cx="5" cy="12" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="19" cy="12" r="1.5"/>"#,
    ]

    static let svgAttributes =
        ##"xmlns="http://www.w3.org/2000/svg" width="25" height="25" viewBox="0 0 24 24" fill="none" stroke="#000000" "##
        + #"stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round""#

    func testCatalogIsTheMastersGlyphTable() {
        XCTAssertEqual(
            NativeTab.catalog.map { "\($0.key):\($0.image):\($0.title)" },
            ["chat:tab-chat:Chat", "voice:tab-voice:Voice", "tasks:tab-tasks:Tasks", "meetings:tab-meetings:Meetings", "more:tab-more:More"])
    }

    /// The asset itself is a template (Contents.json), not only the image
    /// the bar is handed; 25pt, the tab-icon box.
    func testEveryGlyphLoadsAsATemplateAt25pt() throws {
        for tab in NativeTab.catalog {
            let asset = try XCTUnwrap(UIImage(named: tab.image, in: Bundle(for: StandaloneTabBarHost.self), compatibleWith: nil), tab.image)
            XCTAssertEqual(asset.renderingMode, .alwaysTemplate, "\(tab.image): Contents.json template-rendering-intent")
            XCTAssertEqual(asset.size, CGSize(width: 25, height: 25), tab.image)
            XCTAssertEqual(tab.glyph?.renderingMode, .alwaysTemplate, tab.image)
        }
    }

    private func imageset(_ name: String) -> String { "clients/ios/ios/App/App/Assets.xcassets/\(name).imageset" }

    func testEverySvgIsTheMastersGlyphAndEveryImagesetIsAVectorTemplate() throws {
        XCTAssertEqual(Set(Self.mastersGlyphs.keys), Set(NativeTab.catalog.map(\.image)))
        let svg = try NSRegularExpression(pattern: #"^<svg ([^>]*)>(.*)</svg>\n?$"#, options: [.dotMatchesLineSeparators])
        for tab in NativeTab.catalog {
            let text = try read("\(imageset(tab.image))/\(tab.image).svg")
            let match = try XCTUnwrap(svg.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), tab.image)
            let attributes = String(text[try XCTUnwrap(Range(match.range(at: 1), in: text))])
            let body = String(text[try XCTUnwrap(Range(match.range(at: 2), in: text))])
            XCTAssertEqual(body, Self.mastersGlyphs[tab.image], "\(tab.image): the masters' SVG body, verbatim")
            XCTAssertEqual(attributes, Self.svgAttributes, tab.image)

            let contents = try JSONSerialization.jsonObject(with: Data(read("\(imageset(tab.image))/Contents.json").utf8)) as? [String: Any]
            let properties = try XCTUnwrap(contents?["properties"] as? [String: Any], tab.image)
            XCTAssertEqual(properties["preserves-vector-representation"] as? Bool, true, tab.image)
            XCTAssertEqual(properties["template-rendering-intent"] as? String, "template", tab.image)
            let images = try XCTUnwrap(contents?["images"] as? [[String: Any]], tab.image)
            XCTAssertEqual(images.count, 1, "\(tab.image): single scale")
            XCTAssertEqual(images.first?["filename"] as? String, "\(tab.image).svg")
            XCTAssertNil(images.first?["scale"], "\(tab.image): single scale")
        }
    }

    /// The glyph's alpha, drawn at 25pt x `scale`, row 0 at the top.
    private func alpha(_ image: UIImage, scale: CGFloat) -> (side: Int, pixels: [UInt8]) {
        let side = Int(25 * scale)
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: scale, y: -scale)
            UIGraphicsPushContext(context)
            image.draw(in: CGRect(x: 0, y: 0, width: 25, height: 25))
            UIGraphicsPopContext()
        }
        return (side, stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] })
    }

    /// The highest alpha in a square of `radius` viewBox units around a
    /// viewBox point (the 24-unit viewBox drawn into 25pt).
    private func peak(_ map: (side: Int, pixels: [UInt8]), at point: CGPoint, radius: CGFloat, scale: CGFloat) -> UInt8 {
        let unit = 25.0 / 24.0 * scale
        let x0 = max(0, Int(((point.x - radius) * unit).rounded(.down)))
        let x1 = min(map.side - 1, Int(((point.x + radius) * unit).rounded(.up)))
        let y0 = max(0, Int(((point.y - radius) * unit).rounded(.down)))
        let y1 = min(map.side - 1, Int(((point.y + radius) * unit).rounded(.up)))
        var best: UInt8 = 0
        for y in y0...y1 {
            for x in x0...x1 { best = max(best, map.pixels[y * map.side + x]) }
        }
        return best
    }

    /// The asset rasteriser drew every glyph's strokes. Chat's three dots
    /// are 0.01-long segments that only show through their round caps, so
    /// each dot region is checked, and the gaps between them stay clear (a
    /// filled bubble would also put ink on the dots).
    func testEveryGlyphRastersWithInkAndChatHasItsThreeDots() throws {
        // Rasterise the vector at the scale it is drawn into. With the
        // current traits a 2x iPad hands back a 2x raster, and upsampling it
        // into a 3x context blurs ink into chat's gaps (task 01a174e8).
        let scale: CGFloat = 3
        let traits = UITraitCollection(displayScale: scale)
        for tab in NativeTab.catalog {
            let map = alpha(try XCTUnwrap(NativeTab.glyph(named: tab.image, traits: traits), tab.image), scale: scale)
            let inked = map.pixels.filter { $0 > 127 }.count
            XCTAssertGreaterThan(inked, 60, "\(tab.image): \(inked) inked pixels at 25pt @3x")
            XCTAssertLessThan(inked, map.pixels.count / 2, "\(tab.image): an outline, not a filled block")
        }
        let chatGlyph = try XCTUnwrap(NativeTab.glyph(named: "tab-chat", traits: traits))
        let chat = alpha(chatGlyph, scale: scale)
        let dots = [9.0, 12.0, 15.0].map { peak(chat, at: CGPoint(x: $0, y: 11.5), radius: 0.5, scale: scale) }
        let gaps = [10.5, 13.5].map { peak(chat, at: CGPoint(x: $0, y: 11.5), radius: 0.1, scale: scale) }
        // Keep the raster so a failure can be looked at, not just read.
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(size: CGSize(width: 25, height: 25)).image { _ in
            chatGlyph.draw(in: CGRect(x: 0, y: 0, width: 25, height: 25))
        })
        attachment.name = "tab-chat dots \(dots) gaps \(gaps)"
        attachment.lifetime = .keepAlways
        add(attachment)
        for (x, dot) in zip([9.0, 12.0, 15.0], dots) {
            XCTAssertGreaterThan(dot, 127, "chat dot at x=\(x)")
        }
        // A filled bubble puts full ink in the gaps; three dots leave them
        // well under the dots. The iPad simulator's antialiasing leaves a
        // softer edge (84 at x=10.5, iOS 27.0) than the iPhone, so
        // the gap is held to clearly below half ink and clearly below every
        // dot rather than to one runtime's exact edge.
        let weakestDot = dots.min() ?? 0
        for (x, gap) in zip([10.5, 13.5], gaps) {
            XCTAssertLessThan(gap, 112, "chat gap at x=\(x): dots \(dots)")
            XCTAssertGreaterThanOrEqual(Int(weakestDot) - Int(gap), 96, "chat gap at x=\(x) not clearly below the dots \(dots)")
        }
    }
}
