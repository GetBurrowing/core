import XCTest
@testable import App

/// Native sign-out and the stored-bearer launch, against the real shared
/// Keychain (a random host per test) and a stubbed URLSession.
final class InstallSessionTests: XCTestCase {
    private let store = KeychainTokenStore.shared
    private var host = ""

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        host = "s-\(UUID().uuidString.lowercased()).test.invalid"
    }

    override func tearDown() {
        store.remove(for: host)
        super.tearDown()
    }

    private func client() -> SuiteAPIClient {
        SuiteAPIClient(session: StubURLProtocol.session(), tokens: store)
    }

    private func calls() -> [String] {
        StubURLProtocol.requests.map { "\($0.httpMethod ?? "?") \($0.url?.host ?? "") \($0.url?.path ?? "")" }
    }

    // MARK: B. Sign-out

    func testSignOutDeletesTheDeviceThenTheSessionAndForgetsTheBearer() {
        XCTAssertTrue(store.store("bearer-so", for: host))
        StubURLProtocol.respond = { _ in (204, Data()) }

        let done = expectation(description: "signed out")
        NativeSignOut(client: client(), tokens: store, appInstallID: "install-1").run(host: host) { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(calls(), ["DELETE \(host) /api/app/devices/install-1", "DELETE \(host) /api/app/session"])
        XCTAssertEqual(StubURLProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer bearer-so", "Bearer bearer-so"])
        XCTAssertNil(store.token(for: host), "the Keychain entry is removed")
    }

    func testSignOutForgetsTheBearerEvenWhenTheServerFails() {
        XCTAssertTrue(store.store("bearer-so", for: host))
        StubURLProtocol.respond = { _ in (500, Data()) }

        let done = expectation(description: "signed out")
        NativeSignOut(client: client(), tokens: store, appInstallID: "install-1").run(host: host) { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(calls().count, 2)
        XCTAssertNil(store.token(for: host))
    }

    func testLogoutLinkIsTakenOverByTheNativeSignOut() {
        let policy = NavigationPolicy(installHost: "suite.example.com")
        XCTAssertEqual(policy.decide(url: URL(string: "https://suite.example.com/auth/logout"), isMainFrame: true), .signOut)
        XCTAssertEqual(policy.decide(url: URL(string: "https://suite.example.com/auth/logout"), isMainFrame: false), .allow)
        XCTAssertEqual(policy.decide(url: URL(string: "https://other.example/auth/logout"), isMainFrame: true), .openExternally)
    }

    // MARK: C. Stored bearer on launch

    private func launch(destination: URL?) -> LaunchStep? {
        var step: LaunchStep?
        let done = expectation(description: "launch")
        InstallLauncher(client: client(), tokens: store)
            .start(install: Install(host: host), destination: destination) { step = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return step
    }

    func testStoredBearerLoadsTheHandoffWithoutTheAuthSession() {
        XCTAssertTrue(store.store("bearer-l", for: host))
        let handoff = "https://\(host)/auth/app/handoff?code=c1&to=%2Fchat%2Fs1"
        StubURLProtocol.respond = { _ in (200, Data("{\"handoff_url\":\"\(handoff)\"}".utf8)) }

        let step = launch(destination: URL(string: "https://\(host)/chat/s1"))

        XCTAssertEqual(step, .load(URL(string: handoff)!), "no .signIn: the auth session never starts")
        XCTAssertEqual(calls(), ["POST \(host) /api/app/handoff"])
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer bearer-l")
        XCTAssertEqual(store.token(for: host), "bearer-l")
    }

    func testRevokedBearerFallsBackToSignInAndIsRemoved() {
        XCTAssertTrue(store.store("bearer-old", for: host))
        StubURLProtocol.respond = { _ in (401, Data("{\"error\":\"unauthorized\"}".utf8)) }

        XCTAssertEqual(launch(destination: nil), .signIn)
        XCTAssertEqual(calls(), ["POST \(host) /api/app/handoff"])
        XCTAssertNil(store.token(for: host), "the stale bearer is removed")
    }

    func testNoBearerSignsInWithNoRequest() {
        XCTAssertEqual(launch(destination: nil), .signIn)
        XCTAssertEqual(calls(), [])
    }

    func testHandoffOnAnotherHostIsRefused() {
        XCTAssertTrue(store.store("bearer-l", for: host))
        StubURLProtocol.respond = { _ in (200, Data("{\"handoff_url\":\"https://evil.example/x\"}".utf8)) }
        // Not loaded: falls back to the install root.
        XCTAssertEqual(launch(destination: nil), .load(URL(string: "https://\(host)")!))
    }

    func testHandoffPathIsTheLocalPathAndQuery() {
        let h = "suite.example.com"
        XCTAssertEqual(InstallLauncher.localPath(of: URL(string: "https://\(h)/chat/s1?message=m1"), on: h), "/chat/s1?message=m1")
        XCTAssertNil(InstallLauncher.localPath(of: URL(string: "https://\(h)/"), on: h))
        XCTAssertNil(InstallLauncher.localPath(of: URL(string: "https://\(h)"), on: h))
        XCTAssertNil(InstallLauncher.localPath(of: URL(string: "https://other.example/chat"), on: h))
        XCTAssertNil(InstallLauncher.localPath(of: nil, on: h))
    }
}
