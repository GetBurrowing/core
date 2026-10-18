import XCTest

@testable import App

/// Stand-ins for the former built-in hosts. The stores under test get their
/// digests through the `legacyHostHashes` seam, so no real former host
/// appears in this file; `testTheShippedLegacyHostDigestsArePinned` guards
/// the shipped list.
private let legacyStandIns = ["old-a.example.com", "old-b.example.com", "old-c.example.com"]
private let legacyStandInHashes = Set(legacyStandIns.map(InstallStore.hostHash))

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

    func testFreshStoreHasNoInstallsAndNoSelection() {
        // A Keychain item left by an earlier install of the app survives
        // deletion; a fresh, non-legacy store must not adopt it.
        let tokens = MemoryTokenHosts(hosts: ["old-a.example.com"])
        let store = InstallStore(defaults: defaults, tokenHosts: tokens, legacyHostHashes: legacyStandInHashes)
        XCTAssertEqual(store.installs, [])
        XCTAssertNil(store.selectedHost)
        XCTAssertNil(store.selectedInstall)
        XCTAssertFalse(store.hasConfirmedSelection)
        XCTAssertNotNil(defaults.data(forKey: "suite.installs.v1"), "the empty list is persisted")
        XCTAssertEqual(InstallStore(defaults: defaults, tokenHosts: tokens, legacyHostHashes: legacyStandInHashes).installs, [])
    }

    func testSelectionAndAddedInstallsPersistAcrossNewInstances() {
        let first = InstallStore(defaults: defaults, legacyHostHashes: legacyStandInHashes)
        first.add(host: "old-a.example.com")
        first.add(host: "old-b.example.com")
        first.add(host: "old-c.example.com")
        first.select("old-b.example.com")
        first.confirmSelection()

        let second = InstallStore(defaults: defaults, legacyHostHashes: legacyStandInHashes)
        XCTAssertEqual(second.selectedHost, "old-b.example.com")
        XCTAssertTrue(second.hasConfirmedSelection)

        second.add(host: "https://Burrow.Example.com/chat", name: "Example")
        let third = InstallStore(defaults: defaults, legacyHostHashes: legacyStandInHashes)
        XCTAssertEqual(
            third.installs.map(\.host),
            ["old-a.example.com", "old-b.example.com", "old-c.example.com", "burrow.example.com"],
            "adding an install keeps the saved ones")
        XCTAssertEqual(third.installs.last?.name, "Example")
        XCTAssertEqual(third.selectedHost, "burrow.example.com")
    }

    func testRemovingTheSelectedInstallFallsBackToTheFirst() {
        let store = InstallStore(defaults: defaults, legacyHostHashes: legacyStandInHashes)
        store.add(host: "old-a.example.com")
        store.add(host: "old-b.example.com")
        store.add(host: "old-c.example.com")
        store.select("old-a.example.com")
        store.remove(host: "old-a.example.com")
        let reopened = InstallStore(defaults: defaults, legacyHostHashes: legacyStandInHashes)
        XCTAssertEqual(reopened.installs.map(\.host), ["old-b.example.com", "old-c.example.com"])
        XCTAssertEqual(reopened.selectedHost, "old-b.example.com")
    }

    // MARK: Upgrade from builds with built-in installs (task 01a12787)

    func testLegacyUpgradeKeepsSignedInAndSelectedInstalls() {
        // Exactly what an old build leaves: confirmed, a selection, and no
        // saved list (the built-in rows were virtual), plus a bearer for an
        // install the person signed in to.
        defaults.set(true, forKey: "suite.installs.confirmed.v1")
        defaults.set("old-b.example.com", forKey: "suite.installs.selected.v1")
        let tokens = MemoryTokenHosts(hosts: ["old-a.example.com", "OLD-B.example.com"])

        let store = InstallStore(defaults: defaults, tokenHosts: tokens, legacyHostHashes: legacyStandInHashes)
        XCTAssertEqual(store.installs.map(\.host), ["old-b.example.com", "old-a.example.com"])
        XCTAssertEqual(store.selectedHost, "old-b.example.com")
        XCTAssertTrue(store.hasConfirmedSelection)
        XCTAssertNotNil(defaults.data(forKey: "suite.installs.v1"), "the migration persists its result")

        // The saved list is now authoritative: the bearer list is not re-read.
        let reopened = InstallStore(defaults: defaults, tokenHosts: MemoryTokenHosts(hosts: ["other.example.com"]), legacyHostHashes: legacyStandInHashes)
        XCTAssertEqual(reopened.installs.map(\.host), ["old-b.example.com", "old-a.example.com"])
    }

    func testLegacySavedListIsKeptWhole() {
        let hosts = ["old-a.example.com", "old-b.example.com", "old-c.example.com", "burrow.example.com"]
        let seeded = try! JSONEncoder().encode(hosts.map { Install(host: $0) })
        defaults.set(seeded, forKey: "suite.installs.v1")
        defaults.set(true, forKey: "suite.installs.confirmed.v1")
        // Only one of the four holds a bearer; none may be dropped.
        let tokens = MemoryTokenHosts(hosts: ["burrow.example.com"])

        XCTAssertEqual(InstallStore(defaults: defaults, tokenHosts: tokens, legacyHostHashes: legacyStandInHashes).installs.map(\.host), hosts)
        XCTAssertEqual(
            InstallStore(defaults: defaults, tokenHosts: tokens, legacyHostHashes: legacyStandInHashes).installs.map(\.host), hosts,
            "re-opened, the saved list is unchanged")
    }

    func testImplicitDefaultWithNoTokenIsNotAdopted() {
        // An old build where the person only pressed Continue on the
        // implicit first row: confirmed, no explicit selection, no bearer.
        defaults.set(true, forKey: "suite.installs.confirmed.v1")
        let store = InstallStore(defaults: defaults, tokenHosts: MemoryTokenHosts(hosts: []), legacyHostHashes: legacyStandInHashes)
        XCTAssertEqual(store.installs, [])
        XCTAssertNil(store.selectedHost)
    }

    func testAppInstallIDIsStable() {
        let id = InstallStore(defaults: defaults, legacyHostHashes: legacyStandInHashes).appInstallID
        XCTAssertEqual(InstallStore(defaults: defaults, legacyHostHashes: legacyStandInHashes).appInstallID, id)
    }

    func testNormalizeHost() {
        XCTAssertEqual(InstallStore.normalizeHost(" old-a.example.com "), "old-a.example.com")
        XCTAssertEqual(InstallStore.normalizeHost("https://OLD-C.Example.com/chat/x"), "old-c.example.com")
        XCTAssertNil(InstallStore.normalizeHost("localhost"))
        XCTAssertNil(InstallStore.normalizeHost("not a host.example.com"))
        XCTAssertNil(InstallStore.normalizeHost(""))
        XCTAssertNil(InstallStore.normalizeHost("-bad.example.com"))
    }
}

/// The add-your-install flow's state machine (task 01a12787 stage 2):
/// idle -> checking -> confirm | notFound | offline, with an injected probe.
@MainActor
final class AddInstallFlowModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AddInstallFlowModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Holds a probe open until the test answers it.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<InstallCheck, Never>?
        private(set) var hosts: [String] = []

        func wait(_ host: String) async -> InstallCheck {
            await withCheckedContinuation { continuation in
                lock.lock()
                hosts.append(host)
                self.continuation = continuation
                lock.unlock()
            }
        }

        var isWaiting: Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuation != nil
        }

        func answer(_ result: InstallCheck) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: result)
        }
    }

    private func model(_ probe: @escaping AddInstallFlowModel.Probe) -> (AddInstallFlowModel, InstallStore) {
        let store = InstallStore(defaults: defaults, tokenHosts: MemoryTokenHosts())
        return (AddInstallFlowModel(store: store, probe: probe, loadIcon: { _ in nil }), store)
    }

    func testChecksThenShowsTheConfirmationCard() async throws {
        let gate = Gate()
        let (model, _) = model { await gate.wait($0) }
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.canSubmit, "nothing typed")
        model.address = "https://Acme.Example.com/chat  "
        XCTAssertEqual(model.buttonTitle, "Continue")

        let run = Task { await model.submit() }
        for _ in 0..<500 where !gate.isWaiting { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(model.state, .checking)
        XCTAssertEqual(model.buttonTitle, "Checking...")
        XCTAssertFalse(model.canSubmit, "Continue is disabled while checking")
        model.address = "https://Acme.Example.com/chat"
        XCTAssertEqual(model.address, "https://Acme.Example.com/chat", "the field stays editable")

        gate.answer(.found(name: "Acme"))
        await run.value
        XCTAssertEqual(gate.hosts, ["acme.example.com"], "the probe gets the normalized host")
        XCTAssertEqual(model.state, .confirm(.init(host: "acme.example.com", name: "Acme")))
        guard case .confirm(let candidate) = model.state else { return XCTFail("no card") }
        XCTAssertEqual(candidate.displayName, "Acme")
        XCTAssertEqual(candidate.iconURL, Install(host: "acme.example.com").iconURL)
        XCTAssertNil(model.message)
        XCTAssertEqual(AddInstallFlowModel.Candidate(host: "acme.example.com", name: nil).displayName, "acme.example.com")
    }

    func testNotFoundNamesTheHost() async {
        let (model, store) = model { _ in .notFound }
        model.address = "amce.example.com "
        await model.submit()
        XCTAssertEqual(model.state, .notFound(host: "amce.example.com"))
        XCTAssertEqual(
            model.message, "No Burrow install answered at amce.example.com. Check the spelling, or ask the person who invited you.")
        XCTAssertEqual(store.installs, [], "nothing is saved for an address that did not answer")
    }

    func testAnAddressThatIsNotAHostIsNotFoundWithoutAProbe() async {
        var probed = false
        let (model, _) = model { _ in
            probed = true
            return .found(name: nil)
        }
        model.address = "not a host"
        await model.submit()
        XCTAssertFalse(probed)
        XCTAssertEqual(model.state, .notFound(host: "not a host"))
    }

    func testOfflineNeverShowsTheNotFoundCopy() async {
        // The probe classifies the connection errors as offline...
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed] {
            XCTAssertEqual(InstallProbe.classify(URLError(code)), .offline, "\(code)")
        }
        // ...and a host that does not resolve or does not answer as not found.
        for code in [URLError.Code.cannotFindHost, .badServerResponse, .timedOut, .serverCertificateUntrusted] {
            XCTAssertEqual(InstallProbe.classify(URLError(code)), .notFound, "\(code)")
        }

        let (model, _) = model { _ in .offline }
        model.address = "acme.example.com"
        await model.submit()
        XCTAssertEqual(model.state, .offline)
        XCTAssertEqual(model.message, "You're offline. Connect and try again.")
        XCTAssertFalse(model.message?.contains("No Burrow install answered") ?? true)
    }

    func testConfirmAddsSelectsAndConfirmsTheInstall() async {
        let (model, store) = model { _ in .found(name: "Acme") }
        XCTAssertNil(model.confirm(), "nothing to confirm before a check")
        XCTAssertEqual(store.installs, [])

        model.address = "acme.example.com"
        await model.submit()
        let install = model.confirm()
        XCTAssertEqual(install, Install(host: "acme.example.com", name: "Acme"))
        XCTAssertEqual(store.installs, [Install(host: "acme.example.com", name: "Acme")])
        XCTAssertEqual(store.selectedHost, "acme.example.com")
        XCTAssertTrue(store.hasConfirmedSelection)
    }

    func testChangeAddressKeepsTheTypedText() async {
        let (model, store) = model { _ in .found(name: "Stranger") }
        model.address = "amce.example.com"
        await model.submit()
        XCTAssertEqual(model.state, .confirm(.init(host: "amce.example.com", name: "Stranger")))
        model.changeAddress()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.address, "amce.example.com")
        XCTAssertEqual(store.installs, [], "changing the address saves nothing")
    }

    func testThePlaceholderIsTheAllowListedExampleHost() {
        XCTAssertEqual(AddInstallCopy.placeholder, "yourteam.example.com")
        XCTAssertTrue(ShippedHostScanTests.allowedHosts.contains(AddInstallCopy.placeholder))
        let placeholder = AddInstallCopy.placeholder
        XCTAssertFalse(ShippedHostScanTests.namesPersonalHost(placeholder))
    }
}

/// Old builds saved the built-in rows on first display (a name refresh), so
/// a defaults-only list with no bearer is treated as never saved, once
/// (task 01a12787 review finding 2).
final class LegacyDefaultsClearTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let legacyDefaults = legacyStandIns

    override func setUp() {
        super.setUp()
        suiteName = "LegacyDefaultsClearTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// The old build's state after only showing its picker: the defaults
    /// saved by a name refresh, the first selected, Continue pressed.
    private func seedOldBuild(_ hosts: [String]? = nil, selected: String = "old-a.example.com") {
        let list = (hosts ?? legacyDefaults).map { Install(host: $0, name: "Burrow") }
        defaults.set(try! JSONEncoder().encode(list), forKey: "suite.installs.v1")
        defaults.set(selected, forKey: "suite.installs.selected.v1")
        defaults.set(true, forKey: "suite.installs.confirmed.v1")
    }

    private func store(tokens: [String] = []) -> InstallStore {
        InstallStore(defaults: defaults, tokenHosts: MemoryTokenHosts(hosts: tokens), legacyHostHashes: legacyStandInHashes)
    }

    func testTheOldBuiltInHostsAreRecognisedByHashNotByName() {
        XCTAssertTrue(legacyDefaults.allSatisfy { InstallStore.isLegacyHost($0, in: legacyStandInHashes) })
        XCTAssertTrue(InstallStore.isLegacyHost("https://OLD-A.Example.com/chat", in: legacyStandInHashes))
        XCTAssertFalse(InstallStore.isLegacyHost("burrow.example.com", in: legacyStandInHashes))
        XCTAssertFalse(InstallStore.isLegacyHost("new.example.com", in: legacyStandInHashes))
        // The stand-ins are not the shipped hosts: production keeps its own list.
        XCTAssertFalse(legacyDefaults.contains(where: InstallStore.isLegacyDefault))
    }

    func testTheShippedLegacyHostDigestsArePinned() {
        // The preimages are checked outside this repo (a private core-ops
        // script); here a changed or dropped digest goes red.
        XCTAssertEqual(
            InstallStore.legacyDefaultHostHashes,
            [
                "bf8aedd7f65fd728e9ebfec07705bc51e26ae0f54a35e00e8b2ed514b2bb664e",
                "11a3b9f3cee6dab41a8d8ded38d71da667774c858c9eb82c3c596b21b6273717",
                "c3d59dfdd4a743b27afbfd9fe449cbe919dd425ac7dcabee8790365371c2dde3",
            ])
    }

    func testDefaultsOnlyListWithoutBearersClearsToTheAddFlow() {
        seedOldBuild()
        let upgraded = store()
        XCTAssertEqual(upgraded.installs, [])
        XCTAssertNil(upgraded.selectedHost)
        XCTAssertFalse(upgraded.hasConfirmedSelection)
        XCTAssertNil(defaults.string(forKey: "suite.installs.selected.v1"))
        XCTAssertEqual(store().installs, [], "the cleared list is persisted")
    }

    func testDefaultsOnlyListWhereOneDefaultHasABearerIsKeptWhole() {
        seedOldBuild()
        let upgraded = store(tokens: ["OLD-C.example.com"])
        XCTAssertEqual(upgraded.installs.map(\.host), legacyDefaults)
        XCTAssertEqual(upgraded.selectedHost, "old-a.example.com")
        XCTAssertTrue(upgraded.hasConfirmedSelection)
    }

    func testDefaultsPlusACustomHostIsKeptWhole() {
        seedOldBuild(legacyDefaults + ["rig.example.com"], selected: "old-b.example.com")
        let upgraded = store()
        XCTAssertEqual(upgraded.installs.map(\.host), legacyDefaults + ["rig.example.com"])
        XCTAssertEqual(upgraded.selectedHost, "old-b.example.com")
        XCTAssertTrue(upgraded.hasConfirmedSelection)
    }

    func testTheClearHappensOnceSoALaterAddSurvivesARelaunch() {
        seedOldBuild()
        let upgraded = store()
        XCTAssertEqual(upgraded.installs, [])
        // The person then adds a former built-in host themselves, before signing in.
        upgraded.add(host: "old-a.example.com")
        let relaunched = store()
        XCTAssertEqual(relaunched.installs.map(\.host), ["old-a.example.com"])
        XCTAssertEqual(relaunched.selectedHost, "old-a.example.com")
    }
}
