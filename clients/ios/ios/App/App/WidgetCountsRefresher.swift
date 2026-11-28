import Foundation
import WidgetKit

/// Keeps the widgets current from the app's side: after sign-in, sign-out
/// or an install switch, fetch `GET /api/app/counts` for EVERY signed-in
/// install through `InstallFanout` (each with its own bearer, at most 3 at
/// once), write each answer to its own App Group slot, and reload every
/// timeline once (task 01a21e75 stage 3: the widgets show All installs).
/// NOT on foreground: there `OpenRefresh` writes the cache from the
/// reconcile's own request, so an open sends one counts request per install
/// (task 01a1261e). The widgets' own 15-minute refresh covers the time the
/// app is closed.
enum WidgetCountsRefresher {
    static func refresh(
        installs: [Install] = InstallStore.shared.installs, client: BurrowAPIClient = .shared, cache: CountsCache = CountsCache(),
        reload: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }, completion: @escaping () -> Void = {}
    ) {
        Task {
            // The feed widgets' data too (task 01a21e75 stage 4), fresh after
            // a sign-in, sign-out or switch, before the one reload.
            async let feeds = WidgetFeedLoader.load(installs: installs, client: client, cache: WidgetFeedCache(), reuseAfter: 0)
            let results = await InstallFanout.fetch(installs: installs, client: client) { host in try await client.fetchCounts(host: host) }
            for case (let install, .ok(let counts)) in results {
                cache.write(counts, for: install.host)
            }
            _ = await feeds
            reload()
            completion()
        }
    }
}
