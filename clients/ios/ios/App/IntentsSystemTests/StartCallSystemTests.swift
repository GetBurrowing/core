import AppIntentsTesting
import XCTest

/// Task 01a111bb stage 6: the phone-domain call, run out of process against
/// the installed Burrow (see MessagesDomainSystemTests for how to run).
@available(iOS 27.0, *)
final class StartCallSystemTests: XCTestCase {
    let definitions = IntentDefinitions(bundleIdentifier: "com.kobo-ai.burrow")

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { XCUIApplication().launch() }
    }

    /// A person on a host that is not a saved install resolves to nothing,
    /// so no meeting is created and nobody is rung.
    func testCallingAForeignHostsPersonCreatesNoMeeting() async throws {
        let person = definitions.entities["CallPersonEntity"].makeReference(identifier: "evil.example.com|9e000000-0000-4000-8000-000000000001")
        do {
            _ = try await definitions.intents["StartCallIntent"].makeIntent(destination: person, audioVisualMode: "audio").run()
            XCTFail("called a person on a host that is not a saved install")
        } catch {
            let text = String(describing: error)
            print("system-test StartCallIntent refused: \(text.prefix(300))")
            XCTAssertTrue(text.contains("requested value for parameter 'destination'"), String(text.prefix(200)))
        }
    }
}
