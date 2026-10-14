import Foundation
import WidgetKit

// The interactive My approvals widget's state (task 01a10db6 stage 4,
// canvas 01a10db8 "States"). Pure and in the shared Intents sources, so the
// app's unit tests drive the same code the widget runs.

enum WidgetKinds {
    /// Unchanged from v1, so a placed widget survives the update.
    static let approvals = "com.kobo-ai.burrow.widgets.approvals"
}

/// What an intent wrote about one row, keyed by its `<host>|<id>`.
enum WidgetRowState: Codable, Equatable {
    case approving
    case approved
    case failed
    case alreadyHandled(by: String?)
}

struct WidgetRowMark: Codable, Equatable {
    let state: WidgetRowState
    let at: Date

    /// How long the mark shapes the row. After it, the row is gone
    /// (approved, already handled), live again (failed), or, for an approve
    /// that never got a result, Couldn't approve for `failedHold`.
    var hold: TimeInterval {
        switch state {
        case .approving: return WidgetApprovalStore.approvingHold
        case .approved, .alreadyHandled: return WidgetApprovalStore.settledHold
        case .failed: return WidgetApprovalStore.failedHold
        }
    }

    var isSettled: Bool {
        switch state {
        case .approved, .alreadyHandled: return true
        case .approving, .failed: return false
        }
    }

    func isActive(at date: Date) -> Bool {
        date >= at && date.timeIntervalSince(at) < hold
    }
}

/// The confirm strip's arm: one row, armed at one instant.
struct WidgetArm: Codable, Equatable {
    let id: String
    let at: Date

    func isValid(at date: Date) -> Bool {
        let age = date.timeIntervalSince(at)
        return age >= 0 && age < WidgetApprovalStore.armWindow
    }
}

/// The App Group state behind the confirm strip and the row states. Holds
/// ids and timestamps only: never a token, a title or a note.
struct WidgetApprovalStore {
    /// Confirm acts only on an arm younger than this (canvas: the strip
    /// reverts after 8 s).
    static let armWindow: TimeInterval = 8
    /// Approved and Already handled stay on the row for one refresh.
    static let settledHold: TimeInterval = 10
    /// An approve with no result by then shows Couldn't approve, and its
    /// pending record is dropped unsent (PendingApprove.maxAge).
    static let approvingHold: TimeInterval = PendingApprove.maxAge
    /// Couldn't approve stays until the widget's next regular refresh.
    static let failedHold: TimeInterval = 15 * 60

    private static let armKey = "suite.widget.arm.v1"
    private static let marksKey = "suite.widget.rows.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: InstallStore.appGroup)) {
        self.defaults = defaults ?? .standard
    }

    func arm(_ id: String, now: Date) {
        write(WidgetArm(id: id, at: now), key: Self.armKey)
    }

    /// The arm, if one is still inside its window.
    func armed(now: Date) -> WidgetArm? {
        guard let arm: WidgetArm = read(Self.armKey), arm.isValid(at: now) else { return nil }
        return arm
    }

    func disarm() {
        defaults.removeObject(forKey: Self.armKey)
    }

    /// True, and the arm is used up, only for an arm of exactly `id` that is
    /// under `armWindow` old. Anything else leaves no trace and returns false.
    /// The Approving mark is written BEFORE the arm is removed, so a reader
    /// between the two writes sees Approving (a mark wins over an arm),
    /// never Live.
    func takeArmMarkingApproving(for id: String, now: Date) -> Bool {
        guard let arm: WidgetArm = read(Self.armKey), arm.id == id, arm.isValid(at: now) else { return false }
        mark(id, .approving, now: now)
        disarm()
        return true
    }

    func marks() -> [String: WidgetRowMark] {
        read(Self.marksKey) ?? [:]
    }

    func mark(_ id: String, _ state: WidgetRowState, now: Date) {
        var all = marks().filter { $0.value.isActive(at: now) }
        all[id] = WidgetRowMark(state: state, at: now)
        write(all, key: Self.marksKey)
    }

    private func read<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func write<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

/// The last approvals list per install host, in the App Group, so a failed
/// refresh can show the last good rows (as stale after 30 minutes).
struct CachedApprovals: Codable, Equatable {
    var approvals: [SuiteApproval]
    var fetchedAt: Date
}

struct ApprovalsCache {
    private static let keyPrefix = "suite.approvals.v1."
    let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: InstallStore.appGroup)) {
        self.defaults = defaults ?? .standard
    }

    func approvals(for host: String) -> CachedApprovals? {
        defaults.data(forKey: Self.keyPrefix + host).flatMap { try? JSONDecoder().decode(CachedApprovals.self, from: $0) }
    }

    func write(_ value: CachedApprovals, for host: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.keyPrefix + host) }
    }

    func remove(for host: String) {
        defaults.removeObject(forKey: Self.keyPrefix + host)
    }

    /// The new list, keeping any row the server no longer returns while it
    /// still shows Approving, Approved or Already handled: the row leaves on
    /// the next refresh, not the instant the widget reloads after Confirm, and
    /// never before the server has answered the approve. A kept row
    /// stays where it was: right after the row that preceded it before (or
    /// first, if nothing did), never moved to the end.
    static func merge(fetched: [SuiteApproval], previous: [SuiteApproval], host: String, marks: [String: WidgetRowMark], now: Date) -> [SuiteApproval] {
        let fetchedIDs = Set(fetched.map(\.id))
        var merged = fetched
        var lastPlaced: String?
        for approval in previous {
            if fetchedIDs.contains(approval.id) {
                lastPlaced = approval.id
                continue
            }
            guard let mark = marks[EntityRef(host: host, uuid: approval.id).id], mark.isSettled || mark.state == .approving, mark.isActive(at: now)
            else { continue }
            let at = lastPlaced.flatMap { placed in merged.firstIndex { $0.id == placed } }.map { $0 + 1 } ?? 0
            merged.insert(approval, at: at)
            lastPlaced = approval.id
        }
        return merged
    }
}

/// One rendered moment of the approvals widget.
struct ApprovalsEntry: TimelineEntry {
    enum Display: Equatable {
        case live
        case confirming
        case approving
        case approved
        case failed
        case alreadyHandled(by: String?)
        /// The list is older than 30 minutes: no buttons (a stale row
        /// cannot be acted on).
        case stale
    }

    struct Row: Equatable, Identifiable {
        /// `<host>|<id>`, what the intents carry.
        let id: String
        let approval: SuiteApproval
        let display: Display
    }

    let date: Date
    let host: String?
    /// The install name, only when more than one install is saved.
    let installName: String?
    let signedIn: Bool
    let fetchedAt: Date?
    let rows: [Row]

    var count: Int { rows.count }

    var slab: SlabState {
        guard signedIn else { return .signedOut }
        guard let fetchedAt else { return .stale }
        return slabState(count: count, fetchedAt: fetchedAt, now: date, signedIn: signedIn)
    }

    /// The v1 count entry, so small and lock-screen families render exactly
    /// as before.
    var countsEntry: CountsEntry {
        CountsEntry(date: date, host: host, signedIn: signedIn, counts: fetchedAt.map { SuiteCounts(approvals: count, tasks: 0, fetchedAt: $0) })
    }

    /// The approvals list (`/inbox`), or just the app with no install.
    var inboxURL: URL {
        countsEntry.link(.approvals)
    }

    /// A row's task page; the inbox when the approval names no task.
    func taskURL(_ row: Row) -> URL {
        guard let host else { return inboxURL }
        return row.approval.taskID.flatMap { DeepLink.task(host: host, id: $0) }?.url ?? inboxURL
    }

    static let preview = ApprovalsEntry(
        date: Date(), host: "yourteam.example.com", installName: nil, signedIn: true, fetchedAt: Date(),
        rows: [
            Row(
                id: "yourteam.example.com|preview-1",
                approval: SuiteApproval(
                    id: "preview-1", kind: "plan", title: "Burrow iOS intents plan", spaceName: "Burrow iOS", spacePathSegment: nil, taskID: nil,
                    insertedAt: nil, summary: nil),
                display: .live)
        ])
}

/// Builds the widget's entries from the cache and the App Group marks.
enum ApprovalsTimeline {
    static func entry(
        at date: Date, host: String?, installName: String?, signedIn: Bool, cached: CachedApprovals?, arm: WidgetArm?,
        marks: [String: WidgetRowMark]
    ) -> ApprovalsEntry {
        guard signedIn, let host, let cached else {
            return ApprovalsEntry(date: date, host: host, installName: installName, signedIn: signedIn, fetchedAt: cached?.fetchedAt, rows: [])
        }
        let stale = date.timeIntervalSince(cached.fetchedAt) > SlabState.staleAfter
        let rows = cached.approvals.compactMap { approval -> ApprovalsEntry.Row? in
            let id = EntityRef(host: host, uuid: approval.id).id
            let display: ApprovalsEntry.Display
            if let mark = marks[id], mark.isActive(at: date) {
                switch mark.state {
                case .approving: display = .approving
                case .approved: display = .approved
                case .failed: display = .failed
                case .alreadyHandled(let by): display = .alreadyHandled(by: by)
                }
            } else if let mark = marks[id], mark.isSettled, date >= mark.at {
                // Settled and past its hold: the row has left.
                return nil
            } else if let mark = marks[id], mark.state == .approving, date >= mark.at,
                date.timeIntervalSince(mark.at) < mark.hold + WidgetApprovalStore.failedHold
            {
                // No result inside the window: Couldn't approve, never a
                // silent send later.
                display = .failed
            } else if stale {
                display = .stale
            } else if let arm, arm.id == id, arm.isValid(at: date) {
                display = .confirming
            } else {
                display = .live
            }
            return ApprovalsEntry.Row(id: id, approval: approval, display: display)
        }
        return ApprovalsEntry(date: date, host: host, installName: installName, signedIn: signedIn, fetchedAt: cached.fetchedAt, rows: rows)
    }

    /// The entry now, plus one at every instant the picture changes on its
    /// own: the strip reverting (arm + 8 s), a settled row leaving, a
    /// failure clearing, and the list going stale.
    static func entries(
        now: Date, host: String?, installName: String?, signedIn: Bool, cached: CachedApprovals?, arm: WidgetArm?,
        marks: [String: WidgetRowMark]
    ) -> [ApprovalsEntry] {
        var dates: Set<Date> = [now]
        if let arm { dates.insert(arm.at.addingTimeInterval(WidgetApprovalStore.armWindow)) }
        for mark in marks.values { dates.insert(mark.at.addingTimeInterval(mark.hold)) }
        if let cached { dates.insert(cached.fetchedAt.addingTimeInterval(SlabState.staleAfter + 1)) }
        return dates.filter { $0 >= now }.sorted().map {
            entry(at: $0, host: host, installName: installName, signedIn: signedIn, cached: cached, arm: arm, marks: marks)
        }
    }
}

/// What the Control Center controls show (canvas "Controls"). No tint:
/// symbol, label and value line only.
struct ControlCopy: Equatable {
    let symbol: String
    let label: String
    let value: String

    static func waiting(signedIn: Bool, approvals: Int?, install: String?) -> ControlCopy {
        guard signedIn else { return ControlCopy(symbol: "tray", label: "Waiting", value: "Sign in to Burrow") }
        let count = approvals ?? 0
        let value = count > 0 ? IntentCopy.plural(count, "approval") : "Nothing waiting"
        return ControlCopy(symbol: count > 0 ? "tray.full" : "tray", label: "Waiting", value: withInstall(value, install))
    }

    static func startMeeting(lastSpace: String?, install: String?) -> ControlCopy {
        let value = lastSpace.flatMap { $0.isEmpty ? nil : "in \($0)" } ?? ""
        return ControlCopy(symbol: "video.badge.plus", label: "Start meeting", value: withInstall(value, install))
    }

    /// With more than one install, the value line ends with its name.
    private static func withInstall(_ value: String, _ install: String?) -> String {
        guard let install, !install.isEmpty else { return value }
        return value.isEmpty ? install : "\(value), \(install)"
    }
}
