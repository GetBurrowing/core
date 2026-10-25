import UIKit
import XCTest

/// The native tab bar on the `-BurrowTabBarFixture` page (task 01a1557b):
/// stage 2's contract (items, selection, dot, taps, hide/show, the
/// document-start script, the no-state hide) and stage 1's glass probe.
/// Light and dark (stage 1 spiked a UITabBarController hosting too; see
/// clients/ios/README.md, "Native tab bar"). Writes a PNG per state
/// and the native glass probe to $EVIDENCE_DIR (pass
/// TEST_RUNNER_EVIDENCE_DIR to xcodebuild), and attaches both to the result.
final class TabBarUITests: XCTestCase {
    private var dir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["EVIDENCE_DIR"] ?? NSTemporaryDirectory())
    }

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-BurrowTabBarFixture", "YES", "-BurrowTabBarFixtureAppearance", appearance]
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
    private let inks = ["light": "ad4b07ff/0000008c", "dark": "f47721ff/eeeff18c"]

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
        send(other == "dark" ? "Ink dark" : "Ink light", app)
        rendered(["ink=\(inks[other]!)", "style=\(other)"], app)
        sleep(1)
        shot("restyle-\(appearance)-then-\(other)")
        send("Ink malformed", app)
        sleep(2)
        rendered(["ink=\(inks[other]!)", "style=\(other)"], app)

        // Last, so the screenshots above exist whatever it says: iOS drew the
        // per-item font (rung 26 rule zero: no UITabBarAppearance on 26+).
        XCTAssertTrue(drawn.hasSuffix("fonts=Public Sans 11 w550"), drawn)
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
}
