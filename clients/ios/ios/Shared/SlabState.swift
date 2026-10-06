import Foundation

/// What a widget's count slab shows (canvas 01a10887, "Signature element").
///
/// The rule that makes the slab worth having: **cyan means live and
/// non-zero.** Only `.live` gets the `info` (teal-cyan) fill. A zero count
/// and a stale count both drop to `surfaceMuted`, so a cyan slab on the
/// home screen is never an out-of-date number. (Burrow palette: `primary`
/// is orange and belongs to actions; the live fill moved to `info`.)
enum SlabState: Equatable {
    /// Fresh and above zero: info fill, the numeral, `waiting on you` / `open`.
    case live
    /// Fresh and zero: surfaceMuted, `Nothing waiting` / `Nothing open`.
    case zero
    /// The last good count is older than `staleAfter`: surfaceMuted, the
    /// last numeral kept, `As of {time}`.
    case stale
    /// No bearer for the install: no numeral, `Sign in to see approvals`.
    case signedOut

    /// A count is stale once it is OLDER than 30 minutes. Exactly 30 minutes
    /// is still fresh. The widget timeline refreshes every 15 minutes, so a
    /// healthy widget never reaches this; one that cannot reach the server
    /// does, and must stop looking live.
    static let staleAfter: TimeInterval = 30 * 60

    var usesLiveFill: Bool { self == .live }
}

/// The one place the slab rule is decided. `fetchedAt` is when this device
/// received the count, not when the widget rendered.
func slabState(count: Int, fetchedAt: Date, now: Date, signedIn: Bool) -> SlabState {
    guard signedIn else { return .signedOut }
    if now.timeIntervalSince(fetchedAt) > SlabState.staleAfter { return .stale }
    return count > 0 ? .live : .zero
}

/// Which of the two counts a slab shows.
enum SlabKind: String, CaseIterable {
    case approvals, tasks

    var title: String {
        switch self {
        case .approvals: return "My approvals"
        case .tasks: return "My tasks"
        }
    }

    /// The web route the slab opens (router.ex `/inbox`, `/tasks`).
    var path: String {
        switch self {
        case .approvals: return "/inbox"
        case .tasks: return "/tasks"
        }
    }

    /// The caption under the numeral. `As of` uses the short time style in
    /// the person's locale and time zone.
    func caption(for state: SlabState, fetchedAt: Date?, timeZone: TimeZone = .current) -> String {
        switch (state, self) {
        case (.live, .approvals): return "waiting on you"
        case (.live, .tasks): return "open"
        case (.zero, .approvals): return "Nothing waiting"
        case (.zero, .tasks): return "Nothing open"
        case (.signedOut, .approvals): return "Sign in to see approvals"
        case (.signedOut, .tasks): return "Sign in to see tasks"
        case (.stale, _):
            guard let fetchedAt else { return "Not loaded yet" }
            let formatter = DateFormatter()
            formatter.timeZone = timeZone
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "As of \(formatter.string(from: fetchedAt))"
        }
    }
}
