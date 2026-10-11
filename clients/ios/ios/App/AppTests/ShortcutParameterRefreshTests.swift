import UIKit
import XCTest

@testable import App

/// The App Shortcut parameter refresh (review of 5b5c9895, finding 1):
/// resolving or acting on one install's entity must make no request to any
/// other install, and the system re-query a refresh causes must not cause
/// another refresh.
final class ShortcutParameterRefreshTests: XCTestCase {
    private let a = "a.example.com"
    private let b = "b.example.com"
    private let approvalID = "ab000000-0000-4000-8000-000000000001"
    private let agentID = "0a0a0a0a-0000-4000-8000-000000000001"
    private var defaultsName = ""
    private var clock = Date(timeIntervalSince1970: 3_000_000)
    private var updates = 0
    /// Agent names the stub returns; changing them changes the set.
    private var agentNames = ["Saru"]
    private var saved: (IntentEnvironment, Bool, ((String, String, [String]) -> Void)?, ShortcutParameterRefresh, ((String) -> Void)?)!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        defaultsName = "ShortcutParameterRefreshTests.\(UUID().uuidString)"
        saved = (
            IntentEnvironment.current, IntentHooks.indexesSpotlight, IntentHooks.didFetchEntities, ShortcutParameterRefresh.shared,
            InstallStore.didRemove
        )
        IntentEnvironment.current = env()
        // The app's own wiring, with test defaults, a test clock and a
        // counting update in place of the system call.
        ShortcutParameterRefresh.shared = ShortcutParameterRefresh(defaults: defaults, now: { [unowned self] in self.clock })
        IntentAppHooks.install()
        ShortcutParameterRefresh.shared.update = { [unowned self] in self.updates += 1 }
        IntentHooks.indexesSpotlight = false
        StubURLProtocol.respond = { [unowned self] request in self.respond(request) }
    }

    override func tearDown() {
        IntentEnvironment.current = saved.0
        IntentHooks.indexesSpotlight = saved.1
        IntentHooks.didFetchEntities = saved.2
        ShortcutParameterRefresh.shared = saved.3
        InstallStore.didRemove = saved.4
        UserDefaults().removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    private var defaults: UserDefaults { UserDefaults(suiteName: defaultsName)! }

    private func env() -> IntentEnvironment {
        let store = InstallStore(defaults: defaults)
        let removeHook = InstallStore.didRemove
        InstallStore.didRemove = nil
        defer { InstallStore.didRemove = removeHook }
        for host in [a, b] { store.add(host: host) }
        store.select(a)
        return IntentEnvironment(
            client: SuiteAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: [a: "token-for-a", b: "token-for-b"])),
            installs: store, sleeper: VirtualClock(), now: { Date(timeIntervalSince1970: 3_000_000) },
            lastMeetingSpaces: LastMeetingSpaceStore(defaults: defaults))
    }

    private func respond(_ request: URLRequest) -> (Int, Data) {
        let host = request.url?.host ?? ""
        switch request.url?.path ?? "" {
        case "/api/app/agents":
            let agents = agentNames.enumerated().map { index, name in
                #"{"id":"0a0a0a0a-0000-4000-8000-00000000000\#(index + 1)","name":"\#(name)","slug":null,"role":"agent"}"#
            }
            return (200, Data(#"{"agents":[\#(agents.joined(separator: ","))]}"#.utf8))
        case "/api/app/spaces":
            return (
                200,
                Data(
                    #"{"spaces":[{"id":"5a000000-0000-4000-8000-000000000001","name":"Android on \#(host)","slug":"android","kind":"channel","agents":[]}]}"#
                        .utf8)
            )
        case "/api/app/approvals":
            return (
                200,
                Data(
                    #"{"approvals":[{"id":"\#(approvalID)","kind":"plan","title":"Same title plan","space_name":"Android","task_id":null}]}"#.utf8)
            )
        default:
            return (200, Data(#"{"status":"approved"}"#.utf8))
        }
    }

    /// What iOS does after `updateAppShortcutParameters()`: re-queries the
    /// parameter entities across every signed-in install. Runs once per
    /// update the code under test asked for, so a refresh that re-triggers
    /// itself keeps it going (capped).
    private func simulateSystem() async throws {
        var handled = 0
        while handled < updates, handled < 10 {
            handled += 1
            _ = try await AgentQuery().suggestedEntities()
            _ = try await SpaceQuery().suggestedEntities()
        }
    }

    private func hosts(_ requests: [URLRequest]) -> [String] { requests.compactMap { $0.url?.host } }

    // MARK: Acting on B never reaches A

    func testResolvingAndActingOnInstallBMakesZeroRequestsToA() async throws {
        let approval = try await ApprovalQuery().entities(for: [EntityRef(host: b, uuid: approvalID).id])
        XCTAssertEqual(approval.count, 1)
        let agents = try await AgentQuery().entities(for: [EntityRef(host: b, uuid: agentID).id])
        XCTAssertEqual(agents.map(\.name), ["Saru"])
        let spaces = try await SpaceQuery().entities(for: [EntityRef(host: b, uuid: "5a000000-0000-4000-8000-000000000001").id])
        XCTAssertEqual(spaces.map(\.name), ["Android on \(b)"])
        let text = try await IntentActions().approve(try XCTUnwrap(approval.first)) { _ in }
        XCTAssertEqual(text, "Approved. Agents are starting.")
        try await simulateSystem()

        XCTAssertEqual(updates, 0, "an entity fetch never refreshes the App Shortcuts")
        XCTAssertEqual(StubURLProtocol.requests.count, 4)
        XCTAssertEqual(Set(hosts(StubURLProtocol.requests)), [b], "install A must receive nothing")
    }

    /// Positive control for the test above: with the install unscoped, a
    /// suggestion query does reach both installs, so the stub would see A.
    func testAnUnscopedSuggestionReachesEveryInstallAndAScopedOneOnlyItsOwn() async throws {
        _ = try await AgentQuery().suggestedEntities()
        XCTAssertEqual(hosts(StubURLProtocol.requests), [a, b])

        StubURLProtocol.reset()
        StubURLProtocol.respond = { [unowned self] request in self.respond(request) }
        var agentQuery = AgentQuery()
        agentQuery.installScope = b
        _ = try await agentQuery.suggestedEntities()
        var spaceQuery = SpaceQuery()
        spaceQuery.installScope = b
        let spaces = try await spaceQuery.entities(matching: "Android")
        XCTAssertEqual(spaces.map(\.name), ["Android on \(b)"])
        XCTAssertEqual(hosts(StubURLProtocol.requests), [b, b], "an Install parameter scopes the query to that install")
    }

    // MARK: At most one refresh, and only when the set changed

    func testRepeatedLoadsRefreshOnlyWhenTheSetChanges() async throws {
        for _ in 0..<5 { _ = try await AgentQuery().suggestedEntities() }
        XCTAssertEqual(updates, 0)
        XCTAssertTrue(ShortcutParameterRefresh.shared.refreshIfNeeded(), "the first refresh runs")
        XCTAssertFalse(ShortcutParameterRefresh.shared.refreshIfNeeded(), "debounced")
        XCTAssertEqual(updates, 1)

        clock = clock.addingTimeInterval(120)
        for _ in 0..<5 { _ = try await AgentQuery().suggestedEntities() }
        XCTAssertFalse(ShortcutParameterRefresh.shared.refreshIfNeeded(), "same agents: nothing to refresh")
        XCTAssertEqual(updates, 1)

        agentNames = ["Saru", "Echo"]
        _ = try await AgentQuery().suggestedEntities()
        clock = clock.addingTimeInterval(120)
        XCTAssertTrue(ShortcutParameterRefresh.shared.refreshIfNeeded(), "a new agent: refresh")
        XCTAssertEqual(updates, 2)
    }

    func testARenamedAgentCountsAsAChange() async throws {
        _ = try await AgentQuery().suggestedEntities()
        ShortcutParameterRefresh.shared.refreshIfNeeded()
        clock = clock.addingTimeInterval(120)
        _ = try await AgentQuery().suggestedEntities()
        XCTAssertFalse(ShortcutParameterRefresh.shared.refreshIfNeeded())
        agentNames = ["Saru the second"]
        _ = try await AgentQuery().suggestedEntities()
        XCTAssertTrue(ShortcutParameterRefresh.shared.refreshIfNeeded())
    }

    // MARK: The system re-query does not re-trigger

    func testTheSystemReQueryAfterARefreshDoesNotTriggerAnother() async throws {
        XCTAssertTrue(ShortcutParameterRefresh.shared.refreshIfNeeded())
        // The re-query sees agents and spaces this process never fetched
        // before (every digest is new), on both installs.
        agentNames = ["Saru", "Echo", "Silent"]
        try await simulateSystem()
        XCTAssertEqual(updates, 1, "fetching during the re-query never refreshes")

        clock = clock.addingTimeInterval(120)
        XCTAssertFalse(ShortcutParameterRefresh.shared.refreshIfNeeded(), "what the re-query saw is already published")
        try await simulateSystem()
        XCTAssertEqual(updates, 1)
    }

    func testSigningOutOfAnInstallRefreshesOnce() async throws {
        _ = try await AgentQuery().suggestedEntities()
        ShortcutParameterRefresh.shared.refreshIfNeeded()
        clock = clock.addingTimeInterval(120)
        IntentAppHooks.forget(host: b)
        XCTAssertTrue(ShortcutParameterRefresh.shared.refreshIfNeeded(), "B's agents leave the phrases")
        clock = clock.addingTimeInterval(120)
        XCTAssertFalse(ShortcutParameterRefresh.shared.refreshIfNeeded())
        XCTAssertEqual(updates, 2)
    }

    // MARK: The background refresh runs through the app's real scene

    /// Round 2 of the review reported that backgrounding never refreshed.
    /// This drives the delegate of the scene the hosted app ACTUALLY
    /// connected (not a SceneDelegate the test makes), through the same
    /// background callback UIKit calls: it refreshes when the set changed,
    /// not when it did not, and never twice inside `minimumInterval`.
    @MainActor
    func testTheAppsOwnSceneRefreshesOnBackgroundOnlyWhenTheSetChanged() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first { $0.session.role == .windowApplication })
        let delegate = try XCTUnwrap(scene.delegate)
        XCTAssertTrue(delegate is SceneDelegate, "the app's scene runs SceneDelegate")
        func background() { delegate.sceneDidEnterBackground?(scene) }

        _ = try await AgentQuery().suggestedEntities()
        background()
        XCTAssertEqual(updates, 1, "the first background refreshes")

        clock = clock.addingTimeInterval(120)
        _ = try await AgentQuery().suggestedEntities()
        background()
        XCTAssertEqual(updates, 1, "same agents: no refresh")

        agentNames = ["Saru", "Echo"]
        _ = try await AgentQuery().suggestedEntities()
        background()
        XCTAssertEqual(updates, 2, "a new agent: the next background refreshes")

        clock = clock.addingTimeInterval(ShortcutParameterRefresh.settleWindow + 10)
        agentNames = ["Saru", "Echo", "Silent"]
        _ = try await AgentQuery().suggestedEntities()
        background()
        XCTAssertEqual(updates, 2, "inside the minimum interval: held")

        clock = clock.addingTimeInterval(ShortcutParameterRefresh.minimumInterval)
        background()
        XCTAssertEqual(updates, 3, "the held change refreshes once the interval has passed")
    }

    func testTheStoreHoldsDigestsNotNames() async throws {
        _ = try await AgentQuery().suggestedEntities()
        let values = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("suite.shortcuts.") }.values.map { "\($0)" }
        XCTAssertFalse(values.isEmpty)
        XCTAssertFalse(values.contains { $0.contains("Saru") || $0.contains("Android") })
    }
}
