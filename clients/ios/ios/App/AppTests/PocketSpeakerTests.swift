import AVFoundation
import CryptoKit
import UIKit
import XCTest

@testable import App

/// An audio session that always activates and has a speaker route.
private final class OpenBackend: VoiceAudioSessionBackend {
    var category: AVAudioSession.Category = .ambient
    var mode: AVAudioSession.Mode = .default
    var categoryOptions: AVAudioSession.CategoryOptions = []
    var routePortTypes: [AVAudioSession.Port] = [.builtInMic, .builtInSpeaker]
    var hasOutputRoute = true
    var isOtherAudioPlaying = false
    private(set) var activations: [Bool] = []

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {
        self.category = category
        self.mode = mode
        categoryOptions = options
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws { activations.append(active) }
}

/// The model, with every sentence it was asked for. A sentence listed in
/// `hold` waits until `release(_:)`, so a test can see what plays meanwhile.
@MainActor
private final class FakeEngine: PocketEngine {
    private(set) var texts: [String] = []
    /// The voice each sentence was synthesized in.
    private(set) var voices: [String] = []
    private(set) var loads = 0
    private(set) var releases = 0
    var hold: Set<String> = []
    var failLoad = false
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]

    func load() async throws {
        loads += 1
        if failLoad { throw PocketEngineError.unavailable }
    }

    func synthesize(_ text: String, voice: String) async throws -> PocketPCM {
        texts.append(text)
        voices.append(voice)
        if hold.contains(text) {
            await withCheckedContinuation { waiting[text] = $0 }
        }
        return PocketPCM(samples: Self.sentencePCM, sampleRate: 24_000)
    }

    /// What the decoder gives for every sentence: the start-up burst in the
    /// first 80 ms (1,920 samples, peaking at 0.15 like the measured one),
    /// near silence, then 100 ms of speech-level signal.
    static let sentencePCM: [Float] =
        (0..<1_920).map { i in i % 2 == 0 ? 0.15 : -0.15 } + [Float](repeating: 0.0002, count: 1_680)
        + (0..<2_400).map { i in Float(sin(Double(i) * 0.2)) * 0.5 }

    func release(_ text: String) {
        hold.remove(text)
        waiting.removeValue(forKey: text)?.resume()
    }

    func release() { releases += 1 }
}

/// The player: what was scheduled, and its completions. Like
/// AVAudioPlayerNode, `stop()` also runs every pending completion.
@MainActor
private final class FakeOutput: PocketAudioOutput {
    private(set) var scheduled = 0
    private(set) var starts = 0
    private(set) var stops = 0
    /// Every buffer handed to the player, in order.
    private(set) var buffers: [[Float]] = []
    private var pending: [@Sendable () -> Void] = []

    func start(sampleRate: Int) throws { starts += 1 }

    func schedule(_ samples: [Float], played: @escaping @Sendable () -> Void) {
        scheduled += 1
        buffers.append(samples)
        pending.append(played)
    }

    /// The oldest scheduled buffer has been heard.
    func playOne() {
        guard !pending.isEmpty else { return }
        pending.removeFirst()()
    }

    func stop() {
        stops += 1
        let dropped = pending
        pending = []
        for played in dropped { played() }
    }
}

/// Serves fixed bytes per URL, from `offset`, in `chunk`-sized steps. A URL
/// in `blocked` never completes (a download still in flight).
private final class FakeFetcher: PocketFileFetching, @unchecked Sendable {
    var bodies: [URL: Data] = [:]
    var blocked: Set<URL> = []
    var chunk = 7
    private(set) var offsets: [URL: [Int64]] = [:]
    private let lock = NSLock()

    func fetch(_ url: URL, to staging: URL, from offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        lock.withLock { offsets[url, default: []].append(offset) }
        if blocked.contains(url) {
            while !Task.isCancelled { try await Task.sleep(nanoseconds: 50_000_000) }
            throw CancellationError()
        }
        guard let body = bodies[url] else { throw PocketFetchError.http(404) }
        if !FileManager.default.fileExists(atPath: staging.path) { FileManager.default.createFile(atPath: staging.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }
        var at = Int(try handle.seekToEnd())
        while at < body.count {
            let end = min(at + chunk, body.count)
            try handle.write(contentsOf: body.subdata(in: at..<end))
            at = end
            progress(Int64(at))
            await Task.yield()
        }
    }
}

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private func url(_ file: PocketTTSFile) -> URL { URL(string: "https://example.invalid/\(file.repo)/\(file.path)")! }

/// Yields until the main actor has run what is queued.
@MainActor
private func settle() async {
    for _ in 0..<40 { await Task.yield() }
}

@MainActor
final class PocketSpeakerTests: XCTestCase {
    private var root: URL!
    private var engine: FakeEngine!
    private var output: FakeOutput!
    private var backend: OpenBackend!
    private var center: NotificationCenter!
    private var events: [(name: String, data: [String: Any])] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pocket-tests-\(UUID().uuidString)")
        engine = FakeEngine()
        output = FakeOutput()
        backend = OpenBackend()
        center = NotificationCenter()
        events = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let bodyA = Data("first model file, some bytes".utf8)
    private let bodyB = Data("second file: the voice embedding".utf8)

    private func files(shaB: String? = nil) -> [PocketTTSFile] {
        [
            PocketTTSFile(repo: .bundles, path: "a.aimodel/main.mlirb", size: bodyA.count, sha256: sha(bodyA)),
            PocketTTSFile(repo: .weights, path: "languages/english/embeddings/marius.safetensors", size: bodyB.count, sha256: shaB ?? sha(bodyB)),
        ]
    }

    private func makeStore(_ files: [PocketTTSFile], _ fetcher: FakeFetcher) -> PocketModelStore {
        for file in files where fetcher.bodies[url(file)] == nil {
            fetcher.bodies[url(file)] = file.repo == .bundles ? bodyA : bodyB
        }
        return PocketModelStore(root: root, files: files, fetcher: fetcher, engine: engine, urlFor: { url($0) })
    }

    private let voiceBody = Data("another voice's embedding".utf8)
    /// Every voice store the plugin made, by voice name.
    private var voiceStores: [String: PocketModelStore] = [:]

    /// A plugin with Pocket TTS supported. `store` nil: an empty manifest,
    /// so the model is `ready` from the start. A voice other than the default
    /// is fetched by `voiceFetcher` (a stand-in body in place of its 6 MB).
    private func makePlugin(supported: Bool = true, store: PocketModelStore? = nil, voiceFetcher: FakeFetcher = FakeFetcher()) -> (
        BurrowVoicePlugin, ReplySpeakerSpy
    ) {
        let plugin = BurrowVoicePlugin()
        let system = ReplySpeakerSpy()
        plugin.speaker = system
        plugin.voiceCatalog = SpyVoices()
        plugin.languageCode = { "en-US" }
        plugin.session = VoiceAudioSession(backend: backend)
        plugin.callState = { NoCall() }
        plugin.micPermission = { true }
        plugin.micPermissionStatus = { "granted" }
        plugin.isTestBuild = { true }
        plugin.haptic = {}
        plugin.transcriber = SilentTranscriber()
        plugin.notificationCenter = center
        plugin.eventSink = { [unowned self] name, data in self.events.append((name, data)) }
        plugin.pocketGate = { supported ? (true, nil) : (false, "low_memory") }
        let engine = engine!
        let output = output!
        plugin.pocketEngine = engine
        plugin.makePocketSpeaker = { PocketSpeaker(engine: $0, output: output) }
        let made = store ?? makeStore([], FakeFetcher())
        plugin.makePocketStore = { _ in made }
        let root = root!
        let body = voiceBody
        plugin.makePocketVoiceStore = { [unowned self] file in
            let stand = PocketTTSFile(repo: file.repo, path: file.path, size: body.count, sha256: sha(body))
            if voiceFetcher.bodies[url(stand)] == nil { voiceFetcher.bodies[url(stand)] = body }
            let voiceStore = PocketModelStore(
                root: root, files: [stand], fetcher: voiceFetcher, engine: PocketVoiceFileLoader(), urlFor: { url($0) })
            self.voiceStores[(file.path as NSString).lastPathComponent.replacingOccurrences(of: ".safetensors", with: "")] = voiceStore
            return voiceStore
        }
        plugin.load()
        return (plugin, system)
    }

    private var speech: [[String: Any]] { events.filter { $0.name == "speech" }.map(\.data) }
    private func states(_ id: String) -> [String] { speech.filter { $0["id"] as? String == id }.compactMap { $0["state"] as? String } }

    // MARK: Streaming

    /// Plan test 1: sentence 0 is heard before the reply is final.
    func testSpeakPartSeqZeroStartsPlaybackBeforeFinal() async {
        let (plugin, _) = makePlugin()
        let result = plugin.speakPart(id: "r1", seq: 0, text: "First sentence.", final: false, voice: PocketVoice.id)
        XCTAssertEqual(result["voice"] as? String, PocketVoice.id)
        XCTAssertEqual(result["fellBack"] as? Bool, false)
        await settle()
        XCTAssertEqual(output.scheduled, 1, "seq 0 is scheduled without waiting for final")
        XCTAssertEqual(states("r1"), ["started"])
        XCTAssertEqual(engine.texts, ["First sentence."])
        XCTAssertEqual(engine.voices, ["marius"])
    }

    func testSentenceOnePlaysWhileSentenceTwoSynthesizes() async {
        let (plugin, _) = makePlugin()
        engine.hold = ["Two."]
        _ = plugin.speakPart(id: "r1", seq: 0, text: "One.", final: false, voice: PocketVoice.id)
        _ = plugin.speakPart(id: "r1", seq: 1, text: "Two.", final: true, voice: PocketVoice.id)
        await settle()
        XCTAssertEqual(engine.texts, ["One.", "Two."], "sentence 2 is being synthesized")
        XCTAssertEqual(output.scheduled, 1, "while sentence 1 is already playing")
        engine.release("Two.")
        await settle()
        XCTAssertEqual(output.scheduled, 2)
        output.playOne()
        output.playOne()
        await settle()
        XCTAssertEqual(states("r1"), ["started", "finished"])
    }

    func testOutOfOrderPartsAreSpokenInSeqOrder() async {
        let (plugin, _) = makePlugin()
        _ = plugin.speakPart(id: "r1", seq: 0, text: "Zero.", final: false, voice: PocketVoice.id)
        _ = plugin.speakPart(id: "r1", seq: 2, text: "Two.", final: false, voice: PocketVoice.id)
        _ = plugin.speakPart(id: "r1", seq: 1, text: "One.", final: true, voice: PocketVoice.id)
        await settle()
        XCTAssertEqual(engine.texts, ["Zero.", "One.", "Two."])
    }

    /// Plan test 2: the mic mid-stream: exactly one `stopped` (mic_opened), and
    /// no queued or later part of that reply is ever spoken.
    func testMicMidStreamSendsOneStoppedAndDropsTheQueuedParts() async {
        let (plugin, _) = makePlugin()
        engine.hold = ["Two."]
        _ = plugin.speakPart(id: "r1", seq: 0, text: "One.", final: false, voice: PocketVoice.id)
        _ = plugin.speakPart(id: "r1", seq: 1, text: "Two.", final: false, voice: PocketVoice.id)
        _ = plugin.speakPart(id: "r1", seq: 2, text: "Three.", final: false, voice: PocketVoice.id)
        await settle()
        _ = await plugin.startTurn()
        engine.release("Two.")
        await settle()
        // Released: the mic is closed again, so only the dropped-reply rule
        // keeps the rest of r1 from starting mid-reply.
        _ = await plugin.stopTurn()
        let late = plugin.speakPart(id: "r1", seq: 3, text: "Four.", final: true, voice: PocketVoice.id)
        await settle()
        XCTAssertEqual(late["spoken"] as? Bool, false)
        XCTAssertEqual(late["reason"] as? String, "stopped")
        let stopped = speech.filter { $0["state"] as? String == "stopped" }
        XCTAssertEqual(stopped.count, 1, "\(speech)")
        XCTAssertEqual(stopped.first?["reason"] as? String, "mic_opened")
        XCTAssertEqual(output.scheduled, 1, "Two. finished synthesizing after the stop and was dropped")
        XCTAssertEqual(engine.texts, ["One.", "Two."], "Three. and Four. never reach the model")
    }

    /// A late buffer completion (AVAudioPlayerNode runs them on stop) never
    /// sends a second event.
    func testStopSendsExactlyOneStoppedEvenWhenCompletionsFireAfter() async {
        let speaker = PocketSpeaker(engine: engine, output: output)
        var got: [ReplySpeechEvent] = []
        speaker.onEvent = { got.append($0) }
        speaker.speak(id: "r1", text: "One. Two.", voiceID: nil)
        await settle()
        speaker.stop(reason: "stopped")
        speaker.stop(reason: "again")
        output.playOne()
        await settle()
        XCTAssertEqual(got.map(\.state), [.started, .stopped])
        XCTAssertEqual(got.last?.reason, "stopped")
        XCTAssertFalse(speaker.isSpeaking)
    }

    /// The old reply's buffer completions (run by the player's stop when the
    /// next reply replaces it) must not count toward the new reply: that
    /// would end it before its audio is heard. Added after mutant M2b (no
    /// generation guard on completions) survived the first suite.
    func testAReplacedReplysLateCompletionDoesNotFinishTheNextReply() async {
        let speaker = PocketSpeaker(engine: engine, output: output)
        var got: [ReplySpeechEvent] = []
        speaker.onEvent = { got.append($0) }
        speaker.speak(id: "r1", text: "One.", voiceID: nil)
        await settle()
        speaker.speak(id: "r2", text: "Two.", voiceID: nil)
        await settle()
        XCTAssertEqual(got.filter { $0.id == "r2" }.map(\.state), [.started], "r2 is still playing")
        XCTAssertTrue(speaker.isSpeaking)
        output.playOne()
        await settle()
        XCTAssertEqual(got.filter { $0.id == "r2" }.map(\.state), [.started, .finished])
    }

    /// The click at the start of every sentence (task 01a20fdd stage 4): every
    /// buffer the player gets, a sentence in the MIDDLE of a reply included,
    /// starts without the decoder's start-up frame and fades in from silence.
    func testEverySentenceIsScheduledWithoutTheStartupBurstAndFadesIn() async {
        let speaker = PocketSpeaker(engine: engine, output: output)
        speaker.begin(id: "r1", voiceID: nil)
        speaker.append(id: "r1", seq: 0, text: "One.")
        speaker.append(id: "r1", seq: 1, text: "Two.")
        speaker.append(id: "r1", seq: 2, text: "Three.")
        speaker.finish(id: "r1")
        await settle()
        XCTAssertEqual(output.buffers.count, 3)
        let raw = FakeEngine.sentencePCM
        for (n, buffer) in output.buffers.enumerated() {
            XCTAssertEqual(buffer.count, raw.count - 1_920, "sentence \(n): the start-up frame is dropped")
            XCTAssertEqual(buffer.first, 0, "sentence \(n) starts from silence")
            let firstMs = buffer.prefix(24).map(abs).max() ?? 1
            XCTAssertLessThan(firstMs, 0.001, "sentence \(n): no burst in the first millisecond")
            let ramp = buffer.prefix(240).map(abs)
            XCTAssertLessThan(ramp.max() ?? 1, 0.15, "sentence \(n): nothing as loud as the burst while it fades in")
            XCTAssertEqual(buffer.last ?? 1, 0, accuracy: 1e-6, "sentence \(n) ends on silence")
        }
    }

    func testShapingAShortBufferYieldsNothingAndKeepsTheRest() {
        XCTAssertEqual(PocketSpeaker.shaped([Float](repeating: 0.5, count: 1_000), sampleRate: 24_000), [])
        let out = PocketSpeaker.shaped([Float](repeating: 0.5, count: 1_920 + 1_000), sampleRate: 24_000)
        XCTAssertEqual(out.count, 1_000)
        XCTAssertEqual(out[0], 0)
        XCTAssertEqual(out[500], 0.5, "the middle is untouched")
    }

    /// Plan test 3: AirPods out stops Pocket TTS (reason as today).
    func testRouteLossStopsPocketSpeech() async {
        let (plugin, _) = makePlugin()
        _ = plugin.speakPart(id: "r1", seq: 0, text: "One.", final: false, voice: PocketVoice.id)
        await settle()
        center.post(
            name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        await settle()
        XCTAssertEqual(states("r1"), ["started", "stopped"])
        XCTAssertEqual(speech.last?["reason"] as? String, "route_lost")
        XCTAssertGreaterThanOrEqual(output.stops, 1)
    }

    /// Plan test 4: backgrounding stops it and releases the session.
    func testBackgroundStopsPocketSpeechAndReleasesTheSession() async {
        let (plugin, _) = makePlugin()
        _ = plugin.speakPart(id: "r1", seq: 0, text: "One.", final: false, voice: PocketVoice.id)
        await settle()
        XCTAssertEqual(backend.activations, [true])
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await settle()
        XCTAssertEqual(speech.last?["reason"] as? String, "background")
        XCTAssertEqual(backend.activations, [true, false], "the session is released")
    }

    func testAFinishedPocketReplyReleasesTheSession() async {
        let (plugin, _) = makePlugin()
        _ = plugin.speakReply(id: "r1", text: "Only one sentence.", voice: PocketVoice.id)
        await settle()
        output.playOne()
        await settle()
        XCTAssertEqual(states("r1"), ["started", "finished"])
        XCTAssertEqual(backend.activations, [true, false])
    }

    func testMemoryWarningReleasesTheIdleModel() async {
        let (plugin, _) = makePlugin()
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        await settle()
        XCTAssertEqual(engine.releases, 1)
        withExtendedLifetime(plugin) {}
    }

    // MARK: Fallback and the gate

    /// Plan test 5: the Pocket voice while downloading reads with the system
    /// voice and says so; the download keeps going.
    func testPocketVoiceWhileDownloadingSpeaksWithTheSystemVoiceAndFallsBack() async {
        let fetcher = FakeFetcher()
        let store = makeStore(files(), fetcher)
        fetcher.blocked = [url(files()[0])]
        let (plugin, system) = makePlugin(store: store)
        let result = plugin.speakReply(id: "r1", text: "Hello.", voice: PocketVoice.id)
        await settle()
        XCTAssertEqual(store.state.name, "downloading", "picking Pocket started the download")
        XCTAssertEqual(result["fellBack"] as? Bool, true)
        XCTAssertEqual(result["reason"] as? String, "model_not_ready")
        XCTAssertEqual(result["voice"] as? String, "en-best")
        XCTAssertEqual(system.spoken, ["r1"], "the system voice reads it")
        XCTAssertEqual(output.scheduled, 0)
        XCTAssertTrue(engine.texts.isEmpty)
        let part = plugin.speakPart(id: "r2", seq: 0, text: "Hi.", final: true, voice: PocketVoice.id)
        XCTAssertEqual(part["reason"] as? String, "model_not_ready")
        XCTAssertEqual(system.begun, ["r2"])
    }

    /// Plan test 6: an unsupported gate omits the Pocket row, downloads nothing.
    func testUnsupportedGateOmitsThePocketRow() async {
        let fetcher = FakeFetcher()
        let (plugin, _) = makePlugin(supported: false, store: makeStore(files(), fetcher))
        let ids = (plugin.voiceList()["voices"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, ["en-best"])
        let prepared = plugin.prepareModel()
        XCTAssertEqual(prepared["state"] as? String, "absent")
        XCTAssertEqual(prepared["reason"] as? String, "low_memory")
        let spoken = plugin.speakReply(id: "r1", text: "Hi.", voice: PocketVoice.id)
        XCTAssertEqual(spoken["reason"] as? String, "unsupported")
        await settle()
        XCTAssertTrue(fetcher.offsets.isEmpty, "nothing is downloaded")
    }

    func testSupportedGateListsPocketFirstWithItsModelButKeepsTheSystemDefault() {
        let (plugin, _) = makePlugin(store: makeStore(files(), FakeFetcher()))
        let list = plugin.voiceList()
        let rows = list["voices"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.first?["id"] as? String, "pocket-tts:marius")
        XCTAssertEqual(rows.first?["name"] as? String, "Pocket TTS (Marius)")
        XCTAssertEqual(rows.first?["quality"] as? String, "neural")
        let model = rows.first?["model"] as? [String: Any]
        XCTAssertEqual(model?["state"] as? String, "absent")
        XCTAssertEqual(model?["total"] as? Int64, Int64(bodyA.count + bodyB.count))
        XCTAssertEqual(list["default"] as? String, "en-best")
    }

    // MARK: More voices (task 01a20fdd stage 4)

    private func ids(_ list: [String: Any]) -> [String] {
        (list["voices"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    }

    func testTheListCarriesEveryLicensedVoiceTheDefaultFirstAndEachItsOwnModel() {
        let (plugin, _) = makePlugin()
        let rows = plugin.voiceList()["voices"] as? [[String: Any]] ?? []
        let pocket = rows.filter { ($0["id"] as? String).map(PocketVoice.isPocket) == true }
        XCTAssertEqual(pocket.count, 20)
        XCTAssertEqual(pocket.first?["id"] as? String, "pocket-tts:marius")
        let names = pocket.compactMap { $0["name"] as? String }
        XCTAssertEqual(Array(names.dropFirst()), Array(names.dropFirst()).sorted(), "the others by name")
        XCTAssertTrue(names.contains("Pocket TTS (Peter Yearsley)"))
        XCTAssertEqual(rows.last?["id"] as? String, "en-best", "the system voices follow")
        let model = { (id: String) in pocket.first { $0["id"] as? String == id }?["model"] as? [String: Any] }
        XCTAssertEqual(model("pocket-tts:marius")?["state"] as? String, "ready", "comes with the model")
        XCTAssertEqual(model("pocket-tts:alba")?["state"] as? String, "absent", "not fetched until picked")
        XCTAssertEqual(model("pocket-tts:alba")?["total"] as? Int64, Int64(voiceBody.count))
        XCTAssertTrue(voiceStores.values.allSatisfy { $0.state == .absent }, "listing fetches nothing")
    }

    /// Picking a voice that is not on the phone fetches it; a reply meanwhile
    /// is read by the system voice; once it is in place Pocket reads in it.
    func testPickingAnUndownloadedVoiceFetchesItAndTheSystemVoiceReadsMeanwhile() async {
        let fetcher = FakeFetcher()
        let (plugin, system) = makePlugin(voiceFetcher: fetcher)
        let albaURL = url(PocketTTSFile(repo: .weights, path: "languages/english/embeddings/alba.safetensors", size: 0, sha256: ""))
        fetcher.blocked = [albaURL]
        let picked = plugin.prepareModel(voice: "pocket-tts:alba")
        await settle()
        XCTAssertEqual(picked["total"] as? Int64, Int64(voiceBody.count), "the voice's own bytes, not the model's")
        XCTAssertEqual(voiceStores["alba"]?.state.name, "downloading")
        XCTAssertEqual(fetcher.offsets[albaURL], [0])
        let meanwhile = plugin.speakReply(id: "r1", text: "Hello.", voice: "pocket-tts:alba")
        XCTAssertEqual(meanwhile["voice"] as? String, "en-best")
        XCTAssertEqual(meanwhile["fellBack"] as? Bool, true)
        XCTAssertEqual(meanwhile["reason"] as? String, "model_not_ready")
        XCTAssertEqual(system.spoken, ["r1"], "the system voice reads it")
        XCTAssertTrue(engine.texts.isEmpty)
        XCTAssertNil(voiceStores["javert"], "no other voice is touched")
        withExtendedLifetime(plugin) {}
    }

    func testAPickedVoiceOnceFetchedReadsTheReplyInThatVoice() async {
        let fetcher = FakeFetcher()
        let (plugin, _) = makePlugin(voiceFetcher: fetcher)
        _ = plugin.prepareModel(voice: "pocket-tts:alba")
        await voiceStores["alba"]?.waitForJob()
        XCTAssertEqual(voiceStores["alba"]?.state, .ready)
        let models = events.filter { $0.name == "model" }.map(\.data)
        XCTAssertEqual(models.last?["state"] as? String, "ready", "the picker hears the voice is ready")
        XCTAssertEqual(models.last?["total"] as? Int64, Int64(voiceBody.count))
        let result = plugin.speakReply(id: "r1", text: "Hello there.", voice: "pocket-tts:alba")
        XCTAssertEqual(result["voice"] as? String, "pocket-tts:alba")
        XCTAssertEqual(result["fellBack"] as? Bool, false)
        await settle()
        XCTAssertEqual(engine.voices, ["alba"])
        XCTAssertEqual(output.scheduled, 1)
    }

    /// The page may not name the voice when it is picked: the first reply in
    /// it then starts the fetch, and the system voice reads that reply.
    func testAReplyInAnUnfetchedVoiceStartsItsFetch() async {
        let fetcher = FakeFetcher()
        let (plugin, system) = makePlugin(voiceFetcher: fetcher)
        let part = plugin.speakPart(id: "r1", seq: 0, text: "Hi.", final: true, voice: "pocket-tts:george")
        XCTAssertEqual(part["reason"] as? String, "model_not_ready")
        XCTAssertEqual(system.begun, ["r1"])
        await voiceStores["george"]?.waitForJob()
        XCTAssertEqual(voiceStores["george"]?.state, .ready)
    }

    func testAnExcludedVoiceIsNeverListedFetchedOrSpoken() async {
        let fetcher = FakeFetcher()
        let (plugin, system) = makePlugin(voiceFetcher: fetcher)
        let listed = ids(plugin.voiceList())
        for name in ["cosette", "jean", "giovanni", "lola", "juergen", "rafael"] {
            XCTAssertFalse(listed.contains(PocketVoice.prefix + name), name)
        }
        _ = plugin.prepareModel(voice: "pocket-tts:cosette")
        let result = plugin.speakReply(id: "r1", text: "Hello.", voice: "pocket-tts:cosette")
        await settle()
        XCTAssertEqual(result["voice"] as? String, "en-best")
        XCTAssertEqual(result["reason"] as? String, "unknown_voice")
        XCTAssertEqual(system.spoken, ["r1"])
        XCTAssertNil(voiceStores["cosette"])
        XCTAssertFalse(fetcher.offsets.keys.contains { $0.path.contains("cosette") })
        XCTAssertTrue(engine.texts.isEmpty)
    }

    /// Until the model itself is ready every Pocket row shows its progress.
    func testBeforeTheModelIsReadyEveryRowShowsTheModelsProgress() {
        let (plugin, _) = makePlugin(store: makeStore(files(), FakeFetcher()))
        let rows = (plugin.voiceList()["voices"] as? [[String: Any]] ?? []).filter { ($0["id"] as? String).map(PocketVoice.isPocket) == true }
        XCTAssertEqual(rows.count, 20)
        for row in rows {
            let model = row["model"] as? [String: Any]
            XCTAssertEqual(model?["state"] as? String, "absent")
            XCTAssertEqual(model?["total"] as? Int64, Int64(bodyA.count + bodyB.count), row["id"] as? String ?? "")
        }
    }

    func testPocketIsNotListedForANonEnglishLanguage() {
        let (plugin, _) = makePlugin()
        plugin.languageCode = { "fr-FR" }
        let ids = (plugin.voiceList()["voices"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        XCTAssertFalse(ids.contains(PocketVoice.id))
    }

    func testResolveMapsPocketToTheBestSystemVoiceUnlessReady() {
        let all = [ReplyVoice(id: "en-best", name: "Zoe", quality: .premium, language: "en-US")]
        let ready = ReplyVoicePicker.resolve(requested: PocketVoice.id, language: "en-US", in: all, pocket: .ready)
        XCTAssertEqual(ready.voice?.id, PocketVoice.id)
        XCTAssertFalse(ready.fellBack)
        let waiting = ReplyVoicePicker.resolve(requested: PocketVoice.id, language: "en-US", in: all, pocket: .notReady)
        XCTAssertEqual(waiting.voice?.id, "en-best")
        XCTAssertTrue(waiting.fellBack)
        XCTAssertEqual(waiting.reason, "model_not_ready")
        let refused = ReplyVoicePicker.resolve(requested: PocketVoice.id, language: "en-US", in: all, pocket: .unsupported)
        XCTAssertEqual(refused.reason, "unsupported")
        let system = ReplyVoicePicker.resolve(requested: "en-best", language: "en-US", in: all, pocket: .ready)
        XCTAssertEqual(system.voice?.id, "en-best")
        XCTAssertNil(system.reason)
    }

    func testNeuralRanksAbovePremium() {
        XCTAssertLessThan(ReplyVoice.Quality.neural.rank, ReplyVoice.Quality.premium.rank)
        XCTAssertEqual(ReplyVoice.Quality.allCases.first, .neural)
    }

    // MARK: Model store

    /// Plan test 7: a sha mismatch is `failed(checksum)`, and the file is never
    /// moved into place (nor left as a part).
    func testShaMismatchFailsChecksumAndNothingIsMovedIntoPlace() async {
        let bad = files(shaB: String(repeating: "0", count: 64))
        let store = makeStore(bad, FakeFetcher())
        store.prepare()
        await store.waitForJob()
        XCTAssertEqual(store.state, .failed("checksum"))
        let local = store.localURL(bad[1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path), "never moved into place")
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathExtension("part").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.localURL(bad[0]).path), "the good file before it is kept")
        XCTAssertEqual(engine.loads, 0, "nothing is loaded")
    }

    /// Plan test 8: `model` progress only ever goes up, ends at the total,
    /// then compiling and ready.
    func testModelProgressEventsAreMonotonic() async {
        let fetcher = FakeFetcher()
        fetcher.chunk = 5
        let store = makeStore(files(), fetcher)
        var seen: [PocketModelStore.State] = []
        store.onChange = { seen.append($0) }
        store.prepare()
        await store.waitForJob()
        let received = seen.compactMap { state -> Int64? in
            if case .downloading(let got, _) = state { return got }
            return nil
        }
        XCTAssertGreaterThan(received.count, 4)
        XCTAssertEqual(received, received.sorted(), "never backwards")
        XCTAssertEqual(Set(received).count, received.count, "no repeated step")
        XCTAssertEqual(received.last, Int64(bodyA.count + bodyB.count))
        XCTAssertEqual(Array(seen.suffix(2)), [.compiling, .ready])
        XCTAssertEqual(engine.loads, 1)
    }

    func testPluginForwardsModelEventsToThePage() async {
        let store = makeStore(files(), FakeFetcher())
        let (plugin, _) = makePlugin(store: store)
        _ = plugin.prepareModel()
        await store.waitForJob()
        let models = events.filter { $0.name == "model" }.map(\.data)
        XCTAssertEqual(models.last?["state"] as? String, "ready")
        XCTAssertEqual(models.first?["state"] as? String, "downloading")
    }

    func testAnInterruptedDownloadResumesFromThePart() async throws {
        let fetcher = FakeFetcher()
        let list = files()
        let store = makeStore(list, fetcher)
        let part = store.localURL(list[0]).appendingPathExtension("part")
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bodyA.prefix(10).write(to: part)
        store.prepare()
        await store.waitForJob()
        XCTAssertEqual(fetcher.offsets[url(list[0])], [10], "asked only for the rest")
        XCTAssertEqual(try Data(contentsOf: store.localURL(list[0])), bodyA)
        XCTAssertEqual(store.state, .ready)
    }

    func testFilesLiveUnderTheRevisionAndAreExcludedFromBackup() async throws {
        let list = files()
        let store = makeStore(list, FakeFetcher())
        store.prepare()
        await store.waitForJob()
        let local = store.localURL(list[1])
        XCTAssertEqual(local.path, root.appendingPathComponent("\(PocketTTSManifest.weightsRevision)/\(list[1].path)").path)
        XCTAssertEqual(try local.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertTrue(PocketModelStore.defaultRoot().path.contains("Library/Application Support/PocketTTS"))
    }

    func testFilesAlreadyInPlaceAreReadyWithoutAFetch() async throws {
        let list = files()
        let first = makeStore(list, FakeFetcher())
        first.prepare()
        await first.waitForJob()
        let fetcher = FakeFetcher()
        let again = makeStore(list, fetcher)
        XCTAssertEqual(again.state, .ready)
        again.prepare()
        await again.waitForJob()
        XCTAssertTrue(fetcher.offsets.isEmpty)
    }

    func testALoadFailureIsFailedLoad() async {
        engine.failLoad = true
        let store = makeStore(files(), FakeFetcher())
        store.prepare()
        await store.waitForJob()
        XCTAssertEqual(store.state, .failed("load"))
    }

    // MARK: Pure parts

    func testPartQueueReleasesInOrderAndDropsRepeats() {
        var queue = ReplyPartQueue()
        XCTAssertEqual(queue.add(seq: 1, text: "b"), [])
        XCTAssertEqual(queue.add(seq: 0, text: "a"), ["a", "b"])
        XCTAssertEqual(queue.add(seq: 0, text: "a"), [], "a repeat is dropped")
        XCTAssertEqual(queue.add(seq: 3, text: "d"), [])
        XCTAssertEqual(queue.flush(), ["d"])
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.add(seq: 4, text: "e"), ["e"])
    }

    func testOneShotTextIsSplitIntoSentences() {
        XCTAssertEqual(PocketSpeaker.sentences("Hello there. How are you? Fine!"), ["Hello there.", "How are you?", "Fine!"])
        XCTAssertEqual(PocketSpeaker.sentences("no terminal punctuation"), ["no terminal punctuation"])
        XCTAssertEqual(PocketSpeaker.sentences(""), [])
    }
}

// MARK: - Plugin collaborators

@MainActor
final class ReplySpeakerSpy: VoiceSpeaking {
    var onEvent: ((ReplySpeechEvent) -> Void)?
    private(set) var spoken: [String] = []
    private(set) var begun: [String] = []
    private var id: String?
    var isSpeaking: Bool { id != nil }

    func speak(id: String, text: String, voiceID: String?) {
        stop(reason: "replaced")
        spoken.append(id)
        self.id = id
    }

    func begin(id: String, voiceID: String?) {
        stop(reason: "replaced")
        begun.append(id)
        self.id = id
    }

    func append(id: String, seq: Int, text: String) {}
    func finish(id: String) {}

    func stop(reason: String) {
        guard let id else { return }
        self.id = nil
        onEvent?(ReplySpeechEvent(id: id, state: .stopped, reason: reason))
    }
}

private struct SpyVoices: ReplyVoiceCatalog {
    func installedVoices() -> [ReplyVoice] { [ReplyVoice(id: "en-best", name: "Zoe", quality: .premium, language: "en-US")] }
}

@MainActor
private final class NoCall: VoiceCallState {
    var hasCall: Bool { false }
}

@MainActor
private final class SilentTranscriber: VoiceTranscribing {
    func capabilityInputs() async -> VoiceCapabilityInputs { VoiceCapabilityInputs(osSupported: true) }
    func prepare() async throws {}
    func start(onPartial: @escaping @MainActor (String) -> Void) async throws {}
    func finish() async -> String { "" }
    func cancel() {}
}
