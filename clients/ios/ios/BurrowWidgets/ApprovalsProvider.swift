import AppIntents
import Foundation
import WidgetKit

/// Which install a My approvals widget shows. Each widget is configured to
/// ONE install and fetches and acts with that install's bearer only.
struct ApprovalsWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "My approvals"
    static var description = IntentDescription("Choose the Burrow install this widget shows.")

    /// Defaults to the install selected in the app (InstallQuery).
    @Parameter(title: "Install")
    var install: InstallEntity?

    init() {}

    init(install: InstallEntity?) { self.install = install }
}

/// `GET /api/app/approvals` for the configured install, cached in the App
/// Group like CountsCache. Emits extra entries at every moment the picture
/// changes by itself (the confirm strip reverting 8 s after arming, a
/// settled row leaving, the list going stale). Sends the approves Confirm
/// left pending without waiting for them, so Approving is drawn while the
/// request is in flight (WidgetPendingApprovals.swift).
struct ApprovalsProvider: AppIntentTimelineProvider {
    var installs = InstallStore.shared
    var client = BurrowAPIClient.shared
    var cache = ApprovalsCache()
    var store = WidgetApprovalStore()
    var sender = WidgetApprovalSender()

    func placeholder(in context: Context) -> ApprovalsEntry { .preview }

    func snapshot(for configuration: ApprovalsWidgetIntent, in context: Context) async -> ApprovalsEntry {
        if context.isPreview { return .preview }
        return entries(host: host(configuration), now: Date()).first ?? .preview
    }

    func timeline(for configuration: ApprovalsWidgetIntent, in context: Context) async -> Timeline<ApprovalsEntry> {
        let host = host(configuration)
        if let host, client.isSignedIn(host: host) {
            // Claimed here, once across every run and process; the result
            // asks for the next redraw.
            sender.startSending(host: host)
            do {
                let fetched = try await client.approvals(host: host)
                IntentLog.count("widget_approvals", host: host, count: fetched.count)
                let now = Date()
                let merged = ApprovalsCache.merge(
                    fetched: fetched, previous: cache.approvals(for: host)?.approvals ?? [], host: host, marks: store.marks(), now: now)
                cache.write(CachedApprovals(approvals: merged, fetchedAt: now), for: host)
            } catch {
                IntentLog.route("widget_approvals", host: host, status: EntityCatalog.status(of: error))
            }
        }
        let now = Date()
        return Timeline(entries: entries(host: host, now: now), policy: .after(now.addingTimeInterval(CountsEntry.refreshInterval)))
    }

    /// The configured install if it is still saved, else the selected one.
    private func host(_ configuration: ApprovalsWidgetIntent) -> String? {
        if let host = configuration.install?.id, installs.installs.contains(where: { $0.host == host }) { return host }
        return installs.selectedHost
    }

    private func entries(host: String?, now: Date) -> [ApprovalsEntry] {
        let signedIn = host.map(client.isSignedIn(host:)) ?? false
        let installName = host.flatMap { host in installs.installs.count > 1 ? installs.installs.first { $0.host == host }?.displayName : nil }
        return ApprovalsTimeline.entries(
            now: now, host: host, installName: installName, signedIn: signedIn, cached: host.flatMap(cache.approvals(for:)),
            arm: store.armed(now: now), marks: store.marks())
    }
}
