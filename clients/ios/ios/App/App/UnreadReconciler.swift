import Foundation
import UserNotifications
import WidgetKit

/// Reconcile on open (task 01a1261e stage 4): every signed-in install's
/// `GET /api/app/counts`, each with its OWN bearer, at most four at a time
/// (`WidgetCountsRefresher`'s client and request shape). `unread` + `as_of`
/// go into `InstallUnreadStore` (newer wins). A host that fails keeps its
/// last count and is marked stale. Then the icon badge becomes the sum, and
/// listeners hear `.burrowInstallBadgesChanged`.
enum UnreadReconciler {
    typealias Fetch = (String, @escaping (Result<SuiteCounts, Error>) -> Void) -> Void

    static let maxConcurrent = 4

    static func refreshAll() {
        let client = SuiteAPIClient.shared
        let hosts = InstallStore.shared.installs.map(\.host).filter { client.isSignedIn(host: $0) }
        reconcile(
            hosts: hosts, store: .shared,
            fetch: { client.counts(host: $0, completion: $1) },
            completion: { total in UNUserNotificationCenter.current().setBadgeCount(total) })
    }

    /// The testable core. `answered(host, counts)` runs on the main queue for
    /// each host that answered; `completion(total)` runs after every host
    /// answered or failed; `.burrowInstallBadgesChanged` is posted right
    /// after it.
    static func reconcile(
        hosts: [String], store: InstallUnreadStore, maxConcurrent: Int = maxConcurrent, fetch: @escaping Fetch,
        answered: @escaping (String, SuiteCounts) -> Void = { _, _ in }, completion: @escaping (Int) -> Void = { _ in }
    ) {
        let group = DispatchGroup()
        let slots = DispatchSemaphore(value: max(1, maxConcurrent))
        let queue = DispatchQueue(label: "burrow.unread-reconcile", attributes: .concurrent)
        let results = ResultBox()

        for host in hosts {
            group.enter()
            queue.async {
                slots.wait()
                fetch(host) { result in
                    results.set(host, result)
                    slots.signal()
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            for host in hosts {
                switch results.get(host) {
                case .success(let counts):
                    answered(host, counts)
                    if let unread = counts.unread, let asOf = counts.asOf {
                        store.write(count: unread, asOf: asOf, for: host, clearStale: true)
                    }
                case .failure, .none:
                    store.markStale(host)
                }
            }
            completion(store.total)
            NotificationCenter.default.post(name: .burrowInstallBadgesChanged, object: nil)
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Result<SuiteCounts, Error>] = [:]

        func set(_ host: String, _ result: Result<SuiteCounts, Error>) {
            lock.lock()
            values[host] = result
            lock.unlock()
        }

        func get(_ host: String) -> Result<SuiteCounts, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return values[host]
        }
    }
}

/// What every app open refreshes (task 01a1261e, review round 2): each
/// signed-in install's `GET /api/app/counts`, ONCE. The one answer feeds both
/// consumers: the per-install unread (`UnreadReconciler`) and, for the
/// selected install, the widgets' `CountsCache` (what
/// `WidgetCountsRefresher` would have written), then every widget timeline
/// reloads. Before this, `sceneDidBecomeActive` ran both and the selected
/// install got two counts requests per open. Android's `ResumeRefresh`.
enum OpenRefresh {
    static func run() {
        let client = SuiteAPIClient.shared
        let hosts = InstallStore.shared.installs.map(\.host).filter { client.isSignedIn(host: $0) }
        run(
            hosts: hosts, selectedHost: InstallStore.shared.selectedHost, client: client, store: .shared,
            cache: CountsCache(), reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() },
            completion: { total in UNUserNotificationCenter.current().setBadgeCount(total) })
    }

    /// The testable core: `client` is the only thing that touches the network.
    static func run(
        hosts: [String], selectedHost: String?, client: SuiteAPIClient, store: InstallUnreadStore, cache: CountsCache,
        reloadWidgets: @escaping () -> Void, completion: @escaping (Int) -> Void = { _ in }
    ) {
        UnreadReconciler.reconcile(
            hosts: hosts, store: store,
            fetch: { client.counts(host: $0, completion: $1) },
            answered: { host, counts in
                if host == selectedHost { cache.write(counts, for: host) }
            },
            completion: { total in
                reloadWidgets()
                completion(total)
            })
    }
}
