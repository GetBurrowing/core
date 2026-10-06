import Foundation

/// Why a call ended.
enum CallEndReason: Equatable {
    /// The person hung up (our Leave, the Lock Screen, AirPods).
    case local
    /// The meeting ended, or the person was removed from it.
    case remoteEnded
    /// The join or the connection failed.
    case failed
    /// The server said the meeting is over before we connected.
    case meetingOver
    /// The host removed the person from the meeting (no rejoin).
    case removed
}

/// Where the call is. `alone` is a connected call with nobody else in it.
enum CallPhase: Equatable {
    case idle
    case connecting
    case connected
    case alone
    case reconnecting
    /// Still reconnecting after `CallState.reconnectGiveUp` seconds.
    case couldNotReconnect
    case poorConnection
    /// A cellular call (or another VoIP app) holds ours. The mic is off and
    /// stays off until the person resumes; nothing resumes on its own.
    case onHold
    case ended(CallEndReason)

    var isLive: Bool {
        switch self {
        case .connected, .alone, .poorConnection: return true
        default: return false
        }
    }
}

/// One other person or agent in the call.
struct CallParticipant: Equatable, Identifiable {
    /// What a participant whose name has not resolved yet is shown as.
    static let unresolvedName = "Joining"

    let id: String
    let name: String
    let isAgent: Bool
    var isSpeaking: Bool

    init(id: String, name: String?, isAgent: Bool, isSpeaking: Bool = false) {
        self.id = id
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = trimmed.isEmpty ? Self.unresolvedName : trimmed
        self.isAgent = isAgent
        self.isSpeaking = isSpeaking
    }

    /// An agent is a LiveKit agent participant, or anyone whose metadata
    /// says `{"agent": true}` (Suite's own voice workers publish that).
    static func isAgent(kindIsAgent: Bool, metadata: String?) -> Bool {
        if kindIsAgent { return true }
        guard let data = metadata?.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["agent"] as? Bool == true
    }
}

/// Everything the call surface draws, and the only place it changes:
/// `CallState.reduce(_:_:)`. Pure, so every transition is unit-tested
/// without CallKit or LiveKit.
struct CallState: Equatable {
    /// Seconds of reconnecting after which the call reads "could not reconnect".
    static let reconnectGiveUp: TimeInterval = 30
    /// A mic paused by an interruption longer than this is flagged.
    static let longPause: TimeInterval = 5

    var phase: CallPhase = .idle
    var meetingName: String?
    var isMuted = false
    /// The host (or the SFU) muted our mic track.
    var mutedByHost = false
    /// The current audio output's name ("iPhone", "AirPods Pro", ...).
    var route: String?
    var participants: [CallParticipant] = []
    var reconnectingSince: Date?
    /// While a short interruption (Siri, an alarm) has the mic.
    var micPausedSince: Date?
    /// Set once an interruption held the mic longer than `longPause`.
    var hadLongMicPause = false
    /// The call clock: seconds banked before the current running stretch,
    /// and when that stretch started. It runs while connected (alone, on
    /// hold and on a poor connection included) and pauses while
    /// reconnecting. Advanced only by `.tick`, so it is testable.
    var clockBanked: TimeInterval = 0
    var clockRunningSince: Date?
    /// Whether media ever connected (the clock exists).
    var hasConnected = false

    /// Elapsed call time at `now`, or nil before media connected.
    func elapsed(at now: Date) -> TimeInterval? {
        guard hasConnected else { return nil }
        return clockBanked + (clockRunningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    var activeSpeakers: [CallParticipant] { participants.filter(\.isSpeaking) }

    static func reduce(_ state: CallState, _ event: CallEvent) -> CallState {
        // Ended is terminal.
        if case .ended = state.phase { return state }
        var s = state
        switch event {
        case .startConnecting(let name):
            s.phase = .connecting
            s.meetingName = name

        case .connected:
            s.reconnectingSince = nil
            s.hasConnected = true
            if s.phase != .onHold { s.phase = presence(s) }

        case .reconnecting(let at):
            if s.reconnectingSince == nil { s.reconnectingSince = at }
            if s.phase != .couldNotReconnect && s.phase != .onHold { s.phase = .reconnecting }

        case .tick(let now):
            switch s.phase {
            case .connected, .alone, .poorConnection, .onHold:
                if s.hasConnected, s.clockRunningSince == nil { s.clockRunningSince = now }
            case .reconnecting, .couldNotReconnect:
                if let since = s.clockRunningSince {
                    s.clockBanked += max(0, now.timeIntervalSince(since))
                    s.clockRunningSince = nil
                }
            default:
                break
            }
            if let since = s.reconnectingSince, s.phase == .reconnecting,
                now.timeIntervalSince(since) >= reconnectGiveUp
            {
                s.phase = .couldNotReconnect
            }
            if let since = s.micPausedSince, now.timeIntervalSince(since) > longPause {
                s.hadLongMicPause = true
            }

        case .connectionQuality(let poor):
            if poor, s.phase.isLive {
                s.phase = .poorConnection
            } else if !poor, s.phase == .poorConnection {
                s.phase = presence(s)
            }

        case .participantsChanged(let participants):
            s.participants = participants
            if s.phase == .connected || s.phase == .alone { s.phase = presence(s) }

        case .setMuted(let muted):
            s.isMuted = muted
            if !muted { s.mutedByHost = false }

        case .hostMuted(let muted):
            s.mutedByHost = muted
            if muted { s.isMuted = true }

        case .routeChanged(let name):
            // A route change never touches mute (canvas open question 4):
            // pulling out AirPods must not open the mic.
            s.route = name

        case .held:
            s.phase = .onHold
            s.isMuted = true

        case .resumed:
            // The person resumed the call. The mic stays off: they unmute.
            if s.phase == .onHold { s.phase = s.reconnectingSince == nil ? presence(s) : .reconnecting }

        case .interruptionBegan(let at):
            if s.phase != .onHold { s.micPausedSince = at }

        case .interruptionEnded(let at):
            if let since = s.micPausedSince, at.timeIntervalSince(since) > longPause { s.hadLongMicPause = true }
            s.micPausedSince = nil

        case .ended(let reason):
            s.phase = .ended(reason)
            s.reconnectingSince = nil
            s.micPausedSince = nil
        }
        return s
    }

    private static func presence(_ s: CallState) -> CallPhase {
        s.participants.isEmpty ? .alone : .connected
    }
}

enum CallEvent: Equatable {
    case startConnecting(meetingName: String?)
    case connected
    case reconnecting(at: Date)
    case tick(Date)
    case connectionQuality(poor: Bool)
    case participantsChanged([CallParticipant])
    case setMuted(Bool)
    case hostMuted(Bool)
    case routeChanged(String?)
    case held
    case resumed
    case interruptionBegan(at: Date)
    case interruptionEnded(at: Date)
    case ended(CallEndReason)
}
