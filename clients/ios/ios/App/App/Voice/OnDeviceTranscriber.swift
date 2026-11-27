import AVFoundation

#if canImport(Speech)
    import AVFoundation
    import Speech

    /// On-device transcription for the Voice tab (task 01a20dc5 stage 1), with
    /// the system's own SpeechAnalyzer and SpeechTranscriber and the speech
    /// assets iOS manages (AssetInventory). The app ships no model. Nothing
    /// here logs or stores what was said.
    ///
    /// Mic buffers from an AVAudioEngine input tap are converted to the
    /// analyzer's best format and fed to it as a stream. Volatile results are
    /// the words still forming (`partial`); `finish()` ends the input, waits
    /// for the analyzer to finalize, and returns the finalized text (`final`).
    @available(iOS 26, *)
    @MainActor
    final class OnDeviceTranscriber {
        /// Made afresh for every turn, and again while the input settles
        /// (MicTap.settled): a long-lived engine kept reporting an empty
        /// input format after the session activated over a podcast.
        private var engine = AVAudioEngine()
        private var analyzer: SpeechAnalyzer?
        private var input: AsyncStream<AnalyzerInput>.Continuation?
        private var results: Task<Void, Never>?
        private var tapped = false
        /// Text the analyzer has finalized so far this turn.
        private var finalized = ""
        /// The words still forming after `finalized`.
        private var volatile = ""

        static func module(_ locale: Locale) -> SpeechTranscriber {
            SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        }

        /// The locale SpeechTranscriber supports for the person's language, or nil.
        static func locale() async -> Locale? {
            await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        }

        /// What `VoiceCapability.decide` needs. Decided on the phone at run
        /// time: Apple publishes no device list.
        static func capabilityInputs() async -> VoiceCapabilityInputs {
            var inputs = VoiceCapabilityInputs(osSupported: true, isAvailable: SpeechTranscriber.isAvailable)
            inputs.speechPermission = speechPermission(SFSpeechRecognizer.authorizationStatus())
            guard inputs.isAvailable, let locale = await locale() else { return inputs }
            inputs.locale = locale.identifier(.bcp47)
            switch await AssetInventory.status(forModules: [module(locale)]) {
            case .installed: inputs.assets = .installed
            case .supported, .downloading: inputs.assets = .missing
            case .unsupported: inputs.assets = .unsupported
            @unknown default: inputs.assets = .missing
            }
            return inputs
        }

        /// Whether SpeechTranscriber needs the speech-recognition grant is not
        /// documented; a refused grant is reported defensively. Nothing here
        /// asks for it.
        static func speechPermission(_ status: SFSpeechRecognizerAuthorizationStatus) -> VoiceCapabilityInputs.Permission {
            switch status {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .undetermined
            @unknown default: return .undetermined
            }
        }

        /// Downloads the system speech assets for the locale, if iOS has any
        /// to fetch. Returns once they are installed.
        static func prepareAssets() async throws {
            guard let locale = await locale() else { return }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module(locale)]) {
                try await request.downloadAndInstall()
            }
        }

        /// Opens the mic tap and starts analysing. The audio session must
        /// already be active.
        func start(onPartial: @escaping @MainActor (String) -> Void) async throws {
            guard let locale = await Self.locale() else { throw VoiceTranscriberError.localeUnsupported }
            let module = Self.module(locale)
            let analyzer = SpeechAnalyzer(modules: [module])
            let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
            let converter = MicBufferConverter()
            // MicTap reads the input format again right before the tap: the
            // awaits in `prepare` can outlast a route or hardware change
            // (another app's audio being paused as this session activates),
            // and a tap installed with a stale or empty format raises an
            // Objective-C exception that ends the app (task 01a20fdd stage 4).
            _ = try await MicTap.open(
                { [unowned self] in
                    self.engine = AVAudioEngine()
                    return self.engine.inputNode
                },
                prepare: { natural in
                    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: natural)
                    else { throw VoiceTranscriberError.noAudioFormat }
                    try await analyzer.prepareToAnalyze(in: format)
                    return format
                },
                tap: { buffer, format in
                    guard let converted = converter.convert(buffer, to: format) else { return }
                    input.yield(AnalyzerInput(buffer: converted))
                })
            tapped = true

            finalized = ""
            volatile = ""
            self.analyzer = analyzer
            self.input = input
            results = Task { @MainActor [weak self] in
                do {
                    for try await result in module.results {
                        guard let self else { return }
                        let text = String(result.text.characters)
                        if result.isFinal {
                            self.finalized += text
                            self.volatile = ""
                        } else {
                            self.volatile = text
                        }
                        onPartial(self.finalized + self.volatile)
                    }
                } catch {
                    // The turn ends with what was finalized.
                }
            }

            engine.prepare()
            do {
                try engine.start()
                try await analyzer.start(inputSequence: stream)
            } catch {
                cancel()
                throw error
            }
        }

        /// Ends the turn: closes the mic, finalizes, and returns the
        /// finalized text (empty when no words were heard).
        func finish() async -> String {
            closeMic()
            if let analyzer {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            await results?.value
            let text = finalized
            reset()
            return text
        }

        /// Discards the turn: closes the mic and drops every result.
        func cancel() {
            closeMic()
            results?.cancel()
            if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
            reset()
        }

        private func closeMic() {
            if engine.isRunning { engine.stop() }
            if tapped {
                engine.inputNode.removeTap(onBus: 0)
                tapped = false
            }
            input?.finish()
            input = nil
        }

        private func reset() {
            analyzer = nil
            results = nil
            finalized = ""
            volatile = ""
        }

    }

    /// Converts mic buffers to the analyzer's format, from whatever format
    /// each buffer actually arrives in (the tap takes the bus's current
    /// format, which can differ from the one read before the tap). Used only
    /// on the tap's own serial thread.
    final class MicBufferConverter: @unchecked Sendable {
        private var converter: AVAudioConverter?
        private var from: AVAudioFormat?

        func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
            if buffer.format == format { return buffer }
            if from != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: format)
                from = buffer.format
            }
            guard let converter else { return nil }
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            return status == .error ? nil : output
        }
    }
#endif

/// The mic input the Voice tap is installed on (task 01a20fdd stage 4).
/// `AVAudioInputNode` is the real one; tests inject a fake.
@MainActor
protocol MicTapInput: AnyObject {
    /// The hardware format the input delivers right now.
    var currentFormat: AVAudioFormat { get }
    /// Its sample rate and channel count, read separately: a format with no
    /// rate cannot be built in a test, but the input can report one.
    var currentShape: (sampleRate: Double, channels: AVAudioChannelCount) { get }
    /// Installs the bus-0 tap in the bus's CURRENT format (nil format).
    func installMicTap(bufferSize: AVAudioFrameCount, block: @escaping @Sendable (AVAudioPCMBuffer) -> Void)
    func removeMicTap()
}

extension AVAudioInputNode: MicTapInput {
    var currentFormat: AVAudioFormat { inputFormat(forBus: 0) }
    var currentShape: (sampleRate: Double, channels: AVAudioChannelCount) {
        let format = inputFormat(forBus: 0)
        return (format.sampleRate, format.channelCount)
    }

    func installMicTap(bufferSize: AVAudioFrameCount, block: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        installTap(onBus: 0, bufferSize: bufferSize, format: nil) { buffer, _ in block(buffer) }
    }

    func removeMicTap() { removeTap(onBus: 0) }
}

enum MicTapError: Error, Equatable {
    /// The input has no usable format right now (no rate or no channels):
    /// a route or hardware change is under way, or there is no input.
    case noInputFormat
}

/// Opening the Voice mic tap safely (task 01a20fdd stage 4). On the iPhone a
/// tap installed with a stale or empty format made AVAudioEngine raise an
/// Objective-C exception (`_AVAE_CheckAndReturnErr` from `CreateRecordingTap`),
/// which Swift cannot catch, so the app ended: it happened on a mic tap while
/// a podcast was being paused. Here the format is read AFTER `prepare`'s
/// awaits, an empty one is never tapped, any earlier tap is removed first,
/// and the tap takes the bus's own format.
///
/// An empty format is waited out first (`settled`): with a podcast playing,
/// activating the session took 830 ms on the iPhone and the input then read
/// 0 Hz / 0 channels; the same long-lived engine still read 0/0 on the next
/// turn. So each read comes from a FRESH input (`makeInput` builds a new
/// engine), every 50 ms for up to 1.5 s, and only then is the turn refused.
@MainActor
enum MicTap {
    static let bufferSize: AVAudioFrameCount = 4096
    /// Reads of an empty input before giving up, `pauseNanoseconds` apart.
    static let settleAttempts = 30
    static let pauseNanoseconds: UInt64 = 50_000_000

    /// `makeInput` gives a fresh input each call. `prepare` gets the format as
    /// it was before preparing (the analyzer picks its format from it) and
    /// returns the analyzer's format; the tap block gets each buffer with that
    /// format. Returns the analyzer format. `pause` is injected by tests.
    static func open(
        _ makeInput: () -> any MicTapInput, pause: () async -> Void = { try? await Task.sleep(nanoseconds: pauseNanoseconds) },
        prepare: (AVAudioFormat) async throws -> AVAudioFormat,
        tap: @escaping @Sendable (AVAudioPCMBuffer, AVAudioFormat) -> Void
    ) async throws -> AVAudioFormat {
        var input = try await settled(makeInput(), makeInput, pause: pause)
        let early = input.currentShape
        let target = try await prepare(input.currentFormat)
        input = try await settled(input, makeInput, pause: pause)
        let now = input.currentShape
        VoiceTrace.log(
            "mic tap format rate=\(Int(now.sampleRate)) channels=\(now.channels) changed=\(now.sampleRate != early.sampleRate || now.channels != early.channels)"
        )
        input.removeMicTap()
        input.installMicTap(bufferSize: bufferSize) { buffer in tap(buffer, target) }
        return target
    }

    /// `input` once its format is usable, else a fresh input once one is,
    /// within `settleAttempts`; then `noInputFormat`.
    static func settled(
        _ first: any MicTapInput, _ makeInput: () -> any MicTapInput, pause: () async -> Void
    ) async throws -> any MicTapInput {
        var input = first
        var waited = 0
        while !usable(input.currentShape), waited < settleAttempts {
            waited += 1
            await pause()
            input = makeInput()
        }
        if waited > 0 || !usable(input.currentShape) {
            let session = AVAudioSession.sharedInstance()
            VoiceTrace.log(
                "mic input session_rate=\(Int(session.sampleRate)) input_available=\(session.isInputAvailable) input_channels=\(session.inputNumberOfChannels)"
            )
            VoiceTrace.log(
                "mic input settled waited=\(waited) rate=\(Int(input.currentShape.sampleRate)) channels=\(input.currentShape.channels)")
        }
        try check(input.currentShape)
        return input
    }

    static func usable(_ shape: (sampleRate: Double, channels: AVAudioChannelCount)) -> Bool {
        shape.sampleRate > 0 && shape.channels > 0
    }

    static func check(_ shape: (sampleRate: Double, channels: AVAudioChannelCount)) throws {
        guard shape.sampleRate > 0, shape.channels > 0 else {
            VoiceTrace.log("mic tap refused rate=\(Int(shape.sampleRate)) channels=\(shape.channels)")
            throw MicTapError.noInputFormat
        }
    }
}
