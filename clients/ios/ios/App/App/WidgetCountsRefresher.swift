import Foundation
import WidgetKit

/// Keeps the widgets current from the app's side: after sign-in or an
/// install switch, fetch `GET /api/app/counts` for that install, write it to
/// the App Group, and reload every timeline. NOT on foreground: there
/// `OpenRefresh` writes the cache from the reconcile's own request, so an
/// open sends one counts request per install (task 01a1261e).
/// The widgets' own 15-minute refresh covers the time the app is closed.
enum WidgetCountsRefresher {
    static func refresh(host: String? = InstallStore.shared.selectedHost,
                        client: SuiteAPIClient = .shared, cache: CountsCache = CountsCache()) {
        guard let host, client.isSignedIn(host: host) else {
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        client.counts(host: host) { result in
            if case .success(let counts) = result {
                cache.write(counts, for: host)
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
