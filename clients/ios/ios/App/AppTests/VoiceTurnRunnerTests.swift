import AVFoundation
import UIKit
import XCTest

@testable import App

// Task 01a21e75 stage 5: the native Voice turn the Voice control, the
// Action button and the Voice widget start. Every seam is a fake; fixture
// hosts are example.test and the partner is "Test Agent".

@MainActor
private final class Log {
    var entries: [String] = []
}

private final class RecordingBackend: VoiceAudioSessionBackend {
    var category: AVAudioSession.Category = .ambient
    var mode: AVAudioSession.Mode = .default
    var categoryOptions: AVAudioSession.CategoryOptions = []
    var routePortTypes: [AVAudioSession.Port] = [.builtInMic, .builtInSpeaker]
    var hasOutputRoute = true
    var isOtherAudioPlaying = false
    var refuse = false
    /// Refuse only this many activations, then accept.
    var refuseTimes: Int?
    private(set) var activations: [Bool] = []

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {
        self.category = category
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        if active, refuse || (refuseTimes ?? 0) > 0 {
            refuseTimes = refuseTimes.map { $0 - 1 }
            // '!pla', what iOS answered on the device before the activity was up.
            throw NSError(domain: NSOSStatusErrorDomain, code: 561_015_905)
        }
        activations.append(active)
    }
}

@MainActor
private final class Transcriber: VoiceTranscribing {
    let log: Log
    var finalText = "what is left on the list"
    var startFails = false
    private var onPartial: (@MainActor (String) -> Void)?
    private(set) var open = false

    init(_ log: Log) { self.log = log }

    func capabilityInputs() async -> VoiceCapabilityInputs { VoiceCapabilityInputs(osSupported: true) }
    func prepare() async throws {}
    func start(onPartial: @escaping @MainActor (String) -> Void) async throws {
        log.entries.append("mic.open")
        if startFails { throw VoiceTranscriberError.noAudioFormat }
        self.onPartial = onPartial
        open = true
    }

    func partial(_ text: String) { onPartial?(text) }

    func finish() async -> String {
        log.entries.append("mic.finish")
        open = false
        return finalText
    }

    func cancel() {
        if open { log.entries.append("mic.cancel") }
        open = false
    }
}

@MainActor
private final class Speaker: VoiceSpeaking {
    let log: Log
    var onEvent: ((ReplySpeechEvent) -> Void)?
    private(set) var id: String?
    private(set) var parts: [String] = []
    private(set) var stops: [String] = []

    init(_ log: Log) { self.log = log }

    var isSpeaking: Bool { id != nil }
    func speak(id: String, text: String, voiceID: String?) {}
    private(set) var voiceIDs: [String?] = []
    func begin(id: String, voiceID: String?) {
        self.id = id
        voiceIDs.append(voiceID)
    }
    func append(id: String, seq: Int, text: String) {
        guard self.id == id else { return }
        parts.append(text)
    }

    func finish(id: String) {}

    func stop(reason: String) {
        guard let id else { return }
        stops.append(reason)
        log.entries.append("speaker.stop(\(reason))")
        self.id = nil
        onEvent?(ReplySpeechEvent(id: id, state: .stopped, reason: reason))
    }

    /// The last queued part has been read out.
    func done() {
        guard let id else { return }
        self.id = nil
        onEvent?(ReplySpeechEvent(id: id, state: .finished))
    }
}

@MainActor
private final class API: VoiceTurnAPI {
    var partnerChoice: VoicePartnerChoice? = VoicePartnerChoice(
        host: "app.example.test", agentID: "a0000000-0000-4000-8000-000000000001", name: "Test Agent", lastUsedAt: nil)
    var sendFailures = 0
    private(set) var sent: [(text: String, id: String)] = []
    private(set) var sentTo: [VoicePartnerChoice] = []
    var polls: [VoiceReplyPoll] = []
    private(set) var pollCount = 0

    func partner() async -> VoicePartnerChoice? { partnerChoice }

    func send(_ partner: VoicePartnerChoice, text: String, clientTurnID: String) async throws -> VoiceTurnPosted {
        sent.append((text, clientTurnID))
        sentTo.append(partner)
        if sendFailures > 0 {
            sendFailures -= 1
            throw BurrowAPIClient.Failure.badResponse
        }
        return VoiceTurnPosted(spaceID: "s1", pathSegment: "d0000000-0000-4000-8000-000000000001")
    }

    func reply(_ partner: VoicePartnerChoice, clientTurnID: String, spoken: Int) async throws -> VoiceReplyPoll {
        pollCount += 1
        guard !polls.isEmpty else { return VoiceReplyPoll(state: "done", sentences: [], spoken: spoken, final: true) }
        return polls.removeFirst()
    }
}

@MainActor
private final class FakeActivity: VoiceActivityControlling {
    var areActivitiesEnabled = true
    var requestFails = false
    private(set) var started = 0
    private(set) var states: [VoiceActivityState] = []
    private(set) var ended: [(VoiceActivityState, TimeInterval?)] = []
    var isLive: Bool { started > ended.count }

    /// Runs at `start`, so a test can read what was already true then.
    var onStart: (() -> Void)?

    func start(partner: String, installLabel: String?, host: String, state: VoiceActivityState) throws {
        onStart?()
        if requestFails { throw ActivityKitVoiceActivity.Failure.unavailable }
        started += 1
        states.append(state)
    }

    func update(_ state: VoiceActivityState) { states.append(state) }
    func end(_ state: VoiceActivityState, dismissAfter: TimeInterval?) { ended.append((state, dismissAfter)) }

    var phases: [VoicePhase] { states.map(\.phase) }
}

@MainActor
private final class Tasks: VoiceBackgroundTasks {
    private(set) var begun = 0
    private(set) var endedCount = 0
    func begin() -> UIBackgroundTaskIdentifier {
        begun += 1
        return UIBackgroundTaskIdentifier(rawValue: begun)
    }

    func end(_ id: UIBackgroundTaskIdentifier) { endedCount += 1 }
}

@MainActor
private final class Call: VoiceCallState {
    var hasCall = false
}

@MainActor
final class VoiceTurnRunnerTests: XCTestCase {
    private var log: Log!
    private var backend: RecordingBackend!
    private var shared: VoiceAudioSession!
    private var transcriber: Transcriber!
    private var speaker: Speaker!
    private var api: API!
    private var activity: FakeActivity!
    private var tasks: Tasks!
    private var call: Call!
    private var speechReady = true
    private var micGranted = true
    private var autoStartName = ""
    private var replyPick = NativeReplyVoice.Pick(pocket: false, voiceID: "en-premium", reason: nil)

    override func setUp() async throws {
        log = Log()
        backend = RecordingBackend()
        shared = VoiceAudioSession(backend: backend)
        transcriber = Transcriber(log)
        speaker = Speaker(log)
        api = API()
        activity = FakeActivity()
        tasks = Tasks()
        call = Call()
        speechReady = true
        micGranted = true
        autoStartName = "voice-autostart-\(UUID().uuidString)"
        VoiceCoordinator.stopRunner = nil
        VoiceCoordinator.stopPluginSpeakers = nil
    }

    override func tearDown() async throws {
        VoiceTrace.sink = nil
        VoiceCoordinator.stopRunner = nil
        VoiceCoordinator.stopPluginSpeakers = nil
        UserDefaults().removePersistentDomain(forName: autoStartName)
        UserDefaults().removePersistentDomain(forName: autoStartName + "-recents")
    }

    private func makeRunner() -> VoiceTurnRunner {
        let runner = VoiceTurnRunner(
            transcriber: transcriber, speaker: speaker, api: api, activity: activity, session: shared.handle(.runner),
            backgroundTasks: tasks, speechReady: { [unowned self] in self.speechReady }, micGranted: { [unowned self] in self.micGranted },
            callState: { [unowned self] in self.call }, installLabel: { _ in nil })
        runner.sleep = { _ in }
        runner.listeningMark = { _ in }
        runner.sessionRetryDelay = 0
        runner.recents = VoicePartnerHistory(defaults: UserDefaults(suiteName: autoStartName + "-recents"))
        runner.replyVoice = { [unowned self] in self.replyPick }
        runner.fallbackLink = { DeepLink(host: "app.example.test", path: "/voice") }
        var n = 0
        runner.newTurnID = {
            n += 1
            return "native-turn-\(n)"
        }
        return runner
    }

    /// Lets the speaker's finished event run the turn to its end.
    private func settle(_ runner: VoiceTurnRunner) async {
        for _ in 0..<50 where runner.phase != .idle { await Task.yield() }
    }

    /// The runner finished with the session, the mic and the background task
    /// all let go.
    private func assertReleased(_ runner: VoiceTurnRunner, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(transcriber.open, "mic still open", file: file, line: line)
        XCTAssertFalse(shared.isHeld(by: .runner), "runner still holds the session", file: file, line: line)
        XCTAssertFalse(shared.isActive, "session still active", file: file, line: line)
        XCTAssertEqual(tasks.begun, tasks.endedCount, "background task leaked", file: file, line: line)
        XCTAssertNil(VoiceCoordinator.stopRunner, file: file, line: line)
    }

    // MARK: Happy path

    func testHappyPathThroughEveryPhase() async {
        let runner = makeRunner()
        api.polls = [
            VoiceReplyPoll(state: "speaking", sentences: ["First sentence."], spoken: 1, final: false),
            VoiceReplyPoll(state: "done", sentences: ["Second sentence."], spoken: 2, final: true),
        ]

        let outcome = await runner.start()
        XCTAssertEqual(outcome, .background)
        XCTAssertEqual(runner.phase, .listening)
        XCTAssertEqual(activity.started, 1)
        XCTAssertTrue(shared.isActive)
        transcriber.partial("what is left")
        XCTAssertEqual(activity.states.last?.transcriptTail, "what is left")
        XCTAssertEqual(activity.states.last?.caption, "Tap to send")

        // The second tap sends.
        _ = await runner.start()
        XCTAssertEqual(api.sent.map(\.text), ["what is left on the list"])
        XCTAssertEqual(api.sent.map(\.id), ["native-turn-1"])
        XCTAssertEqual(speaker.parts, ["First sentence.", "Second sentence."])
        XCTAssertEqual(runner.phase, .speaking)
        XCTAssertFalse(transcriber.open, "the mic is released on Send")
        speaker.done()
        await settle(runner)

        XCTAssertEqual(runner.phase, .idle)
        let phases = activity.phases
        for expected: VoicePhase in [.listening, .sending, .thinking, .speaking, .finished] {
            XCTAssertTrue(phases.contains(expected), "missing \(expected) in \(phases)")
        }
        XCTAssertEqual(activity.states.first { $0.phase == .thinking }?.caption, "Test Agent is replying")
        XCTAssertEqual(activity.ended.last?.0.phase, .ended)
        XCTAssertEqual(activity.ended.last?.0.replySentence, "Second sentence.")
        XCTAssertEqual(activity.ended.last?.1, VoiceTurnRunner.endedDismissAfter)
        XCTAssertEqual(activity.ended.last?.0.pathSegment, "d0000000-0000-4000-8000-000000000001")
        XCTAssertEqual(tasks.begun, 1, "a background task holds the reply while thinking")
        assertReleased(runner)
    }

    // MARK: No words, failure, cancel

    func testNoWordsSendsNothing() async {
        let runner = makeRunner()
        transcriber.finalText = "   "
        _ = await runner.start()
        await runner.send()
        XCTAssertTrue(api.sent.isEmpty)
        XCTAssertTrue(activity.phases.contains(.noWords))
        XCTAssertEqual(activity.states.last { $0.phase == .noWords }?.caption, "No words heard")
        XCTAssertEqual(activity.ended.count, 1)
        XCTAssertNil(activity.ended[0].1, "no words ends at once after its hold")
        assertReleased(runner)
    }

    func testFailureGivesNotSentAndRetryReusesTheClientTurnID() async {
        let runner = makeRunner()
        api.sendFailures = 1
        _ = await runner.start()
        await runner.send()
        XCTAssertEqual(runner.phase, .notSent)
        XCTAssertEqual(activity.states.last?.phase, .notSent)
        XCTAssertEqual(activity.states.last?.caption, "Not sent")
        XCTAssertFalse(transcriber.open, "the mic is released on failure")
        XCTAssertFalse(shared.isActive, "and the session, until Retry")
        XCTAssertEqual(VoiceActivityButtons.disc(.notSent), .retry)

        await runner.send()
        XCTAssertEqual(api.sent.count, 2)
        XCTAssertEqual(api.sent[0].id, api.sent[1].id, "Retry resends the same client_turn_id")
        XCTAssertEqual(api.sent[0].text, api.sent[1].text)
        XCTAssertEqual(runner.phase, .idle)
        assertReleased(runner)
    }

    func testCancelSendsNothingAndEndsAtOnce() async {
        let runner = makeRunner()
        _ = await runner.start()
        runner.cancel()
        XCTAssertTrue(api.sent.isEmpty)
        XCTAssertEqual(log.entries.filter { $0 == "mic.cancel" }.count, 1)
        XCTAssertEqual(activity.ended.count, 1)
        XCTAssertNil(activity.ended[0].1, "Cancel ends at once")
        XCTAssertEqual(runner.phase, .idle)
        assertReleased(runner)
    }

    // MARK: Barge-in

    func testATapWhileSpeakingStopsTheSpeakerOnceWithMicOpenedAndStartsANewTurn() async {
        let runner = makeRunner()
        api.polls = [VoiceReplyPoll(state: "speaking", sentences: ["One."], spoken: 1, final: true)]
        _ = await runner.start()
        await runner.send()
        XCTAssertEqual(runner.phase, .speaking)

        let outcome = await runner.start()
        XCTAssertEqual(outcome, .background)
        XCTAssertEqual(speaker.stops, ["mic_opened"])
        XCTAssertEqual(runner.phase, .listening)
        XCTAssertEqual(runner.clientTurnID, "native-turn-2")
        XCTAssertEqual(activity.started, 2)
        XCTAssertTrue(shared.isHeld(by: .runner))
        runner.cancel()
        assertReleased(runner)
    }

    // MARK: One audio-session owner

    /// The Voice tab's plugin stops everything on didEnterBackground, which
    /// is exactly when a native turn runs. Its stop drops only its own hold:
    /// the runner's turn keeps listening and the session stays active.
    func testAPluginBackgroundStopDoesNotKillARunnerTurn() async {
        let runner = makeRunner()
        let plugin = BurrowVoicePlugin()
        plugin.session = shared.handle(.plugin)
        plugin.transcriber = Transcriber(Log())
        plugin.speaker = Speaker(Log())
        plugin.pocketGate = { (false, "test") }
        let center = NotificationCenter()
        plugin.notificationCenter = center
        plugin.eventSink = { _, _ in }
        plugin.load()

        _ = await runner.start()
        // The plugin also held the session (a reply it was reading).
        try? plugin.session.activate()
        XCTAssertEqual(shared.holders, [.plugin, .runner])

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await Task.yield()

        XCTAssertEqual(runner.phase, .listening, "the runner's turn survived")
        XCTAssertTrue(transcriber.open)
        XCTAssertEqual(shared.holders, [.runner])
        XCTAssertTrue(shared.isActive)
        XCTAssertEqual(backend.activations, [true], "the session was never deactivated under the runner")
        runner.cancel()
        XCTAssertEqual(backend.activations, [true, false])
        assertReleased(runner)
    }

    func testATabTurnStopsTheRunnerAndARunnerTurnStopsTheTabsSpeakers() async {
        let runner = makeRunner()
        var pluginStops = 0
        VoiceCoordinator.stopPluginSpeakers = { pluginStops += 1 }
        _ = await runner.start()
        XCTAssertEqual(pluginStops, 1)
        XCTAssertNotNil(VoiceCoordinator.stopRunner)
        VoiceCoordinator.stopRunner?()
        XCTAssertEqual(runner.phase, .idle)
        assertReleased(runner)
    }

    // MARK: Fallback

    func testFallbackDecisionTable() {
        let ready = VoiceFallback.Inputs(osSupportsIntent: true, speechReady: true, activitiesEnabled: true, hookPresent: true)
        XCTAssertNil(VoiceFallback.decide(ready))
        var input = ready
        input.osSupportsIntent = false
        XCTAssertEqual(VoiceFallback.decide(input), .osTooOld)
        input = ready
        input.hookPresent = false
        XCTAssertEqual(VoiceFallback.decide(input), .noHook)
        input = ready
        input.speechReady = false
        XCTAssertEqual(VoiceFallback.decide(input), .speechNotReady)
        input = ready
        input.activitiesEnabled = false
        XCTAssertEqual(VoiceFallback.decide(input), .activitiesDisabled)
        input = ready
        input.signedIn = false
        XCTAssertEqual(VoiceFallback.decide(input), .signedOut)
    }

    private func assertFallsBack(_ runner: VoiceTurnRunner, file: StaticString = #filePath, line: UInt = #line) async {
        let outcome = await runner.start()
        XCTAssertEqual(outcome, .openApp(DeepLink(host: "app.example.test", path: "/voice")), file: file, line: line)
        XCTAssertEqual(runner.phase, .idle, file: file, line: line)
        XCTAssertEqual(activity.started, activity.ended.count, "no Live Activity is left up", file: file, line: line)
        XCTAssertTrue(api.sent.isEmpty, file: file, line: line)
        assertReleased(runner, file: file, line: line)
    }

    func testSpeechNotReadyFallsBack() async {
        speechReady = false
        await assertFallsBack(makeRunner())
    }

    func testActivitiesDisabledFallsBack() async {
        activity.areActivitiesEnabled = false
        await assertFallsBack(makeRunner())
    }

    func testActivityRequestThrowingFallsBackAndNeverOpensTheSession() async {
        activity.requestFails = true
        await assertFallsBack(makeRunner())
        XCTAssertEqual(backend.activations, [], "the session is opened only once the activity is up")
    }

    func testMicPermissionMissingOrBusyOpensTheAppWithNoActivity() async {
        micGranted = false
        await assertFallsBack(makeRunner())
        micGranted = true
        call.hasCall = true
        await assertFallsBack(makeRunner())
        call.hasCall = false
        XCTAssertEqual(activity.started, 0, "no permission or a call: no activity at all")
        // The mic refused even after the retry: the activity started for it
        // ends at once.
        backend.refuse = true
        await assertFallsBack(makeRunner())
        XCTAssertEqual(activity.started, 1)
        XCTAssertNil(activity.ended.last?.1)
    }

    // MARK: Device rev 3

    /// On the device the session was refused ('!pla') whenever it was
    /// opened before the Live Activity. The activity now comes first.
    func testTheLiveActivityStartsBeforeTheSessionOpens() async {
        var sessionActiveAtActivityStart: Bool?
        activity.onStart = { [unowned self] in sessionActiveAtActivityStart = self.shared.isActive }
        let runner = makeRunner()
        _ = await runner.start()
        XCTAssertEqual(sessionActiveAtActivityStart, false)
        XCTAssertTrue(shared.isActive)
        XCTAssertEqual(runner.phase, .listening)
        runner.cancel()
        assertReleased(runner)
    }

    func testARefusedSessionIsRetriedOnce() async {
        backend.refuseTimes = 1
        let runner = makeRunner()
        let outcome = await runner.start()
        XCTAssertEqual(outcome, .background)
        XCTAssertEqual(runner.phase, .listening)
        XCTAssertEqual(backend.activations, [true])
        runner.cancel()
        assertReleased(runner)
    }

    func testAChosenAgentIsTalkedToInsteadOfTheLastPartner() async {
        let chosen = VoicePartnerChoice(host: "lab.example.test", agentID: "a0000000-0000-4000-8000-000000000002", name: "Lab Agent", lastUsedAt: nil)
        let runner = makeRunner()
        _ = await runner.start(with: chosen)
        await runner.send()
        XCTAssertEqual(api.sentTo.map(\.agentID), [chosen.agentID])
        XCTAssertEqual(api.sentTo.map(\.host), [chosen.host])
        XCTAssertEqual(runner.recents.partners.first, chosen, "a chosen agent becomes the newest recent")
        speaker.done()
        await settle(runner)
        assertReleased(runner)
    }

    /// Ryan: "use the last stored voice". The reply of a turn started from
    /// the control or widget is read in the voice the Voice tab last picked.
    func testTheReplyIsReadInTheStoredVoice() async {
        replyPick = NativeReplyVoice.Pick(pocket: false, voiceID: "en-enhanced", reason: nil)
        api.polls = [VoiceReplyPoll(state: "done", sentences: ["One."], spoken: 1, final: true)]
        let runner = makeRunner()
        _ = await runner.start()
        await runner.send()
        XCTAssertEqual(speaker.voiceIDs, ["en-enhanced"])
        speaker.done()
        await settle(runner)
    }

    func testAPocketPickIsReadByPocketTTS() async {
        replyPick = NativeReplyVoice.Pick(pocket: true, voiceID: "pocket-tts:marius", reason: nil)
        let pocket = Speaker(log)
        api.polls = [VoiceReplyPoll(state: "done", sentences: ["One."], spoken: 1, final: true)]
        let runner = makeRunner()
        runner.makePocketReader = { pocket }
        _ = await runner.start()
        await runner.send()
        XCTAssertEqual(pocket.voiceIDs, ["pocket-tts:marius"])
        XCTAssertEqual(pocket.parts, ["One."])
        XCTAssertTrue(speaker.voiceIDs.isEmpty, "the system voice did not read it")
        pocket.done()
        await settle(runner)
        assertReleased(runner)
    }

    func testAutoStartIsOneShotAndExpires() {
        let defaults = UserDefaults(suiteName: autoStartName)!
        let flag = VoiceAutoStart(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(flag.take(now: now))
        flag.arm(now: now)
        XCTAssertTrue(flag.take(now: now.addingTimeInterval(5)))
        XCTAssertFalse(flag.take(now: now.addingTimeInterval(6)), "one-shot")
        flag.arm(now: now)
        XCTAssertFalse(flag.take(now: now.addingTimeInterval(VoiceAutoStart.validFor + 1)), "expired")
    }

    func testThePluginReportsAutoStartOnceWhenSpeechIsReady() async {
        let plugin = BurrowVoicePlugin()
        plugin.transcriber = ReadyTranscriber()
        plugin.isTestBuild = { false }
        plugin.micPermissionStatus = { "granted" }
        plugin.autoStart = VoiceAutoStart(defaults: UserDefaults(suiteName: autoStartName)!)
        plugin.autoStart.arm()
        let first = await plugin.capabilityPayload()
        let second = await plugin.capabilityPayload()
        XCTAssertEqual(first["autoStart"] as? Bool, true)
        XCTAssertEqual(second["autoStart"] as? Bool, false)
    }

    // MARK: Logging

    /// Mirrors the plugin's rule: VoiceTrace carries ids, phases and timings
    /// only. A transcript sentinel and a reply sentinel go through a whole
    /// turn and never reach a trace line.
    func testNoTranscriptOrReplyReachesVoiceTrace() async {
        var lines: [String] = []
        VoiceTrace.sink = { lines.append($0) }
        let heard = "SENTINEL-HEARD-7731"
        let reply = "SENTINEL-REPLY-4410"
        transcriber.finalText = "please \(heard) now"
        api.polls = [VoiceReplyPoll(state: "done", sentences: ["Here: \(reply)."], spoken: 1, final: true)]
        let runner = makeRunner()
        _ = await runner.start()
        transcriber.partial("please \(heard)")
        await runner.send()
        speaker.done()
        await settle(runner)

        XCTAssertFalse(lines.isEmpty, "the trace recorded the turn (a positive control for the scan)")
        XCTAssertTrue(lines.contains { $0.contains("native-turn-1") }, "ids are traced")
        for line in lines {
            XCTAssertFalse(line.contains(heard), line)
            XCTAssertFalse(line.contains(reply), line)
            XCTAssertFalse(line.contains("Test Agent"), line)
        }
        // The sentinels did reach the activity, so the scan above is not vacuous.
        XCTAssertTrue(activity.states.contains { $0.transcriptTail.contains(heard) })
        XCTAssertTrue(activity.states.contains { $0.replySentence?.contains(reply) == true })
    }

    // MARK: Copy

    func testTileAndControlCopy() {
        let rest = VoiceTileModel.make(signedIn: true, partner: "Test Agent", install: nil, listening: false)
        XCTAssertEqual(rest.title, "Talk to Test Agent")
        XCTAssertNil(rest.detail)
        XCTAssertEqual(rest.discSize, 64)
        XCTAssertEqual(rest.accessibilityLabel(partner: "Test Agent"), "Talk to Test Agent")
        let several = VoiceTileModel.make(signedIn: true, partner: "Test Agent", install: "Lab", listening: false)
        XCTAssertEqual(several.detail, "on Lab")
        XCTAssertEqual(several.discSize, 52)
        XCTAssertGreaterThanOrEqual(several.discSize, VoiceTileModel.minimumDisc)
        let listening = VoiceTileModel.make(signedIn: true, partner: "Test Agent", install: nil, listening: true)
        XCTAssertEqual(listening.kind, .listening)
        XCTAssertEqual(listening.title, "Tap to send")
        XCTAssertEqual(listening.accessibilityLabel(partner: "Test Agent"), "Send to Test Agent")
        XCTAssertEqual(VoiceTileModel.make(signedIn: false, partner: nil, install: nil, listening: false).title, "Sign in to Burrow")

        XCTAssertEqual(ControlCopy.voice(signedIn: true, partner: "Test Agent", install: nil).value, "Test Agent")
        XCTAssertEqual(ControlCopy.voice(signedIn: true, partner: "Test Agent", install: "Lab").value, "Test Agent · Lab")
        XCTAssertEqual(ControlCopy.voice(signedIn: true, partner: nil, install: nil).label, "Voice")
        XCTAssertEqual(ControlCopy.voice(signedIn: true, partner: nil, install: nil).symbol, "mic")
    }

    func testButtonsPerPhaseKeepOneOrange() {
        let filled = VoicePhase.allCases.filter { [.send, .talkFilled].contains(VoiceActivityButtons.disc($0)) }
        XCTAssertEqual(filled, [.listening, .finished])
        XCTAssertFalse(VoiceActivityButtons.showsCancel(.ended))
        XCTAssertFalse(VoiceActivityButtons.showsCancel(.noWords))
        XCTAssertEqual(VoiceActivityButtons.disc(.ended), VoiceActivityButtons.Disc.none)
        XCTAssertTrue(VoicePhase.ended.isOver)
    }
}

@MainActor
private final class ReadyTranscriber: VoiceTranscribing {
    func capabilityInputs() async -> VoiceCapabilityInputs {
        VoiceCapabilityInputs(osSupported: true, isAvailable: true, locale: "en-US", speechPermission: .granted, assets: .installed)
    }

    func prepare() async throws {}
    func start(onPartial: @escaping @MainActor (String) -> Void) async throws {}
    func finish() async -> String { "" }
    func cancel() {}
}

/// The partner across installs, and the voice requests' bearers.
final class VoicePartnerResolverTests: XCTestCase {
    private let a = "app.example.test"
    private let b = "lab.example.test"
    private var cacheName = ""

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        cacheName = "voice-partner-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: cacheName)
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func partnerBody(_ name: String, _ at: String) -> Data {
        Data(#"{"partner":{"agent_id":"a0000000-0000-4000-8000-000000000001","name":"\#(name)","last_used_at":"\#(at)"}}"#.utf8)
    }

    func testTheNewestPartnerAcrossInstallsWins() async {
        StubURLProtocol.respond = { request in
            request.url?.host == self.b
                ? (200, self.partnerBody("Lab Agent", "2026-11-27T12:00:00Z")) : (200, self.partnerBody("Test Agent", "2026-11-26T12:00:00Z"))
        }
        let client = BurrowAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: [a: "token-for-a", b: "token-for-b"]))
        let cache = VoicePartnerCache(defaults: UserDefaults(suiteName: cacheName))
        let chosen = await VoicePartnerResolver.newest(
            installs: [Install(host: a, name: "Alpha"), Install(host: b, name: "Lab")], client: client, cache: cache)
        XCTAssertEqual(chosen?.host, b)
        XCTAssertEqual(chosen?.name, "Lab Agent")
        XCTAssertEqual(cache.partner, chosen, "cached for the control and the widget")
    }

    /// Every voice request (partner, turn, reply) carries only its own
    /// host's bearer, with install A SELECTED so a lookup by selection fails.
    func testVoiceRequestsCarryOnlyTheirOwnHostsBearer() async throws {
        let shared = InstallStore.shared
        let hadA = shared.installs.contains { $0.host == a }
        let previous = shared.selectedHost
        let removeHook = InstallStore.didRemove
        InstallStore.didRemove = nil
        shared.add(host: a)
        defer {
            if !hadA { shared.remove(host: a) }
            if let previous { shared.select(previous) }
            InstallStore.didRemove = removeHook
        }
        XCTAssertEqual(shared.selectedHost, a)

        let tokens = [a: "token-for-a", b: "token-for-b"]
        StubURLProtocol.respond = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/voice/partner") { return (200, self.partnerBody("Lab Agent", "2026-11-27T12:00:00Z")) }
            if path.hasSuffix("/voice/turns") { return (201, Data(#"{"space_id":"s1","path_segment":"d1","client_turn_id":"native-1"}"#.utf8)) }
            return (200, Data(#"{"state":"done","sentences":[],"spoken":0,"final":true}"#.utf8))
        }
        let client = BurrowAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: tokens))
        let api = await MainActor.run { () -> LiveVoiceTurnAPI in
            let api = LiveVoiceTurnAPI()
            api.client = client
            api.installs = { [Install(host: self.b, name: "Lab")] }
            api.cache = VoicePartnerCache(defaults: UserDefaults(suiteName: self.cacheName))
            return api
        }
        let partner = await api.partner()
        let chosen = try XCTUnwrap(partner)
        _ = try await api.send(chosen, text: "hello", clientTurnID: "native-1")
        _ = try await api.reply(chosen, clientTurnID: "native-1", spoken: 0)

        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.count, 3)
        for request in requests {
            XCTAssertEqual(request.url?.host, b)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-for-b")
        }
    }
}

/// Device rev 3: the stored reply voice, and the recent agents.
@MainActor
final class NativeReplyVoiceTests: XCTestCase {
    private let installed = [
        ReplyVoice(id: "en-default", name: "Samantha", quality: .default, language: "en-US"),
        ReplyVoice(id: "en-enhanced", name: "Ava", quality: .enhanced, language: "en-US"),
        ReplyVoice(id: "en-premium", name: "Zoe", quality: .premium, language: "en-US"),
    ]
    private var suite = ""

    override func setUp() async throws { suite = "reply-voice-\(UUID().uuidString)" }
    override func tearDown() async throws { UserDefaults().removePersistentDomain(forName: suite) }

    func testTheStoredSystemVoiceIsUsedNotTheBest() {
        let pick = NativeReplyVoice.pick(choice: "en-default", language: "en-US", installed: installed, pocket: .unsupported)
        XCTAssertEqual(pick, NativeReplyVoice.Pick(pocket: false, voiceID: "en-default", reason: nil))
    }

    func testAStoredPocketVoiceIsUsedWhenItIsOnThePhone() {
        let id = PocketVoice.id
        XCTAssertEqual(NativeReplyVoice.pick(choice: id, language: "en-US", installed: installed, pocket: .ready).voiceID, id)
        XCTAssertTrue(NativeReplyVoice.pick(choice: id, language: "en-US", installed: installed, pocket: .ready).pocket)
        let notReady = NativeReplyVoice.pick(choice: id, language: "en-US", installed: installed, pocket: .notReady)
        XCTAssertEqual(notReady.voiceID, "en-premium", "as in the tab: the best system voice reads while Pocket is not on the phone")
        XCTAssertEqual(notReady.reason, "model_not_ready")
    }

    func testThePluginStoresEveryPickItIsGiven() async {
        let choice = ReplyVoiceChoice(defaults: UserDefaults(suiteName: suite))
        let plugin = BurrowVoicePlugin()
        plugin.replyVoiceChoice = choice
        plugin.pocketGate = { (false, "test") }
        _ = plugin.prepareModel(voice: "en-enhanced")
        XCTAssertEqual(choice.voiceID, "en-enhanced")
        choice.record(nil)
        XCTAssertEqual(choice.voiceID, "en-enhanced", "a reply with no voice keeps the last pick")
        XCTAssertEqual(plugin.pluginMethods.map(\.name).last, "rememberVoice")
    }

    func testTheHistoryKeepsThreeNewestFirstWithoutRepeats() {
        let history = VoicePartnerHistory(defaults: UserDefaults(suiteName: suite))
        func partner(_ n: Int, _ host: String = "app.example.test") -> VoicePartnerChoice {
            VoicePartnerChoice(host: host, agentID: "a0000000-0000-4000-8000-00000000000\(n)", name: "Agent \(n)", lastUsedAt: nil)
        }
        for n in 1...4 { history.add(partner(n)) }
        history.add(partner(3))
        XCTAssertEqual(history.partners.map(\.name), ["Agent 3", "Agent 4", "Agent 2"])
        let rows = VoiceRecentRow.rows(history.partners, excluding: partner(3), label: { _ in "Alpha" })
        XCTAssertEqual(rows.map(\.partner.name), ["Agent 4", "Agent 2"])
        XCTAssertEqual(rows.first?.spoken, "Talk to Agent 4, on Alpha")
    }

    func testTheAgentParameterDefaultsToLastUsed() async {
        let lastUsed = await VoiceAgentQuery().defaultResult()
        XCTAssertEqual(lastUsed?.id, VoiceAgentEntity.lastUsedID)
        XCTAssertNil(lastUsed?.choice, "Last used carries no agent")
        let chosen = VoiceAgentEntity(id: "app.example.test|a0000000-0000-4000-8000-000000000001", name: "Build agent", subtitle: "Agent")
        XCTAssertEqual(chosen.choice?.host, "app.example.test")
        XCTAssertEqual(chosen.choice?.agentID, "a0000000-0000-4000-8000-000000000001")
    }
}
