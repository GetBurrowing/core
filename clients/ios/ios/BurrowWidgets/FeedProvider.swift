import Foundation
import WidgetKit

/// The timeline of the four feed widgets (task 01a21e75 stage 4): Waiting
/// on you, Blocked for you, Recent and Shipped today. Fetches
/// `GET /api/app/widgets` from every install the widget covers (All
/// installs by default, or the one it is pinned to) through
/// `WidgetFeedLoader`, each with that install's own bearer; a feed younger
/// than 5 minutes is reused, so four placed widgets cost one request per
/// install. Refreshes every 15 minutes, with a second entry at the stale
/// boundary.
struct FeedProvider: AppIntentTimelineProvider {
    var installs = InstallStore.shared
    var cache = WidgetFeedCache()
    var client = BurrowAPIClient.shared

    func placeholder(in context: Context) -> FeedEntry { .preview }

    func snapshot(for configuration: WidgetScopeIntent, in context: Context) async -> FeedEntry {
        if context.isPreview { return .preview }
        return cachedEntry(scope: configuration.widgetScope, now: Date())
    }

    func timeline(for configuration: WidgetScopeIntent, in context: Context) async -> Timeline<FeedEntry> {
        let scope = configuration.widgetScope
        let saved = installs.installs
        let covered = scope.installs(from: saved)
        let results = await WidgetFeedLoader.load(installs: covered, client: client, cache: cache)
        let now = Date()
        var entry = FeedEntry.merged(date: now, results: results, saved: saved, scope: scope)
        entry.diagnosis = Self.diagnosis(saved: saved, covered: covered, client: client)
        return FeedEntry.timeline(from: entry, now: now)
    }

    /// From the cache alone, with no request.
    func cachedEntry(scope: WidgetScope, now: Date) -> FeedEntry {
        let saved = installs.installs
        let results = scope.installs(from: saved).map { install -> (install: Install, result: InstallResult<CachedWidgetFeed>) in
            guard client.isSignedIn(host: install.host) else { return (install, .signedOut) }
            guard let cached = cache.feed(for: install.host) else { return (install, .unreachable(lastKnown: nil, fetchedAt: nil)) }
            return (install, .ok(cached))
        }
        var entry = FeedEntry.merged(date: now, results: results, saved: saved, scope: scope)
        entry.diagnosis = Self.diagnosis(saved: saved, covered: scope.installs(from: saved), client: client)
        return entry
    }

    static func diagnosis(saved: [Install], covered: [Install], client: BurrowAPIClient) -> String? {
        WidgetDiagnosis.summary(
            saved: saved, installs: covered, signedIn: { client.isSignedIn(host: $0) }, failures: WidgetDiagnosisStore().failures)
    }
}
