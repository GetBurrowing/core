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
        private let engine = AVAudioEngine()
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
            let node = engine.inputNode
            let natural = node.outputFormat(forBus: 0)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: natural)
            else { throw VoiceTranscriberError.noAudioFormat }
            try await analyzer.prepareToAnalyze(in: format)

            finalized = ""
            volatile = ""
            self.analyzer = analyzer
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

            let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
            self.input = input
            let converter = natural == format ? nil : AVAudioConverter(from: natural, to: format)
            node.installTap(onBus: 0, bufferSize: 4096, format: natural) { buffer, _ in
                guard let converted = Self.convert(buffer, with: converter, to: format) else { return }
                input.yield(AnalyzerInput(buffer: converted))
            }
            tapped = true
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

        nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
            guard let converter else { return buffer }
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
