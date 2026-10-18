import XCTest
@testable import App

final class SuiteAPIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func client(_ tokens: [String: String]) -> SuiteAPIClient {
        SuiteAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: tokens))
    }

    private func spacesJSON() -> Data {
        Data("""
        {"spaces":[{"id":"s1","name":"Internal Legacy SXI","slug":"sxi","kind":"channel",
          "agents":[{"id":"a1","name":"Saru","slug":"saru"}]}]}
        """.utf8)
    }

    // MARK: Not signed in: no network

    func testMissingTokenGivesNotSignedInWithNoRequest() {
        let install = Install(host: "suite.example.net")
        let defaultsName = "ShareSheetModelTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: defaultsName) }
        let model = ShareSheetModel(install: install, client: client([:]), lastSpace: UserDefaults(suiteName: defaultsName))

        model.start()

        XCTAssertEqual(model.phase, .notSignedIn)
        XCTAssertFalse(model.canSend)
        // Give any stray task a chance to reach the stub before counting.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(StubURLProtocol.requests.count, 0, "a signed-out share sheet makes no network call")
        XCTAssertEqual(ShareSheetModel.notSignedInText,
                       "Sign in to Burrow first. Open the Burrow app, sign in, then share again.")
    }

    func testNoSelectedInstallIsNotSignedIn() {
        let model = ShareSheetModel(install: nil, client: client(["suite.example.net": "tok"]))
        model.start()
        XCTAssertEqual(model.phase, .notSignedIn)
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    func testEveryRouteRefusesWithoutATokenAndSendsNothing() {
        let api = client([:])
        let group = expectation(description: "all")
        group.expectedFulfillmentCount = 4
        api.spaces(host: "b.example.com") { if case .failure(SuiteAPIClient.Failure.notSignedIn) = $0 { group.fulfill() } }
        api.counts(host: "b.example.com") { if case .failure(SuiteAPIClient.Failure.notSignedIn) = $0 { group.fulfill() } }
        api.postJSON(host: "b.example.com", path: "/api/app/devices", json: [:]) {
            if case .failure(SuiteAPIClient.Failure.notSignedIn) = $0 { group.fulfill() }
        }
        api.sendMessage(host: "b.example.com", spaceID: "s1", form: SharePayload.text("hi").form(message: "", agentID: nil)) {
            if case .failure(SuiteAPIClient.Failure.notSignedIn) = $0 { group.fulfill() }
        }
        wait(for: [group], timeout: 5)
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    // MARK: Install isolation

    /// A token for install A is never sent to install B: with only A signed
    /// in, every call to B is refused before a request exists; with both
    /// signed in, B's requests carry B's token and only B's.
    func testInstallATokenIsNeverSentToInstallB() {
        let a = "a.example.com", b = "b.example.com"

        // A is used FIRST, so a client that remembered "the" session (a
        // static, a cached last token, a current-install field) would have
        // A's bearer in hand when B is asked for. Without this call the
        // refusal below passes against exactly that bug (mutation b,
        // stage 4 evidence).
        let onlyA = client([a: "token-for-a"])
        let usedA = expectation(description: "A used")
        onlyA.counts(host: a) { _ in usedA.fulfill() }
        wait(for: [usedA], timeout: 5)
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.host }, [a])

        let refused = expectation(description: "B refused")
        refused.expectedFulfillmentCount = 2
        onlyA.counts(host: b) { if case .failure(SuiteAPIClient.Failure.notSignedIn) = $0 { refused.fulfill() } }
        onlyA.spaces(host: b) { if case .failure(SuiteAPIClient.Failure.notSignedIn) = $0 { refused.fulfill() } }
        wait(for: [refused], timeout: 5)
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.host }, [a], "nothing goes to B without B's own token")
        StubURLProtocol.reset()

        StubURLProtocol.respond = { request in
            request.url?.path == "/api/app/spaces" ? (200, self.spacesJSON()) : (200, Data(#"{"approvals":1,"tasks":2,"as_of":"2026-10-04T23:00:00.123456Z"}"#.utf8))
        }
        let both = client([a: "token-for-a", b: "token-for-b"])
        let sent = expectation(description: "sent")
        sent.expectedFulfillmentCount = 4
        both.counts(host: b) { _ in sent.fulfill() }
        both.spaces(host: a) { _ in sent.fulfill() }
        both.sendMessage(host: b, spaceID: "s1", form: SharePayload.text("hi").form(message: "", agentID: nil)) { _ in sent.fulfill() }
        both.postJSON(host: a, path: "/api/app/devices", json: ["x": 1]) { _ in sent.fulfill() }
        wait(for: [sent], timeout: 5)

        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.count, 4)
        for request in requests {
            let host = request.url?.host
            let auth = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertEqual(auth, host == b ? "Bearer token-for-b" : "Bearer token-for-a", "\(String(describing: request.url)) got the wrong bearer")
        }
        XCTAssertEqual(requests.filter { $0.url?.host == b }.count, 2)
    }

    // MARK: Decoding

    func testSpacesAndCountsDecode() {
        StubURLProtocol.respond = { request in
            request.url?.path == "/api/app/spaces" ? (200, self.spacesJSON())
                : (200, Data(#"{"approvals":3,"tasks":12,"as_of":"2026-10-04T23:00:00.123456Z"}"#.utf8))
        }
        let api = client(["a.example.com": "tok"])
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let done = expectation(description: "decoded")
        done.expectedFulfillmentCount = 2
        api.spaces(host: "a.example.com") { result in
            XCTAssertEqual(try? result.get().first?.agents.first?.name, "Saru")
            done.fulfill()
        }
        api.counts(host: "a.example.com", now: { fetched }) { result in
            // `as_of` is read too since task 01a1261e (no `unread` from this server).
            XCTAssertEqual(
                try? result.get(),
                SuiteCounts(
                    approvals: 3, tasks: 12, fetchedAt: fetched, unread: nil,
                    asOf: InstallUnreadStore.parseDate("2026-10-04T23:00:00.123456Z")))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(StubURLProtocol.requests.compactMap { $0.url?.absoluteString }.sorted(),
                       ["https://a.example.com/api/app/counts", "https://a.example.com/api/app/spaces"])
    }

    // MARK: Share sheet states

    private func signedInModel(_ defaultsName: String) -> ShareSheetModel {
        ShareSheetModel(install: Install(host: "a.example.com"), client: client(["a.example.com": "tok"]),
                        lastSpace: UserDefaults(suiteName: defaultsName))
    }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) {
        let exp = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        wait(for: [exp], timeout: timeout)
    }

    func testLoadingThenReadyThenFailedKeepsEverything() {
        let name = "ShareSheetModelTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: name) }
        StubURLProtocol.respond = { request in
            request.url?.path == "/api/app/spaces" ? (200, self.spacesJSON()) : (500, Data())
        }
        let model = signedInModel(name)
        model.payload = .url(URL(string: "https://example.com")!)
        model.start()
        XCTAssertEqual(model.phase, .loadingSpaces)
        XCTAssertFalse(model.canSend, "Send is disabled while spaces load")

        waitFor { model.phase == .ready }
        model.selectedSpaceID = "s1"
        model.selectedAgentID = "a1"
        model.message = "look"
        XCTAssertTrue(model.canSend)

        model.send {}
        XCTAssertEqual(model.phase, .sending)
        XCTAssertTrue(model.fieldsLocked)
        waitFor { model.banner == .sendFailed }

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.message, "look", "nothing the person entered is cleared")
        XCTAssertEqual(model.selectedSpaceID, "s1")
        XCTAssertEqual(model.selectedAgentID, "a1")
        XCTAssertEqual(model.payload, .url(URL(string: "https://example.com")!))
        XCTAssertEqual(model.banner?.text, "Couldn't send. Your item is still here. Try again.")
    }

    func testSentShowsTheSpaceThenCloses() {
        let name = "ShareSheetModelTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: name) }
        StubURLProtocol.respond = { request in
            request.url?.path == "/api/app/spaces" ? (200, self.spacesJSON()) : (201, Data("{}".utf8))
        }
        let model = signedInModel(name)
        model.payload = .text("hello")
        model.start()
        waitFor { model.phase == .ready }
        model.selectedSpaceID = "s1"

        let closed = expectation(description: "closed")
        model.send { closed.fulfill() }
        waitFor { model.phase == .sent(spaceName: "Internal Legacy SXI") }
        wait(for: [closed], timeout: ShareSheetModel.sentDwell + 2)

        let post = StubURLProtocol.requests.last
        XCTAssertEqual(post?.url?.path, "/api/app/spaces/s1/messages")
        XCTAssertEqual(post?.httpMethod, "POST")
        XCTAssertTrue(post?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)

        // The space is remembered for the next share to this install.
        let again = signedInModel(name)
        again.start()
        waitFor { again.phase == .ready }
        XCTAssertEqual(again.selectedSpaceID, "s1")
    }
}
