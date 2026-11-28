import Foundation

#if canImport(ActivityKit)
    import ActivityKit
#endif

/// The phases of a native Voice turn (task 01a21e75 stage 5; canvas
/// 01a21e80 "States", Voice table). The captions follow 01a20dc5's wording.
enum VoicePhase: String, Codable, Equatable, CaseIterable {
    case listening, sending, thinking, speaking, finished, noWords, notSent, ended

    /// The caption beside the partner marker.
    func caption(partner: String) -> String {
        switch self {
        case .listening: return "Tap to send"
        case .sending: return "Sending"
        case .thinking: return "\(partner) is replying"
        // The reply sentence is the line: no caption beside it.
        case .speaking, .finished: return ""
        case .noWords: return "No words heard"
        case .notSent: return "Not sent"
        case .ended: return "Ended"
        }
    }

    /// The turn is over: no buttons (canvas "Activity ended").
    var isOver: Bool { self == .ended || self == .noWords }
}

/// What one Live Activity shows. The transcript tail and the newest reply
/// sentence are message text: they live only in the activity on the
/// person's own device and are never logged.
struct VoiceActivityState: Codable, Hashable {
    var phase: VoicePhase
    /// The last words heard, for the one transcript line.
    var transcriptTail: String
    /// The newest reply sentence only.
    var replySentence: String?
    var caption: String
    /// The DM's `path_segment` once the turn is sent, so a tap on the ended
    /// activity opens the conversation.
    var pathSegment: String?

    static func make(_ phase: VoicePhase, partner: String, transcript: String = "", reply: String? = nil, pathSegment: String? = nil)
        -> VoiceActivityState
    {
        VoiceActivityState(
            phase: phase, transcriptTail: tail(transcript), replySentence: reply, caption: phase.caption(partner: partner),
            pathSegment: pathSegment)
    }

    /// Where a tap on the activity goes: the conversation once sent, else
    /// the Voice tab.
    func link(host: String) -> DeepLink {
        pathSegment.flatMap { DeepLink.space(host: host, pathSegment: $0) } ?? DeepLink(host: host, path: "/voice")
    }

    /// The last 120 characters, on one line.
    static func tail(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > 120 ? "…" + String(line.suffix(120)) : line
    }
}

#if canImport(ActivityKit)
    /// The Voice Live Activity's fixed attributes: the partner and, with
    /// several installs signed in, the install's display name.
    @available(iOS 16.1, *)
    struct VoiceActivityAttributes: ActivityAttributes {
        typealias ContentState = VoiceActivityState

        let partnerName: String
        let installLabel: String?
        /// The partner's install, for the tap's link.
        let host: String
    }
#endif

/// Why a Voice surface opens the app instead of running in the background
/// (task 01a21e75 stage 5, "Fallback triggers"), or nil when it can stay in
/// the background. Pure, so the decision table is unit-tested.
enum VoiceFallback {
    struct Inputs: Equatable {
        /// iOS 18 or later (AudioRecordingIntent).
        var osSupportsIntent: Bool
        /// On-device speech ready (`VoiceCapability.onDeviceSpeech`).
        var speechReady: Bool
        /// `ActivityAuthorizationInfo().areActivitiesEnabled`.
        var activitiesEnabled: Bool
        /// The app process installed the launcher (nil in an extension).
        var hookPresent: Bool
        var signedIn: Bool = true
    }

    enum Reason: String, Equatable {
        case osTooOld = "os_too_old"
        case speechNotReady = "speech_not_ready"
        case activitiesDisabled = "activities_disabled"
        case noHook = "no_hook"
        case activityRequestFailed = "activity_request_failed"
        case signedOut = "signed_out"
    }

    /// The first reason that forces the app open, in this order.
    static func decide(_ inputs: Inputs) -> Reason? {
        if !inputs.signedIn { return .signedOut }
        if !inputs.osSupportsIntent { return .osTooOld }
        if !inputs.hookPresent { return .noHook }
        if !inputs.speechReady { return .speechNotReady }
        if !inputs.activitiesEnabled { return .activitiesDisabled }
        return nil
    }
}

/// The Voice widget tile (canvas "Voice tile"): what it says and how big
/// the disc is. Pure, so every state is unit-tested and rendered.
struct VoiceTileModel: Equatable {
    enum Kind: Equatable {
        /// Filled primary disc, mic glyph: a tap starts a turn.
        case rest
        /// The same disc with the send glyph: a tap sends.
        case listening
        /// Outline disc: a tap opens the app to sign in.
        case signedOut
    }

    let kind: Kind
    let title: String
    /// "on <install>" with several installs; dropped first at large text.
    let detail: String?
    /// 64pt, 52pt with several installs, never below 44.
    let discSize: Double

    static let minimumDisc: Double = 44

    static func make(signedIn: Bool, partner: String?, install: String?, listening: Bool) -> VoiceTileModel {
        guard signedIn else { return VoiceTileModel(kind: .signedOut, title: "Sign in to Burrow", detail: nil, discSize: 64) }
        let detail = install.flatMap { $0.isEmpty ? nil : "on \($0)" }
        let disc: Double = detail == nil ? 64 : 52
        if listening { return VoiceTileModel(kind: .listening, title: "Tap to send", detail: detail, discSize: disc) }
        return VoiceTileModel(kind: .rest, title: "Talk to \(partner ?? "Burrow")", detail: detail, discSize: disc)
    }

    /// VoiceOver: "Talk to Burrow" / "Send to Burrow" (the system adds ", button").
    func accessibilityLabel(partner: String?) -> String {
        switch kind {
        case .rest: return "Talk to \(partner ?? "Burrow")"
        case .listening: return "Send to \(partner ?? "Burrow")"
        case .signedOut: return title
        }
    }
}

/// Whether a native turn is listening right now, in the App Group, so the
/// widget tile can show "Tap to send". A phase and a time, never words.
struct VoiceTurnStatusStore {
    private static let key = "burrow.voice.listening.v1"
    /// A listening turn is capped at a minute; a stale mark reads as rest.
    static let validFor: TimeInterval = 90
    let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: InstallStore.appGroup)) {
        self.defaults = defaults ?? .standard
    }

    func setListening(_ listening: Bool, now: Date = Date()) {
        if listening { defaults.set(now.timeIntervalSince1970, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
    }

    func isListening(now: Date = Date()) -> Bool {
        let at = defaults.double(forKey: Self.key)
        return at > 0 && now.timeIntervalSince1970 - at <= Self.validFor
    }
}

/// Which buttons the Live Activity shows per phase (canvas "Live Activity"
/// phases). Pure, so the table is unit-tested. One orange at a time: only
/// Send while forming and Talk once finished are filled primary.
enum VoiceActivityButtons {
    enum Disc: Equatable {
        case send, retry, inactiveFilled, inactiveOutline, talkOutline, talkFilled, none
    }

    static func showsCancel(_ phase: VoicePhase) -> Bool {
        [.listening, .sending, .thinking, .speaking, .notSent].contains(phase)
    }

    static func disc(_ phase: VoicePhase) -> Disc {
        switch phase {
        case .listening: return .send
        case .sending: return .inactiveFilled
        case .thinking: return .inactiveOutline
        case .speaking: return .talkOutline
        case .finished: return .talkFilled
        case .notSent: return .retry
        case .noWords, .ended: return .none
        }
    }
}

/// One recent agent on the medium Voice widget (device rev 3).
struct VoiceRecentRow: Equatable, Identifiable {
    static let emptyLine = "Agents you talk to show here"

    let partner: VoicePartnerChoice
    /// The install's display name, only with several installs signed in.
    let installLabel: String?

    var id: String { "\(partner.host)|\(partner.agentID)" }

    /// "Talk to Build agent, on Lab".
    var spoken: String { "Talk to \(partner.name)" + (installLabel.map { ", on \($0)" } ?? "") }

    /// Up to three, newest first, without the agent the big mic talks to.
    static func rows(_ recents: [VoicePartnerChoice], excluding target: VoicePartnerChoice?, label: (String) -> String?) -> [VoiceRecentRow] {
        recents
            .filter { !($0.host == target?.host && $0.agentID == target?.agentID) }
            .prefix(VoicePartnerHistory.limit)
            .map { VoiceRecentRow(partner: $0, installLabel: label($0.host)) }
    }
}
