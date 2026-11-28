import XCTest

@testable import App

/// Task 01a21e75 stage 4: the feed widgets' data. Decoded from the stage 1
/// JSON, fetched from every install with its own bearer, reused for 5
/// minutes, merged with a failed install's last-known feed kept and marked
/// stale. Fixture installs are example.test hosts; people "Test Person",
/// agents "Build agent".
final class FeedProviderTests: XCTestCase {
    private let a = "app.example.test"
    private let b = "lab.example.test"
    private var defaultsName = ""
    private var cache: WidgetFeedCache!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        defaultsName = "feed-\(UUID().uuidString)"
        cache = WidgetFeedCache(defaults: UserDefaults(suiteName: defaultsName))
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: defaultsName)
        StubURLProtocol.reset()
        super.tearDown()
    }

    private var saved: [Install] { [Install(host: a, name: "Alpha"), Install(host: b, name: "Lab")] }

    private func client(_ tokens: [String: String]) -> BurrowAPIClient {
        BurrowAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: tokens))
    }

    /// The stage 1 response shape, microsecond times and all.
    private func body(waiting: Int, rows: Int = 2, prefix: String = "x", minutesAgo: Int = 4) -> Data {
        let waitingRows = (0..<rows).map { i in
            #"{"item_id":"\#(prefix)w\#(i)","space_path_segment":"seg-\#(prefix)\#(i)","asker":"Build agent","summary":"Needs a yes \#(i)","at":"\#(iso(minutesAgo + i))"}"#
        }.joined(separator: ",")
        return Data(
            #"""
            {"as_of":"2026-11-27T12:00:00.123456Z",
             "waiting":{"count":\#(waiting),"rows":[\#(waitingRows)]},
             "blocked":{"count":1,"rows":[{"id":"0b000000-0000-4000-8000-00000000000\#(prefix == "x" ? "1" : "2")","title":"Widget feed","reason":"Waiting on a device test"}]},
             "recent":{"rows":[{"space_id":"s-\#(prefix)","path_segment":"agents-\#(prefix)","kind":"dm","name":"Test Person","counterpart":{"type":"user","id":"u1"},"unread":true}]},
             "shipped":{"count":2,"newest_title":"Calendar landscape fix"}}
            """#.utf8)
    }

    private func iso(_ minutesAgo: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(TimeInterval(-60 * minutesAgo))).replacingOccurrences(of: "Z", with: "123Z")
    }

    func testDecodesTheServerShape() throws {
        let feed = try JSONDecoder().decode(WidgetFeed.self, from: body(waiting: 7))
        XCTAssertEqual(feed.waiting.count, 7)
        XCTAssertEqual(feed.waiting.rows.first?.asker, "Build agent")
        XCTAssertNotNil(feed.waiting.rows.first?.date, "microsecond ISO-8601 parses")
        XCTAssertEqual(feed.recent.rows.first?.counterpart, WidgetFeed.Counterpart(type: "user", id: "u1"))
        XCTAssertEqual(feed.shipped.newestTitle, "Calendar landscape fix")
    }

    func testMergesAcrossInstallsWithEachBearerAndRowsKeepTheirHost() async {
        StubURLProtocol.respond = { request in (200, self.body(waiting: request.url?.host == self.a ? 5 : 2, prefix: request.url?.host == self.a ? "a" : "b")) }
        let tokens = [a: "token-for-a", b: "token-for-b"]
        let results = await WidgetFeedLoader.load(installs: saved, client: client(tokens), cache: cache)
        let entry = FeedEntry.merged(date: Date(), results: results, saved: saved, scope: .all)

        for request in StubURLProtocol.requests {
            XCTAssertEqual(request.url?.path, "/api/app/widgets")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(tokens[request.url?.host ?? ""] ?? "?")")
        }
        XCTAssertEqual(entry.count(.waiting), 7, "totals summed")
        XCTAssertEqual(entry.breakdown(.waiting), "Alpha 5 · Lab 2")
        XCTAssertEqual(entry.waitingRows.count, 4)
        XCTAssertEqual(Set(entry.waitingRows.map(\.installLabel)), ["Alpha", "Lab"])
        for row in entry.waitingRows {
            XCTAssertEqual(DeepLink(url: row.link)?.host, row.host, "a row opens its own install")
            XCTAssertEqual(DeepLink(url: row.link)?.path, "/chat/\(row.row.spacePathSegment)")
        }
        for row in entry.blockedRows { XCTAssertEqual(DeepLink(url: row.link)?.host, row.host) }
        for row in entry.recentRows { XCTAssertEqual(DeepLink(url: row.link)?.host, row.host) }
        XCTAssertEqual(entry.count(.shipped), 4)
        XCTAssertFalse(entry.couldNotRefresh)
    }

    func testWaitingRowsAreNewestFirstAndTheViewShowsAtMostTwo() async {
        StubURLProtocol.respond = { request in
            let isA = request.url?.host == self.a
            return (200, self.body(waiting: 9, rows: 5, prefix: isA ? "a" : "b", minutesAgo: isA ? 1 : 30))
        }
        let results = await WidgetFeedLoader.load(installs: saved, client: client([a: "t", b: "t"]), cache: cache)
        let entry = FeedEntry.merged(date: Date(), results: results, saved: saved, scope: .all)
        let dates = entry.waitingRows.compactMap(\.row.date)
        XCTAssertEqual(dates, dates.sorted(by: >))
        XCTAssertEqual(entry.waitingRows.prefix(2).map(\.host), [a, a])
        XCTAssertEqual(entry.count(.waiting), 18, "the count says the rest; no +N more row")
    }

    func testAFailedInstallKeepsItsLastKnownFeedInTheTotalMarkedStale() async {
        cache.write(
            CachedWidgetFeed(
                feed: try! JSONDecoder().decode(WidgetFeed.self, from: body(waiting: 2, prefix: "b")), fetchedAt: Date().addingTimeInterval(-7200)),
            for: b)
        StubURLProtocol.respond = { request in request.url?.host == self.b ? (500, Data()) : (200, self.body(waiting: 5, prefix: "a")) }
        let results = await WidgetFeedLoader.load(installs: saved, client: client([a: "t", b: "t"]), cache: cache)
        let entry = FeedEntry.merged(date: Date(), results: results, saved: saved, scope: .all)

        XCTAssertEqual(entry.count(.waiting), 7, "the total never quietly drops")
        XCTAssertEqual(entry.breakdown(.waiting), "Alpha 5 · Lab 2 (2h ago)")
        XCTAssertEqual(entry.failures.map(\.text), ["Can't reach Lab"])
        XCTAssertFalse(entry.couldNotRefresh)
    }

    func testEveryInstallFailingIsCouldNotRefreshWithTheLastData() async {
        let old = Date().addingTimeInterval(-7200)
        for (host, prefix) in [(a, "a"), (b, "b")] {
            cache.write(CachedWidgetFeed(feed: try! JSONDecoder().decode(WidgetFeed.self, from: body(waiting: 1, prefix: prefix)), fetchedAt: old), for: host)
        }
        StubURLProtocol.respond = { _ in (500, Data()) }
        let results = await WidgetFeedLoader.load(installs: saved, client: client([a: "t", b: "t"]), cache: cache)
        let entry = FeedEntry.merged(date: Date(), results: results, saved: saved, scope: .all)

        XCTAssertTrue(entry.couldNotRefresh)
        XCTAssertEqual(entry.updatedLine, "Updated 2h ago")
        XCTAssertEqual(entry.count(.waiting), 2, "never blank")
    }

    func testSignedOutIsNeverRequestedAndReadsSignedOut() async {
        let results = await WidgetFeedLoader.load(installs: [saved[0]], client: client([:]), cache: cache)
        let entry = FeedEntry.merged(date: Date(), results: results, saved: [saved[0]], scope: .all)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        XCTAssertFalse(entry.signedIn)
        XCTAssertEqual(entry.link(path: "/inbox"), FeedEntry.appURL, "signed out opens the app")
    }

    func testAFeedUnderFiveMinutesOldIsReusedWithNoSecondRequest() async {
        StubURLProtocol.respond = { _ in (200, self.body(waiting: 3)) }
        let client = client([a: "t"])
        _ = await WidgetFeedLoader.load(installs: [saved[0]], client: client, cache: cache)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)

        // Three more feed widgets refreshing in the same window.
        for _ in 0..<3 { _ = await WidgetFeedLoader.load(installs: [saved[0]], client: client, cache: cache) }
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "four placed widgets, one request per install")

        let later = Date().addingTimeInterval(WidgetFeedLoader.reuseAfter + 1)
        _ = await WidgetFeedLoader.load(installs: [saved[0]], client: client, cache: cache, now: { later })
        XCTAssertEqual(StubURLProtocol.requests.count, 2, "older than 5 minutes: fetched again")
    }

    func testPinnedToOneOfSeveralSaysInstallOnly() async {
        StubURLProtocol.respond = { _ in (200, self.body(waiting: 3)) }
        let results = await WidgetFeedLoader.load(installs: WidgetScope.pinned(b).installs(from: saved), client: client([a: "t", b: "t"]), cache: cache)
        let entry = FeedEntry.merged(date: Date(), results: results, saved: saved, scope: .pinned(b))
        XCTAssertEqual(entry.pinnedLabel, "Lab only")
        XCTAssertEqual(StubURLProtocol.requests.map(\.url?.host), [b])
        XCTAssertNil(entry.breakdown(.waiting))
        XCTAssertNil(entry.waitingRows.first?.installLabel)
    }

    func testShortTimes() {
        let now = Date()
        XCTAssertEqual(FeedEntry.shortAgo(now.addingTimeInterval(-240), now: now), "4m")
        XCTAssertEqual(FeedEntry.shortAgo(now.addingTimeInterval(-7300), now: now), "2h")
        XCTAssertEqual(FeedEntry.shortAgo(now.addingTimeInterval(-20), now: now), "now")
    }
}
