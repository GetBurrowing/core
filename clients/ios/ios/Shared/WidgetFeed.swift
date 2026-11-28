import Foundation
import WidgetKit

/// `GET /api/app/widgets` (task 01a21e75 stage 1): the Waiting on you,
/// Blocked for you, Recent and Shipped today data for one install, in ONE
/// response. `summary` is the server's one-line cut of a message, never the
/// body. Nothing here is logged.
struct WidgetFeed: Codable, Equatable {
    struct WaitingRow: Codable, Equatable {
        let itemID: String
        let spacePathSegment: String
        let asker: String?
        let summary: String
        /// ISO-8601 with microseconds, as the server sends it.
        let at: String?

        var date: Date? { InstallUnreadStore.parseDate(at) }

        enum CodingKeys: String, CodingKey {
            case itemID = "item_id"
            case spacePathSegment = "space_path_segment"
            case asker, summary, at
        }
    }

    struct Waiting: Codable, Equatable {
        let count: Int
        let rows: [WaitingRow]
    }

    struct BlockedRow: Codable, Equatable {
        let id: String
        let title: String
        let reason: String?
    }

    struct Blocked: Codable, Equatable {
        let count: Int
        let rows: [BlockedRow]
    }

    struct Counterpart: Codable, Equatable {
        /// `user` or `agent`.
        let type: String
        let id: String
    }

    struct RecentRow: Codable, Equatable {
        let spaceID: String
        let pathSegment: String
        /// `channel`, `dm` or `group`.
        let kind: String
        let name: String
        let counterpart: Counterpart?
        let unread: Bool

        enum CodingKeys: String, CodingKey {
            case spaceID = "space_id"
            case pathSegment = "path_segment"
            case kind, name, counterpart, unread
        }
    }

    struct Recent: Codable, Equatable {
        let rows: [RecentRow]
    }

    struct Shipped: Codable, Equatable {
        let count: Int
        let newestTitle: String?

        enum CodingKeys: String, CodingKey {
            case count
            case newestTitle = "newest_title"
        }
    }

    let asOf: String?
    let waiting: Waiting
    let blocked: Blocked
    let recent: Recent
    let shipped: Shipped

    enum CodingKeys: String, CodingKey {
        case asOf = "as_of"
        case waiting, blocked, recent, shipped
    }
}

/// One install's feed as this device received it.
struct CachedWidgetFeed: Codable, Equatable {
    let feed: WidgetFeed
    /// When THIS device received it (the phone's clock, as `BurrowCounts`).
    let fetchedAt: Date
}

/// The last feed per install host, in the App Group, so a failed refresh
/// shows the last data ("Updated 2h ago") and four placed feed widgets share
/// one request per install (`WidgetFeedLoader.reuseAfter`).
struct WidgetFeedCache {
    private static let keyPrefix = "burrow.widgetfeed.v1."
    let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: InstallStore.appGroup)) {
        self.defaults = defaults ?? .standard
    }

    func feed(for host: String) -> CachedWidgetFeed? {
        defaults.data(forKey: Self.keyPrefix + host).flatMap { try? Self.decoder.decode(CachedWidgetFeed.self, from: $0) }
    }

    func write(_ value: CachedWidgetFeed, for host: String) {
        if let data = try? Self.encoder.encode(value) { defaults.set(data, forKey: Self.keyPrefix + host) }
    }

    func remove(for host: String) {
        defaults.removeObject(forKey: Self.keyPrefix + host)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

extension BurrowAPIClient {
    /// `GET /api/app/widgets` with `host`'s own bearer.
    func widgetFeed(host: String) async throws -> WidgetFeed {
        try await fetch(WidgetFeed.self, host: host, path: "/api/app/widgets")
    }
}

/// Fetches the feed of every install a widget covers through
/// `InstallFanout` (each with its own bearer, at most 3 at once). A feed
/// younger than `reuseAfter` is reused with no request, so the four feed
/// widgets, refreshed together, cost one request per install.
enum WidgetFeedLoader {
    static let reuseAfter: TimeInterval = 5 * 60

    static func load(
        installs: [Install], client: BurrowAPIClient, cache: WidgetFeedCache, reuseAfter: TimeInterval = WidgetFeedLoader.reuseAfter,
        now: @escaping @Sendable () -> Date = Date.init
    ) async -> [(install: Install, result: InstallResult<CachedWidgetFeed>)] {
        await InstallFanout.fetch(
            installs: installs, client: client,
            lastKnown: { host in cache.feed(for: host).map { ($0, $0.fetchedAt) } },
            fetch: { host in
                if let cached = cache.feed(for: host), now().timeIntervalSince(cached.fetchedAt) < reuseAfter { return cached }
                let fresh = CachedWidgetFeed(feed: try await client.widgetFeed(host: host), fetchedAt: now())
                cache.write(fresh, for: host)
                return fresh
            })
    }
}

// MARK: - The merged entry

/// One install's part of a feed widget.
struct FeedInstall: Equatable {
    let host: String
    /// `InstallLabel.name(for:installs:)`: a display name, never the host.
    let label: String
    let status: InstallCounts.Status
    let cached: CachedWidgetFeed?
}

/// Which section of the feed a widget shows.
enum FeedSection {
    case waiting, blocked, shipped
}

/// One rendered moment of the four feed widgets, across the installs a
/// widget covers (task 01a21e75 stage 4). Counts are summed, a failed
/// install's last-known feed stays in (marked stale in the breakdown), and
/// every row keeps its own host so a tap opens its install.
struct FeedEntry: TimelineEntry {
    let date: Date
    let installs: [FeedInstall]
    /// "<install> only" for a widget pinned to one of several installs.
    var pinnedLabel: String? = nil

    struct Waiting: Equatable, Identifiable {
        let host: String
        /// Install label, only with several installs signed in.
        let installLabel: String?
        let row: WidgetFeed.WaitingRow
        var id: String { "\(host)|\(row.itemID)" }
        var link: URL { DeepLink.space(host: host, pathSegment: row.spacePathSegment)?.url ?? DeepLink(host: host, path: "/").url }
    }

    struct Blocked: Equatable, Identifiable {
        let host: String
        let installLabel: String?
        let row: WidgetFeed.BlockedRow
        var id: String { "\(host)|\(row.id)" }
        var link: URL { DeepLink.task(host: host, id: row.id)?.url ?? DeepLink(host: host, path: "/tasks").url }
    }

    struct Recent: Equatable, Identifiable {
        let host: String
        let installLabel: String?
        let row: WidgetFeed.RecentRow
        var id: String { "\(host)|\(row.spaceID)" }
        var link: URL { DeepLink.space(host: host, pathSegment: row.pathSegment)?.url ?? DeepLink(host: host, path: "/").url }
    }

    // MARK: Installs

    var signedInInstalls: [FeedInstall] { installs.filter { $0.status != .signedOut } }
    var signedIn: Bool { !signedInInstalls.isEmpty }
    var isMultiInstall: Bool { signedInInstalls.count > 1 }

    /// Feeds to show: fresh or last-known, in saved order.
    private var feeds: [(FeedInstall, WidgetFeed)] { signedInInstalls.compactMap { install in install.cached.map { (install, $0.feed) } } }

    /// The newest time any install answered.
    var newestFetch: Date? { signedInInstalls.compactMap(\.cached?.fetchedAt).max() }

    /// Signed in, with last data but nothing fresh: no install answered this
    /// round, or the newest data is past `SlabState.staleAfter`. The widget
    /// keeps the last data and says "Updated 2h ago", never blank.
    var couldNotRefresh: Bool {
        guard signedIn, let newest = newestFetch else { return false }
        let anyFresh = signedInInstalls.contains { $0.status == .ok }
        return !anyFresh || date.timeIntervalSince(newest) > SlabState.staleAfter
    }

    /// "Updated 2h ago".
    var updatedLine: String? {
        guard couldNotRefresh, let newest = newestFetch else { return nil }
        return "Updated \(CountsEntry.ago(newest, now: date))"
    }

    /// Signed in and nothing ever loaded.
    var notLoaded: Bool { signedIn && newestFetch == nil }

    private func label(_ install: FeedInstall) -> String? { isMultiInstall ? install.label : nil }

    // MARK: Sections

    func count(_ section: FeedSection) -> Int {
        feeds.map { _, feed in
            switch section {
            case .waiting: return feed.waiting.count
            case .blocked: return feed.blocked.count
            case .shipped: return feed.shipped.count
            }
        }.reduce(0, +)
    }

    /// Newest first across installs.
    var waitingRows: [Waiting] {
        feeds.flatMap { install, feed in feed.waiting.rows.map { Waiting(host: install.host, installLabel: label(install), row: $0) } }
            .sorted { ($0.row.date ?? .distantPast) > ($1.row.date ?? .distantPast) }
    }

    /// Each install's own order (most recently updated first), interleaved.
    var blockedRows: [Blocked] {
        interleave(feeds.map { install, feed in feed.blocked.rows.map { Blocked(host: install.host, installLabel: label(install), row: $0) } })
    }

    var recentRows: [Recent] {
        interleave(feeds.map { install, feed in feed.recent.rows.map { Recent(host: install.host, installLabel: label(install), row: $0) } })
    }

    /// The first install's newest shipped title (the server has no time on it).
    var newestShipped: String? { feeds.lazy.compactMap { $0.1.shipped.newestTitle }.first }

    private func interleave<T>(_ lists: [[T]]) -> [T] {
        var out: [T] = []
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count { out.append(list[index]) }
        }
        return out
    }

    // MARK: All installs lines

    /// "Alpha 5 · Lab 2 (2h ago)", or "Lab —" for an install with no data.
    func breakdown(_ section: FeedSection) -> String? {
        guard isMultiInstall else { return nil }
        return signedInInstalls.map { install in
            guard let cached = install.cached else { return "\(install.label) —" }
            let part = "\(install.label) \(Self.count(section, in: cached.feed))"
            return install.status == .unreachable ? "\(part) (\(CountsEntry.ago(cached.fetchedAt, now: date)))" : part
        }.joined(separator: " · ")
    }

    /// "Waiting on you, 7: Alpha 5, Lab 2, last updated 2 hours ago."
    func spokenBreakdown(_ section: FeedSection) -> String? {
        guard isMultiInstall else { return nil }
        return signedInInstalls.map { install in
            guard let cached = install.cached else { return "\(install.label), no count yet" }
            let part = "\(install.label) \(Self.count(section, in: cached.feed))"
            return install.status == .unreachable ? "\(part), last updated \(CountsEntry.agoSpoken(cached.fetchedAt, now: date))" : part
        }.joined(separator: ", ")
    }

    var installCountLine: String? { isMultiInstall ? InstallLabel.count(signedInInstalls.count) : nil }

    var failures: [InstallFailure] {
        guard installs.count > 1 else { return [] }
        return installs.compactMap { install in
            switch install.status {
            case .unreachable: return InstallFailure(text: "Can't reach \(install.label)", unreachable: true)
            case .signedOut: return InstallFailure(text: "Signed out of \(install.label)", unreachable: false)
            case .ok: return nil
            }
        }
    }

    private static func count(_ section: FeedSection, in feed: WidgetFeed) -> Int {
        switch section {
        case .waiting: return feed.waiting.count
        case .blocked: return feed.blocked.count
        case .shipped: return feed.shipped.count
        }
    }

    // MARK: Links

    /// The install a tap on a widget with no row opens.
    var primaryHost: String? { signedInInstalls.first { $0.status == .ok }?.host ?? signedInInstalls.first?.host ?? installs.first?.host }

    /// Just the app: signed out, or no install saved.
    static let appURL = URL(string: "\(DeepLink.scheme)://\(DeepLink.action)")!

    func link(path: String) -> URL {
        guard signedIn, let host = primaryHost else { return Self.appURL }
        return DeepLink(host: host, path: path).url
    }

    /// "4m", "2h", "3d"; "now" under a minute.
    static func shortAgo(_ then: Date?, now: Date) -> String {
        guard let then else { return "" }
        let minutes = Int(now.timeIntervalSince(then) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / (24 * 60))d"
    }

    // MARK: Building

    static func merged(
        date: Date, results: [(install: Install, result: InstallResult<CachedWidgetFeed>)], saved: [Install], scope: WidgetScope
    ) -> FeedEntry {
        let parts = results.map { (install, result) -> FeedInstall in
            let label = InstallLabel.name(for: install.host, installs: saved)
            switch result {
            case .ok(let cached): return FeedInstall(host: install.host, label: label, status: .ok, cached: cached)
            case .unreachable(let known, _): return FeedInstall(host: install.host, label: label, status: .unreachable, cached: known)
            case .signedOut: return FeedInstall(host: install.host, label: label, status: .signedOut, cached: nil)
            }
        }
        let pinned = scope.resolved(saved: saved).pinnedHost.flatMap { host in
            saved.count > 1 ? "\(InstallLabel.name(for: host, installs: saved)) only" : nil
        }
        return FeedEntry(date: date, installs: parts, pinnedLabel: pinned)
    }

    func at(_ date: Date) -> FeedEntry { FeedEntry(date: date, installs: installs, pinnedLabel: pinnedLabel) }

    /// The entry now, plus one just past the stale boundary of its newest
    /// data, so a widget whose refresh never comes switches to "Updated …".
    static func timeline(from entry: FeedEntry, now: Date) -> Timeline<FeedEntry> {
        var entries = [entry]
        if let newest = entry.newestFetch {
            let staleAt = newest.addingTimeInterval(SlabState.staleAfter + 1)
            if staleAt > now { entries.append(entry.at(staleAt)) }
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(CountsEntry.refreshInterval)))
    }

    static let preview = FeedEntry(
        date: Date(),
        installs: [
            FeedInstall(
                host: "yourteam.example.com", label: "Burrow", status: .ok,
                cached: CachedWidgetFeed(
                    feed: WidgetFeed(
                        asOf: nil,
                        waiting: .init(
                            count: 2,
                            rows: [
                                .init(itemID: "p1", spacePathSegment: "p1", asker: "Build agent", summary: "Needs a yes on the release note", at: nil)
                            ]),
                        blocked: .init(count: 1, rows: [.init(id: "p2", title: "Widget feed", reason: "Waiting on a device test")]),
                        recent: .init(rows: [
                            .init(spaceID: "s1", pathSegment: "agents", kind: "channel", name: "Agents", counterpart: nil, unread: true)
                        ]),
                        shipped: .init(count: 3, newestTitle: "Calendar landscape fix")),
                    fetchedAt: Date()))
        ])
}
