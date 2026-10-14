import CryptoKit
import Intents
import UserNotifications
import XCTest

@testable import App

/// Task 01a1261e stage 4: sealed push previews, per-install unread, the
/// summed badge, the switcher pills and dot, and the tap banner.
///
/// The fixture `Fixtures/push_seal_v1.json` is a byte-for-byte copy of the
/// server's `apps/platform/test/support/fixtures/push_seal_v1.json`; the
/// server's parity test fails if the copies drift.
final class PushRelayTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PushRelayTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Fixture

    private struct Fixture {
        let json: [String: Any]
        var host: String { json["install_host"] as! String }
        var sealed: String { json["sealed"] as! String }
        var plaintext: String { json["plaintext"] as! String }
        var privateKey: Curve25519.KeyAgreement.PrivateKey {
            try! Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: PushKeyStore.data(base64url: json["recipient_private_key"] as! String)!)
        }
        var inner: [String: String] {
            (try! JSONSerialization.jsonObject(with: Data(plaintext.utf8)) as! [String: Any]).compactMapValues { $0 as? String }
        }
    }

    private func fixture() throws -> Fixture {
        let url =
            Bundle(for: Self.self).url(forResource: "push_seal_v1", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/push_seal_v1.json")
        let data = try Data(contentsOf: url)
        return Fixture(json: try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }

    // MARK: PushSeal

    func testTheFixtureDecryptsToItsExpectedPlaintext() throws {
        let f = try fixture()
        XCTAssertEqual(f.json["info"] as? String, "burrow push v1")
        XCTAssertEqual(
            PushKeyStore.base64url(f.privateKey.publicKey.rawRepresentation), f.json["recipient_public_key"] as? String)

        let opened = try XCTUnwrap(PushSeal.openData(f.sealed, installHost: f.host, key: f.privateKey))
        XCTAssertEqual(String(data: opened, encoding: .utf8), f.plaintext, "byte for byte")
        XCTAssertEqual(PushSeal.open(f.sealed, installHost: f.host, key: f.privateKey)?["title"], "Dana in launch")
    }

    func testAnotherInstallHostAsAADDoesNotOpen() throws {
        let f = try fixture()
        XCTAssertNotNil(PushSeal.open(f.sealed, installHost: f.host, key: f.privateKey), "positive control")
        XCTAssertNil(PushSeal.open(f.sealed, installHost: "suite-a.localhost", key: f.privateKey))
        XCTAssertNil(PushSeal.open(f.sealed, installHost: f.host, key: Curve25519.KeyAgreement.PrivateKey()))
        XCTAssertNil(PushSeal.open("not base64!", installHost: f.host, key: f.privateKey))
    }

    // MARK: PushContentPreparer (the NSE's first step)

    private func installsStore(_ hosts: [String]) -> InstallStore {
        let store = InstallStore(defaults: defaults)
        for host in hosts { store.add(host: host, name: host.split(separator: ".").first.map { String($0).uppercased() }) }
        return store
    }

    private func preparer(
        key: Curve25519.KeyAgreement.PrivateKey?, hosts: [String], signedIn: Set<String> = []
    ) -> (PushContentPreparer, InstallUnreadStore) {
        let installs = installsStore(hosts)
        let unread = InstallUnreadStore(defaults: defaults)
        return (
            PushContentPreparer(
                privateKey: { _ in key }, unread: unread, installs: { installs.installs },
                isSignedIn: { signedIn.contains($0) }),
            unread
        )
    }

    private func relayed(host: String, sealed: String?, count: Int = 3, asOf: String = "2026-10-10T15:00:00.123456Z")
        -> UNNotificationContent
    {
        let content = UNMutableNotificationContent()
        content.title = "Burrow"
        content.body = "New notification"
        var info: [AnyHashable: Any] = ["install_host": host, "unread_count": count, "unread_as_of": asOf]
        if let sealed { info["sealed"] = sealed }
        content.userInfo = info
        return content
    }

    func testARelayedPushIsRebuiltFromTheSealedMap() throws {
        let f = try fixture()
        let (prep, unread) = preparer(key: f.privateKey, hosts: [f.host])

        let out = prep.prepare(relayed(host: f.host, sealed: f.sealed))

        XCTAssertEqual(out.title, "Dana in launch")
        XCTAssertEqual(out.body, "@Marlowe can you check the deck before 3?")
        XCTAssertEqual(out.categoryIdentifier, "SUITE_MENTION")
        XCTAssertEqual(out.threadIdentifier, "suite-b.localhost:\(f.inner["thread_id"]!)", "the NSE adds the host prefix")
        XCTAssertEqual(out.userInfo["space_id"] as? String, f.inner["space_id"])
        XCTAssertEqual(out.userInfo["url"] as? String, f.inner["url"])
        XCTAssertEqual(out.userInfo["install_host"] as? String, f.host)
        XCTAssertNil(out.userInfo["sealed"], "the blob is not carried on")
        XCTAssertEqual(PushPayload(userInfo: out.userInfo).destination()?.host, f.host, "taps route as before")
        XCTAssertEqual(unread.entry(for: f.host)?.count, 3)
        XCTAssertEqual(out.badge, 3)
    }

    func testTheRebuiltPushBecomesACommunicationNotificationInput() throws {
        let f = try fixture()
        let (prep, _) = preparer(key: f.privateKey, hosts: [f.host])
        let out = prep.prepare(relayed(host: f.host, sealed: f.sealed))
        let payload = try XCTUnwrap(CommunicationPayload(userInfo: out.userInfo))
        XCTAssertEqual(payload.host, f.host)
        XCTAssertEqual(payload.authorName, "Dana")
    }

    func testAWrongInstallHostGetsTheFallbackCopyNeverCiphertext() throws {
        let f = try fixture()
        let (prep, _) = preparer(key: f.privateKey, hosts: [f.host, "suite-a.localhost"])

        // The blob was sealed for suite-b; a relay that moved it to suite-a.
        let out = prep.prepare(relayed(host: "suite-a.localhost", sealed: f.sealed))

        XCTAssertEqual(out.body, "New message in SUITE-A")
        XCTAssertFalse(out.body.contains(f.sealed.prefix(12)))
        XCTAssertFalse(out.body.isEmpty)
    }

    func testANullSealedGetsTheFallbackCopy() throws {
        let (prep, _) = preparer(key: nil, hosts: ["suite-b.localhost"])
        let out = prep.prepare(relayed(host: "suite-b.localhost", sealed: nil))
        XCTAssertEqual(out.body, "New message in SUITE-B")
    }

    func testAKeylessDeviceGetsTheFallbackCopy() throws {
        let f = try fixture()
        let (prep, _) = preparer(key: nil, hosts: [f.host])
        XCTAssertEqual(prep.prepare(relayed(host: f.host, sealed: f.sealed)).body, "New message in SUITE-B")
    }

    func testADirectPushKeepsItsTextAndStillRecordsTheCount() {
        let (prep, unread) = preparer(key: nil, hosts: ["suite-c.localhost"])
        let content = UNMutableNotificationContent()
        content.title = "Dana in launch"
        content.body = "direct path check"
        content.threadIdentifier = "suite-c.localhost:s1"
        content.userInfo = [
            "kind": "chat_mention", "install_host": "suite-c.localhost", "unread_count": 2,
            "unread_as_of": "2026-10-10T15:00:00Z",
        ]

        let out = prep.prepare(content)

        XCTAssertEqual(out.title, "Dana in launch")
        XCTAssertEqual(out.body, "direct path check")
        XCTAssertEqual(out.threadIdentifier, "suite-c.localhost:s1")
        XCTAssertEqual(unread.entry(for: "suite-c.localhost")?.count, 2)
        XCTAssertEqual(out.badge, 2)
    }

    func testTheBadgeIsTheSumAcrossInstalls() {
        let (prep, unread) = preparer(key: nil, hosts: ["suite-a.localhost", "suite-b.localhost"])
        unread.write(count: 2, asOf: Date(timeIntervalSince1970: 100), for: "suite-a.localhost")

        let out = prep.prepare(relayed(host: "suite-b.localhost", sealed: nil, count: 3))

        XCTAssertEqual(out.badge, 5)
    }

    func testTheSubtitleNamesTheInstallOnlyWithTwoSignedIn() throws {
        let f = try fixture()
        let hosts = [f.host, "suite-a.localhost"]

        let (one, _) = preparer(key: f.privateKey, hosts: hosts, signedIn: [f.host])
        XCTAssertEqual(one.prepare(relayed(host: f.host, sealed: f.sealed)).subtitle, "")

        let (two, _) = preparer(key: f.privateKey, hosts: hosts, signedIn: Set(hosts))
        XCTAssertEqual(two.prepare(relayed(host: f.host, sealed: f.sealed)).subtitle, "SUITE-B")
    }

    // MARK: InstallUnreadStore

    func testAnOlderAsOfWriteIsIgnored() {
        let store = InstallUnreadStore(defaults: defaults, hosts: { ["b"] })
        XCTAssertTrue(store.write(count: 0, asOf: Date(timeIntervalSince1970: 200), for: "b"))
        XCTAssertFalse(store.write(count: 3, asOf: Date(timeIntervalSince1970: 100), for: "b"), "a late, older push")
        XCTAssertEqual(store.entry(for: "b")?.count, 0)
        XCTAssertFalse(store.write(count: 3, asOf: Date(timeIntervalSince1970: 200), for: "b"), "equal is not newer")
        XCTAssertTrue(store.write(count: 4, asOf: Date(timeIntervalSince1970: 300), for: "b"))
        XCTAssertEqual(store.entry(for: "b")?.count, 4)
    }

    func testTheTotalExcludesARemovedInstall() {
        let installs = installsStore(["suite-a.localhost", "suite-b.localhost"])
        let store = InstallUnreadStore(defaults: defaults)
        store.write(count: 2, asOf: Date(), for: "suite-a.localhost")
        store.write(count: 3, asOf: Date(), for: "suite-b.localhost")
        XCTAssertEqual(store.total, 5)

        installs.remove(host: "suite-b.localhost")

        XCTAssertEqual(store.total, 2)
        XCTAssertNil(store.entry(for: "suite-b.localhost"), "removal clears the entry")
    }

    func testAnEntryForAHostNotSavedNeverCounts() {
        let store = InstallUnreadStore(defaults: defaults, hosts: { ["a"] })
        store.write(count: 9, asOf: Date(), for: "ghost")
        XCTAssertEqual(store.total, 0)
    }

    func testServerTimesParseWithMicrosecondsMillisecondsOrNone() {
        let micro = InstallUnreadStore.parseDate("2026-10-10T15:00:00.123456Z")
        let milli = InstallUnreadStore.parseDate("2026-10-10T15:00:00.123Z")
        let none = InstallUnreadStore.parseDate("2026-10-10T15:00:00Z")
        XCTAssertNotNil(micro)
        XCTAssertEqual(micro, milli)
        XCTAssertEqual(none.map { $0.timeIntervalSince1970 + 0.123 }, micro?.timeIntervalSince1970)
        XCTAssertNil(InstallUnreadStore.parseDate("yesterday"))
        XCTAssertNil(InstallUnreadStore.parseDate(nil))
    }

    // MARK: installBadges (the web switcher dot)

    func testInstallBadgesIsFalseWhenOnlyTheCurrentInstallHasUnread() {
        let store = InstallUnreadStore(defaults: defaults, hosts: { ["a", "b"] })
        store.write(count: 4, asOf: Date(), for: "a")
        XCTAssertFalse(SuiteNativePlugin.othersUnread(store: store, selectedHost: "a"))
        XCTAssertTrue(SuiteNativePlugin.othersUnread(store: store, selectedHost: "b"))

        store.write(count: 0, asOf: Date().addingTimeInterval(10), for: "a")
        XCTAssertFalse(SuiteNativePlugin.othersUnread(store: store, selectedHost: "b"), "zero is not unread")
    }

    func testInstallBadgesIsARegisteredBridgeMethod() {
        XCTAssertTrue(SuiteNativePlugin().pluginMethods.contains { $0.name == "installBadges" })
    }

    // MARK: Picker pill

    func testPillText() {
        XCTAssertNil(UnreadPill.text(0), "zero renders no pill, never 0")
        XCTAssertEqual(UnreadPill.text(7), "7")
        XCTAssertEqual(UnreadPill.text(99), "99")
        XCTAssertEqual(UnreadPill.text(100), "99+")
    }

    @MainActor
    func testThePickerKeepsItsRowOrderAndLastCountsAcrossARefresh() {
        let installs = installsStore(["suite-a.localhost", "suite-b.localhost"])
        let store = InstallUnreadStore(defaults: defaults)
        store.write(count: 3, asOf: Date(timeIntervalSince1970: 100), for: "suite-b.localhost")
        let model = InstallPickerModel(store: installs, unreadStore: store)
        let order = model.installs.map(\.host)

        store.markStale("suite-b.localhost")
        NotificationCenter.default.post(name: .burrowInstallBadgesChanged, object: nil)

        XCTAssertEqual(model.installs.map(\.host), order, "unread never reorders rows")
        XCTAssertEqual(model.unread["suite-b.localhost"]?.count, 3)
        XCTAssertEqual(model.unread["suite-b.localhost"]?.stale, true)
    }

    // MARK: UnreadReconciler

    private struct Unreachable: Error {}

    func testTheReconcilerMarksAnUnreachableHostStaleAndKeepsItsCount() {
        let store = InstallUnreadStore(defaults: defaults, hosts: { ["a", "b"] })
        store.write(count: 2, asOf: Date(timeIntervalSince1970: 100), for: "b")
        let asOf = Date(timeIntervalSince1970: 500)

        let done = expectation(description: "reconciled")
        var total = -1
        UnreadReconciler.reconcile(
            hosts: ["a", "b"], store: store,
            fetch: { host, reply in
                if host == "a" {
                    reply(.success(SuiteCounts(approvals: 0, tasks: 0, fetchedAt: Date(), unread: 1, asOf: asOf)))
                } else {
                    reply(.failure(Unreachable()))
                }
            },
            completion: {
                total = $0
                done.fulfill()
            })
        wait(for: [done], timeout: 5)

        XCTAssertEqual(store.entry(for: "a"), InstallUnread(count: 1, asOf: asOf, stale: false))
        XCTAssertEqual(store.entry(for: "b")?.count, 2, "keeps its last count")
        XCTAssertEqual(store.entry(for: "b")?.stale, true)
        XCTAssertEqual(total, 3)
    }

    func testASuccessfulReconcileClearsStaleEvenWhenAPushWasNewer() {
        let store = InstallUnreadStore(defaults: defaults, hosts: { ["a"] })
        store.write(count: 5, asOf: Date(timeIntervalSince1970: 900), for: "a")
        store.markStale("a")

        let done = expectation(description: "reconciled")
        UnreadReconciler.reconcile(
            hosts: ["a"], store: store,
            fetch: { _, reply in
                reply(
                    .success(
                        SuiteCounts(
                            approvals: 0, tasks: 0, fetchedAt: Date(), unread: 1, asOf: Date(timeIntervalSince1970: 100))))
            },
            completion: { _ in done.fulfill() })
        wait(for: [done], timeout: 5)

        XCTAssertEqual(store.entry(for: "a"), InstallUnread(count: 5, asOf: Date(timeIntervalSince1970: 900), stale: false))
    }

    func testTheReconcilerRunsAtMostFourAtOnce() {
        let store = InstallUnreadStore(defaults: defaults, hosts: { [] })
        let lock = NSLock()
        var inFlight = 0
        var peak = 0
        let hosts = (1...10).map { "h\($0)" }

        let done = expectation(description: "reconciled")
        UnreadReconciler.reconcile(
            hosts: hosts, store: store,
            fetch: { _, reply in
                lock.lock()
                inFlight += 1
                peak = max(peak, inFlight)
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    lock.lock()
                    inFlight -= 1
                    lock.unlock()
                    reply(.failure(Unreachable()))
                }
            },
            completion: { _ in done.fulfill() })
        wait(for: [done], timeout: 10)

        XCTAssertEqual(peak, 4)
    }

    // MARK: Counts decoding

    func testCountsWithoutUnreadStillDecodeFromAnOlderServerAndCache() throws {
        struct Old: Encodable { let approvals = 1, tasks = 2, fetchedAt = Date() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let counts = try decoder.decode(SuiteCounts.self, from: encoder.encode(Old()))
        XCTAssertNil(counts.unread)
        XCTAssertNil(counts.asOf)
    }

    func testTheCountsRouteReadsUnreadAndAsOf() {
        StubURLProtocol.reset()
        StubURLProtocol.respond = { _ in
            (200, Data(#"{"approvals":1,"tasks":2,"unread":7,"as_of":"2026-10-10T15:00:00.5Z"}"#.utf8))
        }
        let client = SuiteAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: ["x.test": "t"]))
        let done = expectation(description: "counts")
        var got: SuiteCounts?
        client.counts(host: "x.test") {
            got = try? $0.get()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(got?.unread, 7)
        XCTAssertEqual(got?.asOf, InstallUnreadStore.parseDate("2026-10-10T15:00:00.500Z"))
    }

    // MARK: Keys

    func testOneKeyPerHostInTheSharedKeychainAndSignOutDeletesIt() {
        let keys = PushKeyStore.shared
        let a = "k-\(UUID().uuidString.lowercased()).test.invalid"
        let b = "k-\(UUID().uuidString.lowercased()).test.invalid"
        defer {
            keys.remove(for: a)
            keys.remove(for: b)
        }

        let pubA = keys.publicKey(for: a)
        let pubB = keys.publicKey(for: b)
        XCTAssertNotNil(pubA)
        XCTAssertNotEqual(pubA, pubB, "installs cannot correlate the device by key")
        XCTAssertEqual(keys.publicKey(for: a), pubA, "stable once created")
        XCTAssertEqual(pubA?.count, 43, "base64url, no padding, 32 bytes")
        XCTAssertFalse(pubA?.contains("=") ?? true)

        keys.remove(for: a)
        XCTAssertNil(keys.privateKey(for: a))
        XCTAssertNotNil(keys.privateKey(for: b))
    }

    func testNativeSignOutForgetsThePushKey() {
        StubURLProtocol.reset()
        StubURLProtocol.respond = { _ in (204, Data()) }
        let host = "so-\(UUID().uuidString.lowercased()).test.invalid"
        var forgotten: [String] = []
        let tokens = KeychainTokenStore.shared
        XCTAssertTrue(tokens.store("bearer", for: host))
        defer { tokens.remove(for: host) }

        let done = expectation(description: "signed out")
        NativeSignOut(
            client: SuiteAPIClient(session: StubURLProtocol.session(), tokens: tokens), tokens: tokens,
            appInstallID: "install-1", forgetPushKey: { forgotten.append($0) }
        ).run(host: host) { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(forgotten, [host])
    }

    // MARK: Review round 2: the install on a communication notification

    private func chatPush(host: String, space: String?, author: String, kind: String = "chat_mention") -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = space.map { "\(author) in \($0)" } ?? author
        content.body = "@Marlowe can you check the deck before 3?"
        var info: [AnyHashable: Any] = [
            "kind": kind, "install_host": host, "space_id": UUID().uuidString, "message_id": UUID().uuidString,
            "author_id": UUID().uuidString, "author_type": "user", "author_name": author,
        ]
        if let space { info["space_name"] = space }
        content.userInfo = info
        return content
    }

    private func intent(_ prep: PushContentPreparer, _ push: UNNotificationContent) throws -> INSendMessageIntent {
        CommunicationNotification.sendMessageIntent(try XCTUnwrap(CommunicationPayload(userInfo: prep.prepare(push).userInfo)))
    }

    /// iOS 27 draws a communication notification as sender, conversation
    /// name, body, and the conversation name ONLY for a group (two or more
    /// recipients); `content.subtitle` is never drawn. Measured on the
    /// simulator: "Dana, launch · B, @Marlowe ..." (review round 2 evidence).
    func testTwoSignedInInstallsPutTheInstallInADrawnGroupName() throws {
        let hosts = ["suite-a.localhost", "suite-b.localhost"]
        let (prep, _) = preparer(key: nil, hosts: hosts, signedIn: Set(hosts))

        let space = try intent(prep, chatPush(host: "suite-b.localhost", space: "launch", author: "Dana"))
        XCTAssertEqual(space.speakableGroupName?.spokenPhrase, "launch · SUITE-B")
        XCTAssertEqual(space.recipients?.count, 2, "iOS draws the group name only with more than one recipient")
        XCTAssertEqual(space.recipients?.filter(\.isMe).count, 1)
        XCTAssertEqual(space.recipients?.first?.displayName, "Dana")

        let dm = try intent(prep, chatPush(host: "suite-b.localhost", space: "Cora", author: "Cora", kind: "chat_message"))
        XCTAssertEqual(dm.speakableGroupName?.spokenPhrase, "Cora · SUITE-B", "a dm: <sender> · <install>")
        XCTAssertEqual(dm.recipients?.count, 2)
        XCTAssertEqual(dm.sender?.displayName, "Cora", "the sender line is unchanged")
    }

    func testOneSignedInInstallKeepsTheIntentAsBefore() throws {
        let hosts = ["suite-a.localhost", "suite-b.localhost"]
        let (prep, _) = preparer(key: nil, hosts: hosts, signedIn: ["suite-b.localhost"])

        let space = try intent(prep, chatPush(host: "suite-b.localhost", space: "launch", author: "Dana"))
        XCTAssertEqual(space.speakableGroupName?.spokenPhrase, "launch")
        XCTAssertNil(space.recipients)

        let dm = try intent(prep, chatPush(host: "suite-b.localhost", space: "Cora", author: "Cora", kind: "chat_message"))
        XCTAssertNil(dm.speakableGroupName)
        XCTAssertNil(dm.recipients)
        XCTAssertNil(prep.prepare(chatPush(host: "suite-b.localhost", space: nil, author: "Cora")).userInfo["install_label"])
    }

    func testTheConversationNameRule() {
        XCTAssertEqual(CommunicationNotification.conversationName(space: "launch", sender: "Dana", install: "B"), "launch · B")
        XCTAssertEqual(CommunicationNotification.conversationName(space: nil, sender: "Cora", install: "B"), "Cora · B")
        XCTAssertEqual(CommunicationNotification.conversationName(space: nil, sender: nil, install: "B"), "B")
        XCTAssertEqual(CommunicationNotification.conversationName(space: "launch", sender: "Dana", install: nil), "launch")
        XCTAssertNil(CommunicationNotification.conversationName(space: nil, sender: "Cora", install: nil))
    }

    // MARK: Review round 2: one counts request per install per open

    func testAnOpenSendsOneCountsRequestPerInstallAndFeedsTheWidgets() {
        StubURLProtocol.reset()
        StubURLProtocol.respond = { request in
            let unread = ["a.test": 1, "b.test": 2, "c.test": 3][request.url?.host ?? ""] ?? 0
            return (200, Data(#"{"approvals":4,"tasks":5,"unread":\#(unread),"as_of":"2026-10-10T15:00:00Z"}"#.utf8))
        }
        let hosts = ["a.test", "b.test", "c.test"]
        let client = SuiteAPIClient(
            session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: Dictionary(uniqueKeysWithValues: hosts.map { ($0, "t") })))
        let store = InstallUnreadStore(defaults: defaults, hosts: { hosts })
        let cache = CountsCache(defaults: defaults)
        var reloads = 0

        let done = expectation(description: "open refreshed")
        OpenRefresh.run(
            hosts: hosts, selectedHost: "b.test", client: client, store: store, cache: cache,
            reloadWidgets: { reloads += 1 }, completion: { _ in done.fulfill() })
        wait(for: [done], timeout: 5)

        let perHost = Dictionary(grouping: StubURLProtocol.requests.filter { $0.url?.path == "/api/app/counts" }) { $0.url?.host ?? "" }
            .mapValues(\.count)
        XCTAssertEqual(perHost, ["a.test": 1, "b.test": 1, "c.test": 1], "one GET /api/app/counts per install per open")
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        XCTAssertEqual(cache.counts(for: "b.test")?.approvals, 4, "the selected install's widgets come from the same answer")
        XCTAssertEqual(cache.counts(for: "b.test")?.tasks, 5)
        XCTAssertNil(cache.counts(for: "a.test"), "only the selected install feeds the widgets")
        XCTAssertEqual(store.total, 6)
        XCTAssertEqual(reloads, 1)
    }

    /// The app's foreground hook makes ONE refresh call; the widget refresher
    /// no longer fetches there too.
    func testTheForegroundHookRunsOnlyTheOneOpenRefresh() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("App/SceneDelegate.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func sceneDidBecomeActive"))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("OpenRefresh.run()"))
        XCTAssertFalse(body.contains("WidgetCountsRefresher"), "a second counts request for the selected install")
        XCTAssertFalse(body.contains("UnreadReconciler.refreshAll"), "a second counts request per install")
    }

    // MARK: Review round 2: the host line of a stale install

    func testAStaleInstallThatIsAlsoUnreachableReadsCouldNotUpdateDimmed() {
        let stale = InstallUnread(count: 3, asOf: Date(timeIntervalSince1970: 100), stale: true)
        let status = InstallRowStatus(unreachable: true, unread: stale)
        XCTAssertEqual(status, .couldNotUpdate(unreachable: true))
        XCTAssertEqual(status.text(host: "b.test"), "Could not update")
        XCTAssertTrue(status.showsUnreachableDot, "the red dot stays: a tap retries")
        XCTAssertTrue(status.dimmed)

        let zero = InstallRowStatus(unreachable: false, unread: InstallUnread(count: 0, asOf: Date(), stale: true))
        XCTAssertEqual(zero.text(host: "b.test"), "Could not update")
        XCTAssertTrue(zero.dimmed, "a 0-count stale row is dimmed too")
        XCTAssertFalse(zero.showsUnreachableDot)

        let fresh = InstallUnread(count: 3, asOf: Date(), stale: false)
        XCTAssertEqual(InstallRowStatus(unreachable: true, unread: nil).text(host: "b.test"), "Can't reach. Tap to retry.")
        XCTAssertEqual(InstallRowStatus(unreachable: true, unread: fresh).text(host: "b.test"), "Can't reach. Tap to retry.")
        XCTAssertFalse(InstallRowStatus(unreachable: true, unread: fresh).dimmed)
        XCTAssertEqual(InstallRowStatus(unreachable: false, unread: fresh).text(host: "b.test"), "b.test")
    }

    /// No seam: the install's host does not resolve (`.invalid`), so BOTH the
    /// counts fetch and the picker's reachability probe fail on the real
    /// network stack, as with a stopped server.
    @MainActor
    func testATrulyUnreachableStaleInstallReadsCouldNotUpdateInThePicker() async {
        let host = "gone-\(UUID().uuidString.prefix(8).lowercased()).invalid"
        let installs = installsStore([host])
        let store = InstallUnreadStore(defaults: defaults, hosts: { [host] })
        store.write(count: 3, asOf: Date(timeIntervalSince1970: 100), for: host)
        let client = SuiteAPIClient(
            session: URLSession(configuration: .ephemeral), tokens: MemoryTokenStore(tokens: [host: "t"]))

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            OpenRefresh.run(
                hosts: [host], selectedHost: host, client: client, store: store, cache: CountsCache(defaults: defaults),
                reloadWidgets: {}, completion: { _ in done.resume() })
        }
        let model = InstallPickerModel(store: installs, unreadStore: store)
        model.refresh(host)
        for _ in 0..<100 where model.reachability[host] != .unreachable { try? await Task.sleep(nanoseconds: 100_000_000) }

        XCTAssertEqual(model.reachability[host], .unreachable, "the probe really failed")
        XCTAssertEqual(model.unread[host]?.stale, true, "the counts fetch really failed")
        XCTAssertEqual(model.unread[host]?.count, 3)
        let row = InstallRow(
            install: Install(host: host), icon: nil, selected: false, unreachable: model.reachability[host] == .unreachable,
            unread: model.unread[host])
        XCTAssertEqual(row.status, .couldNotUpdate(unreachable: true))
        XCTAssertEqual(row.status.text(host: host), "Could not update")
        XCTAssertTrue(row.status.dimmed)
    }

    // MARK: Switch banner

    func testTheSwitchBannerShowsOnlyWhenTheInstallChanges() {
        XCTAssertEqual(SwitchBanner.message("B"), "Switched to B")
        XCTAssertTrue(SwitchBanner.shouldShow(currentHost: "suite-a.localhost", targetHost: "suite-b.localhost"))
        XCTAssertFalse(SwitchBanner.shouldShow(currentHost: "suite-b.localhost", targetHost: "Suite-B.localhost"))
        XCTAssertFalse(SwitchBanner.shouldShow(currentHost: nil, targetHost: "suite-b.localhost"), "cold launch")
        XCTAssertEqual(SwitchBanner.duration, 2)
    }
}
