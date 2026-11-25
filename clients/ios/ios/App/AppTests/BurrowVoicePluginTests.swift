import AVFoundation
import Capacitor
import UIKit
import XCTest

@testable import App

/// One ordered log every fake writes to, so a test can assert what ran first.
@MainActor
private final class CallLog {
    var entries: [String] = []
}

/// An audio session that records each call and can refuse activation, as
/// iOS does when another app holds the mic.
private final class FakeBackend: VoiceAudioSessionBackend {
    let log: CallLog
    var category: AVAudioSession.Category = .ambient
    var mode: AVAudioSession.Mode = .default
    var categoryOptions: AVAudioSession.CategoryOptions = []
    var refuseActivation = false
    var routePortTypes: [AVAudioSession.Port] = [.builtInMic, .builtInSpeaker]
    var hasOutputRoute = true
    /// Another app's audio (a podcast) is playing.
    var isOtherAudioPlaying = false
    /// What iOS does to a NON-mixable session opened over another app's
    /// audio when that app takes its audio back: it interrupts this one.
    /// Set by tests that model a podcast; runs after a successful
    /// `setActive(true)`.
    var onNonMixableActivation: (() -> Void)?

    init(_ log: CallLog) { self.log = log }

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {
        MainActor.assumeIsolated { log.entries.append("setCategory(\(category.rawValue))") }
        self.category = category
        self.mode = mode
        categoryOptions = options
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        let notify = options.contains(.notifyOthersOnDeactivation)
        MainActor.assumeIsolated { log.entries.append("setActive(\(active)\(notify ? ", notifyOthers" : ""))") }
        if active && refuseActivation { throw NSError(domain: NSOSStatusErrorDomain, code: 561_017_449) }
        let mixable = !categoryOptions.isDisjoint(with: [.mixWithOthers, .duckOthers, .interruptSpokenAudioAndMixWithOthers])
        if active, isOtherAudioPlaying, !mixable { onNonMixableActivation?() }
    }
}

@MainActor
private final class FakeTranscriber: VoiceTranscribing {
    let log: CallLog
    var inputs = VoiceCapabilityInputs(osSupported: true, isAvailable: true, locale: "en-US", speechPermission: .undetermined, assets: .installed)
    var finalText = ""
    var startFails = false
    var prepared = 0
    private var onPartial: (@MainActor (String) -> Void)?

    init(_ log: CallLog) { self.log = log }

    func capabilityInputs() async -> VoiceCapabilityInputs { inputs }
    func prepare() async throws {
        prepared += 1
        inputs.assets = .installed
    }

    func start(onPartial: @escaping @MainActor (String) -> Void) async throws {
        log.entries.append("transcriber.start")
        if startFails { throw VoiceTranscriberError.noAudioFormat }
        self.onPartial = onPartial
    }

    func partial(_ text: String) { onPartial?(text) }

    func finish() async -> String {
        log.entries.append("transcriber.finish")
        onPartial = nil
        return finalText
    }

    func cancel() {
        log.entries.append("transcriber.cancel")
        onPartial = nil
    }
}

@MainActor
private final class FakeSpeaker: VoiceSpeaking {
    let log: CallLog
    var onEvent: ((ReplySpeechEvent) -> Void)?
    private(set) var speakingID: String?
    private(set) var voiceIDs: [String?] = []

    init(_ log: CallLog) { self.log = log }

    var isSpeaking: Bool { speakingID != nil }

    func speak(id: String, text: String, voiceID: String?) {
        stop(reason: "replaced")
        log.entries.append("speaker.speak")
        voiceIDs.append(voiceID)
        speakingID = id
        onEvent?(ReplySpeechEvent(id: id, state: .started))
    }

    private(set) var parts: [String] = []

    func begin(id: String, voiceID: String?) {
        stop(reason: "replaced")
        log.entries.append("speaker.begin")
        voiceIDs.append(voiceID)
        speakingID = id
        onEvent?(ReplySpeechEvent(id: id, state: .started))
    }

    func append(id: String, seq: Int, text: String) {
        guard speakingID == id else { return }
        parts.append(text)
    }

    func finish(id: String) {}

    func stop(reason: String) {
        log.entries.append("speaker.stop(\(reason))")
        guard let id = speakingID else { return }
        speakingID = nil
        onEvent?(ReplySpeechEvent(id: id, state: .stopped, reason: reason))
    }

    func finish() {
        guard let id = speakingID else { return }
        speakingID = nil
        onEvent?(ReplySpeechEvent(id: id, state: .finished))
    }
}

private struct FakeVoices: ReplyVoiceCatalog {
    var voices: [ReplyVoice]
    func installedVoices() -> [ReplyVoice] { voices }
}

private let installedVoices = [
    ReplyVoice(id: "en-default", name: "Samantha", quality: .default, language: "en-US"),
    ReplyVoice(id: "en-gb-premium", name: "Jamie", quality: .premium, language: "en-GB"),
    ReplyVoice(id: "en-enhanced", name: "Ava", quality: .enhanced, language: "en-US"),
    ReplyVoice(id: "en-premium", name: "Zoe", quality: .premium, language: "en-US"),
    ReplyVoice(id: "fr-premium", name: "Amelie", quality: .premium, language: "fr-FR"),
]

@MainActor
private final class FakeCall: VoiceCallState {
    var hasCall = false
}

/// `BurrowVoice` (task 01a20dc5 stage 1): the capability check, a turn, the
/// reply, and every way the system stops them.
@MainActor
final class BurrowVoicePluginTests: XCTestCase {
    private var log: CallLog!
    private var backend: FakeBackend!
    private var transcriber: FakeTranscriber!
    private var speaker: FakeSpeaker!
    private var callState: FakeCall!
    private var center: NotificationCenter!
    private var events: [(name: String, data: [String: Any])] = []
    private var haptics = 0
    private var micGranted = true

    override func setUp() async throws {
        log = CallLog()
        backend = FakeBackend(log)
        transcriber = FakeTranscriber(log)
        speaker = FakeSpeaker(log)
        callState = FakeCall()
        center = NotificationCenter()
        events = []
        haptics = 0
        micGranted = true
    }

    private func makePlugin() -> BurrowVoicePlugin {
        let plugin = BurrowVoicePlugin()
        plugin.transcriber = transcriber
        plugin.speaker = speaker
        plugin.voiceCatalog = FakeVoices(voices: installedVoices)
        plugin.languageCode = { "en-US" }
        plugin.session = VoiceAudioSession(backend: backend)
        let call = callState!
        plugin.callState = { call }
        plugin.micPermission = { [unowned self] in self.micGranted }
        plugin.micPermissionStatus = { "granted" }
        plugin.isTestBuild = { true }
        plugin.haptic = { [unowned self] in self.haptics += 1 }
        plugin.notificationCenter = center
        plugin.eventSink = { [unowned self] name, data in self.events.append((name, data)) }
        // Pocket TTS off: these tests cover the system voice (task 01a20fdd
        // stage 2 has its own suite, PocketSpeakerTests).
        plugin.pocketGate = { (false, "simulator") }
        plugin.load()
        return plugin
    }

    private var eventNames: [String] { events.map(\.name) }
    private var deactivated: Bool { log.entries.contains("setActive(false, notifyOthers)") }

    private func post(_ name: Notification.Name, _ userInfo: [AnyHashable: Any]? = nil) async {
        center.post(name: name, object: nil, userInfo: userInfo)
        await Task.yield()
    }

    // MARK: Registration

    func testNameMethodsAndEvents() {
        let plugin = BurrowVoicePlugin()
        XCTAssertEqual(plugin.identifier, "BurrowVoicePlugin")
        XCTAssertEqual(plugin.jsName, "BurrowVoice")
        XCTAssertEqual(
            plugin.pluginMethods.map(\.name),
            ["capabilities", "prepare", "start", "stop", "cancel", "speak", "stopSpeaking", "openSettings", "voices", "speakPart", "prepareModel"])
        XCTAssertEqual(BurrowVoicePlugin.events, ["partial", "final", "ended", "speech", "route", "model"])
    }

    // MARK: Capabilities

    private func reason(_ inputs: VoiceCapabilityInputs) async -> (Bool?, String?) {
        transcriber.inputs = inputs
        let payload = await makePlugin().capabilityPayload()
        return (payload["onDeviceSpeech"] as? Bool, payload["reason"] as? String)
    }

    private let ready = VoiceCapabilityInputs(osSupported: true, isAvailable: true, locale: "en-US", speechPermission: .undetermined, assets: .installed)

    func testCapabilitiesReadyOnASupportedPhone() async {
        transcriber.inputs = ready
        let payload = await makePlugin().capabilityPayload()
        XCTAssertEqual(payload["onDeviceSpeech"] as? Bool, true)
        XCTAssertTrue(payload["reason"] is NSNull)
        XCTAssertEqual(payload["locale"] as? String, "en-US")
        XCTAssertEqual(payload["testBuild"] as? Bool, true)
        XCTAssertEqual(payload["micPermission"] as? String, "granted")
    }

    func testCapabilitiesOSTooOld() async {
        let result = await reason(VoiceCapabilityInputs(osSupported: false))
        XCTAssertEqual(result.0, false)
        XCTAssertEqual(result.1, "os_too_old")
    }

    func testCapabilitiesUnavailableWhenSpeechTranscriberIsNot() async {
        var inputs = ready
        inputs.isAvailable = false
        let result = await reason(inputs)
        XCTAssertEqual(result.0, false)
        XCTAssertEqual(result.1, "unavailable", "decided by SpeechTranscriber.isAvailable on the phone, never a model list")
    }

    func testCapabilitiesLocaleUnsupported() async {
        var inputs = ready
        inputs.locale = nil
        let none = await reason(inputs)
        XCTAssertEqual(none.1, "locale_unsupported")
        inputs = ready
        inputs.assets = .unsupported
        let noAssets = await reason(inputs)
        XCTAssertEqual(noAssets.1, "locale_unsupported")
    }

    func testCapabilitiesSpeechPermissionDenied() async {
        var inputs = ready
        inputs.speechPermission = .denied
        let result = await reason(inputs)
        XCTAssertEqual(result.0, false)
        XCTAssertEqual(result.1, "speech_permission_denied")
    }

    func testCapabilitiesAssetsMissingThenPrepareInstallsThem() async {
        var inputs = ready
        inputs.assets = .missing
        let result = await reason(inputs)
        XCTAssertEqual(result.1, "assets_missing")
        let done = expectation(description: "prepared")
        var resolved: [String: Any]?
        let call: CAPPluginCall = CAPPluginCall(
            callbackId: "1", methodName: "prepare", options: [:],
            success: { result, _ in
                resolved = result?.data
                done.fulfill()
            }, error: { _ in done.fulfill() })
        makePlugin().prepare(call)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(transcriber.prepared, 1)
        XCTAssertEqual(resolved?["onDeviceSpeech"] as? Bool, true)
    }

    // MARK: A turn

    func testStartPartialStopEmitsFinal() async {
        let plugin = makePlugin()
        let started = await plugin.startTurn()
        XCTAssertEqual(started["started"] as? Bool, true)
        XCTAssertEqual(haptics, 1, "a light haptic on the confirmed mic open")
        transcriber.partial("what is left on")
        transcriber.finalText = " what is left on the list "
        let stopped = await plugin.stopTurn()
        XCTAssertEqual(stopped["text"] as? String, "what is left on the list")
        XCTAssertEqual(eventNames, ["route", "partial", "final", "ended"])
        XCTAssertEqual(events[1].data["text"] as? String, "what is left on")
        XCTAssertEqual(events[2].data["text"] as? String, "what is left on the list")
        XCTAssertEqual(events[3].data["reason"] as? String, "released")
        XCTAssertEqual(haptics, 2, "and another on release")
    }

    func testStopDeactivatesTheSessionItActivated() async {
        let plugin = makePlugin()
        _ = await plugin.startTurn()
        XCTAssertEqual(log.entries.prefix(2), ["speaker.stop(mic_opened)", "setCategory(AVAudioSessionCategoryPlayAndRecord)"])
        XCTAssertFalse(deactivated)
        transcriber.finalText = "hello"
        _ = await plugin.stopTurn()
        XCTAssertTrue(deactivated, "stop releases the session with notifyOthersOnDeactivation: \(log.entries)")
        XCTAssertEqual(backend.category, .ambient, "and restores the category the app had")
        XCTAssertFalse(plugin.session.isActive)
    }

    func testNoWordsHeardSendsNoFinal() async {
        let plugin = makePlugin()
        _ = await plugin.startTurn()
        transcriber.finalText = "  "
        _ = await plugin.stopTurn()
        XCTAssertEqual(eventNames, ["route", "ended"])
        XCTAssertEqual(events.last?.data["reason"] as? String, "no_words")
    }

    func testStartStopsSpeechFirst() async {
        let plugin = makePlugin()
        XCTAssertEqual(plugin.speakReply(id: "r1", text: "three items")["spoken"] as? Bool, true)
        log.entries.removeAll()
        events.removeAll()
        _ = await plugin.startTurn()
        XCTAssertEqual(log.entries.first, "speaker.stop(mic_opened)", "opening the mic stops speaking before anything else: \(log.entries)")
        XCTAssertEqual(events.first?.name, "speech")
        XCTAssertEqual(events.first?.data["state"] as? String, "stopped")
        XCTAssertEqual(events.first?.data["reason"] as? String, "mic_opened")
        XCTAssertEqual(events.first?.data["id"] as? String, "r1")
    }

    func testCancelEmitsNothing() async {
        let plugin = makePlugin()
        _ = await plugin.startTurn()
        events.removeAll()
        plugin.cancelTurn()
        XCTAssertTrue(events.isEmpty, "a cancelled turn sends nothing: \(eventNames)")
        XCTAssertTrue(log.entries.contains("transcriber.cancel"))
        XCTAssertTrue(deactivated)
        transcriber.partial("late words")
        XCTAssertTrue(events.isEmpty, "a partial after cancel is dropped")
    }

    func testABusyTurnRefusesASecondStart() async {
        let plugin = makePlugin()
        _ = await plugin.startTurn()
        let second = await plugin.startTurn()
        XCTAssertEqual(second["started"] as? Bool, false)
        XCTAssertEqual(second["reason"] as? String, "busy")
    }

    func testTranscriberFailureReleasesTheSession() async {
        transcriber.startFails = true
        let plugin = makePlugin()
        let result = await plugin.startTurn()
        XCTAssertEqual(result["reason"] as? String, "start_failed")
        XCTAssertTrue(deactivated)
        XCTAssertEqual(haptics, 0)
    }

    // MARK: The system stops it

    func testBackgroundStopsTheEngineAndDeactivatesTheSession() async {
        let plugin = makePlugin()
        _ = await plugin.startTurn()
        await post(UIApplication.didEnterBackgroundNotification)
        XCTAssertTrue(log.entries.contains("transcriber.cancel"), "the mic tap closes natively: \(log.entries)")
        XCTAssertTrue(deactivated, "and the session is released, so the mic indicator clears")
        XCTAssertEqual(events.last?.name, "ended")
        XCTAssertEqual(events.last?.data["reason"] as? String, "background")
    }

    func testBackgroundStopsAReply() async {
        let plugin = makePlugin()
        _ = plugin.speakReply(id: "r1", text: "reply")
        await post(UIApplication.didEnterBackgroundNotification)
        XCTAssertEqual(events.last?.data["state"] as? String, "stopped")
        XCTAssertEqual(events.last?.data["reason"] as? String, "background")
        XCTAssertTrue(deactivated)
    }

    func testInterruptionStopsSpeechAndDiscardsTheTurn() async {
        let plugin = makePlugin()
        _ = plugin.speakReply(id: "r1", text: "reply")
        await post(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        let speech = events.filter { $0.name == "speech" }.last
        XCTAssertEqual(speech?.data["state"] as? String, "stopped")
        XCTAssertEqual(speech?.data["reason"] as? String, "interrupted")

        _ = await plugin.startTurn()
        transcriber.partial("half a thought")
        await post(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        XCTAssertEqual(events.last?.name, "ended")
        XCTAssertEqual(events.last?.data["reason"] as? String, "interrupted")
        XCTAssertFalse(eventNames.contains("final"), "a half-formed turn is discarded, never sent")

        let count = events.count
        await post(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        XCTAssertEqual(events.count, count, "an interruption ending starts nothing")
    }

    func testRouteDropStopsSpeechInsteadOfMovingToTheLoudspeaker() async {
        let plugin = makePlugin()
        _ = plugin.speakReply(id: "r1", text: "reply")
        await post(
            AVAudioSession.routeChangeNotification,
            [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        XCTAssertTrue(speaker.isSpeaking, "a new device keeps the reply going")
        await post(
            AVAudioSession.routeChangeNotification,
            [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        XCTAssertFalse(speaker.isSpeaking)
        let speech = events.filter { $0.name == "speech" }.last
        XCTAssertEqual(speech?.data["reason"] as? String, "route_lost")
    }

    // MARK: Another app's audio (task 01a20fdd stage 4)

    /// A podcast is playing: what iOS does when that app takes its audio back
    /// from a NON-mixable session is modelled by posting, just after the
    /// activation, the interruption began it would send.
    private func podcastPlaying() {
        backend.isOtherAudioPlaying = true
        let center = center!
        // Asynchronously, as on a device: the other app reacts after this
        // session is already active (the mic open, or the reply playing).
        backend.onNonMixableActivation = {
            DispatchQueue.main.async {
                center.post(
                    name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            }
        }
    }

    func testATapLatchesWhileAPodcastPlays() async {
        podcastPlaying()
        let plugin = makePlugin()
        let result = await plugin.startTurn()
        XCTAssertEqual(result["started"] as? Bool, true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(log.entries.contains("transcriber.cancel"), "the toggled turn stays open: \(log.entries)")
        XCTAssertFalse(eventNames.contains("ended"), "no ended(interrupted) right after the tap: \(eventNames)")
        transcriber.finalText = "still listening"
        let stopped = await plugin.stopTurn()
        XCTAssertEqual(stopped["text"] as? String, "still listening")
    }

    func testAReplyPlaysOverAPodcastAndThePodcastIsToldToResume() async {
        podcastPlaying()
        let plugin = makePlugin()
        let result = plugin.speakReply(id: "r1", text: "reply")
        // Let the main queue deliver what the podcast app's grab would post.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(result["spoken"] as? Bool, true)
        XCTAssertTrue(speaker.isSpeaking, "not stopped by the podcast taking its audio back")
        XCTAssertFalse(deactivated, "the session is still held while the reply plays: \(log.entries)")
        XCTAssertFalse(eventNames.contains("ended"))
        XCTAssertFalse(events.contains { $0.data["state"] as? String == "stopped" }, "\(events.map(\.data))")
        speaker.finish()
        XCTAssertTrue(deactivated, "deactivated with notifyOthers, so the podcast resumes")
    }

    func testTheSessionDucksOrPausesOtherAudioInsteadOfInterruptingIt() async {
        let plugin = makePlugin()
        _ = plugin.speakReply(id: "r1", text: "reply")
        XCTAssertTrue(backend.categoryOptions.contains(.duckOthers))
        XCTAssertTrue(backend.categoryOptions.contains(.interruptSpokenAudioAndMixWithOthers))
        XCTAssertTrue(backend.categoryOptions.contains(.allowBluetoothHFP))
        XCTAssertTrue(backend.categoryOptions.contains(.defaultToSpeaker))
    }

    func testAStaleInterruptionFromAppSuspensionStopsNothing() async {
        let plugin = makePlugin()
        _ = plugin.speakReply(id: "r1", text: "reply")
        await post(
            AVAudioSession.interruptionNotification,
            [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
                AVAudioSessionInterruptionReasonKey: AVAudioSession.InterruptionReason.appWasSuspended.rawValue,
            ])
        XCTAssertTrue(speaker.isSpeaking)
        // A real interruption (a call) still stops it, as before.
        await post(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        XCTAssertFalse(speaker.isSpeaking)
    }

    // MARK: Meetings guard

    func testStartDuringAMeetingCallRefusesAndLeavesTheSessionUntouched() async {
        callState.hasCall = true
        let plugin = makePlugin()
        let result = await plugin.startTurn()
        XCTAssertEqual(result["started"] as? Bool, false)
        XCTAssertEqual(result["reason"] as? String, "mic_in_use")
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("setCategory") || $0.hasPrefix("setActive") }, "\(log.entries)")
        XCTAssertFalse(log.entries.contains("transcriber.start"))
        XCTAssertEqual(plugin.speakReply(id: "r1", text: "reply")["reason"] as? String, "mic_in_use")
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("setActive") }, "a reply never takes the session from a call")
    }

    func testAnotherAppHoldingTheMicRefusesMicInUse() async {
        backend.refuseActivation = true
        let plugin = makePlugin()
        let result = await plugin.startTurn()
        XCTAssertEqual(result["reason"] as? String, "mic_in_use")
        XCTAssertFalse(plugin.session.isActive)
        XCTAssertEqual(backend.category, .ambient, "the category goes back")
        XCTAssertFalse(deactivated, "never deactivates a session it did not activate")
        XCTAssertFalse(log.entries.contains("transcriber.start"))
    }

    func testMicPermissionDeniedIsNotAFallbackReason() async {
        micGranted = false
        let plugin = makePlugin()
        let result = await plugin.startTurn()
        XCTAssertEqual(result["reason"] as? String, "mic_permission_denied")
        XCTAssertEqual(result["micPermission"] as? String, "denied")
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("setActive") })
    }

    // MARK: Replies

    func testSpeakIsRefusedWhileTheMicIsOpen() async {
        let plugin = makePlugin()
        _ = await plugin.startTurn()
        XCTAssertEqual(plugin.speakReply(id: "r1", text: "reply")["reason"] as? String, "listening")
    }

    func testAFinishedReplyReleasesTheSession() {
        let plugin = makePlugin()
        _ = plugin.speakReply(id: "r1", text: "reply")
        XCTAssertTrue(plugin.session.isActive)
        speaker.finish()
        XCTAssertEqual(events.map { $0.data["state"] as? String }, ["started", "finished"])
        XCTAssertTrue(deactivated)
    }

    func testAReplyWithNoAudioRouteIsUnheard() {
        backend.hasOutputRoute = false
        let plugin = makePlugin()
        let result = plugin.speakReply(id: "r1", text: "reply")
        XCTAssertEqual(result["spoken"] as? Bool, false)
        XCTAssertEqual(events.last?.data["state"] as? String, "unheard")
        XCTAssertEqual(events.last?.data["reason"] as? String, "no_audio_route")
        XCTAssertTrue(deactivated)
    }

    /// The real speaker: a second reply stops the first, once, with
    /// `replaced`.
    func testReplySpeakerStopsTheUtteranceInFlightFirst() {
        let real = ReplySpeaker()
        var seen: [ReplySpeechEvent] = []
        real.onEvent = { seen.append($0) }
        real.speak(id: "a", text: "one", voiceID: nil)
        real.speak(id: "b", text: "two", voiceID: "not-a-voice-on-this-phone")
        XCTAssertEqual(seen.first, ReplySpeechEvent(id: "a", state: .stopped, reason: "replaced"))
        real.stop(reason: "stopped")
        XCTAssertFalse(real.isSpeaking)
        XCTAssertEqual(seen.filter { $0.state == .stopped }.map(\.id), ["a", "b"])
    }

    // MARK: Reply voices

    /// The current language's voices, best first: premium, enhanced, default;
    /// within a quality the exact region first. Other languages are left out.
    func testVoicesListsTheLanguagesVoicesBestFirst() {
        let list = makePlugin().voiceList()
        let ids = (list["voices"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, ["en-premium", "en-gb-premium", "en-enhanced", "en-default"])
        XCTAssertEqual(list["default"] as? String, "en-premium")
        let first = (list["voices"] as? [[String: Any]])?.first
        XCTAssertEqual(first?["quality"] as? String, "premium")
        XCTAssertEqual(first?["name"] as? String, "Zoe")
    }

    func testTheDefaultFallsFromPremiumToEnhancedToDefault() {
        let enhanced = installedVoices.filter { $0.quality != .premium }
        XCTAssertEqual(ReplyVoicePicker.best(for: "en-US", in: enhanced)?.id, "en-enhanced")
        let plain = installedVoices.filter { $0.quality == .default }
        XCTAssertEqual(ReplyVoicePicker.best(for: "en-US", in: plain)?.id, "en-default")
        XCTAssertNil(ReplyVoicePicker.best(for: "de-DE", in: installedVoices))
    }

    func testVoicesWithNoneInstalledHasNoDefault() {
        let plugin = makePlugin()
        plugin.voiceCatalog = FakeVoices(voices: [])
        let list = plugin.voiceList()
        XCTAssertEqual((list["voices"] as? [[String: Any]])?.count, 0)
        XCTAssertTrue(list["default"] is NSNull)
    }

    func testSpeakUsesTheChosenVoice() {
        let plugin = makePlugin()
        let result = plugin.speakReply(id: "r1", text: "reply", voice: "en-enhanced")
        XCTAssertEqual(speaker.voiceIDs, ["en-enhanced"])
        XCTAssertEqual(result["voice"] as? String, "en-enhanced")
        XCTAssertEqual(result["fellBack"] as? Bool, false)
    }

    func testSpeakWithoutAChoiceUsesTheBestInstalledVoice() {
        let result = makePlugin().speakReply(id: "r1", text: "reply")
        XCTAssertEqual(speaker.voiceIDs, ["en-premium"])
        XCTAssertEqual(result["fellBack"] as? Bool, false)
    }

    /// A voice the user picked that is no longer on the phone (deleted in
    /// Settings): the default reads the reply, and the page is told.
    func testAChosenVoiceThatIsNotInstalledFallsBackToTheDefaultAndSaysSo() {
        let result = makePlugin().speakReply(id: "r1", text: "reply", voice: "removed-voice")
        XCTAssertEqual(speaker.voiceIDs, ["en-premium"])
        XCTAssertEqual(result["voice"] as? String, "en-premium")
        XCTAssertEqual(result["fellBack"] as? Bool, true)
    }

    func testTheSystemCatalogMapsAVQuality() {
        XCTAssertEqual(SystemReplyVoiceCatalog.quality(.premium), .premium)
        XCTAssertEqual(SystemReplyVoiceCatalog.quality(.enhanced), .enhanced)
        XCTAssertEqual(SystemReplyVoiceCatalog.quality(.default), .default)
    }

    // MARK: Session and route

    func testASessionNeverActivatedIsNeverDeactivated() {
        VoiceAudioSession(backend: backend).deactivate()
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testRouteLabelComesFromThePortTypeNeverItsName() {
        XCTAssertNil(VoiceAudioSession.routeLabel([.builtInMic, .builtInSpeaker]))
        XCTAssertNil(VoiceAudioSession.routeLabel([.builtInMic, .builtInReceiver]))
        XCTAssertEqual(VoiceAudioSession.routeLabel([.bluetoothHFP, .bluetoothHFP]), "Bluetooth")
        XCTAssertEqual(VoiceAudioSession.routeLabel([.builtInMic, .bluetoothA2DP]), "Bluetooth")
        XCTAssertEqual(VoiceAudioSession.routeLabel([.headsetMic, .headphones]), "Headphones")
        XCTAssertEqual(VoiceAudioSession.routeLabel([.carAudio]), "Car")
    }

    func testStartReportsTheRoute() async {
        backend.routePortTypes = [.bluetoothHFP]
        let result = await makePlugin().startTurn()
        XCTAssertEqual(result["route"] as? String, "Bluetooth")
        XCTAssertEqual(events.first?.name, "route")
        XCTAssertEqual(events.first?.data["label"] as? String, "Bluetooth")
    }

    // MARK: This Simulator

    /// Not an assertion about the device: records what the REAL capability
    /// check returns here (the fallback path's natural Simulator check).
    func testRecordTheSimulatorsRealCapabilities() async {
        let inputs = await SystemVoiceTranscriber().capabilityInputs()
        let capability = VoiceCapability.decide(inputs)
        print("VOICE_SIMULATOR_CAPABILITIES inputs=\(inputs) decided=\(capability)")
    }
}

// MARK: - The mic tap (task 01a20fdd stage 4)

/// A mic input whose format a test can change while the analyzer prepares,
/// as a route change or another app's audio being paused does on a device.
@MainActor
private final class FakeMicInput: MicTapInput {
    var shape: (sampleRate: Double, channels: AVAudioChannelCount) = (48_000, 1)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private(set) var calls: [String] = []

    var currentFormat: AVAudioFormat { format }
    var currentShape: (sampleRate: Double, channels: AVAudioChannelCount) { shape }

    func installMicTap(bufferSize: AVAudioFrameCount, block: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        calls.append("install")
    }

    func removeMicTap() { calls.append("remove") }

    func note(_ call: String) { calls.append(call) }
}

@MainActor
final class MicTapTests: XCTestCase {
    private let analyzerFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    /// The crash: the format was read before the analyzer's awaits and went
    /// stale (here: empty) by the time the tap was installed. The fresh read
    /// refuses with a Swift error and no tap is ever installed.
    func testAFormatThatEmptiesWhilePreparingIsRefusedBeforeAnyTap() async {
        let input = FakeMicInput()
        let target = analyzerFormat
        do {
            _ = try await MicTap.open(
                input,
                prepare: { _ in
                    input.shape = (0, 0)
                    return target
                }, tap: { _, _ in })
            XCTFail("an empty format must not reach installTap")
        } catch {
            XCTAssertEqual(error as? MicTapError, .noInputFormat)
        }
        XCTAssertFalse(input.calls.contains("install"), "\(input.calls)")
    }

    func testAnEmptyFormatBeforePreparingIsRefusedAndNothingIsPrepared() async {
        let input = FakeMicInput()
        input.shape = (48_000, 0)
        let target = analyzerFormat
        var prepared = false
        do {
            _ = try await MicTap.open(
                input,
                prepare: { _ in
                    prepared = true
                    return target
                }, tap: { _, _ in })
            XCTFail("refused")
        } catch {
            XCTAssertEqual(error as? MicTapError, .noInputFormat)
        }
        XCTAssertFalse(prepared)
        XCTAssertTrue(input.calls.isEmpty)
    }

    /// A rate change while preparing still opens the mic: the tap takes the
    /// bus's own format, after any earlier tap is removed, and only once the
    /// analyzer is prepared.
    func testAChangedFormatOpensTheTapAfterPreparingAndRemovesAnyOldTapFirst() async throws {
        let input = FakeMicInput()
        let target = analyzerFormat
        let opened = try await MicTap.open(
            input,
            prepare: { _ in
                input.note("prepare")
                input.shape = (24_000, 1)
                return target
            }, tap: { _, _ in })
        XCTAssertEqual(opened, target)
        XCTAssertEqual(input.calls, ["prepare", "remove", "install"])
    }

    /// Buffers are converted from the format they arrive in, which can
    /// change between turns or mid-turn, not from a format read earlier.
    func testTheConverterFollowsEachBuffersOwnFormat() throws {
        let converter = MicBufferConverter()
        let target = analyzerFormat
        for rate in [48_000.0, 24_000.0, 48_000.0] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            let out = try XCTUnwrap(converter.convert(buffer, to: target), "\(rate)")
            XCTAssertEqual(out.format, target)
            XCTAssertEqual(Double(out.frameLength), 4_800 * 16_000 / rate, accuracy: 2, "\(rate)")
        }
        let same = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 160))
        XCTAssertTrue(converter.convert(same, to: target) === same, "already in the analyzer's format: passed through")
    }
}
