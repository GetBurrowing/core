import UIKit
import XCTest

/// The native tab bar on the `-BurrowTabBarFixture` page (task 01a1557b):
/// stage 2's contract (items, selection, dot, taps, hide/show, the
/// document-start script, the no-state hide) and stage 1's glass probe.
/// Light and dark (stage 1 spiked a UITabBarController hosting too; see
/// clients/ios/README.md, "Native tab bar"). Writes a PNG per state
/// and the native glass probe to $EVIDENCE_DIR (pass
/// TEST_RUNNER_EVIDENCE_DIR to xcodebuild), and attaches both to the result.
/// Task 01a174e8 stage 3: the inks' WCAG contrast over the real glass, light
/// and dark over a white and a black backdrop, into $EVIDENCE_DIR/contrast.json.
final class TabBarUITests: XCTestCase {
    private var dir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["EVIDENCE_DIR"] ?? NSTemporaryDirectory())
    }

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-BurrowTabBarFixture", "YES", "-BurrowTabBarFixtureAppearance", appearance] + extra
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Tab bar fixture"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.webViews.staticTexts["plugin: tabBarState present"].waitForExistence(timeout: 10))
        return app
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? screenshot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private func note(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? text.write(to: dir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }

    private func send(_ label: String, _ app: XCUIApplication) {
        app.webViews.buttons[label].tap()
    }

    /// A `burrowNativeTab` line in the fixture's #events list ("1. voice …").
    private func event(_ text: String, _ app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", text)).firstMatch
    }

    private func probe(_ app: XCUIApplication) -> String {
        let glass = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'glass: hosting='")).firstMatch
        XCTAssertTrue(glass.waitForExistence(timeout: 10))
        return glass.label
    }

    /// Waits for a fixture line containing every fragment.
    @discardableResult
    private func line(_ prefix: String, _ fragments: [String], _ app: XCUIApplication, timeout: TimeInterval = 10) -> XCUIElement {
        var format = "label BEGINSWITH %@"
        var args: [Any] = [prefix]
        for fragment in fragments {
            format += " AND label CONTAINS %@"
            args.append(fragment)
        }
        let element = app.webViews.staticTexts.matching(NSPredicate(format: format, argumentArray: args)).firstMatch
        let current = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(fragments) not in: \(current.exists ? current.label : "no line")")
        return element
    }

    private func rendered(_ fragments: [String], _ app: XCUIApplication) {
        line("rendered: keys=", fragments, app)
    }

    private func gone(_ bar: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !(bar.exists && bar.isHittable) { return true }
            usleep(250_000)
        }
        return false
    }

    private func labels(_ bar: XCUIElement) -> [String] {
        bar.buttons.allElementsBoundByIndex.map(\.label)
    }

    private func assertLabels(_ bar: XCUIElement, _ expected: [String], file: StaticString = #filePath, line: UInt = #line) {
        let actual = labels(bar)
        XCTAssertEqual(actual.count, expected.count, "\(actual)", file: file, line: line)
        for (label, title) in zip(actual, expected) {
            XCTAssertTrue(label.hasPrefix(title), "\(actual) vs \(expected)", file: file, line: line)
        }
    }

    private let five = ["Chat", "Voice", "Tasks", "Meetings", "More"]

    /// Before the first state, then the dot-on state, for screenshots.
    private func start(_ appearance: String) -> (XCUIApplication, XCUIElement) {
        let app = launch(appearance)
        let bar = app.tabBars["native-tab-bar"]
        XCTAssertFalse(bar.exists && bar.isHittable, "no bar before the first state")
        line("rendered: ", ["waiting"], app)
        shot("stage2-\(appearance)-0-before-state")

        send("Chat, dot on", app)
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        XCTAssertTrue(bar.isHittable)
        assertLabels(bar, five)
        rendered(["keys=chat,voice,tasks,meetings,more", "selected=chat", "badges=more ", "hidden=false"], app)
        // Document-start script: the attribute and a real height.
        let doc = line("doc: attr=true height=", [], app)
        XCTAssertFalse(doc.label.hasSuffix("unset") || doc.label.hasSuffix("=0px"), doc.label)
        note("stage2-\(appearance)-doc", doc.label)
        sleep(1)
        shot("stage2-\(appearance)-1-chat-dot-on")
        return (app, bar)
    }

    private func hideAndShow(_ appearance: String, _ app: XCUIApplication, _ bar: XCUIElement) {
        send("Hide bar", app)
        XCTAssertTrue(gone(bar, timeout: 5), "hidden bar must not be hittable")
        rendered(["hidden=true"], app)
        shot("stage2-\(appearance)-2-hidden")
        send("Show bar", app)
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(bar.isHittable)
    }

    private func fixture(_ appearance: String) {
        let app = launch(appearance)
        let name = "standalone-\(appearance)"
        let bar = app.tabBars["native-tab-bar"]
        send("Chat, dot on", app)
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        sleep(2)
        let report = probe(app)
        let tree = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'UITabBar'")).firstMatch
        note("\(name)-probe", report + "\n" + (tree.exists ? tree.label : ""))
        restyle(appearance, app)
        app.terminate()
    }

    /// The Burrow preset's inks as the fixture sends them (BURROW_INK).
    private let inks = ["light": "8b3b04ff/000000ff", "dark": "f47721ff/eeeff1ff"]

    /// Task 01a174e8 stage 2: the bar paints the web's inks and scheme, a
    /// theme change repaints it with no restart, a malformed ink keeps the
    /// last one, and the labels are drawn in Public Sans 11 at weight 550.
    private func restyle(_ appearance: String, _ app: XCUIApplication) {
        rendered(["ink=\(inks[appearance]!)", "style=\(appearance)"], app)
        let drawn = line("rendered: keys=", ["fonts="], app).label
        note("restyle-\(appearance)-rendered", drawn)
        shot("restyle-\(appearance)-chat")
        send("Select tasks", app)
        rendered(["selected=tasks"], app)
        sleep(1)
        shot("restyle-\(appearance)-tasks")

        let other = appearance == "dark" ? "light" : "dark"
        // The bar follows the content behind it, which is still the page's
        // own ground: the style stays, and the crossed web ink gives way to
        // the system label ink.
        send(other == "dark" ? "Ink dark" : "Ink light", app)
        rendered(["style=\(appearance)"], app)
        sleep(1)
        shot("restyle-\(appearance)-then-\(other)")
        send("Ink malformed", app)
        sleep(2)
        rendered(["style=\(appearance)"], app)

        // Last, so the screenshots above exist whatever it says: iOS drew the
        // per-item font (rung 26 rule zero: no UITabBarAppearance on 26+).
        XCTAssertTrue(drawn.contains("fonts=Public Sans 11 w550"), drawn)
    }

    /// Stage 2: the full contract on the fixture, light.
    func testContractLight() {
        let (app, bar) = start("light")

        // Every tap reports its key; the selected tab is a reselect, and the
        // selection waits for the web.
        let expected = ["chat reselect=true", "voice reselect=false", "tasks reselect=false", "meetings reselect=false", "more reselect=false"]
        for (index, text) in expected.enumerated() {
            bar.buttons.element(boundBy: index).tap()
            XCTAssertTrue(event(text, app).waitForExistence(timeout: 5), text)
        }
        // The selection is read from the bar itself (`selectedItem`); XCUI's
        // isSelected does not follow a programmatic selection.
        rendered(["selected=chat"], app)

        // Selection follows the web's state.
        send("Select tasks", app)
        rendered(["selected=tasks"], app)
        bar.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(event("tasks reselect=true", app).waitForExistence(timeout: 5))
        send("Select none", app)
        rendered(["selected=none"], app)

        // The More dot on and off.
        send("Dot off", app)
        rendered(["badges=none"], app)
        send("Dot on", app)
        rendered(["badges=more "], app)

        // items: the web's order, unknown keys dropped, empty or missing
        // keeps the previous list.
        send("Reorder", app)
        rendered(["keys=more,meetings,tasks,voice,chat", "titles=More,Meetings,Tasks,Voice,Chat"], app)
        assertLabels(bar, ["More", "Meetings", "Tasks", "Voice", "Chat"])
        bar.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(event("more reselect=false", app).waitForExistence(timeout: 5))
        send("Unknown key", app)
        rendered(["keys=chat,voice,tasks,meetings,more "], app)
        assertLabels(bar, five)
        send("Empty items", app)
        rendered(["keys=chat,voice,tasks,meetings,more ", "selected=chat"], app)
        send("No items field", app)
        rendered(["keys=chat,voice,tasks,meetings,more ", "selected=voice"], app)
        assertLabels(bar, five)

        hideAndShow("light", app, bar)

        // A new document that sends no state hides the bar after didFinish
        // plus the grace; one that does keeps it.
        app.webViews.links["Silent page"].tap()
        XCTAssertTrue(app.webViews.staticTexts["mode: silent"].waitForExistence(timeout: 10))
        XCTAssertTrue(gone(bar, timeout: 10), "a document with no state hides the bar")
        send("Chat, dot on", app)
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        app.webViews.links["Stateful page"].tap()
        XCTAssertTrue(app.webViews.staticTexts["mode: auto"].waitForExistence(timeout: 10))
        rendered(["selected=tasks", "hidden=false"], app)
        sleep(5)
        XCTAssertTrue(bar.exists && bar.isHittable, "a document that sends a state keeps the bar")
        line("doc: attr=true height=", [], app)
        app.terminate()
    }

    /// Stage 2 screenshots, dark: dot on and hidden.
    func testContractDark() {
        let (app, bar) = start("dark")
        hideAndShow("dark", app, bar)
        app.terminate()
    }

    /// Stage 4: the web's desktop breakpoint as this device's web view sees
    /// it. A 13-inch iPad (1032pt) is past the 1024px the hook hides at, so
    /// the web shows its desktop rail there and never asks for the native
    /// bar; an iPhone is below it.
    func testViewportAgainstTheDesktopBreakpoint() {
        let app = launch("light")
        let viewport = line("viewport: width=", [], app)
        note("stage4-viewport-\(UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")", viewport.label)
        let width = Int(viewport.label.components(separatedBy: "width=").last?.components(separatedBy: " ").first ?? "") ?? 0
        XCTAssertGreaterThan(width, 0, viewport.label)
        if width >= 1024 {
            line("viewport: width=", ["desktop=true"], app)
        } else {
            line("viewport: width=", ["desktop=false"], app)
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertGreaterThanOrEqual(width, 1024, "the CI iPad must be wide enough for the desktop rail: \(viewport.label)")
        } else {
            XCTAssertLessThan(width, 1024, viewport.label)
        }
        shot("stage4-viewport")
        app.terminate()
    }

    /// Stage 1: the glass probe, light and dark; task 01a174e8 stage 2's
    /// restyle on the same launch.
    func testFixtureLight() { fixture("light") }
    func testFixtureDark() { fixture("dark") }

    // MARK: Contrast over the real glass (task 01a174e8 stage 3)

    private let keys = ["chat", "voice", "tasks", "meetings", "more"]
    /// AX5. The launch argument takes the category's raw value
    /// (`UICTContentSizeCategoryAccessibilityXXXL`); the spelled-out name
    /// is not a category and leaves the default size.
    private let largestType = ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]

    /// Merges `value` under `key` into $EVIDENCE_DIR/contrast.json, so each
    /// test adds its own section and a failure later on keeps what is there.
    private func evidence(_ key: String, _ value: Any) {
        let url = dir.appendingPathComponent("contrast.json")
        var all = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        all[key] = value
        guard let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "contrast-\(key).json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The inks the bar is painting, from the probe's `ink=sel/unsel`.
    private func sentInks(_ rendered: String) -> (selected: SentInk, unselected: SentInk)? {
        guard let field = rendered.components(separatedBy: " ").first(where: { $0.hasPrefix("ink=") }) else { return nil }
        let parts = field.dropFirst(4).components(separatedBy: "/")
        guard parts.count == 2, let selected = SentInk(parts[0]), let unselected = SentInk(parts[1]) else { return nil }
        return (selected, unselected)
    }

    /// Opens the flat backdrop page; it sends Chat selected, the More dot
    /// on and the page scheme's inks.
    /// False under Reduce Transparency: the solid bar keeps the web's scheme.
    private var adaptiveStyle = true

    private func backdrop(_ colour: String, _ app: XCUIApplication, _ bar: XCUIElement) {
        app.webViews.links["Backdrop \(colour)"].tap()
        XCTAssertTrue(app.webViews.staticTexts["mode: buttons backdrop=\(colour)"].waitForExistence(timeout: 10))
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        // Option 1 (task 01a174e8 stage 3): the bar takes the style of the
        // content behind it, whatever the page's scheme.
        if adaptiveStyle { line("rendered: keys=", ["style=\(colour == "white" ? "light" : "dark")"], app, timeout: 30) }
    }

    /// Selects `selected`, screenshots the bar and measures every item:
    /// the selected one against the selected ink, the rest against the
    /// unselected ink. Returns the JSON and the worst-percentile ratios.
    private func measureBar(_ app: XCUIApplication, _ bar: XCUIElement, name: String, selected: String) -> ([String: Any], [Measured]) {
        if selected != "chat" { send("Select \(selected)", app) }
        let rendered = line("rendered: keys=", ["selected=\(selected) ", "badges=more ", "hidden=false"], app).label
        sleep(2)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? screenshot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
        guard let inks = sentInks(rendered) else { return (["error": "no ink in: \(rendered)"], []) }
        guard let raster = Raster(screenshot.image, pointWidth: app.frame.width) else { return (["error": "screenshot unreadable"], []) }
        var items: [String: Any] = [:]
        var measured: [Measured] = []
        for (index, key) in keys.enumerated() {
            let byId = bar.buttons["native-tab-\(key)"]
            let button = byId.exists ? byId : bar.buttons.element(boundBy: index)
            let state = key == selected ? "selected" : "unselected"
            let ink = key == selected ? inks.selected : inks.unselected
            let measurement = TabContrast.measure(raster, frame: button.frame, ink: ink, drawnWhenVibrant: state == "unselected")
            var json = measurement.json
            json["state"] = state
            json["sent_ink"] = ink.hex
            json["frame_pt"] = TabContrast.describe(button.frame)
            json["located_by"] = byId.exists ? "identifier" : "index"
            items[key] = json
            for (region, value) in measurement.ratios {
                measured.append(Measured(shot: name, key: key, state: state, region: region, value: value))
            }
        }
        return (["shot": "\(name).png", "rendered": rendered, "scale": raster.scale, "items": items], measured)
    }

    /// The worst value of each state x region cell, nil if never measured.
    private func cells(_ measured: [Measured]) -> [String: [String: Double]] {
        var out: [String: [String: Double]] = [:]
        for state in ["selected", "unselected"] {
            var regions: [String: Double] = [:]
            for region in ["label", "glyph"] {
                if let worst = measured.filter({ $0.state == state && $0.region == region }).map(\.value).min() {
                    regions[region] = TabContrast.round(worst)
                }
            }
            out[state] = regions
        }
        return out
    }

    private func assertCells(_ name: String, _ summary: [String: [String: Double]], file: StaticString = #filePath, line: UInt = #line) {
        for state in ["selected", "unselected"] {
            for (region, threshold) in [("label", 4.5), ("glyph", 3.0)] {
                guard let value = summary[state]?[region] else {
                    XCTFail("\(name) \(state) \(region): not measured", file: file, line: line)
                    continue
                }
                XCTAssertGreaterThanOrEqual(value, threshold, "\(name) \(state) \(region)", file: file, line: line)
            }
        }
    }

    /// Four combinations (light and dark over the white and the black
    /// backdrop), every tab selected once with the More dot on. The ink sent
    /// (with its alpha) is composited over each glass pixel around it; the
    /// asserted value is the 5th percentile of those ratios per region.
    /// Also the Reduce Transparency fallback, computed against the bar's
    /// opaque system fill (testReduceTransparency tries to measure it).
    func testContrastOverBackdrops() {
        continueAfterFailure = true
        var summaries: [String: [String: [String: Double]]] = [:]
        var computed: [String: Any] = [:]
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            let bar = app.tabBars["native-tab-bar"]
            var lastRendered = ""
            for colour in ["white", "black"] {
                backdrop(colour, app, bar)
                var shots: [String: Any] = [:]
                var measured: [Measured] = []
                for key in keys {
                    let (json, values) = measureBar(app, bar, name: "contrast-\(appearance)-\(colour)-\(key)", selected: key)
                    shots[key] = json
                    measured += values
                    lastRendered = (json["rendered"] as? String) ?? lastRendered
                }
                let name = "\(appearance)-\(colour)"
                let summary = cells(measured)
                summaries[name] = summary
                evidence("combo-\(name)", ["summary": summary, "selected_shots": shots, "method": TabContrast.method] as [String: Any])
            }
            if let inks = sentInks(lastRendered) {
                computed[appearance] = TabContrast.opaqueFill(appearance, inks.selected, inks.unselected)
            }
            app.terminate()
        }
        evidence("summary", summaries)
        evidence("reduce_transparency_computed", computed)
        for (name, summary) in summaries.sorted(by: { $0.key < $1.key }) { assertCells(name, summary) }
        XCTAssertEqual(summaries.count, 4, "\(summaries.keys)")
    }

    /// Largest Dynamic Type (AX5): no label truncated, labels at the 13pt
    /// cap, Chat and Meetings selected, More dot on.
    func testLargestDynamicType() {
        continueAfterFailure = true
        var out: [String: Any] = [:]
        for (appearance, colour, key) in [("light", "white", "chat"), ("dark", "black", "meetings")] {
            let app = launch(appearance, extra: largestType)
            let bar = app.tabBars["native-tab-bar"]
            backdrop(colour, app, bar)
            assertLabels(bar, five)
            let name = "dynamic-type-\(appearance)-\(colour)-\(key)"
            let (json, measured) = measureBar(app, bar, name: name, selected: key)
            let rendered = (json["rendered"] as? String) ?? ""
            out[name] = ["shot": json, "summary": cells(measured)] as [String: Any]
            evidence("dynamic_type", out)
            XCTAssertTrue(rendered.contains("truncated=none"), rendered)
            XCTAssertTrue(rendered.contains("fonts=Public Sans 13 w550"), rendered)
            app.terminate()
        }
    }

    /// Reduce Transparency, measured if the simulator can be switched to it
    /// through Settings; otherwise recorded as not measured (the computed
    /// values from testContrastOverBackdrops stand). Switched back off.
    func testReduceTransparency() {
        continueAfterFailure = true
        if let reason = setReduceTransparency(true) {
            evidence("reduce_transparency_measured", ["measured": false, "reason": reason] as [String: Any])
            _ = setReduceTransparency(false)
            return
        }
        adaptiveStyle = false
        var out: [String: Any] = ["measured": true]
        var summaries: [String: [String: [String: Double]]] = [:]
        var grounds: [String: String] = [:]
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            let bar = app.tabBars["native-tab-bar"]
            for colour in ["white", "black"] {
                backdrop(colour, app, bar)
                var measured: [Measured] = []
                var shots: [String: Any] = [:]
                for key in ["chat", "more"] {
                    let (json, values) = measureBar(app, bar, name: "reduce-transparency-\(appearance)-\(colour)-\(key)", selected: key)
                    shots[key] = json
                    measured += values
                    if key == "chat", let items = json["items"] as? [String: Any], let voice = items["voice"] as? [String: Any] {
                        grounds["\(appearance)-\(colour)"] = voice["item_glass_median"] as? String
                    }
                }
                summaries["\(appearance)-\(colour)"] = cells(measured)
                out["shots-\(appearance)-\(colour)"] = shots
            }
            app.terminate()
        }
        // Solid: the glass behind an unselected item reads the same over
        // white and over black.
        let solid = ["light", "dark"].allSatisfy { appearance in
            guard let white = grounds["\(appearance)-white"], let black = grounds["\(appearance)-black"] else { return false }
            return TabContrast.close(white, black, within: 6)
        }
        out["glass_median_voice"] = grounds
        out["solid"] = solid
        out["summary"] = summaries
        evidence("reduce_transparency_measured", out)
        _ = setReduceTransparency(false)
        if solid {
            for (name, summary) in summaries.sorted(by: { $0.key < $1.key }) { assertCells("reduce-transparency-\(name)", summary) }
        }
    }

    /// Flips Settings > Accessibility > Display & Text Size > Reduce
    /// Transparency. Nil when the switch reads `on`; otherwise why not.
    private func setReduceTransparency(_ on: Bool) -> String? {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        for label in ["Accessibility", "Display & Text Size"] {
            let target = settings.staticTexts[label].firstMatch
            guard reveal(target, in: settings) else {
                settings.terminate()
                return "Settings: '\(label)' not found"
            }
            target.tap()
        }
        let toggle = settings.switches["Reduce Transparency"].firstMatch
        guard reveal(toggle, in: settings) else {
            settings.terminate()
            return "Settings: no 'Reduce Transparency' switch"
        }
        let want = on ? "1" : "0"
        func value() -> String { (toggle.value as? String) ?? (toggle.value as? NSNumber)?.stringValue ?? "?" }
        if value() != want { toggle.tap() }
        sleep(1)
        if value() != want { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
        sleep(1)
        let now = value()
        settings.terminate()
        return now == want ? nil : "Settings: the switch reads \(now) after tapping"
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 {
            if element.waitForExistence(timeout: 3), element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }
}

// MARK: Contrast measurement (task 01a174e8 stage 3)

/// One worst-percentile ratio: a region of one item in one screenshot.
struct Measured {
    let shot: String
    let key: String
    let state: String
    let region: String
    let value: Double
}

/// An sRGB colour, channels 0...1.
struct RGB {
    var r: Double
    var g: Double
    var b: Double
}

/// A '#rrggbbaa' ink as the probe reports it (`rrggbbaa`, no '#'): the
/// value the web sent, read back from the bar. Not a literal.
struct SentInk {
    let colour: RGB
    let alpha: Double
    let hex: String

    init?(_ hex: String) {
        guard hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        let channel = { (shift: UInt32) in Double(value >> shift & 0xff) / 255 }
        colour = RGB(r: channel(24), g: channel(16), b: channel(8))
        alpha = channel(0)
        self.hex = hex
    }
}

/// A screenshot as 8-bit sRGB pixels, row 0 at the top.
struct Raster {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    /// Pixels per point.
    let scale: Double

    init?(_ image: UIImage, pointWidth: CGFloat) {
        guard let cg = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB), pointWidth > 0 else { return nil }
        let w = cg.width
        let h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        pixels = data
        scale = Double(w) / Double(pointWidth)
    }

    func at(_ x: Int, _ y: Int) -> RGB {
        let i = (y * width + x) * 4
        return RGB(r: Double(pixels[i]) / 255, g: Double(pixels[i + 1]) / 255, b: Double(pixels[i + 2]) / 255)
    }
}

/// WCAG 2.x contrast of a tab item's ink over the glass behind it.
///
/// In the item's frame, the glass reference is the per-channel median, and
/// the sent ink composited over it (with its alpha) gives the ink's
/// direction from the glass. Each pixel is projected on that direction:
/// past half way it is ink, under a fifth it is glass, between is the
/// anti-aliased edge (counted, not used). Rows (or, for an inline layout,
/// columns) with ink split the item into the glyph and the label (the last
/// cluster). For every glass pixel in a region, padded 2pt, the sent ink is
/// composited over THAT pixel and the ratio taken; the region's value is
/// the 5th percentile, so the worst glass around the ink decides it.
/// The ink the system actually drew (the strongest quarter of the ink
/// pixels) is reported beside it, so a vibrant ink that ignores the tint
/// shows up as a large `drawn_vs_sent`; for unselected items that value is
/// then measured with the drawn ink (`measured_against: drawn`).
enum TabContrast {
    static let method = "sent ink (with its alpha) composited over each glass pixel in the region (2pt pad); value = 5th percentile of the WCAG 2.x ratios; an unselected item whose drawn ink is not the sent one (iOS 26 vibrant ink) is measured with the drawn ink, opaque; label >= 4.5, glyph >= 3"

    static func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }

    static func luminance(_ c: RGB) -> Double { 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b) }

    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func over(_ ink: SentInk, _ ground: RGB) -> RGB {
        let a = ink.alpha
        return RGB(r: ink.colour.r * a + ground.r * (1 - a), g: ink.colour.g * a + ground.g * (1 - a), b: ink.colour.b * a + ground.b * (1 - a))
    }

    static func hex(_ c: RGB) -> String {
        let byte = { (v: Double) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02x%02x%02x", byte(c.r), byte(c.g), byte(c.b))
    }

    static func round(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    static func describe(_ frame: CGRect) -> String {
        "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
    }

    /// Two `rrggbb` strings within `within` (0-255) on every channel.
    static func close(_ a: String, _ b: String, within: Int) -> Bool {
        guard let x = UInt32(a, radix: 16), let y = UInt32(b, radix: 16) else { return false }
        return [16, 8, 0].allSatisfy { (shift: UInt32) in abs(Int(x >> shift & 0xff) - Int(y >> shift & 0xff)) <= within }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    static func medianColour(_ colours: [RGB]) -> RGB {
        RGB(r: median(colours.map(\.r)), g: median(colours.map(\.g)), b: median(colours.map(\.b)))
    }

    /// Runs of non-zero counts, joining gaps up to `gap`; runs holding fewer
    /// than `minimum` ink pixels are noise and dropped.
    static func clusters(_ counts: [Int], gap: Int, minimum: Int) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        var current: (start: Int, end: Int, total: Int)?
        for (i, count) in counts.enumerated() where count > 0 {
            if let run = current, i - run.end <= gap + 1 {
                current = (run.start, i, run.total + count)
            } else {
                if let run = current, run.total >= minimum { out.append(run.start...run.end) }
                current = (i, i, count)
            }
        }
        if let run = current, run.total >= minimum { out.append(run.start...run.end) }
        return out
    }

    /// The opaque system bar fill (UITabBarAppearance's opaque background)
    /// resolved in `appearance`, and the four ratios of the sent inks on it.
    static func opaqueFill(_ appearance: String, _ selected: SentInk, _ unselected: SentInk) -> [String: Any] {
        let bar = UITabBarAppearance()
        bar.configureWithOpaqueBackground()
        let source = bar.backgroundColor == nil ? "UIColor.systemBackground" : "UITabBarAppearance.configureWithOpaqueBackground().backgroundColor"
        let traits = UITraitCollection(userInterfaceStyle: appearance == "dark" ? .dark : .light)
        let colour = (bar.backgroundColor ?? UIColor.systemBackground).resolvedColor(with: traits)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard colour.getRed(&r, green: &g, blue: &b, alpha: &a) else { return ["error": "fill unresolved", "source": source] }
        let fill = RGB(r: Double(r), g: Double(g), b: Double(b))
        let sel = round(ratio(over(selected, fill), fill))
        let unsel = round(ratio(over(unselected, fill), fill))
        return [
            "mode": "computed",
            "source": source,
            "fill": hex(fill),
            "fill_alpha": round(Double(a)),
            "selected": ["label": sel, "glyph": sel, "ink": selected.hex] as [String: Any],
            "unselected": ["label": unsel, "glyph": unsel, "ink": unselected.hex] as [String: Any],
        ]
    }

    /// Past this (0-255, any channel) the drawn ink is not the sent one.
    static let vibrantApart = 32

    /// `drawnWhenVibrant`: when the system drew its own ink instead of the
    /// tint (iOS 26 glass does this for unselected items), the value is
    /// taken with the DRAWN ink, opaque, over each glass pixel; the sent
    /// ink's value is still reported as `ratio_p5_sent`.
    static func measure(_ raster: Raster, frame: CGRect, ink: SentInk, drawnWhenVibrant: Bool = false) -> (json: [String: Any], ratios: [String: Double]) {
        let s = raster.scale
        let x0 = max(0, Int((Double(frame.minX) * s).rounded()))
        let x1 = min(raster.width - 1, Int((Double(frame.maxX) * s).rounded()) - 1)
        let y0 = max(0, Int((Double(frame.minY) * s).rounded()))
        let y1 = min(raster.height - 1, Int((Double(frame.maxY) * s).rounded()) - 1)
        guard x1 > x0 + 8, y1 > y0 + 8 else { return (["error": "frame off screen: \(describe(frame))"], [:]) }
        let w = x1 - x0 + 1
        let h = y1 - y0 + 1
        var colours: [RGB] = []
        colours.reserveCapacity(w * h)
        for y in y0...y1 {
            for x in x0...x1 { colours.append(raster.at(x, y)) }
        }
        let ground = medianColour(colours)
        let expected = over(ink, ground)
        let d = RGB(r: expected.r - ground.r, g: expected.g - ground.g, b: expected.b - ground.b)
        let d2 = d.r * d.r + d.g * d.g + d.b * d.b
        var json: [String: Any] = [
            "item_glass_median": hex(ground),
            "item_expected_ink": hex(expected),
            "item_ratio_on_median": round(ratio(expected, ground)),
        ]
        guard d2 > 1e-6 else {
            json["error"] = "the sent ink equals the glass: no ink to find"
            return (json, ["label": round(ratio(expected, ground)), "glyph": round(ratio(expected, ground))])
        }
        // Projection on the glass-to-ink direction; the outer 1pt ring of
        // the frame is left out (the platter's edge light can reach it).
        let ring = max(1, Int(s.rounded()))
        var t = [Double](repeating: 0, count: w * h)
        var rowInk = [Int](repeating: 0, count: h)
        var colInk = [Int](repeating: 0, count: w)
        for j in ring..<max(ring, h - ring) {
            for i in ring..<max(ring, w - ring) {
                let p = colours[j * w + i]
                let value = ((p.r - ground.r) * d.r + (p.g - ground.g) * d.g + (p.b - ground.b) * d.b) / d2
                t[j * w + i] = value
                if value > 0.5 {
                    rowInk[j] += 1
                    colInk[i] += 1
                }
            }
        }
        let gap = max(1, Int((1.5 * s).rounded()))
        let minimum = Int((6 * s * s).rounded())
        let rowRuns = clusters(rowInk, gap: gap, minimum: minimum)
        let pad = Int((2 * s).rounded())
        var regions: [(String, ClosedRange<Int>, ClosedRange<Int>)] = []
        func columns(in rows: ClosedRange<Int>) -> ClosedRange<Int>? {
            var lo: Int?
            var hi: Int?
            for j in rows {
                for i in 0..<w where t[j * w + i] > 0.5 {
                    lo = min(lo ?? i, i)
                    hi = max(hi ?? i, i)
                }
            }
            guard let lo, let hi else { return nil }
            return lo...hi
        }
        func rows(in cols: ClosedRange<Int>) -> ClosedRange<Int>? {
            var lo: Int?
            var hi: Int?
            for j in 0..<h {
                for i in cols where t[j * w + i] > 0.5 {
                    lo = min(lo ?? j, j)
                    hi = max(hi ?? j, j)
                }
            }
            guard let lo, let hi else { return nil }
            return lo...hi
        }
        if rowRuns.count >= 2, let last = rowRuns.last, let first = rowRuns.first {
            // Stacked: glyph above, label below.
            let glyphRows = first.lowerBound...rowRuns[rowRuns.count - 2].upperBound
            let labelRows = last
            let glyphPadded = max(0, glyphRows.lowerBound - pad)...min(labelRows.lowerBound - 1, glyphRows.upperBound + pad)
            let labelPadded = max(glyphRows.upperBound + 1, labelRows.lowerBound - pad)...min(h - 1, labelRows.upperBound + pad)
            if let gc = columns(in: glyphRows), let lc = columns(in: labelRows) {
                regions.append(("glyph", glyphPadded, max(0, gc.lowerBound - pad)...min(w - 1, gc.upperBound + pad)))
                regions.append(("label", labelPadded, max(0, lc.lowerBound - pad)...min(w - 1, lc.upperBound + pad)))
                json["label_width_pt"] = round(Double(lc.count) / s)
            }
            json["layout"] = "stacked"
        } else if let firstCol = colInk.firstIndex(where: { $0 > 0 }), let lastCol = colInk.lastIndex(where: { $0 > 0 }) {
            // Inline (regular width): the glyph's 25pt box, then the label.
            let glyphEnd = min(lastCol, firstCol + Int((25.5 * s).rounded()))
            let labelStart = colInk[(glyphEnd + 1)...].firstIndex(where: { $0 > 0 }) ?? lastCol
            if labelStart > glyphEnd, let gr = rows(in: firstCol...glyphEnd), let lr = rows(in: labelStart...lastCol) {
                let glyphCols = max(0, firstCol - pad)...min(labelStart - 1, glyphEnd + pad)
                let labelCols = max(glyphEnd + 1, labelStart - pad)...min(w - 1, lastCol + pad)
                regions.append(("glyph", max(0, gr.lowerBound - pad)...min(h - 1, gr.upperBound + pad), glyphCols))
                regions.append(("label", max(0, lr.lowerBound - pad)...min(h - 1, lr.upperBound + pad), labelCols))
                json["label_width_pt"] = round(Double(lastCol - labelStart + 1) / s)
            }
            json["layout"] = "inline"
        }
        json["row_runs"] = rowRuns.map { "\($0.lowerBound)-\($0.upperBound)" }
        guard regions.count == 2 else {
            json["error"] = "could not split glyph and label (row runs \(rowRuns.count))"
            return (json, [:])
        }
        var ratios: [String: Double] = [:]
        for (name, rowRange, colRange) in regions {
            var glass: [RGB] = []
            var inkPixels: [(Double, RGB)] = []
            var edge = 0
            for j in rowRange {
                for i in colRange {
                    let value = t[j * w + i]
                    let p = colours[j * w + i]
                    if value < 0.2 {
                        glass.append(p)
                    } else if value > 0.5 {
                        // The badge's system red is not tab ink.
                        if !(p.r > 0.85 && p.g < 0.4 && p.b < 0.4) { inkPixels.append((value, p)) }
                    } else {
                        edge += 1
                    }
                }
            }
            guard !glass.isEmpty else {
                json[name] = ["error": "no glass pixels"]
                continue
            }
            let regionGround = medianColour(glass)
            let regionExpected = over(ink, regionGround)
            var drawn: RGB?
            var apart = 0
            if !inkPixels.isEmpty {
                let strongest = inkPixels.sorted { $0.0 > $1.0 }.prefix(max(1, inkPixels.count / 4)).map { $0.1 }
                let n = Double(strongest.count)
                let mean = RGB(
                    r: strongest.map(\.r).reduce(0, +) / n, g: strongest.map(\.g).reduce(0, +) / n, b: strongest.map(\.b).reduce(0, +) / n
                )
                drawn = mean
                let gap = [abs(mean.r - regionExpected.r), abs(mean.g - regionExpected.g), abs(mean.b - regionExpected.b)].max() ?? 0
                apart = Int((gap * 255).rounded())
            }
            func percentile(_ ratios: [Double]) -> Double {
                let sorted = ratios.sorted()
                return sorted[min(sorted.count - 1, sorted.count * 5 / 100)]
            }
            let sentValues = glass.map { ratio(over(ink, $0), $0) }
            let sentP5 = percentile(sentValues)
            var p5 = sentP5
            var against = "sent"
            var values = sentValues
            if drawnWhenVibrant, let drawn, apart > vibrantApart {
                values = glass.map { ratio(drawn, $0) }
                p5 = percentile(values)
                against = "drawn"
            }
            values.sort()
            var entry: [String: Any] = [
                "ratio_p5": round(p5),
                "ratio_p5_sent": round(sentP5),
                "measured_against": against,
                "ratio_min": round(values[0]),
                "ratio_median": round(values[values.count / 2]),
                "glass_pixels": values.count,
                "ink_pixels": inkPixels.count,
                "edge_pixels": edge,
                "glass_median": hex(regionGround),
                "expected_ink": hex(regionExpected),
                "rows_px": "\(rowRange.lowerBound)-\(rowRange.upperBound)",
                "cols_px": "\(colRange.lowerBound)-\(colRange.upperBound)",
            ]
            if let drawn {
                entry["drawn_ink"] = hex(drawn)
                entry["drawn_ratio"] = round(ratio(drawn, regionGround))
                entry["drawn_vs_sent"] = apart
            }
            json[name] = entry
            ratios[name] = p5
        }
        return (json, ratios)
    }
}
