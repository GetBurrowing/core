import XCTest

@testable import App

final class SlabStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ago(minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    /// The whole rule as a table. Cyan (`.live`) only when signed in, fresh
    /// and non-zero; the 30-minute boundary is exclusive (exactly 30 is
    /// fresh, anything past it is stale).
    func testSlabStateTable() {
        let cases: [(count: Int, age: Double, signedIn: Bool, expected: SlabState, why: String)] = [
            (3, 0, true, .live, "fresh and non-zero"),
            (1, 14, true, .live, "one refresh old"),
            (9999, 1, true, .live, "four digits is still live"),
            (0, 0, true, .zero, "fresh zero"),
            (0, 29, true, .zero, "zero inside the window"),
            (3, 29.99, true, .live, "just inside 30 minutes"),
            (3, 30, true, .live, "exactly 30 minutes is not OLDER than 30"),
            (3, 30.02, true, .stale, "one second past the boundary"),
            (3, 31, true, .stale, "31 minutes old"),
            (0, 31, true, .stale, "an old zero is stale, not zero"),
            (3, 600, true, .stale, "hours old"),
            (3, 0, false, .signedOut, "no bearer wins over a fresh count"),
            (0, 31, false, .signedOut, "no bearer wins over stale"),
        ]
        for c in cases {
            XCTAssertEqual(
                slabState(count: c.count, fetchedAt: ago(minutes: c.age), now: now, signedIn: c.signedIn),
                c.expected, c.why)
        }
    }

    func testOnlyLiveUsesTheLiveFill() {
        XCTAssertTrue(SlabState.live.usesLiveFill)
        XCTAssertFalse(SlabState.zero.usesLiveFill)
        XCTAssertFalse(SlabState.stale.usesLiveFill)
        XCTAssertFalse(SlabState.signedOut.usesLiveFill)
    }

    func testCaptionsUseTheCanvasCopy() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(SlabKind.approvals.caption(for: .live, fetchedAt: nil), "waiting on you")
        XCTAssertEqual(SlabKind.tasks.caption(for: .live, fetchedAt: nil), "open")
        XCTAssertEqual(SlabKind.approvals.caption(for: .zero, fetchedAt: nil), "Nothing waiting")
        XCTAssertEqual(SlabKind.tasks.caption(for: .zero, fetchedAt: nil), "Nothing open")
        XCTAssertEqual(SlabKind.approvals.caption(for: .signedOut, fetchedAt: nil), "Sign in to see approvals")
        let stale = SlabKind.approvals.caption(for: .stale, fetchedAt: now, timeZone: utc)
        XCTAssertTrue(stale.hasPrefix("As of "), stale)
    }

    /// A widget whose refresh never comes must still drop its cyan on time:
    /// the timeline carries a second entry just past the stale boundary.
    func testTimelineCarriesAnEntryThatTurnsStale() {
        let counts = SuiteCounts(approvals: 3, tasks: 0, fetchedAt: now)
        let entry = CountsEntry(date: now, host: "suite.example.net", signedIn: true, counts: counts)
        let timeline = CountsEntry.timeline(from: entry, now: now)

        XCTAssertEqual(timeline.entries.count, 2)
        XCTAssertEqual(timeline.entries[0].state(.approvals), .live)
        XCTAssertEqual(timeline.entries[0].state(.tasks), .zero)
        XCTAssertEqual(timeline.entries[1].state(.approvals), .stale)
        XCTAssertEqual(timeline.entries[1].state(.tasks), .stale)
        XCTAssertEqual(timeline.policy, .after(now.addingTimeInterval(15 * 60)))
    }

    func testSignedOutEntryHasNoCountState() {
        let entry = CountsEntry(
            date: now, host: "suite.example.net", signedIn: false,
            counts: SuiteCounts(approvals: 3, tasks: 1, fetchedAt: now))
        XCTAssertEqual(entry.state(.approvals), .signedOut)
        XCTAssertEqual(CountsEntry.timeline(from: entry, now: now).entries.first?.state(.tasks), .signedOut)
    }

    func testCountsCacheRoundTripsPerHost() {
        let name = "CountsCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let cache = CountsCache(defaults: defaults)
        let counts = SuiteCounts(approvals: 2, tasks: 5, fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))
        cache.write(counts, for: "a.example.com")
        XCTAssertEqual(cache.counts(for: "a.example.com"), counts)
        XCTAssertNil(cache.counts(for: "b.example.com"))
    }

    func testDeepLinksRoundTripAndRefuseOtherPaths() throws {
        let approvals = DeepLink(host: "suite.example.net", path: SlabKind.approvals.path)
        XCTAssertEqual(approvals.url.absoluteString, "burrow://open?host=suite.example.net&path=/inbox")
        XCTAssertEqual(DeepLink(url: approvals.url), approvals)
        XCTAssertEqual(approvals.destination.absoluteString, "https://suite.example.net/inbox")
        XCTAssertEqual(
            DeepLink(host: "suite.example.net", path: SlabKind.tasks.path).destination.absoluteString,
            "https://suite.example.net/tasks")

        XCTAssertNil(DeepLink(url: URL(string: "burrow://open?host=suite.example.net&path=/admin")!))
        XCTAssertNil(DeepLink(url: URL(string: "burrow://open?host=evil.example.com%2Fx&path=//evil.example.com")!))
        XCTAssertNil(DeepLink(url: URL(string: "burrow://auth/callback?code=x")!))
        XCTAssertNil(DeepLink(url: URL(string: "burrow://open?path=/inbox")!))
    }
}
