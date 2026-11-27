import AppIntents
import Foundation
import WidgetKit

/// Which installs a My approvals widget shows (task 01a21e75 stage 3).
///
/// `install` is the v1 parameter, kept so a widget placed before this
/// change decodes unchanged: a legacy `install` that is still saved keeps
/// the widget PINNED to it. `scope` is new, defaulting to All installs. An
/// explicit one-install `scope` wins over `install`. Each install is
/// fetched and acted on with its own bearer only.
struct ApprovalsWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "My approvals"
    static var description = IntentDescription("Choose the Burrow installs this widget shows.")

    /// v1: the one install a widget was pinned to.
    @Parameter(title: "Install")
    var install: InstallEntity?

    @Parameter(title: "Installs")
    var scope: InstallScopeEntity?

    init() {}

    init(install: InstallEntity?, scope: InstallScopeEntity? = nil) {
        self.install = install
        self.scope = scope
    }

    /// Pinned by an explicit one-install scope, else by a legacy `install`
    /// that is still saved, else All installs. A pinned install that was
    /// removed falls back to All installs.
    func widgetScope(saved: [Install]) -> WidgetScope {
        WidgetScope.approvals(legacyInstall: install?.id, scope: scope?.scope, saved: saved)
    }
}

/// `GET /api/app/approvals` for every install the widget covers, through
/// `InstallFanout`, cached per host in the App Group like CountsCache.
/// Emits extra entries at every moment the picture changes by itself (the
/// confirm strip reverting 8 s after arming, a settled row leaving, the
/// list going stale). Sends the approves Confirm left pending without
/// waiting for them, so Approving is drawn while the request is in flight
/// (WidgetPendingApprovals.swift). Every row keeps its host, so Approve and
/// Confirm act on the row's own install.
struct ApprovalsProvider: AppIntentTimelineProvider {
    var installs = InstallStore.shared
    var client = BurrowAPIClient.shared
    var cache = ApprovalsCache()
    var store = WidgetApprovalStore()
    var sender = WidgetApprovalSender()

    func placeholder(in context: Context) -> ApprovalsEntry { .preview }

    func snapshot(for configuration: ApprovalsWidgetIntent, in context: Context) async -> ApprovalsEntry {
        if context.isPreview { return .preview }
        let scope = configuration.widgetScope(saved: installs.installs)
        return entries(scope: scope, unreachable: [], now: Date()).first ?? .preview
    }

    func timeline(for configuration: ApprovalsWidgetIntent, in context: Context) async -> Timeline<ApprovalsEntry> {
        let saved = installs.installs
        let scope = configuration.widgetScope(saved: saved)
        let covered = scope.installs(from: saved)
        for install in covered where client.isSignedIn(host: install.host) {
            // Claimed here, once across every run and process; the result
            // asks for the next redraw.
            sender.startSending(host: install.host)
        }
        let client = client
        let results = await InstallFanout.fetch(
            installs: covered, client: client, fetch: { host in try await client.approvals(host: host) })
        var unreachable: Set<String> = []
        for (install, result) in results {
            let host = install.host
            switch result {
            case .ok(let fetched):
                IntentLog.count("widget_approvals", host: host, count: fetched.count)
                let now = Date()
                let merged = ApprovalsCache.merge(
                    fetched: fetched, previous: cache.approvals(for: host)?.approvals ?? [], host: host, marks: store.marks(), now: now)
                cache.write(CachedApprovals(approvals: merged, fetchedAt: now), for: host)
            case .unreachable:
                unreachable.insert(host)
                IntentLog.route("widget_approvals", host: host, status: 0)
            case .signedOut:
                break
            }
        }
        let now = Date()
        return Timeline(
            entries: entries(scope: scope, unreachable: unreachable, now: now), policy: .after(now.addingTimeInterval(CountsEntry.refreshInterval)))
    }

    private func entries(scope: WidgetScope, unreachable: Set<String>, now: Date) -> [ApprovalsEntry] {
        let saved = installs.installs
        let sources = scope.installs(from: saved).map { install in
            ApprovalsSource(
                host: install.host, label: InstallLabel.name(for: install.host, installs: saved), signedIn: client.isSignedIn(host: install.host),
                unreachable: unreachable.contains(install.host), cached: cache.approvals(for: install.host))
        }
        guard !sources.isEmpty else {
            return [ApprovalsEntry(date: now, host: nil, installName: nil, signedIn: false, fetchedAt: nil, rows: [])]
        }
        let pinned = scope.pinnedHost.flatMap { host in saved.count > 1 ? "\(InstallLabel.name(for: host, installs: saved)) only" : nil }
        return ApprovalsTimeline.mergedEntries(now: now, sources: sources, installName: pinned, arm: store.armed(now: now), marks: store.marks())
    }
}
