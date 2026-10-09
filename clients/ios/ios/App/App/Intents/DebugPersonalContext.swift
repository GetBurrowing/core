#if DEBUG
    import CoreSpotlight
    import Foundation
    import os

    /// DEBUG-only `burrow://debug/personal-context?host=<host>` (task 01a111bb
    /// stage 4): writes the donation ledger's count per host and the Spotlight
    /// hit count for the probe title on `host` to the app log. Counts only:
    /// no ids, names or text. Optional flags for the review rig:
    ///
    ///   * `seed=1` indexes the probe task under `host` first;
    ///   * `forget=1` runs the sign-out cleanup for `host` first.
    ///
    /// Compiled out of Release.
    enum DebugPersonalContext {
        static let probeTitle = "Burrow personal-context probe"
        static let probeUUID = "7e570000-0000-4000-8000-000000000001"
        private static let log = Logger(subsystem: "com.kobo-ai.burrow", category: "personal-context")

        /// True when `url` is the personal-context link (handled here).
        @discardableResult
        static func handle(url: URL) -> Bool {
            guard url.scheme?.lowercased() == DeepLink.scheme, url.host?.lowercased() == "debug", url.path == "/personal-context",
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                let host = items.first(where: { $0.name == "host" })?.value.flatMap(InstallStore.normalizeHost)
            else { return false }
            let flag = { (name: String) in items.contains { $0.name == name && $0.value == "1" } }
            Task {
                if flag("forget") { await IntentAppHooks.forget(host: host).value }
                if flag("seed"), #available(iOS 18, *) { await seed(host: host) }
                await report(host: host)
            }
            return true
        }

        @available(iOS 18, *)
        private static func seed(host: String) async {
            let probe = TaskEntity(id: EntityRef(host: host, uuid: probeUUID).id, title: probeTitle, subtitle: "Task")
            try? await CSSearchableIndex.default().indexSearchableItems(SpotlightIndexer.items([probe], host: host))
        }

        private static func report(host: String) async {
            for (ledgerHost, ids) in DonationLedger().all.sorted(by: { $0.key < $1.key }) {
                log.info("personal-context ledger host=\(ledgerHost, privacy: .public) donations=\(ids.count, privacy: .public)")
            }
            let hits = await spotlightHits(host: host)
            log.info("personal-context spotlight host=\(host, privacy: .public) probe_hits=\(hits, privacy: .public)")
        }

        /// Items titled with the probe title in `host`'s domain.
        private static func spotlightHits(host: String) async -> Int {
            await withCheckedContinuation { continuation in
                let context = CSSearchQueryContext()
                context.fetchAttributes = ["domainIdentifier"]
                let query = CSSearchQuery(queryString: "title == \"\(probeTitle)\"", queryContext: context)
                var count = 0
                query.foundItemsHandler = { items in count += items.filter { $0.domainIdentifier == host }.count }
                query.completionHandler = { _ in continuation.resume(returning: count) }
                query.start()
            }
        }
    }
#endif
