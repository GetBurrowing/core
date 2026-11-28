import AppIntents
import Foundation

/// How a Voice surface's tap ended.
enum VoiceLaunchOutcome: Equatable {
    /// The turn runs in the background with its Live Activity.
    case background
    /// The app must open, to Voice already listening (`VoiceAutoStart`).
    case openApp(DeepLink)
}

/// The one-tap Voice mic (task 01a21e75 stage 5). The app installs these in
/// `IntentAppHooks.install` (VoiceTurnRunner); the widget extension compiles
/// this file and installs nothing, so a tap that lands in the extension
/// falls back to opening Voice already listening. Mirrors `MeetingLauncher`.
enum VoiceLauncher {
    /// The agent chosen in the widget or control's configuration, or nil
    /// for the last one used.
    static var start: (@MainActor (VoicePartnerChoice?) async -> VoiceLaunchOutcome)?
    static var send: (@MainActor () async -> Void)?
    static var cancel: (@MainActor () async -> Void)?

    /// `/voice` on the partner's install (else the selected one), with the
    /// one-shot autoStart flag armed. Nil with no install.
    static func fallback(installs: InstallStore = .shared, partners: VoicePartnerCache = VoicePartnerCache(), autoStart: VoiceAutoStart = VoiceAutoStart())
        -> DeepLink?
    {
        guard let host = partners.partner?.host ?? installs.selectedHost else { return nil }
        autoStart.arm()
        return DeepLink(host: host, path: "/voice")
    }
}

/// Starts a Voice turn with the last partner without bringing the app to
/// the foreground (iOS 18 `AudioRecordingIntent`; a Live Activity starts
/// with it, or the recording stops). A `LiveActivityIntent` too, so it runs
/// in the APP's process, where the launcher is. Used by the Voice control
/// (Control Center, Lock Screen, Action button) and the Voice widget.
@available(iOS 18, *)
struct StartVoiceTurnIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Talk to Burrow"
    static var description = IntentDescription("Starts a Voice turn with an agent: the one you talked to last, or the one you pick.")
    /// Never opens the app to run: the turn runs in the background with its
    /// Live Activity (iOS only foregrounds it for the fallback).
    static var openAppWhenRun = false

    /// "Last used" by default (device rev 3).
    @Parameter(title: "Agent")
    var agent: VoiceAgentEntity?

    init() {}

    init(agent: VoiceAgentEntity?) {
        self.agent = agent
    }

    @MainActor
    func perform() async throws -> IntentResultContainer<Never, Never, Never, Never> {
        // Which process ran perform: ids and states only, never words.
        let chosen = agent?.choice
        let process = InstallQuery.isAppExtension ? "extension" : "app"
        let agentKind = chosen == nil ? "last" : "chosen"
        IntentLog.step("voice.perform", "process=\(process) hook=\(VoiceLauncher.start != nil) agent=\(agentKind)")
        if let start = VoiceLauncher.start {
            switch await start(chosen) {
            case .background: return .result()
            case .openApp(let link): return open(link)
            }
        }
        guard let link = VoiceLauncher.fallback() else { return .result() }
        return open(link)
    }

    /// Opens the app at `link` (iOS 18.2: in the result; 18.0-18.1: parked
    /// for the app's next launch).
    @MainActor
    private func open(_ link: DeepLink) -> IntentResultContainer<Never, Never, Never, Never> {
        if #available(iOS 18.2, *) { return .result(opensIntent: OpenURLIntent(link.url)) }
        IntentNavigator.open(link)
        return .result()
    }
}

/// The Live Activity's send disc: ends the turn and sends it (or Retry).
@available(iOS 18, *)
struct SendVoiceTurnIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Send to Burrow"
    static var isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLog.step("voice.send", "process=\(InstallQuery.isAppExtension ? "extension" : "app") hook=\(VoiceLauncher.send != nil)")
        await VoiceLauncher.send?()
        return .result()
    }
}

/// The Live Activity's Cancel: ends the turn at once, sending nothing.
@available(iOS 18, *)
struct CancelVoiceTurnIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Cancel Voice"
    static var isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLog.step("voice.cancel", "process=\(InstallQuery.isAppExtension ? "extension" : "app") hook=\(VoiceLauncher.cancel != nil)")
        await VoiceLauncher.cancel?()
        return .result()
    }
}

/// The iOS 17 tile, and any surface where the background turn cannot run:
/// opens Voice already listening (the one-shot autoStart flag).
struct OpenVoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Voice"
    static var description = IntentDescription("Opens Voice, already listening.")
    static var openAppWhenRun = true
    static var isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLog.step("voice.open", "process=\(InstallQuery.isAppExtension ? "extension" : "app")")
        if let link = VoiceLauncher.fallback() { IntentNavigator.open(link) }
        return .result()
    }
}

extension ControlCopy {
    /// The Voice control (canvas "Control"): the system mic, "Voice", and
    /// the partner as the value; with several installs "<partner> · <install>".
    static func voice(signedIn: Bool, partner: String?, install: String?, phase: VoiceWidgetPhase = .idle) -> ControlCopy {
        guard signedIn else { return ControlCopy(symbol: "mic", label: "Voice", value: "Sign in to Burrow") }
        let name = partner ?? "Burrow"
        // The turn's state (device rev 4): a tap while listening sends.
        switch phase {
        case .listening: return ControlCopy(symbol: "arrow.up.circle.fill", label: "Tap to send", value: name)
        case .sending: return ControlCopy(symbol: "arrow.up.circle", label: "Sending", value: name)
        case .replying: return ControlCopy(symbol: "waveform", label: "\(name) is replying", value: "Tap to talk")
        case .idle: break
        }
        let value = install.flatMap { $0.isEmpty ? nil : "\(name) · \($0)" } ?? name
        return ControlCopy(symbol: "mic", label: "Voice", value: value)
    }
}

// MARK: - The agent a Voice surface talks to (device rev 3)

/// "Last used", or one agent on one install: the Voice widget's and the
/// Voice control's configuration parameter. Its id is `last` or an agent
/// `EntityRef` (`<host>|<uuid>`); the host is never shown.
struct VoiceAgentEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static var defaultQuery = VoiceAgentQuery()
    static let lastUsedID = "last"
    static let lastUsed = VoiceAgentEntity(id: lastUsedID, name: "Last used", subtitle: "The agent you talked to last")

    let id: String
    let name: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)", subtitle: "\(subtitle)", image: .init(systemName: id == Self.lastUsedID ? "clock.arrow.circlepath" : "cpu"))
    }

    init(id: String, name: String, subtitle: String) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
    }

    init(_ agent: AgentEntity) {
        self.init(id: agent.id, name: agent.name, subtitle: agent.subtitle)
    }

    /// A recent partner, as a widget button's agent.
    init(_ partner: VoicePartnerChoice, subtitle: String = "Agent") {
        self.init(id: EntityRef(host: partner.host, uuid: partner.agentID).id, name: partner.name, subtitle: subtitle)
    }

    /// The partner the turn talks to; nil for "Last used".
    var choice: VoicePartnerChoice? {
        guard id != Self.lastUsedID, let ref = EntityRef(id) else { return nil }
        return VoicePartnerChoice(host: ref.host, agentID: ref.uuid, name: name, lastUsedAt: nil)
    }
}

struct VoiceAgentQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [VoiceAgentEntity] {
        let agents = identifiers.filter { $0 != VoiceAgentEntity.lastUsedID }
        let resolved = agents.isEmpty ? [] : try await AgentQuery().entities(for: agents).map(VoiceAgentEntity.init)
        return (identifiers.contains(VoiceAgentEntity.lastUsedID) ? [.lastUsed] : []) + resolved
    }

    func suggestedEntities() async throws -> [VoiceAgentEntity] {
        [.lastUsed] + (try await AgentQuery().suggestedEntities()).map(VoiceAgentEntity.init)
    }

    func entities(matching string: String) async throws -> [VoiceAgentEntity] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func defaultResult() async -> VoiceAgentEntity? { .lastUsed }
}

/// The Voice widget's configuration: which agent the big mic talks to.
struct VoiceWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Voice"
    static var description = IntentDescription("Pick the agent the mic talks to.")

    @Parameter(title: "Agent")
    var agent: VoiceAgentEntity?

    init() {}
}

/// The Voice control's configuration (Control Center, Lock Screen).
@available(iOS 18, *)
struct VoiceControlIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Voice"
    static var description = IntentDescription("Pick the agent the control talks to.")

    @Parameter(title: "Agent")
    var agent: VoiceAgentEntity?

    init() {}
}
