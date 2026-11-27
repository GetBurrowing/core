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
/// LiveKit and no voice worker on this path. Registered beside
/// `BurrowNativePlugin` and `BurrowMeetingsPlugin` in
/// `BurrowBridgeViewController.capacitorDidLoad`.
///
/// Methods: `capabilities`, `prepare`, `start`, `stop`, `cancel`, `speak`,
/// `stopSpeaking`, `openSettings`, `voices`, `speakPart`, `prepareModel`.
/// Events: `partial {text}`, `final {text}`, `ended {reason}`,
/// `speech {id, state, reason}`, `route {label}`,
/// `model {state, received, total, reason}`.
///
/// Two reply voices (task 01a20fdd stage 2): the system voice (`speaker`) and,
/// on an iPhone `PocketTTSSupport` allows, Pocket TTS. ONE is active at a
/// time; every system stop (route, interruption, background, the mic) stops
/// both, so it reaches whichever is playing.
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
        CAPPluginMethod(name: "voices", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "speakPart", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "prepareModel", returnType: CAPPluginReturnPromise),
    ]

    static let events = ["partial", "final", "ended", "speech", "route", "model"]

    // Seams, injected by tests.
    lazy var transcriber: any VoiceTranscribing = MainActor.assumeIsolated { SystemVoiceTranscriber() }
    lazy var speaker: any VoiceSpeaking = MainActor.assumeIsolated { ReplySpeaker() }
    /// Pocket TTS: the gate, the engine, and factories for its speaker and
    /// model store, which are only built on an iPhone the gate allows.
    var pocketGate: () -> (supported: Bool, reason: String?) = { PocketTTSSupport.current() }
    lazy var pocketEngine: any PocketEngine = MainActor.assumeIsolated { SystemPocketEngine() }
    var makePocketSpeaker: @MainActor (any PocketEngine) -> any VoiceSpeaking = { engine in
        PocketSpeaker(engine: engine, output: AVPocketAudioOutput())
    }
    var makePocketStore: @MainActor (any PocketEngine) -> PocketModelStore = { engine in
        PocketModelStore(root: PocketModelStore.defaultRoot(), fetcher: HTTPRangeFetcher(), engine: engine)
    }
    /// One more built-in voice (task 01a20fdd stage 4): its one embedding
    /// file, fetched into the model's directory when the voice is picked.
    var makePocketVoiceStore: @MainActor (PocketTTSFile) -> PocketModelStore = { file in
        PocketModelStore(root: PocketModelStore.defaultRoot(), files: [file], fetcher: HTTPRangeFetcher(), engine: PocketVoiceFileLoader())
    }
    lazy var session: any VoiceAudioSessionControl = MainActor.assumeIsolated { VoiceAudioSession() }
    var voiceCatalog: any ReplyVoiceCatalog = SystemReplyVoiceCatalog()
    var languageCode: () -> String = { AVSpeechSynthesisVoice.currentLanguageCode() }
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
    private var pocketInstance: (any VoiceSpeaking)?
    private var storeInstance: PocketModelStore?
    /// The voices other than the default, by name, built when first needed.
    private var voiceStores: [String: PocketModelStore] = [:]
    /// The streamed reply in flight (`speakPart`) and the speaker reading it.
    private var stream: (id: String, speaker: any VoiceSpeaking)?
    /// The last streamed reply that was stopped: its later parts are dropped,
    /// never restarted from the middle.
    private var droppedID: String?
    /// The last whole percent traced while the model downloads.
    private var lastTracedPercent: Int64?

    override public func load() {
        observeSystem()
    }

    private func emit(_ name: String, _ data: [String: Any]) {
        if name == "ended" { VoiceTrace.log("mic ended reason=\(data["reason"] ?? "-")") }
        if let eventSink { eventSink(name, data) } else { notifyListeners(name, data: data) }
    }

    /// A call (or Siri), the route losing its device (AirPods out) and the
    /// app leaving the foreground all stop the turn and the reply natively:
    /// the page's JS may already be suspended (canvas states 10 and 16).
    func observeSystem() {
        for observer in observers { notificationCenter.removeObserver(observer) }
        let names = [
            AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
            UIApplication.didEnterBackgroundNotification, UIApplication.didReceiveMemoryWarningNotification,
        ]
        observers = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.handleSystem(note) }
            }
        }
    }

    @MainActor
    private func handleSystem(_ note: Notification) {
        VoiceTrace.log(
            "system \(note.name.rawValue) type=\(note.userInfo?[AVAudioSessionInterruptionTypeKey] ?? "-") "
                + "interruption_reason=\(note.userInfo?[AVAudioSessionInterruptionReasonKey] ?? "-") "
                + "route_reason=\(note.userInfo?[AVAudioSessionRouteChangeReasonKey] ?? "-") "
                + "stop=\(VoiceAudioSession.stopReason(for: note) ?? "none") turn=\(turn) speaking=\(speaker.isSpeaking || pocketInstance?.isSpeaking == true)")
        if note.name == UIApplication.didReceiveMemoryWarningNotification, pocketInstance?.isSpeaking != true {
            // The model is loaded lazily and comes back on the next reply.
            pocketEngine.release()
        }
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
        stopSpeakers(reason: reason)
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
        guard turn == .idle, !speaker.isSpeaking, pocketInstance?.isSpeaking != true else { return }
        session.deactivate()
    }

    /// Stops whichever reply voice is playing (the other one is idle and
    /// sends nothing).
    @MainActor
    private func stopSpeakers(reason: String) {
        speaker.stop(reason: reason)
        pocketInstance?.stop(reason: reason)
    }

    @MainActor
    private func pocketSpeaker() -> any VoiceSpeaking {
        if let pocketInstance { return pocketInstance }
        let made = makePocketSpeaker(pocketEngine)
        pocketInstance = made
        return made
    }

    /// The model store, built on first use; nil where the gate says no.
    @MainActor
    private func pocketStore() -> PocketModelStore? {
        if let storeInstance { return storeInstance }
        guard pocketGate().supported else { return nil }
        let store = makePocketStore(pocketEngine)
        store.onChange = { [weak self, weak store] state in
            guard let self, let store else { return }
            if case .downloading(let got, let total) = state {
                if total > 0, got * 100 / total != (self.lastTracedPercent ?? -1) {
                    self.lastTracedPercent = got * 100 / total
                    VoiceTrace.log("model downloading received=\(got) total=\(total)")
                }
            } else {
                VoiceTrace.log("model state=\(state.name) footprint_mb=\(VoiceTrace.footprintMB())")
            }
            self.emit("model", store.data)
        }
        storeInstance = store
        return store
    }

    /// The store of a voice other than the default (which comes with the
    /// model); nil for the default, an unlisted name, or where the gate says no.
    @MainActor
    private func pocketVoiceStore(_ voice: PocketTTSVoice) -> PocketModelStore? {
        guard voice.name != PocketTTSManifest.voice, pocketStore() != nil else { return nil }
        if let made = voiceStores[voice.name] { return made }
        let store = makePocketVoiceStore(voice.file)
        store.onChange = { [weak self, weak store] state in
            guard let self, let store else { return }
            if case .downloading = state {} else { VoiceTrace.log("voice name=\(voice.name) state=\(state.name)") }
            // While the model itself is not ready its progress is what the
            // picker shows; the voice's few MB only once it is.
            if self.storeInstance?.state == .ready { self.emit("model", store.data) }
        }
        voiceStores[voice.name] = store
        return store
    }

    /// Pocket TTS reads in `requested` only once the model and that voice's
    /// file are both ready.
    @MainActor
    private func pocketAvailability(_ requested: String) -> PocketVoice.Availability {
        guard let store = pocketStore() else { return .unsupported }
        guard store.state == .ready else { return .notReady }
        guard let voice = PocketVoice.voice(for: requested), let voiceStore = pocketVoiceStore(voice) else { return .ready }
        return voiceStore.state == .ready ? .ready : .notReady
    }

    /// Starts whatever `requested` still needs: the model, its voice, or both.
    @MainActor
    private func preparePocket(_ requested: String?) {
        pocketStore()?.prepare()
        if let requested, let voice = PocketVoice.voice(for: requested) { pocketVoiceStore(voice)?.prepare() }
    }

    /// A Pocket row's `model`: the model's own progress until it is ready,
    /// then the voice's (the default voice comes with the model).
    @MainActor
    private func pocketModel(for voice: PocketTTSVoice, core: PocketModelStore) -> [String: Any] {
        let data = core.state == .ready ? (pocketVoiceStore(voice) ?? core).data : core.data
        return ["state": data["state"] as Any, "received": data["received"] as Any, "total": data["total"] as Any]
    }

    /// The voice for a reply and the speaker that reads it. Picking Pocket
    /// TTS before its model is ready starts the download; the best system
    /// voice reads this reply meanwhile.
    @MainActor
    private func choose(_ requested: String?) -> (speaker: any VoiceSpeaking, voice: ReplyVoice?, fellBack: Bool, reason: String?) {
        let pocket = requested.flatMap { PocketVoice.isPocket($0) ? pocketAvailability($0) : nil } ?? .unsupported
        let resolved = ReplyVoicePicker.resolve(
            requested: requested, language: languageCode(), in: voiceCatalog.installedVoices(), pocket: pocket)
        if resolved.reason == "model_not_ready" { preparePocket(requested) }
        let pocketReads = resolved.voice.map { PocketVoice.isPocket($0.id) } == true
        return (pocketReads ? pocketSpeaker() : speaker, resolved.voice, resolved.fellBack, resolved.reason)
    }

    /// Routes a speaker's events to the page and keeps the stream in step.
    @MainActor
    private func wire(_ reader: any VoiceSpeaking) {
        let engineName = reader === speaker ? "system" : "pocket"
        reader.onEvent = { [weak self] event in
            guard let self else { return }
            VoiceTrace.log(
                "speech id=\(event.id) state=\(event.state.rawValue) reason=\(event.reason ?? "-") speaker=\(engineName) footprint_mb=\(VoiceTrace.footprintMB())"
            )
            self.emit("speech", event.data)
            guard event.state == .finished || event.state == .stopped else { return }
            if self.stream?.id == event.id {
                self.stream = nil
                if event.state == .stopped { self.droppedID = event.id }
            }
            self.releaseSessionIfIdle()
        }
    }

    /// Makes `reader` the one active speaker: the other stops (`replaced`).
    @MainActor
    private func activate(_ reader: any VoiceSpeaking) {
        if reader !== speaker { speaker.stop(reason: "replaced") }
        if let pocketInstance, reader !== pocketInstance { pocketInstance.stop(reason: "replaced") }
        wire(reader)
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
        VoiceTrace.log("mic start turn=\(turn)")
        stopSpeakers(reason: "mic_opened")
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
        VoiceTrace.log("mic started route=\(session.routeLabel ?? "builtin")")
        haptic()
        emitRoute()
        return ["started": true, "route": session.routeLabel ?? NSNull()]
    }

    private func refusal(_ reason: String) -> [String: Any] {
        VoiceTrace.log("mic start refused reason=\(reason)")
        return ["started": false, "reason": reason]
    }

    /// Release (or the second tap): closes the mic, then `final {text}` and
    /// `ended {reason: "released"}`; with no words, only
    /// `ended {reason: "no_words"}` (canvas state 4). Resolves `{text}`.
    @objc func stop(_ call: CAPPluginCall) {
        Task { @MainActor in call.resolve(await self.stopTurn()) }
    }

    @MainActor
    func stopTurn() async -> [String: Any] {
        VoiceTrace.log("mic stop turn=\(turn)")
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
        VoiceTrace.log("mic cancel turn=\(turn)")
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
    /// `{id, text, voice?}`: reads the reply in `voice` (an id from `voices`)
    /// or, without one, the best installed voice. Resolves `{spoken, voice,
    /// fellBack}`; `fellBack` is true when the requested voice is not on the
    /// phone and the default read it instead.
    @objc func speak(_ call: CAPPluginCall) {
        guard let id = call.getString("id"), !id.isEmpty, let text = call.getString("text") else {
            call.reject("id and text are required")
            return
        }
        let voice = call.getString("voice")
        Task { @MainActor in call.resolve(self.speakReply(id: id, text: text, voice: voice)) }
    }

    /// `{voices: [{id, name, quality, language}], default}`: the on-device
    /// voices for the current language, best first (premium, enhanced,
    /// default); `default` is the first, or null when there is none.
    @objc func voices(_ call: CAPPluginCall) {
        Task { @MainActor in call.resolve(self.voiceList()) }
    }

    /// The Pocket TTS rows, first (the default voice, then the others by
    /// name), only where the gate allows it and the language is English, each
    /// with `model {state, received, total}`. `default` stays the best SYSTEM
    /// voice: picking Pocket starts a 437 MB download.
    @MainActor
    func voiceList() -> [String: Any] {
        let voices = ReplyVoicePicker.voices(for: languageCode(), in: voiceCatalog.installedVoices())
        var rows = voices.map(\.data)
        if PocketVoice.speaks(languageCode()), let store = pocketStore() {
            let others = PocketTTSManifest.voices.dropFirst().sorted { $0.displayName < $1.displayName }
            let pocket = ([PocketTTSManifest.voices[0]] + others).compactMap { voice -> [String: Any]? in
                guard var row = PocketVoice.entry(for: voice.name)?.data else { return nil }
                row["model"] = pocketModel(for: voice, core: store)
                return row
            }
            rows.insert(contentsOf: pocket, at: 0)
        }
        return ["voices": rows, "default": voices.first?.id ?? NSNull()]
    }

    /// `{id, seq, text, final, voice?}`: one sentence of a streamed reply
    /// (task 01a20fdd stage 2). The first part opens the reply and resolves
    /// `{spoken, voice, fellBack, reason}` as `speak` does; later parts of the
    /// same id resolve `{spoken: true}`. Parts of a reply that was stopped (the
    /// mic, a route loss) resolve `{spoken: false, reason: "stopped"}` and are
    /// never spoken. The same refusals as `speak`.
    @objc func speakPart(_ call: CAPPluginCall) {
        guard let id = call.getString("id"), !id.isEmpty, let text = call.getString("text") else {
            call.reject("id and text are required")
            return
        }
        let seq = call.getInt("seq") ?? 0
        let final = call.getBool("final") ?? false
        let voice = call.getString("voice")
        Task { @MainActor in call.resolve(self.speakPart(id: id, seq: seq, text: text, final: final, voice: voice)) }
    }

    @MainActor
    func speakPart(id: String, seq: Int, text: String, final: Bool, voice requested: String? = nil) -> [String: Any] {
        VoiceTrace.log("part id=\(id) seq=\(seq) final=\(final) chars=\(text.count)")
        if let stream, stream.id == id {
            stream.speaker.append(id: id, seq: seq, text: text)
            if final { stream.speaker.finish(id: id) }
            return ["spoken": true]
        }
        if droppedID == id { return ["spoken": false, "reason": "stopped"] }
        if let refused = refuseReply(id) { return refused }
        let chosen = choose(requested)
        VoiceTrace.log("choose id=\(id) voice=\(chosen.voice?.id ?? "-") fellBack=\(chosen.fellBack) reason=\(chosen.reason ?? "-")")
        activate(chosen.speaker)
        stream = (id, chosen.speaker)
        chosen.speaker.begin(id: id, voiceID: chosen.voice?.id)
        chosen.speaker.append(id: id, seq: seq, text: text)
        if final { chosen.speaker.finish(id: id) }
        return ["spoken": true, "voice": chosen.voice?.id ?? NSNull(), "fellBack": chosen.fellBack, "reason": chosen.reason ?? NSNull()]
    }

    /// Starts the Pocket TTS download (and load). Resolves the `model` data;
    /// `{state: "absent", reason}` where the gate says no.
    /// `{voice?}`: the picked Pocket voice, whose file is fetched too
    /// (task 01a20fdd stage 4). Without it, the model and the default voice;
    /// another voice is then fetched by its first reply, which a system voice
    /// reads meanwhile.
    @objc func prepareModel(_ call: CAPPluginCall) {
        let voice = call.getString("voice")
        Task { @MainActor in call.resolve(self.prepareModel(voice: voice)) }
    }

    @MainActor
    func prepareModel(voice requested: String? = nil) -> [String: Any] {
        guard let store = pocketStore() else {
            return ["state": "absent", "received": 0, "total": 0, "reason": pocketGate().reason ?? NSNull()]
        }
        preparePocket(requested)
        guard store.state == .ready, let voice = requested.flatMap(PocketVoice.voice(for:)) else { return store.data }
        return (pocketVoiceStore(voice) ?? store).data
    }

    /// The refusals shared by `speak` and `speakPart`; nil when the reply may play.
    @MainActor
    private func refuseReply(_ id: String) -> [String: Any]? {
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
        return nil
    }

    @MainActor
    func speakReply(id: String, text: String, voice requested: String? = nil) -> [String: Any] {
        VoiceTrace.log("speak id=\(id) chars=\(text.count)")
        if let refused = refuseReply(id) { return refused }
        let chosen = choose(requested)
        VoiceTrace.log("choose id=\(id) voice=\(chosen.voice?.id ?? "-") fellBack=\(chosen.fellBack) reason=\(chosen.reason ?? "-")")
        activate(chosen.speaker)
        stream = nil
        chosen.speaker.speak(id: id, text: text, voiceID: chosen.voice?.id)
        var result: [String: Any] = ["spoken": true, "voice": chosen.voice?.id ?? NSNull(), "fellBack": chosen.fellBack]
        if let reason = chosen.reason { result["reason"] = reason }
        return result
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
            self.stopSpeakers(reason: reason)
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
