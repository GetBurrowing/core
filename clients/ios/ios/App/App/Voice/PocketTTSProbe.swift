#if DEBUG
    import Foundation

    /// DEBUG-only feasibility probe for Pocket TTS (task 01a20fdd stage 1).
    /// Launch a Debug build with `-BurrowPocketTTSProbe` and it downloads the
    /// pinned manifest, loads the vendored pipeline, warms it up, times one
    /// short sentence and one fixed paragraph, and appends the numbers to
    /// `Library/Caches/pocket-tts-probe.log`. Read it back from the Mac with
    /// `xcrun devicectl device copy from --device <udid> --domain-type
    /// appDataContainer --domain-identifier com.kobo-ai.burrow --source
    /// Library/Caches/pocket-tts-probe.log --destination <file>`.
    /// Logs constants and numbers only. Release builds compile this to nothing.
    enum PocketTTSProbeLauncher {
        static let argument = "-BurrowPocketTTSProbe"

        static func startIfRequested() {
            guard ProcessInfo.processInfo.arguments.contains(argument) else { return }
            #if canImport(CoreAI)
                if #available(iOS 27, *) {
                    Task.detached(priority: .userInitiated) { await PocketTTSProbe.run() }
                    return
                }
            #endif
            let gate = PocketTTSSupport.current()
            PocketTTSProbeLog.append("probe skipped gate_supported=\(gate.supported) reason=\(gate.reason ?? "nil")")
        }
    }

    enum PocketTTSProbeLog {
        private static let lock = NSLock()
        private static let url: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("pocket-tts-probe.log")

        static func append(_ line: String) {
            guard let url else { return }
            lock.lock()
            defer { lock.unlock() }
            let stamp = ISO8601DateFormatter().string(from: Date())
            guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// phys_footprint (what jetsam counts) and the headroom iOS reports.
    enum ProbeMemory {
        static func footprintBytes() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return result == KERN_SUCCESS ? info.phys_footprint : 0
        }

        static func availableBytes() -> UInt64 { UInt64(os_proc_available_memory()) }
    }

    /// Samples the footprint every 20 ms; keeps the peak and the lowest headroom.
    final class ProbeMemorySampler: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: UInt64 = 0
        private var minAvailable = UInt64.max
        private var timer: DispatchSourceTimer?

        func start() {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "pocket-tts-probe.memory"))
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.sample() }
            self.timer = timer
            timer.resume()
        }

        func sample() {
            let footprint = ProbeMemory.footprintBytes()
            let available = ProbeMemory.availableBytes()
            lock.lock()
            peak = max(peak, footprint)
            minAvailable = min(minAvailable, available)
            lock.unlock()
        }

        /// Peak footprint and lowest headroom since `start`, in MB, then resets the peak.
        func readAndReset() -> (peakMB: Double, minAvailableMB: Double) {
            sample()
            lock.lock()
            defer {
                peak = 0
                minAvailable = .max
                lock.unlock()
            }
            return (Double(peak) / 1_048_576, Double(minAvailable) / 1_048_576)
        }

        func stop() { timer?.cancel() }
    }

    #if canImport(CoreAI)
        @available(iOS 27, *)
        enum PocketTTSProbe {
            /// The fixed paragraph: 96 words of ordinary reply-like English.
            static let paragraph =
                "Here is what changed while you were away. The release went out this morning, and the "
                + "first reports look good. Two people asked for the export to include attachments, so I "
                + "opened a task for it and set it to medium priority. The calendar sync failed once at "
                + "about nine, then recovered on its own. I checked the logs and found nothing that needs "
                + "your attention today. Tomorrow I will review the open pull requests, answer the support "
                + "thread about invoices, and send you a short summary before lunch. Let me know if you "
                + "would like anything moved up."
            static let sentence = "Sure, I can do that for you."

            static func ms(_ since: UInt64) -> Int { Int((nowNanos() - since) / 1_000_000) }

            static func run() async {
                let log = PocketTTSProbeLog.append
                let gate = PocketTTSSupport.current()
                let os = ProcessInfo.processInfo.operatingSystemVersion
                var machine = utsname()
                uname(&machine)
                let model = withUnsafeBytes(of: &machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                log(
                    "probe start model=\(model) os=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) "
                        + "physical_memory_mb=\(ProcessInfo.processInfo.physicalMemory / 1_048_576) "
                        + "gate_supported=\(gate.supported) gate_reason=\(gate.reason ?? "nil") "
                        + "footprint_mb=\(ProbeMemory.footprintBytes() / 1_048_576) available_mb=\(ProbeMemory.availableBytes() / 1_048_576)")
                let sampler = ProbeMemorySampler()
                sampler.start()
                defer { sampler.stop() }
                do {
                    let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                        .appendingPathComponent("PocketTTS-probe", isDirectory: true)
                    // HubStore fetches a file whole or skips it when present at the
                    // right size, so the bytes fetched are the sizes of the files
                    // missing before the call.
                    var fetched = 0
                    for file in PocketTTSManifest.files {
                        let local = root.appendingPathComponent(PocketTTSManifest.repoID(of: file.repo).replacingOccurrences(of: "/", with: "--"))
                            .appendingPathComponent(PocketTTSManifest.revision(of: file.repo)).appendingPathComponent(file.path)
                        let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int) ?? nil
                        if size != file.size { fetched += file.size }
                    }
                    let tDownload = nowNanos()
                    var dirs: [PocketTTSFile.Repo: URL] = [:]
                    for repo in [PocketTTSFile.Repo.bundles, .weights] {
                        let paths = Set(PocketTTSManifest.files.filter { $0.repo == repo }.map(\.path))
                        dirs[repo] = try await HubStore.ensure(
                            HubRepo(id: PocketTTSManifest.repoID(of: repo), revision: PocketTTSManifest.revision(of: repo)),
                            where: { paths.contains($0) }, cacheDirectory: root)
                    }
                    let downloadMs = ms(tDownload)
                    let tVerify = nowNanos()
                    var onDisk = 0
                    for file in PocketTTSManifest.files {
                        guard let dir = dirs[file.repo] else { continue }
                        let url = dir.appendingPathComponent(file.path)
                        let digest = try HubStore.sha256(of: url)
                        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
                        onDisk += size
                        if digest != file.sha256 || size != file.size {
                            log("probe manifest_mismatch path=\(file.path) size=\(size)")
                            throw TTSError.message("manifest mismatch")
                        }
                    }
                    let memDownload = sampler.readAndReset()
                    log(
                        "probe download bytes_fetched=\(fetched) bytes_on_disk=\(onDisk) manifest_bytes=\(PocketTTSManifest.totalBytes) "
                            + "download_ms=\(downloadMs) verify_ms=\(ms(tVerify)) peak_footprint_mb=\(Int(memDownload.peakMB))")

                    guard let bundles = dirs[.bundles], let weights = dirs[.weights] else { return }
                    let english = weights.appendingPathComponent("languages/english")
                    let layout = WeightsLayout(
                        modelURL: english.appendingPathComponent("model.safetensors"),
                        tokenizerURL: english.appendingPathComponent("tokenizer.model"),
                        embeddingsDir: english.appendingPathComponent("embeddings"))
                    let tLoad = nowNanos()
                    let tts = try await TTSPipeline(assetsDir: bundles, layout: layout, dtype: PocketTTSManifest.dtype, unit: .gpu)
                    let voice = try tts.voice(PocketTTSManifest.voice)
                    let loadMs = ms(tLoad)
                    let memLoad = sampler.readAndReset()
                    log(
                        "probe load load_ms=\(loadMs) pipeline_load_s=\(String(format: "%.3f", tts.loadSeconds)) "
                            + "lm_s=\(String(format: "%.3f", tts.lmAsset.loadSeconds)) flow_s=\(String(format: "%.3f", tts.flowAsset.loadSeconds)) "
                            + "mimi_s=\(String(format: "%.3f", tts.mimiAsset.loadSeconds)) peak_footprint_mb=\(Int(memLoad.peakMB)) "
                            + "min_available_mb=\(Int(memLoad.minAvailableMB))")

                    let tWarm = nowNanos()
                    let warm = try await tts.synthesize(text: "Warming up.", voice: voice, seed: 0, applyGain: true)
                    let memWarm = sampler.readAndReset()
                    log(
                        "probe warmup warmup_ms=\(ms(tWarm)) audio_s=\(String(format: "%.2f", warm.durationSeconds)) "
                            + "peak_footprint_mb=\(Int(memWarm.peakMB)) min_available_mb=\(Int(memWarm.minAvailableMB))")

                    let tSentence = nowNanos()
                    let short = try await tts.synthesize(text: sentence, voice: voice, seed: 0, applyGain: true)
                    log(
                        "probe sentence first_buffer_ms=\(ms(tSentence)) audio_s=\(String(format: "%.2f", short.durationSeconds)) "
                            + "rtf=\(String(format: "%.4f", short.rtf)) words=7")

                    let paragraphResult = try await tts.synthesize(text: paragraph, voice: voice, seed: 0, applyGain: true)
                    let memSynth = sampler.readAndReset()
                    log(
                        "probe paragraph wall_s=\(String(format: "%.3f", paragraphResult.wallSeconds)) "
                            + "audio_s=\(String(format: "%.2f", paragraphResult.durationSeconds)) rtf=\(String(format: "%.4f", paragraphResult.rtf)) "
                            + "chunks=\(paragraphResult.chunks.count) sample_rate=\(Model.sampleRate) words=96 "
                            + "peak_footprint_mb=\(Int(memSynth.peakMB)) min_available_mb=\(Int(memSynth.minAvailableMB))")
                    log("probe done ok=true")
                } catch {
                    log("probe failed error=\(String(describing: error).prefix(300))")
                }
            }
        }

    #endif
#endif
