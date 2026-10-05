import XCTest
@testable import App

final class KeychainTokenStoreTests: XCTestCase {
    /// The app reads the access group from its own Info.plist, with the
    /// team prefix the build filled in.
    func testAccessGroupIsTheTeamPrefixedSharedGroup() {
        XCTAssertEqual(KeychainTokenStore.shared.accessGroup, "XJ2GLJ9ST2.com.kobo-ai.burrow.shared")
    }

    /// Round trip through the real Keychain in the shared access group, one
    /// item per host.
    func testOneSessionPerHost() {
        let store = KeychainTokenStore.shared
        let a = "a-\(UUID().uuidString.lowercased()).test.invalid"
        let b = "b-\(UUID().uuidString.lowercased()).test.invalid"
        defer { store.remove(for: a); store.remove(for: b) }

        XCTAssertNil(store.token(for: a))
        XCTAssertTrue(store.store("token-a", for: a))
        XCTAssertTrue(store.store("token-b", for: b))
        XCTAssertEqual(store.token(for: a), "token-a")
        XCTAssertEqual(store.token(for: b), "token-b")

        XCTAssertTrue(store.store("token-a2", for: a), "storing again updates")
        XCTAssertEqual(store.token(for: a), "token-a2")

        store.remove(for: a)
        XCTAssertNil(store.token(for: a))
        XCTAssertEqual(store.token(for: b), "token-b")
    }

    /// Nothing about the session lands in the App Group defaults the
    /// extensions can read as plain data.
    func testStoringATokenWritesNothingToTheAppGroupDefaults() throws {
        let store = KeychainTokenStore.shared
        let host = "c-\(UUID().uuidString.lowercased()).test.invalid"
        let secret = "secret-\(UUID().uuidString)"
        defer { store.remove(for: host) }
        XCTAssertTrue(store.store(secret, for: host))

        let defaults = try XCTUnwrap(UserDefaults(suiteName: InstallStore.appGroup))
        let dump = String(describing: defaults.dictionaryRepresentation())
        XCTAssertFalse(dump.contains(secret))
    }
}
