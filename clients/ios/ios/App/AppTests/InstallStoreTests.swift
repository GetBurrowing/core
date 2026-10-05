import XCTest
@testable import App

final class InstallStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "InstallStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFirstLaunchListsTheThreeInstallsWithFabrikamSelected() {
        let store = InstallStore(defaults: defaults)
        XCTAssertEqual(store.installs.map(\.host),
                       ["suite.example.com", "suite.example.com", "suite.milv.life"])
        XCTAssertEqual(store.selectedHost, "suite.example.com")
        XCTAssertFalse(store.hasConfirmedSelection)
    }

    func testSelectionAndAddedInstallsPersistAcrossNewInstances() {
        let first = InstallStore(defaults: defaults)
        first.select("suite.example.com")
        first.confirmSelection()

        let second = InstallStore(defaults: defaults)
        XCTAssertEqual(second.selectedHost, "suite.example.com")
        XCTAssertTrue(second.hasConfirmedSelection)

        second.add(host: "https://Suite.Example.com/chat", name: "Example")
        let third = InstallStore(defaults: defaults)
        XCTAssertEqual(third.installs.map(\.host),
                       ["suite.example.com", "suite.example.com", "suite.milv.life", "suite.example.com"],
                       "adding an install keeps the defaults")
        XCTAssertEqual(third.installs.last?.name, "Example")
        XCTAssertEqual(third.selectedHost, "suite.example.com")
    }

    func testRemovingTheSelectedInstallFallsBackToTheFirst() {
        let store = InstallStore(defaults: defaults)
        store.remove(host: "suite.example.com")
        let reopened = InstallStore(defaults: defaults)
        XCTAssertEqual(reopened.installs.map(\.host), ["suite.example.com", "suite.milv.life"])
        XCTAssertEqual(reopened.selectedHost, "suite.example.com")
    }

    func testAppInstallIDIsStable() {
        let id = InstallStore(defaults: defaults).appInstallID
        XCTAssertEqual(InstallStore(defaults: defaults).appInstallID, id)
    }

    func testNormalizeHost() {
        XCTAssertEqual(InstallStore.normalizeHost(" suite.example.com "), "suite.example.com")
        XCTAssertEqual(InstallStore.normalizeHost("https://SUITE.milv.life/chat/x"), "suite.milv.life")
        XCTAssertNil(InstallStore.normalizeHost("localhost"))
        XCTAssertNil(InstallStore.normalizeHost("not a host.com"))
        XCTAssertNil(InstallStore.normalizeHost(""))
        XCTAssertNil(InstallStore.normalizeHost("-bad.example.com"))
    }
}
