import AppIntentsTesting
import XCTest

/// Task 01a111bb stage 5: on iOS 27 the existing AskAgentIntent type is
/// long-running and cancellable (an availability-gated conformance, so
/// existing Shortcuts keep the same type). Run like the other system tests.
@available(iOS 27.0, *)
final class AskAgentSystemTests: XCTestCase {
    let definitions = IntentDefinitions(bundleIdentifier: "com.kobo-ai.burrow")

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { XCUIApplication().launch() }
    }

    /// An agent on a host that is not a saved install resolves to nothing,
    /// so the ask is never posted: it fails asking for the agent again.
    func testAskingAForeignHostsAgentPostsNothing() async throws {
        let agent = definitions.entities["AgentEntity"].makeReference(identifier: "evil.example.com|0a0a0a0a-0000-4000-8000-000000000001")
        do {
            _ = try await definitions.intents["AskAgentIntent"].makeIntent(agent: agent, question: "Is it done?").run()
            XCTFail("asked an agent on a host that is not a saved install")
        } catch {
            let text = String(describing: error)
            print("system-test AskAgentIntent refused: \(text.prefix(300))")
            XCTAssertTrue(text.contains("requested value for parameter 'agent'"), String(text.prefix(200)))
        }
    }
}
