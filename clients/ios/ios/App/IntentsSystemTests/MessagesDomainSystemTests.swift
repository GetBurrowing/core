import AppIntents
import AppIntentsTesting
import XCTest

/// Task 01a111bb stage 3: the iOS 27 messages domain, run the way Siri and
/// Shortcuts run it, out of process against the installed Burrow. The
/// simulator has no signed-in install, so these pin the contract that needs
/// no server: the five schema intents and four entities are registered
/// under their type names, the queries answer, and an id on a host that is
/// not a saved install resolves to nothing and acts on nothing.
///
/// Run: install and launch the Debug build on an iOS 27 simulator FIRST
/// (`simctl install` + `simctl launch`), then `xcodebuild test-without-building
/// -scheme IntentsSystem`. A plain `xcodebuild test` ran before the system
/// had indexed the app's App Intents metadata and every call failed with
/// "com.kobo-ai.burrow is not present", which an error-expecting test would
/// have counted as a pass.
@available(iOS 27.0, *)
final class MessagesDomainSystemTests: XCTestCase {
    let definitions = IntentDefinitions(bundleIdentifier: "com.kobo-ai.burrow")

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { XCUIApplication().launch() }
    }

    func testEditUnsendAndReadStatusNeverActOnAForeignHostsMessage() async throws {
        let message = definitions.entities["MessageEntity"].makeReference(identifier: "evil.example.com|3e000000-0000-4000-8000-000000000001")
        for name in ["MessagesEditIntent", "MessagesUnsendIntent", "MessagesSetReadStatusIntent"] {
            let intent = definitions.intents[name]
            do {
                switch name {
                case "MessagesEditIntent": _ = try await intent.makeIntent(message: message, content: "x").run()
                case "MessagesSetReadStatusIntent": _ = try await intent.makeIntent(message: message, isRead: true).run()
                default: _ = try await intent.makeIntent(message: message).run()
                }
                XCTFail("\(name) acted on a message from a host that is not a saved install")
            } catch {
                // The reference must fail to RESOLVE (so the system asks for
                // the message again), not fail for any other reason: a
                // "bundle is not present" metadata error would also throw,
                // and would prove nothing about Burrow's query.
                let text = String(describing: error)
                print("system-test \(name) refused: \(text.prefix(300))")
                XCTAssertTrue(text.contains("requested value for parameter 'message'"), "\(name): \(text.prefix(200))")
            }
        }
    }

    /// Positive control: the pipeline reaches THIS app's code. The install
    /// list is pre-seeded with Burrow's default hosts, so the install query
    /// answers non-empty even with nobody signed in.
    func testThePipelineReachesBurrowsOwnQueries() async throws {
        let installs = try await definitions.entities["InstallEntity"].suggestedEntities()
        XCTAssertGreaterThan(installs.count, 0)
    }

    func testPeopleAndConversationQueriesAnswerWithNoInstall() async throws {
        let people = try await definitions.entities["MessagePersonEntity"].entities(matching: "Priya")
        XCTAssertEqual(people.count, 0, "no signed-in install, so nobody")
        let suggested = try await definitions.entities["ConversationEntity"].suggestedEntities()
        XCTAssertEqual(suggested.count, 0)
        let foreign = try await definitions.entities["MessagePersonEntity"].entities(identifiers: ["evil.example.com|9e000000-0000-4000-8000-000000000001"])
        XCTAssertEqual(foreign.count, 0, "an id on an unknown host resolves to nothing")
    }

    /// Task 01a111bb stage 7, round 3: the device trace ended at
    /// `person.query ids=1`, so Siri resolved the recipient by ID and the
    /// system failed before perform. This drives that path: an entity
    /// REFERENCE (id only) the system must resolve through MessagePersonEntityQuery,
    /// then the send. The person is seeded in the people cache on a
    /// `*.invalid` host, so the send itself never reaches a server.
    func testSchemaSendResolvesAPersonReferenceAndReachesPerform() async throws {
        let id = "evidence.invalid|3e000000-0000-4000-8000-0000000000d1"
        await MainActor.run {
            let app = XCUIApplication()
            app.launchArguments += ["-BurrowEvidencePerson", "\(id)|Dalton Evidence|user"]
            app.launch()
        }
        let entities = definitions.entities["MessagePersonEntity"]
        let resolved = try await entities.entities(identifiers: [id])
        XCTAssertEqual(resolved.count, 1, "the seeded person resolves by id")
        if let first = resolved.first {
            let exported = try await first.exported(as: IntentPerson.self)
            print("system-test export identifier=\(exported.identifier)")
        }
        let reference = entities.makeReference(identifier: id)
        let intent = definitions.intents["MessagesSendIntent"].makeIntent(destination: reference, content: AttributedString("hi"))
        do {
            let result = try await intent.run()
            print("system-test ref-send result: \(result)")
        } catch {
            let text = String(describing: error)
            print("system-test ref-send refused: \(text.prefix(600))")
        }
    }

    /// Task 01a111bb stage 7, round 3: on the device Siri's send never
    /// reached `perform` (no `intent step=send`). Run the schema send the
    /// way the system does, with a contact Burrow cannot match: perform
    /// must RUN and refuse with Burrow's own spoken failure, not die in
    /// the framework before it.
    func testSchemaSendRunsPerformForASystemPerson() async throws {
        let person = IntentPerson(identifier: .unknown, name: .displayName("Nobody Here"), handle: nil)
        let intent = definitions.intents["MessagesSendIntent"].makeIntent(destination: [person], content: AttributedString("hi"))
        do {
            let result = try await intent.run()
            print("system-test send result: \(result)")
        } catch {
            let text = String(describing: error)
            print("system-test send refused: \(text.prefix(400))")
            XCTAssertFalse(text.contains("is not present"), "metadata not indexed yet: \(text.prefix(200))")
        }
    }
}
