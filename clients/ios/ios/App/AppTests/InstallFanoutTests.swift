import WidgetKit
import XCTest

@testable import App

/// Task 01a21e75 stage 3: every widget fetches every signed-in install, each
/// with its OWN bearer, at most 3 at once; one install failing or signed
/// out never blanks the others. Fixture installs are example.test hosts.
final class InstallFanoutTests: XCTestCase {
    private let a = "app.example.test"
    private let b = "lab.example.test"
    private let c = "home.example.test"
    private var defaultsName = ""

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        defaultsName = "fanout-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: defaultsName)
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func installs(_ hosts: [String], names: [String?]? = nil) -> [Install] {
        hosts.enumerated().map { index, host in Install(host: host, name: names?[index] ?? "Install \(host.prefix(3))") }
    }

    private func client(_ tokens: [String: String]) -> BurrowAPIClient {
        BurrowAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: tokens))
    }

    private func countsBody(_ approvals: Int, _ tasks: Int) -> Data {
        Data(#"{"approvals":\#(approvals),"tasks":\#(tasks),"unread":0,"as_of":"2026-11-27T12:00:00Z"}"#.utf8)
    }

    // MARK: Token isolation

    /// Three hosts, three bearers: every request carries exactly its own
    /// host's token, and none to A carries B's or C's.
    func testEveryRequestCarriesOnlyItsOwnHostsBearer() async {
        let tokens = [a: "token-for-a", b: "token-for-b", c: "token-for-c"]
        StubURLProtocol.respond = { _ in (200, self.countsBody(1, 2)) }
        let client = client(tokens)

        let results = await InstallFanout.fetch(installs: installs([a, b, c]), client: client) { host in
            try await client.fetchCounts(host: host)
        }

        XCTAssertEqual(results.map(\.install.host), [a, b, c])
        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(Set(requests.compactMap(\.url?.host)), [a, b, c])
        for request in requests {
            let host = request.url?.host ?? ""
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(tokens[host] ?? "?")", host)
            for (other, token) in tokens where other != host {
                XCTAssertNotEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)", "\(host) carried \(other)'s bearer")
            }
        }
    }

    // MARK: Concurrency cap

    private actor InFlight {
        var now = 0
        var peak = 0
        func enter() {
            now += 1
            peak = max(peak, now)
        }
        func leave() { now -= 1 }
    }

    func testNeverMoreThanThreeInFlight() async {
        let hosts = (1...7).map { "i\($0).example.test" }
        let tokens = Dictionary(uniqueKeysWithValues: hosts.map { ($0, "token-\($0)") })
        let gauge = InFlight()

        let results = await InstallFanout.fetch(installs: installs(hosts), client: client(tokens)) { host -> Int in
            await gauge.enter()
            try await Task.sleep(nanoseconds: 50_000_000)
            await gauge.leave()
            return host.count
        }

        let peak = await gauge.peak
        XCTAssertEqual(peak, 3)
        XCTAssertEqual(results.compactMap(\.result.value).count, 7)
    }

    func testASlowInstallTimesOutAsUnreachable() async {
        let results = await InstallFanout.fetch(
            installs: installs([a, b]), client: client([a: "t", b: "t"]), timeout: 0.1,
            lastKnown: { $0 == self.b ? (41, Date(timeIntervalSince1970: 0)) : nil }
        ) { host -> Int in
            if host == self.b { try await Task.sleep(nanoseconds: 2_000_000_000) }
            return 1
        }
        guard case .ok(1) = results[0].result else { return XCTFail("a: \(results[0].result)") }
        guard case .unreachable(lastKnown: 41?, fetchedAt: _?) = results[1].result else { return XCTFail("b: \(results[1].result)") }
    }

    // MARK: Failures

    func testA500IsUnreachableWithItsLastKnownCountWhileOthersAreOk() async {
        StubURLProtocol.respond = { request in request.url?.host == self.b ? (500, Data()) : (200, self.countsBody(5, 1)) }
        let cache = CountsCache(defaults: UserDefaults(suiteName: defaultsName))
        let old = BurrowCounts(approvals: 2, tasks: 9, fetchedAt: Date().addingTimeInterval(-7200))
        cache.write(old, for: b)
        let client = client([a: "token-for-a", b: "token-for-b", c: "token-for-c"])

        let results = await InstallFanout.fetch(
            installs: installs([a, b, c]), client: client, lastKnown: { host in cache.counts(for: host).map { ($0, $0.fetchedAt) } }
        ) { host in try await client.fetchCounts(host: host) }

        guard case .ok(let fresh) = results[0].result else { return XCTFail("a") }
        XCTAssertEqual(fresh.approvals, 5)
        guard case .unreachable(let known, let at) = results[1].result else { return XCTFail("b") }
        XCTAssertEqual(known, old)
        XCTAssertEqual(at, old.fetchedAt)
        guard case .ok = results[2].result else { return XCTFail("c") }
    }

    func testASignedOutInstallIsNeverRequested() async {
        StubURLProtocol.respond = { _ in (200, self.countsBody(1, 1)) }
        let client = client([a: "token-for-a", c: "token-for-c"])

        let results = await InstallFanout.fetch(installs: installs([a, b, c]), client: client) { host in
            try await client.fetchCounts(host: host)
        }

        guard case .signedOut = results[1].result else { return XCTFail("b should be signed out") }
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.host == b })
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    // MARK: Merged counts entry

    private func merged(_ results: [(Install, InstallResult<BurrowCounts>)], saved: [Install], scope: WidgetScope = .all, now: Date) -> CountsEntry {
        CountsEntry.merged(date: now, results: results.map { (install: $0.0, result: $0.1) }, saved: saved, scope: scope)
    }

    func testTotalsSumAndAFailedInstallKeepsItsLastKnownCountMarkedStale() {
        let now = Date()
        let saved = installs([a, b], names: ["Alpha", "Lab"])
        let entry = merged(
            [
                (saved[0], .ok(BurrowCounts(approvals: 5, tasks: 1, fetchedAt: now))),
                (saved[1], .unreachable(lastKnown: BurrowCounts(approvals: 2, tasks: 4, fetchedAt: now.addingTimeInterval(-7200)), fetchedAt: nil)),
            ], saved: saved, now: now)

        XCTAssertEqual(entry.count(.approvals), 7, "the total never quietly drops")
        XCTAssertEqual(entry.state(.approvals), .live)
        XCTAssertEqual(entry.breakdown(.approvals), "Alpha 5 · Lab 2 (2h ago)")
        XCTAssertEqual(entry.failures.map(\.text), ["Can't reach Lab"])
        XCTAssertEqual(entry.installCountLine, "2 installs")
        XCTAssertEqual(DeepLink(url: entry.link(.approvals))?.host, a)
    }

    func testNoLastKnownCountReadsAsADash() {
        let now = Date()
        let saved = installs([a, b], names: ["Alpha", "Lab"])
        let entry = merged(
            [(saved[0], .ok(BurrowCounts(approvals: 1, tasks: 0, fetchedAt: now))), (saved[1], .unreachable(lastKnown: nil, fetchedAt: nil))],
            saved: saved, now: now)
        XCTAssertEqual(entry.breakdown(.approvals), "Alpha 1 · Lab —")
    }

    func testASignedOutInstallGivesAFailureLineAndNoBreakdownWithOneLeft() {
        let now = Date()
        let saved = installs([a, b], names: ["Alpha", "Lab"])
        let entry = merged([(saved[0], .ok(BurrowCounts(approvals: 3, tasks: 0, fetchedAt: now))), (saved[1], .signedOut)], saved: saved, now: now)
        XCTAssertEqual(entry.failures.map(\.text), ["Signed out of Lab"])
        XCTAssertFalse(entry.failures[0].unreachable)
        XCTAssertNil(entry.breakdown(.approvals), "one signed-in install: no breakdown")
        XCTAssertEqual(entry.count(.approvals), 3)
    }

    func testEveryInstallFailingIsStaleNotBlank() {
        let now = Date()
        let saved = installs([a, b])
        let old = now.addingTimeInterval(-3 * 3600)
        let entry = merged(
            [
                (saved[0], .unreachable(lastKnown: BurrowCounts(approvals: 1, tasks: 0, fetchedAt: old), fetchedAt: old)),
                (saved[1], .unreachable(lastKnown: BurrowCounts(approvals: 2, tasks: 0, fetchedAt: old), fetchedAt: old)),
            ], saved: saved, now: now)
        XCTAssertEqual(entry.state(.approvals), .stale)
        XCTAssertEqual(entry.count(.approvals), 3)
        XCTAssertTrue(entry.caption(.approvals).hasPrefix("As of"))
    }

    func testOneInstallReadsExactlyAsBefore() {
        let now = Date()
        let saved = installs([a])
        let entry = merged([(saved[0], .ok(BurrowCounts(approvals: 2, tasks: 3, fetchedAt: now)))], saved: saved, now: now)
        XCTAssertTrue(entry.installs.isEmpty)
        XCTAssertNil(entry.breakdown(.tasks))
        XCTAssertNil(entry.installCountLine)
        XCTAssertTrue(entry.failures.isEmpty)
        XCTAssertNil(entry.pinnedLabel)
    }

    func testPinnedToOneOfSeveralSaysInstallOnly() {
        let now = Date()
        let saved = installs([a, b], names: ["Alpha", "Lab"])
        let entry = merged([(saved[1], .ok(BurrowCounts(approvals: 1, tasks: 0, fetchedAt: now)))], saved: saved, scope: .pinned(b), now: now)
        XCTAssertEqual(entry.pinnedLabel, "Lab only")
    }

    func testRowLinksCarryTheirOwnHost() {
        let now = Date()
        let saved = installs([a, b])
        let entry = merged(
            [(saved[0], .ok(BurrowCounts(approvals: 0, tasks: 0, fetchedAt: now))), (saved[1], .ok(BurrowCounts(approvals: 4, tasks: 0, fetchedAt: now)))],
            saved: saved, now: now)
        XCTAssertEqual(DeepLink(url: entry.link(.approvals))?.host, b, "the slab opens the install holding the approvals")
        XCTAssertEqual(DeepLink(url: entry.link(.tasks))?.host, a)
    }
}

/// `InstallLabel`: nil with one install; a name, or "Install <n>"; never a host.
final class InstallLabelTests: XCTestCase {
    func testOneSignedInInstallHasNoLabel() {
        let saved = [Install(host: "app.example.test", name: "Alpha"), Install(host: "lab.example.test", name: "Lab")]
        XCTAssertNil(InstallLabel.label(for: "app.example.test", installs: saved, signedIn: ["app.example.test"]))
    }

    func testSeveralSignedInUseTheName() {
        let saved = [Install(host: "app.example.test", name: "Alpha"), Install(host: "lab.example.test", name: "Lab")]
        XCTAssertEqual(InstallLabel.label(for: "lab.example.test", installs: saved, signedIn: ["app.example.test", "lab.example.test"]), "Lab")
    }

    func testANamelessInstallIsInstallN() {
        let saved = [Install(host: "app.example.test", name: "Alpha"), Install(host: "lab.example.test", name: nil)]
        XCTAssertEqual(InstallLabel.name(for: "lab.example.test", installs: saved), "Install 2")
        XCTAssertEqual(InstallLabel.name(for: "lab.example.test", installs: [Install(host: "lab.example.test", name: "lab.example.test")]), "Install 1")
    }

    func testALabelIsNeverAHost() {
        let saved = [Install(host: "app.example.test", name: nil), Install(host: "lab.example.test", name: "  ")]
        for install in saved {
            let label = InstallLabel.name(for: install.host, installs: saved)
            XCTAssertFalse(label.contains("example.test"), label)
        }
        XCTAssertEqual(InstallScopeQuery.options(saved).map(\.name), ["All installs", "Install 1", "Install 2"])
    }
}

/// Widget scope: All installs by default; pinned stays pinned; a removed
/// pinned install falls back to All installs.
final class WidgetScopeTests: XCTestCase {
    private let saved = [Install(host: "app.example.test", name: "Alpha"), Install(host: "lab.example.test", name: "Lab")]

    private let lab = "lab.example.test"

    func testANewWidgetDefaultsToAllInstalls() async {
        XCTAssertEqual(WidgetScopeIntent().widgetScope, WidgetScope.all)
        XCTAssertEqual(WidgetScope.approvals(legacyInstall: nil, scope: nil, saved: saved), WidgetScope.all)
        XCTAssertEqual(WidgetScope.approvals(legacyInstall: nil, scope: InstallScopeEntity.all.scope, saved: saved), WidgetScope.all)
        let defaultScope = await InstallScopeQuery().defaultResult()
        XCTAssertEqual(defaultScope?.id, InstallScopeEntity.allID)
    }

    func testALegacyPinnedApprovalsWidgetStaysPinned() {
        XCTAssertEqual(WidgetScope.approvals(legacyInstall: lab, scope: nil, saved: saved), WidgetScope.pinned(lab))
        XCTAssertEqual(
            WidgetScope.approvals(legacyInstall: lab, scope: WidgetScope.all, saved: saved), WidgetScope.pinned(lab),
            "the All installs default does not unpin a v1 widget")
    }

    func testAnExplicitScopeWinsOverTheLegacyInstall() {
        XCTAssertEqual(
            WidgetScope.approvals(legacyInstall: lab, scope: WidgetScope.pinned("app.example.test"), saved: saved), WidgetScope.pinned("app.example.test"))
    }

    func testARemovedPinnedInstallFallsBackToAllInstalls() {
        XCTAssertEqual(WidgetScope.approvals(legacyInstall: "gone.example.test", scope: nil, saved: saved), WidgetScope.all)
        XCTAssertEqual(WidgetScope.pinned("gone.example.test").resolved(saved: saved), WidgetScope.all)
        XCTAssertEqual(WidgetScope.pinned("gone.example.test").installs(from: saved), saved)
        XCTAssertEqual(WidgetScope.pinned(lab).installs(from: saved).map(\.host), [lab])
    }

    func testTheAppKeepsTheSelectedInstallAsTheLegacyDefault() {
        XCTAssertFalse(InstallQuery.isAppExtension, "the app process keeps its Siri default")
    }
}
