import AVFoundation
import Foundation
import NaturalLanguage

/// One synthesized sentence: mono float PCM.
struct PocketPCM: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Int
}

enum PocketEngineError: Error {
    case unavailable
}

/// The Pocket TTS model as the speaker sees it. `SystemPocketEngine` is the
/// real one; tests inject a fake.
@MainActor
protocol PocketEngine: PocketEngineLoading {
    /// One whole sentence in, its PCM out. Loads the model first if it is not
    /// loaded (lazily, and again after `release`).
    func synthesize(_ text: String) async throws -> PocketPCM
    /// Drops the loaded model (memory warning). The files stay.
    func release()
}

/// The iOS 27 engine behind `#available`, so the app keeps its iOS 17
/// deployment target (the `SystemVoiceTranscriber` pattern). On a simulator or
/// an older iOS every call throws `unavailable`.
@MainActor
final class SystemPocketEngine: PocketEngine {
    private let bundles: URL
    private let weights: URL
    private var impl: AnyObject?

    init(root: URL = PocketModelStore.defaultRoot()) {
        bundles = PocketModelStore.directory(for: .bundles, under: root)
        weights = PocketModelStore.directory(for: .weights, under: root)
    }

    func load() async throws {
        #if canImport(CoreAI)
            if #available(iOS 27, *) {
                let engine = (impl as? VendoredPocketEngine) ?? VendoredPocketEngine()
                impl = engine
                return try await engine.load(bundles: bundles, weights: weights)
            }
        #endif
        throw PocketEngineError.unavailable
    }

    func synthesize(_ text: String) async throws -> PocketPCM {
        #if canImport(CoreAI)
            if #available(iOS 27, *) {
                try await load()
                guard let engine = impl as? VendoredPocketEngine else { throw PocketEngineError.unavailable }
                return try await engine.synthesize(text)
            }
        #endif
        throw PocketEngineError.unavailable
    }

    func release() { impl = nil }
}

#if canImport(CoreAI)
    /// The vendored pipeline on its own actor, so synthesis never runs on the
    /// main thread. Voice: PocketTTSManifest.voice, fixed seed, fp16 on the GPU.
    @available(iOS 27, *)
    actor VendoredPocketEngine {
        private var pipeline: TTSPipeline?
        private var voice: VoiceState?

        func load(bundles: URL, weights: URL) async throws {
            if pipeline != nil { return }
            let english = weights.appendingPathComponent("languages/english")
            let layout = WeightsLayout(
                modelURL: english.appendingPathComponent("model.safetensors"),
                tokenizerURL: english.appendingPathComponent("tokenizer.model"),
                embeddingsDir: english.appendingPathComponent("embeddings"))
            let loaded = try await TTSPipeline(assetsDir: bundles, layout: layout, dtype: PocketTTSManifest.dtype, unit: .gpu)
            let voice = try loaded.voice(PocketTTSManifest.voice)
            // The first synthesis specializes the graphs (about 3.6 s on the
            // stage 1 iPhone); pay it here, in `compiling`, not on a reply.
            _ = try await loaded.synthesize(text: "Ready.", voice: voice, seed: 0, applyGain: true)
            self.voice = voice
            pipeline = loaded
        }

        func synthesize(_ text: String) async throws -> PocketPCM {
            guard let pipeline, let voice else { throw PocketEngineError.unavailable }
            let result = try await pipeline.synthesize(text: text, voice: voice, seed: 0, applyGain: true)
            return PocketPCM(samples: result.samples, sampleRate: Model.sampleRate)
        }
    }
#endif

/// Where the PCM plays. `AVPocketAudioOutput` is the real one.
@MainActor
protocol PocketAudioOutput: AnyObject {
    /// Starts (or keeps) the engine at `sampleRate`. Never touches the audio
    /// session's category: the plugin's `VoiceAudioSession` owns it.
    func start(sampleRate: Int) throws
    /// Queues `samples` after whatever is queued; `played` runs when they
    /// have been heard (or dropped by `stop`).
    func schedule(_ samples: [Float], played: @escaping @Sendable () -> Void)
    /// Stops playback at once and drops everything queued.
    func stop()
}

enum PocketAudioError: Error {
    case format
}

/// `AVAudioEngine` + `AVAudioPlayerNode` at the model's sample rate.
@MainActor
final class AVPocketAudioOutput: PocketAudioOutput {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?

    func start(sampleRate: Int) throws {
        if let engine, engine.isRunning, format?.sampleRate == Double(sampleRate) { return }
        stop()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)
        else { throw PocketAudioError.format }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.play()
        self.engine = engine
        self.player = player
        self.format = format
    }

    func schedule(_ samples: [Float], played: @escaping @Sendable () -> Void) {
        guard let player, let format,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))
        else {
            played()
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
            }
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in played() }
    }

    func stop() {
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        format = nil
    }
}

/// A reply read by Pocket TTS (task 01a20fdd stage 2). One sentence at a time:
/// a synthesis task turns the next part into PCM while the previous one
/// plays, and each buffer is scheduled the moment it exists, so sentence 1 is
/// heard while sentence 2 is synthesizing. The vendored host has no
/// incremental API (its `synthesize` returns a whole buffer), so a sentence is
/// the smallest unit. The text is never logged.
@MainActor
final class PocketSpeaker: VoiceSpeaking {
    var onEvent: ((ReplySpeechEvent) -> Void)?
    private let engine: any PocketEngine
    private let output: any PocketAudioOutput

    private struct Reply {
        let id: String
        var parts = ReplyPartQueue()
        var texts: [String] = []
        var final = false
        var started = false
        var synthesizing = false
        var scheduled = 0
        var played = 0
    }

    private var current: Reply?
    /// Bumped by every begin and stop: work from an older reply is dropped.
    private var generation = 0
    private var task: Task<Void, Never>?

    init(engine: any PocketEngine, output: any PocketAudioOutput) {
        self.engine = engine
        self.output = output
    }

    var isSpeaking: Bool { current != nil }

    func speak(id: String, text: String, voiceID: String?) {
        begin(id: id, voiceID: voiceID)
        for (seq, sentence) in Self.sentences(text).enumerated() { append(id: id, seq: seq, text: sentence) }
        finish(id: id)
    }

    func begin(id: String, voiceID: String?) {
        stop(reason: "replaced")
        generation += 1
        current = Reply(id: id)
    }

    func append(id: String, seq: Int, text: String) {
        guard current?.id == id else { return }
        let ready = current?.parts.add(seq: seq, text: text) ?? []
        current?.texts += ready.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        pump()
    }

    func finish(id: String) {
        guard current?.id == id else { return }
        current?.final = true
        // Parts held back for a missing earlier seq are spoken in order now.
        let held = current?.parts.flush() ?? []
        current?.texts += held.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        pump()
        finishIfDone()
    }

    func stop(reason: String) {
        guard let reply = current else { return }
        // Cleared first, synchronously: a synthesis result or a buffer
        // completion that lands after this belongs to an old generation and
        // is dropped, so the page gets exactly one `stopped`.
        current = nil
        generation += 1
        task?.cancel()
        task = nil
        output.stop()
        onEvent?(ReplySpeechEvent(id: reply.id, state: .stopped, reason: reason))
    }

    private func pump() {
        guard var reply = current, !reply.synthesizing, !reply.texts.isEmpty else { return }
        let text = reply.texts.removeFirst()
        reply.synthesizing = true
        current = reply
        let mine = generation
        let engine = engine
        task = Task { [weak self] in
            let result: Result<PocketPCM, Error>
            let started = Date()
            do {
                result = .success(try await engine.synthesize(text))
            } catch {
                result = .failure(error)
            }
            if case .success(let pcm) = result {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let audio = Double(pcm.samples.count) / Double(max(pcm.sampleRate, 1))
                VoiceTrace.log(
                    "synth chars=\(text.count) ms=\(ms) audio_s=\(String(format: "%.2f", audio)) rtf=\(String(format: "%.3f", audio > 0 ? Double(ms) / 1000 / audio : 0)) footprint_mb=\(VoiceTrace.footprintMB())"
                )
            } else {
                VoiceTrace.log("synth failed chars=\(text.count)")
            }
            guard let self, self.generation == mine, self.current != nil else { return }
            self.current?.synthesizing = false
            switch result {
            case .success(let pcm): self.play(pcm, generation: mine)
            case .failure: return self.stop(reason: "synthesis_failed")
            }
            self.pump()
            self.finishIfDone()
        }
    }

    private func play(_ pcm: PocketPCM, generation mine: Int) {
        do {
            try output.start(sampleRate: pcm.sampleRate)
        } catch {
            return stop(reason: "audio_unavailable")
        }
        current?.scheduled += 1
        output.schedule(Self.shaped(pcm.samples, sampleRate: pcm.sampleRate)) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                self.current?.played += 1
                self.finishIfDone()
            }
        }
        if current?.started == false, let id = current?.id {
            current?.started = true
            onEvent?(ReplySpeechEvent(id: id, state: .started))
        }
    }

    private func finishIfDone() {
        guard let reply = current, reply.final, !reply.synthesizing, reply.texts.isEmpty, reply.played == reply.scheduled else { return }
        current = nil
        generation += 1
        output.stop()
        onEvent?(ReplySpeechEvent(id: reply.id, state: .finished))
    }

    /// The decoder's start-up frame, dropped from every sentence: 80 ms
    /// (one Mimi frame, 1,920 samples at 24 kHz).
    static let startupMs = 80
    static let fadeInMs = 10
    static let fadeOutMs = 5

    /// A sentence's PCM as it is played (task 01a20fdd stage 4). Each sentence
    /// is a fresh `synthesize` run, and the Mimi decoder starts from zeroed
    /// state every time, so EVERY sentence begins with the same start-up
    /// transient: a burst peaking at 0.09 to 0.17 in its first 5 to 20 ms,
    /// decayed to about 0.0002 by 80 to 130 ms, whatever the text (measured
    /// on rock with the vendored host, marius, fp16: the first samples were
    /// identical across three different sentences). Played at the start of
    /// each sentence it is heard as a click. The first decoder frame is
    /// dropped (speech began no earlier than about 145 ms in the samples
    /// measured), then a short linear fade-in and fade-out, so no buffer
    /// starts or ends on a step.
    static func shaped(_ samples: [Float], sampleRate: Int) -> [Float] {
        let trim = sampleRate * startupMs / 1000
        guard samples.count > trim else { return [] }
        var out = Array(samples[trim...])
        let fadeIn = min(sampleRate * fadeInMs / 1000, out.count)
        for i in 0..<fadeIn { out[i] *= Float(i) / Float(fadeIn) }
        let fadeOut = min(sampleRate * fadeOutMs / 1000, out.count)
        for i in 0..<fadeOut { out[out.count - 1 - i] *= Float(i) / Float(fadeOut) }
        return out
    }

    /// The sentences of a one-shot reply, in order.
    static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { out.append(sentence) }
            return true
        }
        return out.isEmpty && !text.isEmpty ? [text] : out
    }
}
