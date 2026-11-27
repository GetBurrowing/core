import Foundation
import WidgetKit

/// Fetches `GET /api/app/counts` from every install the widget covers (task
/// 01a21e75 stage 3: All installs by default, or the one it is pinned to),
/// each with that install's own bearer from the shared Keychain, through
/// `InstallFanout`. Refreshes every 15 minutes; an install whose fetch
/// fails keeps its last counts from the App Group (`CountsCache`), marked
/// stale in the breakdown, so the total never quietly drops.
struct CountsProvider: AppIntentTimelineProvider {
    var installs = InstallStore.shared
    var cache = CountsCache()
    var client = BurrowAPIClient.shared

    func placeholder(in context: Context) -> CountsEntry { .preview }

    func snapshot(for configuration: WidgetScopeIntent, in context: Context) async -> CountsEntry {
        if context.isPreview { return .preview }
        return cachedEntry(scope: configuration.widgetScope, now: Date())
    }

    func timeline(for configuration: WidgetScopeIntent, in context: Context) async -> Timeline<CountsEntry> {
        let entry = await refreshedEntry(scope: configuration.widgetScope)
        return CountsEntry.timeline(from: entry, now: entry.date)
    }

    /// Fetches every covered install, writes each fresh answer to its own
    /// cache slot, and builds the merged entry.
    func refreshedEntry(scope: WidgetScope) async -> CountsEntry {
        let saved = installs.installs
        let client = client
        let cache = cache
        let results = await InstallFanout.fetch(
            installs: scope.installs(from: saved), client: client,
            lastKnown: { host in cache.counts(for: host).map { ($0, $0.fetchedAt) } },
            fetch: { host in try await client.fetchCounts(host: host) })
        for case (let install, .ok(let counts)) in results {
            cache.write(counts, for: install.host)
        }
        return CountsEntry.merged(date: Date(), results: results, saved: saved, scope: scope)
    }

    /// The entry from the cache alone, with no request (snapshots).
    func cachedEntry(scope: WidgetScope, now: Date) -> CountsEntry {
        let saved = installs.installs
        let results = scope.installs(from: saved).map { install -> (install: Install, result: InstallResult<BurrowCounts>) in
            guard client.isSignedIn(host: install.host) else { return (install, .signedOut) }
            guard let counts = cache.counts(for: install.host) else { return (install, .unreachable(lastKnown: nil, fetchedAt: nil)) }
            return (install, .ok(counts))
        }
        return CountsEntry.merged(date: now, results: results, saved: saved, scope: scope)
    }
}
