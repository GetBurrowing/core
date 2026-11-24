import AVFoundation
import Capacitor
import Foundation
import StoreKit
import UIKit

/// What decides whether this iPhone transcribes on the device. Gathered at
/// run time on the phone (`OnDeviceTranscriber.capabilityInputs`); tests
/// build it by hand.
struct VoiceCapabilityInputs: Equatable {
    enum Permission: String {
        case granted, denied, undetermined
    }

    enum Assets {
        case installed, missing, unsupported
    }

    /// iOS 26 or later (SpeechAnalyzer).
    var osSupported: Bool
    /// `SpeechTranscriber.isAvailable`.
    var isAvailable = false
    /// The supported locale equivalent to the person's, BCP 47, or nil.
    var locale: String?
    var speechPermission: Permission = .undetermined
    var assets: Assets = .missing
}

/// `capabilities()`: whether the Voice tab may use on-device speech, and if
/// not, why. The page shows today's tab, unchanged, for every reason
/// except `assets_missing` ("Preparing speech on this iPhone", then
/// `prepare()`). Microphone permission is NOT a reason: the LiveKit path
/// needs the same grant, so the page shows the permission card instead.
struct VoiceCapability: Equatable {
    let onDeviceSpeech: Bool
    /// os_too_old | unavailable | locale_unsupported |
    /// speech_permission_denied | assets_missing, or nil when on-device
    /// speech is ready.
    let reason: String?
    let locale: String?

    static func decide(_ inputs: VoiceCapabilityInputs) -> VoiceCapability {
        let reason: String?
        if !inputs.osSupported {
            reason = "os_too_old"
        } else if !inputs.isAvailable {
            reason = "unavailable"
        } else if inputs.locale == nil || inputs.assets == .unsupported {
            reason = "locale_unsupported"
        } else if inputs.speechPermission == .denied {
            reason = "speech_permission_denied"
        } else if inputs.assets != .installed {
            reason = "assets_missing"
        } else {
            reason = nil
        }
        return VoiceCapability(onDeviceSpeech: reason == nil, reason: reason, locale: inputs.locale)
    }
}

enum VoiceTranscriberError: Error {
    case osTooOld
    case localeUnsupported
    case noAudioFormat
}

/// What the plugin needs from the transcriber. `SystemVoiceTranscriber` is
/// the real one; tests inject a fake.
@MainActor
protocol VoiceTranscribing: AnyObject {
    func capabilityInputs() async -> VoiceCapabilityInputs
    /// Downloads the system speech assets, if any are missing.
    func prepare() async throws
    /// Opens the mic and starts transcribing; `onPartial` gets the whole
    /// turn's text so far each time it changes.
    func start(onPartial: @escaping @MainActor (String) -> Void) async throws
    /// Closes the mic and returns the finalized text.
    func finish() async -> String
    /// Closes the mic and discards the turn.
    func cancel()
}

/// Whether a meeting call holds the audio session. `CallController` is the
/// real one; tests inject a fake.
@MainActor
protocol VoiceCallState: AnyObject {
    var hasCall: Bool { get }
}

extension CallController: VoiceCallState {
    var hasCall: Bool { meetingID != nil }
}

/// The iOS 26 transcriber behind `#available`, so the app keeps its iOS 17
/// deployment target.
@MainActor
final class SystemVoiceTranscriber: VoiceTranscribing {
    private var impl: AnyObject?

    func capabilityInputs() async -> VoiceCapabilityInputs {
        #if canImport(Speech)
            if #available(iOS 26, *) { return await OnDeviceTranscriber.capabilityInputs() }
        #endif
        return VoiceCapabilityInputs(osSupported: false)
    }

    func prepare() async throws {
        #if canImport(Speech)
            if #available(iOS 26, *) { return try await OnDeviceTranscriber.prepareAssets() }
        #endif
        throw VoiceTranscriberError.osTooOld
    }

    func start(onPartial: @escaping @MainActor (String) -> Void) async throws {
        #if canImport(Speech)
            if #available(iOS 26, *) {
                let transcriber = OnDeviceTranscriber()
                impl = transcriber
                return try await transcriber.start(onPartial: onPartial)
            }
        #endif
        throw VoiceTranscriberError.osTooOld
    }

    func finish() async -> String {
        #if canImport(Speech)
            if #available(iOS 26, *), let transcriber = impl as? OnDeviceTranscriber {
                impl = nil
                return await transcriber.finish()
            }
        #endif
        return ""
    }

    func cancel() {
        #if canImport(Speech)
            if #available(iOS 26, *), let transcriber = impl as? OnDeviceTranscriber { transcriber.cancel() }
        #endif
        impl = nil
    }
}

/// `BurrowVoice` (task 01a20dc5 stage 1): the Voice tab on an iPhone that can
/// transcribe on the device. The mic's words are transcribed here and the
/// page sends them as text; the reply is read by the system voice. No
/// LiveKit and no voice worker on this path. Registered beside `SuiteNative`
/// and `SuiteMeetings` in `BurrowBridgeViewController.capacitorDidLoad`.
///
/// Methods: `capabilities`, `prepare`, `start`, `stop`, `cancel`, `speak`,
/// `stopSpeaking`, `openSettings`. Events: `partial {text}`, `final {text}`,
/// `ended {reason}`, `speech {id, state, reason}`, `route {label}`.
///
/// Never logs what was said, the reply, or a device name.
public class BurrowVoicePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "BurrowVoicePlugin"
    public let jsName = "BurrowVoice"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "capabilities", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "prepare", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "speak", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopSpeaking", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openSettings", returnType: CAPPluginReturnPromise),
    ]

    static let events = ["partial", "final", "ended", "speech", "route"]

    // Seams, injected by tests.
    lazy var transcriber: any VoiceTranscribing = MainActor.assumeIsolated { SystemVoiceTranscriber() }
    lazy var speaker: any VoiceSpeaking = MainActor.assumeIsolated { ReplySpeaker() }
    lazy var session: any VoiceAudioSessionControl = MainActor.assumeIsolated { VoiceAudioSession() }
    var callState: @MainActor () -> any VoiceCallState = { CallController.shared }
    /// Asks for the microphone if iOS has not yet; true when granted.
    var micPermission: @MainActor () async -> Bool = { await AVAudioApplication.requestRecordPermission() }
    var micPermissionStatus: () -> String = { BurrowVoicePlugin.permissionName(AVAudioApplication.shared.recordPermission) }
    var isTestBuild: () async -> Bool = { await BurrowVoicePlugin.systemIsTestBuild() }
    /// A light tap on confirmed mic open and on release. No earcon (canvas
    /// state 6: it would play into the opening mic).
    var haptic: @MainActor () -> Void = { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    var notificationCenter: NotificationCenter = .default
    /// Every event goes here; nil sends it to the page.
    var eventSink: ((String, [String: Any]) -> Void)?

    private enum Turn {
        case idle
        case starting
        case listening
    }

    private var turn = Turn.idle
    /// Bumped by every cancel, so a `start` still awaiting the transcriber
    /// knows its turn was discarded meanwhile.
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

    override public func load() {
        observeSystem()
    }

    private func emit(_ name: String, _ data: [String: Any]) {
        if let eventSink { eventSink(name, data) } else { notifyListeners(name, data: data) }
    }

    /// A call (or Siri), the route losing its device (AirPods out) and the
    /// app leaving the foreground all stop the turn and the reply natively:
    /// the page's JS may already be suspended (canvas states 10 and 16).
    func observeSystem() {
        for observer in observers { notificationCenter.removeObserver(observer) }
        let names = [
            AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
            UIApplication.didEnterBackgroundNotification,
        ]
        observers = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.handleSystem(note) }
            }
        }
    }

    @MainActor
    private func handleSystem(_ note: Notification) {
        if let reason = VoiceAudioSession.stopReason(for: note) {
            stopEverything(reason: reason)
        }
        if note.name == AVAudioSession.routeChangeNotification, session.isActive {
            emitRoute()
        }
    }

    /// Stops the reply and discards any turn, with `reason`; then releases
    /// the session if this plugin holds it.
    @MainActor
    private func stopEverything(reason: String) {
        speaker.stop(reason: reason)
        if turn != .idle {
            generation += 1
            turn = .idle
            transcriber.cancel()
            emit("ended", ["reason": reason])
        }
        releaseSessionIfIdle()
    }

    @MainActor
    private func releaseSessionIfIdle() {
        guard turn == .idle, !speaker.isSpeaking else { return }
        session.deactivate()
    }

    @MainActor
    private func emitRoute() {
        emit("route", ["label": session.routeLabel ?? NSNull()])
    }

    // MARK: Methods

    /// `{onDeviceSpeech, reason, locale, testBuild, micPermission}`.
    /// `testBuild` (a debug or TestFlight build) gates the canvas state-17
    /// caption, so App Store builds never show it.
    @objc func capabilities(_ call: CAPPluginCall) {
        Task { @MainActor in call.resolve(await self.capabilityPayload()) }
    }

    @MainActor
    func capabilityPayload() async -> [String: Any] {
        let capability = VoiceCapability.decide(await transcriber.capabilityInputs())
        return [
            "onDeviceSpeech": capability.onDeviceSpeech,
            "reason": capability.reason ?? NSNull(),
            "locale": capability.locale ?? NSNull(),
            "testBuild": await isTestBuild(),
            "micPermission": micPermissionStatus(),
        ]
    }

    /// Downloads the system speech assets (`assets_missing`), then resolves
    /// the fresh `capabilities()` payload. Rejects `PREPARE_FAILED`.
    @objc func prepare(_ call: CAPPluginCall) {
        Task { @MainActor in
            do {
                try await self.transcriber.prepare()
                call.resolve(await self.capabilityPayload())
            } catch {
                call.reject("Couldn't prepare speech on this iPhone", "PREPARE_FAILED")
            }
        }
    }

    /// Opens the mic -> `{started: true, route}` or `{started: false, reason}`.
    /// Always stops the reply first (canvas state 10). Refusals, which touch
    /// no audio session:
    /// - `mic_in_use`: a meeting call is up, or another app holds the mic;
    /// - `mic_permission_denied` (with `micPermission: "denied"`);
    /// - `busy`: a turn is already open;
    /// - `start_failed`, `cancelled`.
    @objc func start(_ call: CAPPluginCall) {
        Task { @MainActor in call.resolve(await self.startTurn()) }
    }

    @MainActor
    func startTurn() async -> [String: Any] {
        speaker.stop(reason: "mic_opened")
        guard turn == .idle else { return refusal("busy") }
        if callState().hasCall { return refusal("mic_in_use") }
        turn = .starting
        let mine = generation
        guard await micPermission() else {
            if generation == mine { turn = .idle }
            var data = refusal("mic_permission_denied")
            data["micPermission"] = "denied"
            return data
        }
        guard generation == mine else { return refusal("cancelled") }
        do {
            try session.activate()
        } catch {
            turn = .idle
            return refusal("mic_in_use")
        }
        do {
            try await transcriber.start { [weak self] text in
                guard let self, self.generation == mine else { return }
                self.emit("partial", ["text": text])
            }
        } catch {
            if generation == mine {
                turn = .idle
                releaseSessionIfIdle()
            }
            return refusal("start_failed")
        }
        guard generation == mine else {
            transcriber.cancel()
            releaseSessionIfIdle()
            return refusal("cancelled")
        }
        turn = .listening
        haptic()
        emitRoute()
        return ["started": true, "route": session.routeLabel ?? NSNull()]
    }

    private func refusal(_ reason: String) -> [String: Any] { ["started": false, "reason": reason] }

    /// Release (or the second tap): closes the mic, then `final {text}` and
    /// `ended {reason: "released"}`; with no words, only
    /// `ended {reason: "no_words"}` (canvas state 4). Resolves `{text}`.
    @objc func stop(_ call: CAPPluginCall) {
        Task { @MainActor in call.resolve(await self.stopTurn()) }
    }

    @MainActor
    func stopTurn() async -> [String: Any] {
        switch turn {
        case .idle:
            return ["text": ""]
        case .starting:
            // Released before the mic opened: nothing was heard.
            cancelTurn()
            emit("ended", ["reason": "no_words"])
            return ["text": ""]
        case .listening:
            turn = .idle
            generation += 1
            let text = await transcriber.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            releaseSessionIfIdle()
            haptic()
            if text.isEmpty {
                emit("ended", ["reason": "no_words"])
            } else {
                emit("final", ["text": text])
                emit("ended", ["reason": "released"])
            }
            return ["text": text]
        }
    }

    /// Slide-off: discards the turn. Sends no event.
    @objc func cancel(_ call: CAPPluginCall) {
        Task { @MainActor in
            self.cancelTurn()
            call.resolve()
        }
    }

    @MainActor
    func cancelTurn() {
        guard turn != .idle else { return }
        generation += 1
        turn = .idle
        transcriber.cancel()
        releaseSessionIfIdle()
    }

    /// `{id, text}` -> `{spoken: true}`, or `{spoken: false, reason}` with a
    /// `speech {id, state: "unheard", reason}` event. Stops any reply in
    /// flight first. Refused while the mic is open (`listening`) and during
    /// a meeting call (`mic_in_use`).
    @objc func speak(_ call: CAPPluginCall) {
        guard let id = call.getString("id"), !id.isEmpty, let text = call.getString("text") else {
            call.reject("id and text are required")
            return
        }
        Task { @MainActor in call.resolve(self.speakReply(id: id, text: text)) }
    }

    @MainActor
    func speakReply(id: String, text: String) -> [String: Any] {
        if turn != .idle { return ["spoken": false, "reason": "listening"] }
        if callState().hasCall { return unheard(id, "mic_in_use") }
        do {
            try session.activate()
        } catch {
            return unheard(id, "audio_unavailable")
        }
        guard session.hasOutputRoute else {
            releaseSessionIfIdle()
            return unheard(id, "no_audio_route")
        }
        speaker.onEvent = { [weak self] event in
            guard let self else { return }
            self.emit("speech", event.data)
            if event.state == .finished || event.state == .stopped { self.releaseSessionIfIdle() }
        }
        speaker.speak(id: id, text: text)
        return ["spoken": true]
    }

    @MainActor
    private func unheard(_ id: String, _ reason: String) -> [String: Any] {
        emit("speech", ReplySpeechEvent(id: id, state: .unheard, reason: reason).data)
        return ["spoken": false, "reason": reason]
    }

    /// `{reason?}`: stops the reply (`speech {state: "stopped", reason}`).
    @objc func stopSpeaking(_ call: CAPPluginCall) {
        let reason = call.getString("reason") ?? "stopped"
        Task { @MainActor in
            self.speaker.stop(reason: reason)
            self.releaseSessionIfIdle()
            call.resolve()
        }
    }

    /// The app's page in Settings, for the permission card (canvas state 12).
    @objc func openSettings(_ call: CAPPluginCall) {
        Task { @MainActor in
            guard let url = URL(string: UIApplication.openSettingsURLString) else {
                call.reject("no settings URL")
                return
            }
            let opened = await UIApplication.shared.open(url)
            call.resolve(["opened": opened])
        }
    }

    // MARK: Helpers

    static func permissionName(_ permission: AVAudioApplication.recordPermission) -> String {
        switch permission {
        case .granted: return "granted"
        case .denied: return "denied"
        default: return "undetermined"
        }
    }

    /// A debug build, or a TestFlight one (StoreKit's sandbox environment).
    static func systemIsTestBuild() async -> Bool {
        #if DEBUG
            return true
        #else
            guard let result = try? await AppTransaction.shared else { return false }
            switch result {
            case .verified(let transaction), .unverified(let transaction, _):
                return transaction.environment == .sandbox
            }
        #endif
    }
}
