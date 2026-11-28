import Foundation
import WidgetKit

/// One install's part of a counts widget (task 01a21e75 stage 3).
struct InstallCounts: Equatable {
    enum Status: Equatable {
        case ok
        /// The refresh failed; `counts` is the last-known answer, if any.
        case unreachable
        case signedOut
    }

    let host: String
    /// `InstallLabel.name(for:installs:)`: a display name, never the host.
    let label: String
    let status: Status
    let counts: BurrowCounts?
}

/// One rendered moment of the counts widgets: the installs it covers,
/// whether any has a bearer, and the counts summed across them.
///
/// `host` is the install a tap opens when the widget has no rows (the first
/// install with something to show), `counts` the sum. With one install
/// (`installs` empty or a single entry) everything reads as before.
struct CountsEntry: TimelineEntry {
    let date: Date
    let host: String?
    let signedIn: Bool
    let counts: BurrowCounts?
    /// Per install, in saved order. Empty for a single-install entry.
    var installs: [InstallCounts] = []
    /// "<install> only" for a widget pinned to one of several installs.
    var pinnedLabel: String? = nil
    /// Which step failed when there is nothing to show (`WidgetDiagnosis`).
    var diagnosis: String? = nil

    func state(_ kind: SlabKind) -> SlabState {
        guard signedIn else { return .signedOut }
        // Signed in with nothing ever fetched: nothing to be live about.
        guard let counts else { return .stale }
        return slabState(count: counts.count(kind), fetchedAt: counts.fetchedAt, now: date, signedIn: signedIn)
    }

    func count(_ kind: SlabKind) -> Int? { counts?.count(kind) }

    func caption(_ kind: SlabKind) -> String {
        let base = kind.caption(for: state(kind), fetchedAt: counts?.fetchedAt)
        // "Not loaded yet · HTTP 500" / "Sign in to see tasks · no token".
        guard let diagnosis, counts == nil || !signedIn else { return base }
        return "\(base) · \(diagnosis)"
    }

    /// The deep link the slab opens; with no install selected, just the app.
    /// With several installs, the first one holding something of `kind`.
    func link(_ kind: SlabKind) -> URL {
        let target = installs.first { $0.status == .ok && ($0.counts?.count(kind) ?? 0) > 0 }?.host ?? host
        guard let target else { return URL(string: "\(DeepLink.scheme)://\(DeepLink.action)")! }
        return DeepLink(host: target, path: kind.path).url
    }

    /// A deep link into one install of this entry.
    func link(_ kind: SlabKind, host: String) -> URL { DeepLink(host: host, path: kind.path).url }

    // MARK: All installs

    /// Installs holding a bearer.
    var signedInInstalls: [InstallCounts] { installs.filter { $0.status != .signedOut } }

    /// Labels, the breakdown and "2 installs" show only with a choice.
    var isMultiInstall: Bool { signedInInstalls.count > 1 }

    /// "Alpha 5 · Lab 2 (2h ago)": each signed-in install's count, a failed
    /// one's last-known count marked stale, "Home —" with none.
    func breakdown(_ kind: SlabKind) -> String? {
        guard isMultiInstall else { return nil }
        return signedInInstalls.map { install in
            guard let counts = install.counts else { return "\(install.label) —" }
            let part = "\(install.label) \(counts.count(kind))"
            return install.status == .unreachable ? "\(part) (\(Self.ago(counts.fetchedAt, now: date)))" : part
        }.joined(separator: " · ")
    }

    /// "2 installs", under a summed count on the small sizes.
    var installCountLine: String? { isMultiInstall ? InstallLabel.count(signedInInstalls.count) : nil }

    /// One line per install that failed or is signed out, worst first.
    /// Shown only when the widget covers more than one install.
    var failures: [InstallFailure] {
        guard installs.count > 1 else { return [] }
        return installs.compactMap { install in
            switch install.status {
            case .unreachable: return InstallFailure(text: "Can't reach \(install.label)", unreachable: true)
            case .signedOut: return InstallFailure(text: "Signed out of \(install.label)", unreachable: false)
            case .ok: return nil
            }
        }
    }

    /// VoiceOver for the total: "7: Alpha 5, Lab 2, last updated 2 hours ago".
    func spokenBreakdown(_ kind: SlabKind) -> String? {
        guard isMultiInstall else { return nil }
        return signedInInstalls.map { install in
            guard let counts = install.counts else { return "\(install.label), no count yet" }
            let part = "\(install.label) \(counts.count(kind))"
            return install.status == .unreachable ? "\(part), last updated \(Self.agoSpoken(counts.fetchedAt, now: date))" : part
        }.joined(separator: ", ")
    }

    /// "4m ago", "2h ago", "3d ago".
    static func ago(_ then: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(then) / 60))
        if minutes < 60 { return "\(minutes)m ago" }
        if minutes < 24 * 60 { return "\(minutes / 60)h ago" }
        return "\(minutes / (24 * 60))d ago"
    }

    static func agoSpoken(_ then: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(then) / 60))
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s") ago" }
        if minutes < 60 { return unit(minutes, "minute") }
        if minutes < 24 * 60 { return unit(minutes / 60, "hour") }
        return unit(minutes / (24 * 60), "day")
    }

    /// Builds the entry from a fan-out: totals summed (a failed install's
    /// last-known count stays in), per-install parts, the pinned marker.
    static func merged(
        date: Date, results: [(install: Install, result: InstallResult<BurrowCounts>)], saved: [Install], scope: WidgetScope
    ) -> CountsEntry {
        let parts = results.map { (install, result) -> InstallCounts in
            let label = InstallLabel.name(for: install.host, installs: saved)
            switch result {
            case .ok(let counts): return InstallCounts(host: install.host, label: label, status: .ok, counts: counts)
            case .unreachable(let known, _): return InstallCounts(host: install.host, label: label, status: .unreachable, counts: known)
            case .signedOut: return InstallCounts(host: install.host, label: label, status: .signedOut, counts: nil)
            }
        }
        let signedIn = parts.filter { $0.status != .signedOut }
        let known = signedIn.compactMap(\.counts)
        let fresh = signedIn.filter { $0.status == .ok }.compactMap(\.counts)
        let total: BurrowCounts? =
            known.isEmpty
            ? nil
            : BurrowCounts(
                approvals: known.map(\.approvals).reduce(0, +), tasks: known.map(\.tasks).reduce(0, +),
                // Live while any install answered; stale only when none did.
                fetchedAt: (fresh.isEmpty ? known : fresh).map(\.fetchedAt).max()!)
        let primary = signedIn.first { $0.status == .ok }?.host ?? signedIn.first?.host ?? parts.first?.host
        let pinned = scope.resolved(saved: saved).pinnedHost.flatMap { host in
            saved.count > 1 ? "\(InstallLabel.name(for: host, installs: saved)) only" : nil
        }
        return CountsEntry(
            date: date, host: primary, signedIn: !signedIn.isEmpty, counts: total, installs: parts.count > 1 ? parts : [],
            pinnedLabel: pinned)
    }

    func at(_ date: Date) -> CountsEntry {
        CountsEntry(date: date, host: host, signedIn: signedIn, counts: counts, installs: installs, pinnedLabel: pinnedLabel, diagnosis: diagnosis)
    }

    static let preview = CountsEntry(
        date: Date(), host: "yourteam.example.com", signedIn: true,
        counts: BurrowCounts(approvals: 3, tasks: 12, fetchedAt: Date()))

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
                entries.append(entry.at(staleAt))
            }
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(refreshInterval)))
    }
}

/// "Can't reach Home" (with a cloud-slash glyph) or "Signed out of Lab".
struct InstallFailure: Equatable {
    let text: String
    let unreachable: Bool

    /// Two failures share one line, the second dropped whole when it does
    /// not fit (the view tries both, then the first).
    static func line(_ failures: [InstallFailure]) -> [String] {
        let texts = failures.prefix(2).map(\.text)
        return texts.count == 2 ? [texts.joined(separator: " · "), texts[0]] : texts
    }
}
