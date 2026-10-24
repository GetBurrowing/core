import XCTest

@testable import App

/// The companion identity contract (task 01a13ca2 stage 4).
///
/// `Fixtures/companion_identities_v1.json` is a byte-for-byte copy of the
/// server's `apps/platform/test/support/fixtures/companion_identities_v1.json`,
/// the same table the server's `Meetings.person_identity/1` and the page's
/// `personIdentity` are tested against; the server suite's
/// `companion_fixture_parity_test.exs` fails if the copy drifts. Loaded from
/// the test bundle only, so a fixture missing from the target fails here.
final class CompanionIdentityTests: XCTestCase {
    private struct Case {
        let note: String
        let identity: String?
        let person: String?
        let companion: Bool
    }

    private func cases() throws -> [Case] {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "companion_identities_v1", withExtension: "json"),
            "companion_identities_v1.json is not in the AppTests bundle")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        let raw = try XCTUnwrap(object["cases"] as? [[String: Any]], "the fixture has no cases array")
        return try raw.map { row in
            Case(
                note: try XCTUnwrap(row["note"] as? String),
                identity: row["identity"] as? String,
                person: row["person"] as? String,
                companion: try XCTUnwrap(row["companion"] as? Bool))
        }
    }

    func testTheFixtureHasCases() throws {
        XCTAssertGreaterThan(try cases().count, 0, "the companion identity fixture has no cases")
    }

    func testIsCompanionAgreesWithEveryFixtureCase() throws {
        let all = try cases()
        XCTAssertGreaterThan(all.count, 0)
        for c in all {
            XCTAssertEqual(CallParticipant.isCompanion(identity: c.identity), c.companion, c.note)
        }
    }

    func testPersonIdentityAgreesWithEveryFixtureCase() throws {
        let all = try cases()
        XCTAssertGreaterThan(all.count, 0)
        for c in all {
            XCTAssertEqual(CallParticipant.personIdentity(c.identity), c.person, c.note)
        }
    }

    /// The fixture's companion cases survive the reducer's filter as
    /// nothing; its non-companion cases survive whole.
    func testPersonsDropsExactlyTheFixturesCompanions() throws {
        let all = try cases().filter { $0.identity != nil }
        let participants = all.map { CallParticipant(id: $0.identity!, name: $0.note, isAgent: false) }
        XCTAssertEqual(
            CallParticipant.persons(participants).map(\.id),
            all.filter { !$0.companion }.map { $0.identity! })
    }
}
