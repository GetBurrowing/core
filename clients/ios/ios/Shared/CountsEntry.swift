import Foundation
import WidgetKit

/// One rendered moment of the widgets: the selected install, whether it has
/// a bearer, and the last counts this device received for it.
struct CountsEntry: TimelineEntry {
    let date: Date
    let host: String?
    let signedIn: Bool
    let counts: SuiteCounts?

    func state(_ kind: SlabKind) -> SlabState {
        guard signedIn else { return .signedOut }
        // Signed in with nothing ever fetched: nothing to be live about.
        guard let counts else { return .stale }
        return slabState(count: counts.count(kind), fetchedAt: counts.fetchedAt, now: date, signedIn: signedIn)
    }

    func count(_ kind: SlabKind) -> Int? { counts?.count(kind) }

    func caption(_ kind: SlabKind) -> String {
        kind.caption(for: state(kind), fetchedAt: counts?.fetchedAt)
    }

    /// The deep link the slab opens; with no install selected, just the app.
    func link(_ kind: SlabKind) -> URL {
        guard let host else { return URL(string: "\(DeepLink.scheme)://\(DeepLink.action)")! }
        return DeepLink(host: host, path: kind.path).url
    }

    static let preview = CountsEntry(date: Date(), host: "suite.example.com", signedIn: true,
                                     counts: SuiteCounts(approvals: 3, tasks: 12, fetchedAt: Date()))

    /// The widgets ask for a new timeline this often.
    static let refreshInterval: TimeInterval = 15 * 60

    /// The entry now, plus a second entry just past the stale boundary of
    /// the counts it shows, so a widget whose refresh never comes still
    /// drops its cyan on time rather than showing an old number as live.
    static func timeline(from entry: CountsEntry, now: Date) -> Timeline<CountsEntry> {
        var entries = [entry]
        if let counts = entry.counts {
            let staleAt = counts.fetchedAt.addingTimeInterval(SlabState.staleAfter + 1)
            if staleAt > now {
                entries.append(CountsEntry(date: staleAt, host: entry.host, signedIn: entry.signedIn, counts: counts))
            }
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(refreshInterval)))
    }
}
