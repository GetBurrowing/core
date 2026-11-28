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
    static var start: (@MainActor () async -> VoiceLaunchOutcome)?
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
    static var description = IntentDescription("Starts a Voice turn with the agent you talked to last.")

    init() {}

    @MainActor
    func perform() async throws -> IntentResultContainer<Never, Never, Never, Never> {
        // Which process ran perform: ids and states only, never words.
        IntentLog.step("voice.perform", "process=\(InstallQuery.isAppExtension ? "extension" : "app") hook=\(VoiceLauncher.start != nil)")
        if let start = VoiceLauncher.start {
            switch await start() {
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

    init() {}

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

    init() {}

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

    init() {}

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
    static func voice(signedIn: Bool, partner: String?, install: String?) -> ControlCopy {
        guard signedIn else { return ControlCopy(symbol: "mic", label: "Voice", value: "Sign in to Burrow") }
        let name = partner ?? "Burrow"
        let value = install.flatMap { $0.isEmpty ? nil : "\(name) · \($0)" } ?? name
        return ControlCopy(symbol: "mic", label: "Voice", value: value)
    }
}
