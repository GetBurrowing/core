import AVFoundation
import Foundation
import UIKit
import WidgetKit

#if canImport(ActivityKit)
    import ActivityKit
#endif

// The native Voice turn (task 01a21e75 stage 5): one tap on the Voice
// control, the Action button or the Voice widget starts listening to the
// last partner with NO web view, shows the turn in a Live Activity, sends
// it on the second tap, long-polls the reply and speaks it in the
// background. Every seam is injected, so VoiceTurnRunnerTests drive it with
// fakes. Never logs what was said or the reply: VoiceTrace carries ids,
// phases and timings only.

/// The Live Activity, as the runner needs it. `ActivityKitVoiceActivity` is
/// the real one.
@MainActor
protocol VoiceActivityControlling: AnyObject {
    var areActivitiesEnabled: Bool { get }
    func start(partner: String, installLabel: String?, host: String, state: VoiceActivityState) throws
    func update(_ state: VoiceActivityState)
    /// Ends the activity showing `state`; it leaves the Lock Screen after
    /// `dismissAfter` seconds, or at once with nil.
    func end(_ state: VoiceActivityState, dismissAfter: TimeInterval?)
}

/// The server half (stage 2 endpoints), each request with its own host's
/// bearer. `LiveVoiceTurnAPI` is the real one.
@MainActor
protocol VoiceTurnAPI: AnyObject {
    /// The newest partner across every signed-in install, or nil.
    func partner() async -> VoicePartnerChoice?
    func send(_ partner: VoicePartnerChoice, text: String, clientTurnID: String) async throws -> VoiceTurnPosted
    func reply(_ partner: VoicePartnerChoice, clientTurnID: String, spoken: Int) async throws -> VoiceReplyPoll
}

/// `UIApplication`'s background tasks, so the reply can arrive and be
/// spoken with the phone locked.
@MainActor
protocol VoiceBackgroundTasks: AnyObject {
    func begin() -> UIBackgroundTaskIdentifier
    func end(_ id: UIBackgroundTaskIdentifier)
}

@MainActor
final class SystemBackgroundTasks: VoiceBackgroundTasks {
    func begin() -> UIBackgroundTaskIdentifier { UIApplication.shared.beginBackgroundTask(withName: "voice-turn") }
    func end(_ id: UIBackgroundTaskIdentifier) { UIApplication.shared.endBackgroundTask(id) }
}

@MainActor
final class VoiceTurnRunner {
    enum Phase: String, Equatable {
        case idle, starting, listening, sending, thinking, speaking, finished, notSent

        /// What the Voice widget and control show.
        var widgetPhase: VoiceWidgetPhase {
            switch self {
            case .listening: return .listening
            case .sending: return .sending
            case .thinking, .speaking: return .replying
            case .idle, .starting, .finished, .notSent: return .idle
            }
        }
    }

    /// The app's runner, built on first use in the app process only.
    static let shared = VoiceTurnRunner()

    // Seams.
    var transcriber: any VoiceTranscribing
    var speaker: any VoiceSpeaking
    var api: any VoiceTurnAPI
    var activity: any VoiceActivityControlling
    var session: any VoiceAudioSessionControl
    var backgroundTasks: any VoiceBackgroundTasks
    /// On-device speech ready (`VoiceCapability.decide`).
    var speechReady: @MainActor () async -> Bool
    /// The microphone is already granted. Never prompts: a turn started
    /// with the app in the background cannot show the prompt.
    var micGranted: () -> Bool
    var callState: @MainActor () -> any VoiceCallState
    /// "Talk to <partner>" needs a label for the install when several are
    /// signed in.
    var installLabel: (String) -> String?
    /// Tells the Voice widget and the Voice control the turn's state
    /// (device rev 4): written to the App Group, then both reload.
    var statusMark: (VoiceWidgetPhase) -> Void = { phase in
        VoiceTurnStatusStore().set(phase)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.voice)
        if #available(iOS 18, *) { ControlCenter.shared.reloadControls(ofKind: WidgetKinds.voiceControl) }
    }
    /// Where the app opens when the turn cannot run in the background.
    var fallbackLink: () -> DeepLink? = { VoiceLauncher.fallback() }
    var newTurnID: () -> String = { "native-\(UUID().uuidString.lowercased())" }
    var sleep: (TimeInterval) async -> Void = { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    /// How long "No words heard" shows before the activity ends (canvas: about 2 s).
    var noWordsHold: TimeInterval = 2
    /// The pauses between transcriber attempts.
    var transcriberRetryDelays: [TimeInterval] = [0.25, 0.5, 0.75]
    /// Where the app opens when the turn has to move to the foreground.
    var handOffLink: (VoicePartnerChoice) -> DeepLink? = { DeepLink(host: $0.host, path: "/voice") }
    var now: () -> Date = Date.init
    static let handOffValidFor: TimeInterval = 30
    private(set) var pendingForeground: (partner: VoicePartnerChoice, at: Date)?
    /// The pause before the one retry of a refused session.
    var sessionRetryDelay: TimeInterval = 0.3
    /// The reply voice: the Voice tab's last pick (`ReplyVoiceChoice`).
    var replyVoice: @MainActor () -> NativeReplyVoice.Pick = { NativeReplyVoice.current() }
    /// Pocket TTS, built only when the pick is a Pocket voice.
    var makePocketReader: @MainActor () -> any VoiceSpeaking = {
        PocketSpeaker(engine: SystemPocketEngine(), output: AVPocketAudioOutput())
    }
    private var pocketInstance: (any VoiceSpeaking)?
    /// This turn's reply so far (message text: kept only in memory, never traced).
    private var sentences: [String] = []
    private var replyFinal = false
    private var chosenReader: (any VoiceSpeaking)?
    /// Whichever voice reads this turn's reply.
    private var reader: any VoiceSpeaking { chosenReader ?? speaker }

    private func pocketReader() -> any VoiceSpeaking {
        if let pocketInstance { return pocketInstance }
        let made = makePocketReader()
        pocketInstance = made
        return made
    }

    /// The recent partners the medium Voice widget offers.
    var recents = VoicePartnerHistory()
    /// How long the finished activity keeps Talk filled before it ends.
    var finishedHold: TimeInterval = 8
    /// How long the ended activity stays on the Lock Screen.
    static let endedDismissAfter: TimeInterval = 120

    private(set) var phase: Phase = .idle {
        didSet {
            if oldValue.widgetPhase != phase.widgetPhase { statusMark(phase.widgetPhase) }
        }
    }
    private(set) var partner: VoicePartnerChoice?
    private(set) var clientTurnID: String?
    private var transcript = ""
    private var pathSegment: String?
    private var spoken = 0
    private var seq = 0
    private var lastSentence: String?
    private var generation = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(
        transcriber: (any VoiceTranscribing)? = nil, speaker: (any VoiceSpeaking)? = nil,
        api: (any VoiceTurnAPI)? = nil, activity: (any VoiceActivityControlling)? = nil,
        session: (any VoiceAudioSessionControl)? = nil, backgroundTasks: (any VoiceBackgroundTasks)? = nil,
        speechReady: @escaping @MainActor () async -> Bool = {
            VoiceCapability.decide(await SystemVoiceTranscriber().capabilityInputs()).onDeviceSpeech
        },
        micGranted: @escaping () -> Bool = { AVAudioApplication.shared.recordPermission == .granted },
        callState: @escaping @MainActor () -> any VoiceCallState = { CallController.shared },
        installLabel: @escaping (String) -> String? = { host in
            let saved = InstallStore.shared.installs
            let signedIn = Set(saved.map(\.host).filter { BurrowAPIClient.shared.isSignedIn(host: $0) })
            return InstallLabel.label(for: host, installs: saved, signedIn: signedIn)
        }
    ) {
        self.transcriber = transcriber ?? SystemVoiceTranscriber()
        self.speaker = speaker ?? ReplySpeaker()
        self.api = api ?? LiveVoiceTurnAPI()
        self.activity = activity ?? ActivityKitVoiceActivity()
        self.session = session ?? VoiceAudioSession.shared.handle(.runner)
        self.backgroundTasks = backgroundTasks ?? SystemBackgroundTasks()
        self.speechReady = speechReady
        self.micGranted = micGranted
        self.callState = callState
        self.installLabel = installLabel
    }

    private var partnerName: String { partner?.name ?? "Burrow" }

    private func state(_ phase: VoicePhase, reply: String? = nil) -> VoiceActivityState {
        .make(phase, partner: partnerName, transcript: transcript, reply: reply, pathSegment: pathSegment)
    }

    private func trace(_ line: String) {
        VoiceTrace.log("runner \(line) phase=\(phase.rawValue) turn=\(clientTurnID ?? "-")")
    }

    // MARK: Start (the control, the Action button, the widget, the disc)

    /// One tap. Listening: the tap sends. Speaking or thinking: it barges
    /// in with a new turn. Otherwise it starts listening, or says why the
    /// app must open (`VoiceFallback`).
    func start(with chosen: VoicePartnerChoice? = nil) async -> VoiceLaunchOutcome {
        trace("tap process=app")
        switch phase {
        case .listening:
            await send()
            return .background
        case .sending, .starting:
            // Toggle only (device rev 4): a tap while the mic is opening is
            // a repeat of the same tap, never a second turn or a cancel.
            trace("tap ignored")
            return .background
        case .speaking, .thinking, .finished, .notSent:
            // Barge-in: the reply stops once, and a new turn starts.
            interruptCurrent(reason: "mic_opened")
        case .idle:
            break
        }
        return await beginTurn(with: chosen)
    }

    private func beginTurn(with chosen: VoicePartnerChoice?) async -> VoiceLaunchOutcome {
        VoiceCoordinator.stopPluginSpeakers?()
        let inputs = VoiceFallback.Inputs(
            osSupportsIntent: true, speechReady: await speechReady(), activitiesEnabled: activity.areActivitiesEnabled, hookPresent: true)
        if let reason = VoiceFallback.decide(inputs) { return fallback(reason.rawValue) }
        // Mic permission missing or a call holding the mic: no activity; the
        // app opens to Voice's own permission or busy state.
        guard micGranted() else { return fallback("mic_permission") }
        if callState().hasCall { return fallback("mic_in_use") }
        var resolved = chosen
        if resolved == nil { resolved = await api.partner() }
        guard let partner = resolved else { return fallback("no_partner") }
        phase = .starting
        self.partner = partner
        recents.add(partner)
        transcript = ""
        pathSegment = nil
        spoken = 0
        seq = 0
        lastSentence = nil
        chosenReader = nil
        sentences = []
        replyFinal = false
        generation += 1
        let mine = generation
        // The Live Activity FIRST (device rev 3): an AudioRecordingIntent may
        // record from the background only while its Live Activity is up.
        // Activating the session before it was refused with '!pla'
        // (cannotStartPlaying) on the device whenever the app was not in
        // the foreground.
        do {
            try activity.start(partner: partner.name, installLabel: installLabel(partner.host), host: partner.host, state: state(.listening))
            trace("activity started")
        } catch {
            trace("activity failed \(Self.code(error))")
            phase = .idle
            return fallback(VoiceFallback.Reason.activityRequestFailed.rawValue)
        }
        do {
            try await activateSession()
        } catch {
            trace("session refused \(Self.code(error))")
            activity.end(state(.ended), dismissAfter: nil)
            phase = .idle
            return foregroundHandOff(partner, reason: "mic_in_use")
        }
        do {
            try await startTranscriber(mine)
        } catch {
            trace("transcriber failed \(Self.code(error))")
            activity.end(state(.ended), dismissAfter: nil)
            session.deactivate()
            phase = .idle
            return foregroundHandOff(partner, reason: "start_failed")
        }
        guard generation == mine else { return .background }
        clientTurnID = newTurnID()
        phase = .listening
        VoiceCoordinator.stopRunner = { [weak self] in self?.cancel(reason: "tab_turn") }
        trace("listening")
        return .background
    }

    /// The transcriber, retried while iOS refuses to start the mic engine.
    /// On the device (rev 3 trace) a turn started with the app in the
    /// background failed at once with avfaudio 2003329396 ('what') while the
    /// same tap worked with the app in front; the retries cover an activity
    /// that needs a moment before recording counts.
    private func startTranscriber(_ mine: Int) async throws {
        var attempt = 0
        while true {
            do {
                try await transcriber.start { [weak self] text in
                    guard let self, self.generation == mine, self.phase == .listening else { return }
                    self.transcript = text
                    self.activity.update(self.state(.listening))
                }
                if attempt > 0 { trace("transcriber started attempt=\(attempt + 1)") }
                return
            } catch {
                guard attempt < transcriberRetryDelays.count else { throw error }
                trace("transcriber retry attempt=\(attempt + 1) \(Self.code(error))")
                await sleep(transcriberRetryDelays[attempt])
                attempt += 1
            }
        }
    }

    /// iOS would not open the mic with the app in the background: the app
    /// opens (on Voice), and the moment it is in front the turn starts here,
    /// natively, with its Live Activity: no web page and no second tap.
    private func foregroundHandOff(_ partner: VoicePartnerChoice, reason: String) -> VoiceLaunchOutcome {
        trace("hand off to foreground reason=\(reason)")
        pendingForeground = (partner, now())
        guard let link = handOffLink(partner) else { return .background }
        return .openApp(link)
    }

    /// The app came to the front: a turn handed off in the last 30 s starts.
    func appDidBecomeActive() async {
        guard let pending = pendingForeground else { return }
        pendingForeground = nil
        guard now().timeIntervalSince(pending.at) <= Self.handOffValidFor, phase == .idle else { return }
        trace("foreground start")
        _ = await beginTurn(with: pending.partner)
    }

    /// The session, once more after a short pause if iOS refuses it at
    /// first: the activity just requested can take a moment to count.
    private func activateSession() async throws {
        do {
            try session.activate()
        } catch {
            trace("session retry \(Self.code(error))")
            await sleep(sessionRetryDelay)
            try session.activate()
        }
    }

    /// An error's domain and code, for the trace: never its message.
    static func code(_ error: Error) -> String {
        let ns = error as NSError
        return "domain=\(ns.domain) code=\(ns.code)"
    }

    private func fallback(_ reason: String) -> VoiceLaunchOutcome {
        trace("fallback reason=\(reason)")
        guard let link = fallbackLink() else { return .background }
        return .openApp(link)
    }

    // MARK: Send (the disc, or Retry)

    func send() async {
        switch phase {
        case .listening:
            phase = .sending
            activity.update(state(.sending))
            transcript = await transcriber.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            trace("mic closed words=\(transcript.isEmpty ? 0 : transcript.split(separator: " ").count)")
            if transcript.isEmpty { return await noWords() }
        case .notSent:
            phase = .sending
            activity.update(state(.sending))
            try? session.activate()
        default:
            return
        }
        await post()
    }

    private func noWords() async {
        let mine = generation
        activity.update(state(.noWords))
        phase = .idle
        trace("no_words")
        await sleep(noWordsHold)
        guard generation == mine else { return }
        activity.end(state(.noWords), dismissAfter: nil)
        releaseAll()
    }

    private func post() async {
        guard let partner, let clientTurnID else { return }
        let mine = generation
        do {
            pathSegment = try await api.send(partner, text: transcript, clientTurnID: clientTurnID).pathSegment
        } catch {
            guard generation == mine else { return }
            // Not sent: the words stay; Retry resends the SAME client_turn_id.
            phase = .notSent
            activity.update(state(.notSent))
            trace("not_sent")
            // Nothing plays until Retry: the session and the background
            // task are let go; Retry takes them again.
            session.deactivate()
            if backgroundTask != .invalid {
                backgroundTasks.end(backgroundTask)
                backgroundTask = .invalid
            }
            return
        }
        guard generation == mine else { return }
        phase = .thinking
        activity.update(state(.thinking))
        trace("sent")
        if backgroundTask == .invalid { backgroundTask = backgroundTasks.begin() }
        await pollReply(mine)
    }

    // MARK: The reply

    private func pollReply(_ mine: Int) async {
        guard let partner, let clientTurnID else { return }
        var failures = 0
        while generation == mine, phase == .thinking || phase == .speaking {
            let poll: VoiceReplyPoll
            do {
                poll = try await api.reply(partner, clientTurnID: clientTurnID, spoken: spoken)
                failures = 0
            } catch {
                failures += 1
                if failures >= 3 { break }
                continue
            }
            guard generation == mine else { return }
            for sentence in poll.sentences { speak(sentence) }
            spoken = max(spoken, poll.spoken)
            if poll.final {
                replyFinal = true
                reader.finish(id: clientTurnID)
                break
            }
        }
        guard generation == mine else { return }
        // Failed polls also end the turn; otherwise it ends when the voice
        // has read the last sentence (`readerEvent`).
        replyFinal = true
        if !reader.isSpeaking { await finish(mine) }
    }

    /// The reading voice reported `event`. The turn ends only once the reply
    /// is final AND read: a voice that runs dry between sentences (rev 3:
    /// Pocket TTS said finished after part 2 of 3 and the session closed under
    /// part 3) does not end it. A Pocket voice that could not play hands the
    /// whole reply to the system voice.
    private func readerEvent(_ event: ReplySpeechEvent, _ mine: Int) {
        guard generation == mine, event.id == clientTurnID else { return }
        let voice = chosenReader === pocketInstance && pocketInstance != nil ? "pocket" : "system"
        trace("reply event state=\(event.state.rawValue) reason=\(event.reason ?? "-") speaker=\(voice)")
        if chosenReader != nil, chosenReader !== speaker, Self.couldNotPlay(event) {
            rescueWithSystemVoice()
            return
        }
        switch event.state {
        case .started:
            return
        case .finished, .stopped, .unheard:
            guard replyFinal else { return }
            Task { @MainActor in await self.finish(mine) }
        }
    }

    /// Pocket's own failures (`PocketSpeaker`): it could not synthesise or
    /// could not reach the speaker. A stop for any other reason is not one.
    static func couldNotPlay(_ event: ReplySpeechEvent) -> Bool {
        event.state == .unheard || ["synthesis_failed", "audio_unavailable"].contains(event.reason ?? "")
    }

    private func rescueWithSystemVoice() {
        guard let clientTurnID else { return }
        trace("reply rescued by system voice parts=\(sentences.count)")
        let mine = generation
        chosenReader = speaker
        speaker.onEvent = { [weak self] event in self?.readerEvent(event, mine) }
        speaker.begin(id: clientTurnID, voiceID: nil)
        for (index, sentence) in sentences.enumerated() { speaker.append(id: clientTurnID, seq: index, text: sentence) }
        if replyFinal { speaker.finish(id: clientTurnID) }
    }

    private func speak(_ sentence: String) {
        guard let clientTurnID else { return }
        if seq == 0 {
            let mine = generation
            // The voice the person last picked in the Voice tab (device rev 3).
            let pick = replyVoice()
            chosenReader = pick.pocket ? pocketReader() : speaker
            trace("reply voice pocket=\(pick.pocket) fell_back=\(pick.reason ?? "-")")
            reader.onEvent = { [weak self] event in self?.readerEvent(event, mine) }
            reader.begin(id: clientTurnID, voiceID: pick.voiceID)
        }
        reader.append(id: clientTurnID, seq: seq, text: sentence)
        sentences.append(sentence)
        seq += 1
        lastSentence = sentence
        phase = .speaking
        activity.update(state(.speaking, reply: sentence))
        trace("speaking parts=\(seq)")
    }

    private func finish(_ mine: Int) async {
        guard generation == mine, phase == .thinking || phase == .speaking else { return }
        phase = .finished
        activity.update(state(.finished, reply: lastSentence))
        trace("finished parts=\(seq)")
        releaseAll()
        await sleep(finishedHold)
        guard generation == mine, phase == .finished else { return }
        activity.end(state(.ended, reply: lastSentence), dismissAfter: Self.endedDismissAfter)
        phase = .idle
        trace("ended")
    }

    // MARK: Cancel

    /// Cancel: the activity ends at once and nothing is sent.
    func cancel(reason: String = "cancelled") {
        guard phase != .idle else { return }
        trace("cancel reason=\(reason)")
        generation += 1
        transcriber.cancel()
        reader.stop(reason: reason)
        activity.end(state(.ended, reply: lastSentence), dismissAfter: nil)
        phase = .idle
        releaseAll()
    }

    private func interruptCurrent(reason: String) {
        trace("interrupt reason=\(reason)")
        generation += 1
        transcriber.cancel()
        reader.stop(reason: reason)
        activity.end(state(.ended, reply: lastSentence), dismissAfter: nil)
        phase = .idle
        releaseAll()
    }

    /// The mic and the session are released at every end.
    private func releaseAll() {
        session.deactivate()
        if backgroundTask != .invalid {
            backgroundTasks.end(backgroundTask)
            backgroundTask = .invalid
        }
        VoiceCoordinator.stopRunner = nil
    }
}

// MARK: - Live seams

@MainActor
final class LiveVoiceTurnAPI: VoiceTurnAPI {
    var installs: () -> [Install] = { InstallStore.shared.installs }
    var client = BurrowAPIClient.shared
    var cache = VoicePartnerCache()
    /// The long-poll window (the client's request timeout is 20 s).
    var waitMs = 15_000

    func partner() async -> VoicePartnerChoice? {
        await VoicePartnerResolver.newest(installs: installs(), client: client, cache: cache)
    }

    func send(_ partner: VoicePartnerChoice, text: String, clientTurnID: String) async throws -> VoiceTurnPosted {
        try await client.sendVoiceTurn(host: partner.host, agentID: partner.agentID, text: text, clientTurnID: clientTurnID)
    }

    func reply(_ partner: VoicePartnerChoice, clientTurnID: String, spoken: Int) async throws -> VoiceReplyPoll {
        try await client.voiceReply(host: partner.host, clientTurnID: clientTurnID, spoken: spoken, waitMs: waitMs)
    }
}

/// The real Live Activity (ActivityKit). Requesting from the background is
/// allowed only to an `AudioRecordingIntent` / `LiveActivityIntent`.
@MainActor
final class ActivityKitVoiceActivity: VoiceActivityControlling {
    enum Failure: Error { case unavailable }

    #if canImport(ActivityKit)
        private var current: Any?
    #endif

    var areActivitiesEnabled: Bool {
        #if canImport(ActivityKit)
            return ActivityAuthorizationInfo().areActivitiesEnabled
        #else
            return false
        #endif
    }

    func start(partner: String, installLabel: String?, host: String, state: VoiceActivityState) throws {
        #if canImport(ActivityKit)
            let attributes = VoiceActivityAttributes(partnerName: partner, installLabel: installLabel, host: host)
            current = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: nil)
        #else
            throw Failure.unavailable
        #endif
    }

    func update(_ state: VoiceActivityState) {
        #if canImport(ActivityKit)
            guard let activity = current as? Activity<VoiceActivityAttributes> else { return }
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        #endif
    }

    func end(_ state: VoiceActivityState, dismissAfter: TimeInterval?) {
        #if canImport(ActivityKit)
            guard let activity = current as? Activity<VoiceActivityAttributes> else { return }
            current = nil
            let policy: ActivityUIDismissalPolicy = dismissAfter.map { .after(Date().addingTimeInterval($0)) } ?? .immediate
            Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy) }
        #endif
    }
}
