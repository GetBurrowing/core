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
        let diagnosis = WidgetDiagnosisStore()
        let covered = scope.installs(from: saved)
        let results = await InstallFanout.fetch(
            installs: covered, client: client,
            lastKnown: { host in cache.counts(for: host).map { ($0, $0.fetchedAt) } },
            fetch: { host in
                do {
                    let counts = try await client.fetchCounts(host: host)
                    diagnosis.record(nil, for: Self.key(host))
                    return counts
                } catch {
                    diagnosis.record(WidgetDiagnosis.code(for: error), for: Self.key(host))
                    throw error
                }
            })
        for case (let install, .ok(let counts)) in results {
            cache.write(counts, for: install.host)
        }
        var entry = CountsEntry.merged(date: Date(), results: results, saved: saved, scope: scope)
        entry.diagnosis = Self.diagnosis(saved: saved, covered: covered, client: client)
        return entry
    }

    /// The entry from the cache alone, with no request (snapshots).
    func cachedEntry(scope: WidgetScope, now: Date) -> CountsEntry {
        let saved = installs.installs
        let results = scope.installs(from: saved).map { install -> (install: Install, result: InstallResult<BurrowCounts>) in
            guard client.isSignedIn(host: install.host) else { return (install, .signedOut) }
            guard let counts = cache.counts(for: install.host) else { return (install, .unreachable(lastKnown: nil, fetchedAt: nil)) }
            return (install, .ok(counts))
        }
        var entry = CountsEntry.merged(date: now, results: results, saved: saved, scope: scope)
        entry.diagnosis = Self.diagnosis(saved: saved, covered: scope.installs(from: saved), client: client)
        return entry
    }

    /// The counts fetch's failures live beside the feed's, under their own key.
    static func key(_ host: String) -> String { "counts|\(host)" }

    static func diagnosis(saved: [Install], covered: [Install], client: BurrowAPIClient) -> String? {
        let failures = WidgetDiagnosisStore().failures
        let mine = Dictionary(uniqueKeysWithValues: covered.compactMap { install in failures[key(install.host)].map { (install.host, $0) } })
        return WidgetDiagnosis.summary(saved: saved, installs: covered, signedIn: { client.isSignedIn(host: $0) }, failures: mine)
    }
}
