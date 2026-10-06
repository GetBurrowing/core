import Foundation

/// What the in-call screen draws, derived from `CallState` alone (task
/// 01a10db7 stage 4, design canvas 01a11166 "Burrow iOS v2: native
/// meetings"). Pure, so the copy, the row order and the speaking ring are
/// unit-tested without CallKit, LiveKit or a view.
struct InCallModel: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let name: String
        let isAgent: Bool
        let isYou: Bool
        let isMuted: Bool
        /// The 2 pt ring and the `surfaceMuted` row fill.
        let isSpeaking: Bool

        var initial: String { name.first.map { String($0).uppercased() } ?? "?" }
        /// `{Agent} is answering` under a speaking agent's name.
        var answering: String? { isAgent && isSpeaking ? InCallCopy.answering(name) : nil }
    }

    /// The single recovery action, if any. One cyan thing per moment.
    enum Recovery: Equatable {
        case resume
        case tryAgain
    }

    enum StatusKind: Equatable {
        case connecting
        case timer
        case reconnecting
        case poorConnection
        case onHold
    }

    let title: String
    let statusKind: StatusKind
    /// The status line: the timer and head count, or the state words.
    let status: String
    let agents: [Row]
    let people: [Row]
    /// `You're the only one here`, when nobody else is in the call.
    let aloneText: String?
    /// `Lost connection to the meeting.` with Try again.
    let lostConnection: Bool
    let recovery: Recovery?
    /// Reconnecting dims the list to 60%.
    let dimsList: Bool
    let isMuted: Bool
    let mutedByHostNote: String?
    let routeName: String?

    /// Who is ringed: exactly the speaking rows.
    var ringed: [String] { (agents + people).filter(\.isSpeaking).map(\.id) }

    /// `elapsed` is the call clock (paused while reconnecting); nil before
    /// media connects.
    static func make(state: CallState, elapsed: TimeInterval?) -> InCallModel {
        let others = state.participants
        // Order is the participants' own order (stable ids), agents first.
        // NEVER sorted by speaking: the ring moves, the list stays still.
        let agents = others.filter(\.isAgent).map { row($0, isYou: false, isMuted: false) }
        let people = others.filter { !$0.isAgent }.map { row($0, isYou: false, isMuted: false) }
        let you = Row(
            id: "you", name: InCallCopy.you, isAgent: false, isYou: true, isMuted: state.isMuted, isSpeaking: false)

        let headCount = others.count + 1
        let clock = elapsed.map { InCallCopy.clock($0) }
        let statusKind: StatusKind
        let status: String
        switch state.phase {
        case .idle, .connecting:
            statusKind = .connecting
            status = InCallCopy.connecting
        case .reconnecting, .couldNotReconnect:
            statusKind = .reconnecting
            status = InCallCopy.reconnecting
        case .poorConnection:
            statusKind = .poorConnection
            status = [clock, InCallCopy.poorConnection].compactMap { $0 }.joined(separator: "  ·  ")
        case .onHold:
            statusKind = .onHold
            status = InCallCopy.onHold
        case .connected, .alone, .ended:
            statusKind = .timer
            status = [clock, InCallCopy.inMeeting(headCount)].compactMap { $0 }.joined(separator: "  ·  ")
        }

        let connecting = statusKind == .connecting
        return InCallModel(
            title: state.meetingName ?? InCallCopy.fallbackTitle,
            statusKind: statusKind,
            status: status,
            // Connecting: the list shows you only.
            agents: connecting ? [] : agents,
            people: connecting ? [you] : [you] + people,
            aloneText: state.phase == .alone ? InCallCopy.alone : nil,
            lostConnection: state.phase == .couldNotReconnect,
            recovery: state.phase == .couldNotReconnect ? .tryAgain : state.phase == .onHold ? .resume : nil,
            dimsList: state.phase == .reconnecting,
            isMuted: state.isMuted,
            mutedByHostNote: state.mutedByHost ? InCallCopy.mutedByHost : nil,
            routeName: state.route)
    }

    private static func row(_ p: CallParticipant, isYou: Bool, isMuted: Bool) -> Row {
        Row(id: p.id, name: p.name, isAgent: p.isAgent, isYou: isYou, isMuted: isMuted, isSpeaking: p.isSpeaking)
    }
}

/// The ended screen: `Meeting ended` (or `You were removed from the
/// meeting`, with no rejoin), the duration, `Open the space`, Done.
struct EndedModel: Equatable {
    let title: String
    let duration: String?
    let showsOpenSpace: Bool

    static func make(reason: CallEndReason, elapsed: TimeInterval?) -> EndedModel {
        switch reason {
        case .removed:
            return EndedModel(title: InCallCopy.removed, duration: elapsed.map(InCallCopy.clock), showsOpenSpace: false)
        default:
            return EndedModel(title: InCallCopy.ended, duration: elapsed.map(InCallCopy.clock), showsOpenSpace: true)
        }
    }
}

/// Every string on the in-call screen, exactly as the canvas's copy and
/// states tables word it.
enum InCallCopy {
    static let fallbackTitle = "Meeting"
    static let you = "You"
    static let connecting = "Connecting"
    static let reconnecting = "Reconnecting"
    static let poorConnection = "Poor connection"
    static let onHold = "On hold"
    static let lostConnection = "Lost connection to the meeting."
    static let tryAgain = "Try again"
    static let resume = "Resume"
    static let alone = "You're the only one here"
    static let ended = "Meeting ended"
    static let removed = "You were removed from the meeting"
    static let openSpace = "Open the space"
    static let done = "Done"
    static let openFullMeeting = "Open full meeting"
    static let agentsHeader = "AGENTS"
    static let peopleHeader = "PEOPLE"
    static let agentTag = "Agent"
    static let mute = "Mute"
    static let muted = "Muted"
    static let audio = "Audio"
    static let leave = "Leave"
    static let siriPaused = "Mic was paused for Siri"
    /// The SFU tells us our track was muted, not by whom; so the canvas's
    /// "{Name} muted you" reads "The host" (deviation, stage 4 notes).
    static let mutedByHost = "The host muted you. Tap Mute to talk."

    static func answering(_ agent: String) -> String { "\(agent) is answering" }
    static func inMeeting(_ count: Int) -> String { "\(count) in meeting" }
    static func routeMoved(_ route: String) -> String { "Audio moved to \(route)" }

    /// `m:ss`, or `h:mm:ss` past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
