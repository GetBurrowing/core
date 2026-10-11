import XCTest

/// Drives the app into each state the stage evidence canvas shows and writes
/// a PNG per state to $EVIDENCE_DIR (pass TEST_RUNNER_EVIDENCE_DIR to
/// xcodebuild). Not an assertion suite; the App scheme's AppTests is.
final class EvidenceUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var dir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["EVIDENCE_DIR"] ?? NSTemporaryDirectory())
    }

    override func setUp() {
        continueAfterFailure = true
    }

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private func note(_ name: String, _ text: String) {
        try? text.write(to: dir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }

    /// ASWebAuthenticationSession's consent alert: in the app's own tree on
    /// iOS 26, in springboard on older runtimes.
    private func consentButton(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let inApp = app.alerts.buttons[label]
        return inApp.exists ? inApp : (springboard.alerts.buttons[label].exists ? springboard.alerts.buttons[label] : inApp)
    }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        return app
    }

    func test1Picker() {
        var app = launch(["-SuiteEvidenceReset", "YES"])
        XCTAssertTrue(app.staticTexts["Choose a Burrow install"].waitForExistence(timeout: 15))
        sleep(5)
        shot("picker-first-launch")
        app.terminate()

        app = launch(["-SuiteExtraInstall", "suite-offline.invalid"])
        XCTAssertTrue(app.staticTexts["Choose a Burrow install"].waitForExistence(timeout: 15))
        sleep(6)
        shot("picker-saved-unreachable")
        app.staticTexts["suite.milv.life"].firstMatch.swipeLeft()
        sleep(1)
        shot("picker-swipe-remove")
        app.staticTexts["Choose a Burrow install"].tap()
        sleep(1)

        app.buttons["Add an install"].tap()
        let field = app.textFields["install-address"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("example.com")
        app.buttons["Check and add"].tap()
        let error = app.staticTexts["Couldn't find Burrow at this address. Check the spelling, or ask your admin for the link."]
        XCTAssertTrue(error.waitForExistence(timeout: 20))
        shot("picker-add-error")
        app.swipeDown(velocity: .fast)
        app.swipeDown(velocity: .fast)
        for _ in 0..<10 where field.exists { sleep(1) }
        sleep(2)

        let offline = app.staticTexts["suite-offline.invalid"].firstMatch
        XCTAssertTrue(offline.waitForExistence(timeout: 5))
        // The first tap can be spent closing the row left swiped open.
        offline.tap()
        sleep(1)
        offline.tap()
        sleep(2)
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Can't reach suite-offline.invalid"].waitForExistence(timeout: 20))
        shot("picker-cant-reach")
        app.buttons["Choose another install"].tap()

        app.staticTexts["suite.example.com"].firstMatch.tap()
        app.buttons["Continue"].tap()
        // ASWebAuthenticationSession's consent alert belongs to springboard.
        let consent = consentButton(app, "Continue")
        if consent.waitForExistence(timeout: 20) {
            shot("login-consent")
            consent.tap()
            sleep(8)
            shot("login-sheet-fabrikam")
            // Leave the sheet: Cancel in the auth session's navigation bar.
            if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
            sleep(2)
        } else {
            shot("login-no-consent")
        }
    }

    func test2LoginProbe() {
        let app = launch(["-SuiteLoginProbe", "suite.example.com"])
        let signIn = app.webViews.buttons["Sign in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 30))
        shot("probe-1-pocket-id-in-wkwebview")
        signIn.tap()
        sleep(8)
        shot("probe-2-after-sign-in-tap")
        let texts = app.webViews.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        let alerts = springboard.alerts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        let sheets = springboard.otherElements.allElementsBoundByIndex.prefix(0)
        _ = sheets
        note("probe-after-tap", "webview text:\n\(texts)\n\nspringboard alerts:\n\(alerts)\n")
    }

    func test3Notification() {
        let app = launch(["-SuiteRequestPush", "YES"])
        for _ in 0..<3 {
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 5) { allow.tap() }
            // Relaunching with fabrikam confirmed and no session starts sign-in.
            let cancel = consentButton(app, "Cancel")
            if cancel.waitForExistence(timeout: 5) { cancel.tap() }
        }
        sleep(2)
        XCUIDevice.shared.press(.home)
        // The harness runs `xcrun simctl push` while this waits.
        let banner = springboard.otherElements["NotificationShortLookView"].firstMatch
        guard banner.waitForExistence(timeout: 90) else {
            shot("notification-missing")
            return
        }
        shot("notification-banner")
        banner.press(forDuration: 1.2)
        sleep(2)
        shot("notification-expanded")
        _ = app
    }

    /// Task 01a1261e review round 2: what iOS RENDERS for a chat push from
    /// one of two signed-in installs. The harness first copies each payload
    /// named in $COMM_FILES (comma-separated) into the App Group container;
    /// each runs through the DEBUG `-SuiteDebugLocalPush` seam (the Notification
    /// Service Extension's own two calls). Writes every Notification Center
    /// cell's accessibility label to `<tag>-nc-cells.txt`.
    func testCommunicationNotificationLabels() {
        let env = ProcessInfo.processInfo.environment
        let tag = env["COMM_TAG"] ?? "comm"
        let files = (env["COMM_FILES"] ?? "").split(separator: ",").map(String.init)
        let extra = (env["COMM_ARGS"] ?? "").split(separator: " ").map(String.init)
        var app = launch(["-SuiteRequestPush", "YES"])
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }
        sleep(2)
        app.terminate()
        for file in files {
            app = launch(["-SuiteDebugLocalPush", file] + extra)
            sleep(2)
            XCUIDevice.shared.press(.home)
            sleep(5)
        }
        let cells = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'NotificationShortLookView' OR identifier == 'NotificationCell'"))
        // Pull down Notification Center from the top left; retry, since the
        // first drag can land while springboard is still animating.
        for _ in 0..<4 where cells.count == 0 {
            let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.0))
            start.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.8)))
            sleep(4)
        }
        var labels: [String] = []
        for index in 0..<min(cells.count, 30) { labels.append(cells.element(boundBy: index).label) }
        note("\(tag)-nc-cells", labels.joined(separator: "\n---\n"))
        shot("\(tag)-nc")
        XCUIDevice.shared.press(.home)
    }

    /// Task 01a1261e review round 2: the picker as it renders, after the
    /// harness set up the installs. Writes the row labels and a screenshot.
    func testPickerRows() {
        let env = ProcessInfo.processInfo.environment
        let tag = env["COMM_TAG"] ?? "picker"
        let extra = (env["COMM_ARGS"] ?? "").split(separator: " ").map(String.init)
        let app = launch(extra)
        let title = app.staticTexts["Choose a Burrow install"]
        if !title.waitForExistence(timeout: 20) { shot("\(tag)-no-picker") }
        sleep(12)
        let rows = app.descendants(matching: .any).allElementsBoundByIndex.prefix(300).map(\.label).filter { !$0.isEmpty }
        note("\(tag)-rows", rows.joined(separator: "\n"))
        shot("\(tag)-picker")
    }

    /// Task 01a120be stage 4: the "Sent to #<space>" notification a finished
    /// background upload posts, drawn by the system.
    func test4UploadSentNotification() {
        let app = launch(["-SuiteEvidenceSentNotification", "design-review"])
        for _ in 0..<3 {
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 5) { allow.tap() }
            let cancel = consentButton(app, "Cancel")
            if cancel.waitForExistence(timeout: 3) { cancel.tap() }
        }
        XCUIDevice.shared.press(.home)
        let banner = springboard.otherElements["NotificationShortLookView"].firstMatch
        guard banner.waitForExistence(timeout: 60) else {
            shot("upload-sent-missing")
            return
        }
        shot("upload-sent-notification")
    }
}
