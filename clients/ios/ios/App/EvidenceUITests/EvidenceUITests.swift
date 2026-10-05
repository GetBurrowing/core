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
}
