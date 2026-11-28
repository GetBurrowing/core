import AppIntentsTesting
import XCTest

/// Task 01a21e75 stage 5: StartVoiceTurnIntent run out of process against
/// the installed Burrow, with the app in the background (see
/// MessagesDomainSystemTests for how to run).
///
/// What AppIntentsTesting can and cannot say here: it runs the intent and
/// XCUIApplication reports whether Burrow came to the foreground. It has no
/// API for another process's Live Activities (`Activity.activities` answers
/// only inside the app that requested them), so "an Activity exists" is NOT
/// asserted here; VoiceTurnRunnerTests covers the request through its seam,
/// and only a device shows the activity itself.
@available(iOS 27.0, *)
final class VoiceTurnSystemTests: XCTestCase {
    let definitions = IntentDefinitions(bundleIdentifier: "com.kobo-ai.burrow")

    func testStartVoiceTurnRunsWithoutForegroundingTheApp() async throws {
        let app = await MainActor.run { XCUIApplication() }
        await MainActor.run {
            app.launch()
            XCUIDevice.shared.press(.home)
        }
        _ = await MainActor.run { app.wait(for: .runningBackground, timeout: 10) }

        _ = try await definitions.intents["StartVoiceTurnIntent"].makeIntent().run()

        let state = await MainActor.run { app.state }
        print("system-test StartVoiceTurnIntent app_state=\(state.rawValue)")
        XCTAssertNotEqual(state, .runningForeground, "the intent brought Burrow to the foreground")
    }
}
