import Foundation
import WidgetKit

/// Fetches `GET /api/app/counts` for the install selected in the app, with
/// that install's bearer from the shared Keychain. Refreshes every 15
/// minutes; a fetch that fails falls back to the App Group's last counts,
/// which `slabState` marks stale once they pass 30 minutes.
struct CountsProvider: TimelineProvider {
    var installs = InstallStore.shared
    var cache = CountsCache()
    var client = BurrowAPIClient.shared

    func placeholder(in context: Context) -> CountsEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (CountsEntry) -> Void) {
        if context.isPreview { return completion(.preview) }
        completion(currentEntry(now: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CountsEntry>) -> Void) {
        let now = Date()
        guard let host = installs.selectedHost, client.isSignedIn(host: host) else {
            return completion(CountsEntry.timeline(from: currentEntry(now: now), now: now))
        }
        client.counts(host: host) { result in
            if case .success(let counts) = result {
                cache.write(counts, for: host)
            }
            let entry = currentEntry(now: Date())
            completion(CountsEntry.timeline(from: entry, now: entry.date))
        }
    }

    func currentEntry(now: Date) -> CountsEntry {
        let host = installs.selectedHost
        let signedIn = host.map(client.isSignedIn(host:)) ?? false
        return CountsEntry(date: now, host: host, signedIn: signedIn, counts: host.flatMap(cache.counts(for:)))
    }
}
