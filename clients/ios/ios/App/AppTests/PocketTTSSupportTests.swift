import XCTest

@testable import App

/// The Pocket TTS gate and the pinned download manifest (task 01a20fdd stage 1).
final class PocketTTSSupportTests: XCTestCase {
    private let enough = PocketTTSSupport.minimumPhysicalMemoryBytes

    private func decide(os: Int = 27, coreAI: Bool = true, memory: UInt64? = nil, simulator: Bool = false) -> (supported: Bool, reason: String?) {
        PocketTTSSupport.decide(osMajor: os, hasCoreAI: coreAI, physicalMemoryBytes: memory ?? enough, isSimulator: simulator)
    }

    // MARK: - Gate

    func testSupportedOnIOS27DeviceWithCoreAIAndEnoughMemory() {
        let gate = decide()
        XCTAssertTrue(gate.supported)
        XCTAssertNil(gate.reason)
        XCTAssertTrue(decide(os: 28, memory: 12 * 1024 * 1024 * 1024).supported)
    }

    func testOSTooOldBelow27() {
        let gate = decide(os: 26)
        XCTAssertFalse(gate.supported)
        XCTAssertEqual(gate.reason, "os_too_old")
        XCTAssertEqual(decide(os: 17).reason, "os_too_old")
    }

    func testSimulator() {
        let gate = decide(simulator: true)
        XCTAssertFalse(gate.supported)
        XCTAssertEqual(gate.reason, "simulator")
    }

    func testNoCoreAI() {
        let gate = decide(coreAI: false)
        XCTAssertFalse(gate.supported)
        XCTAssertEqual(gate.reason, "no_core_ai")
    }

    func testLowMemoryJustUnderTheThreshold() {
        let gate = decide(memory: enough - 1)
        XCTAssertFalse(gate.supported)
        XCTAssertEqual(gate.reason, "low_memory")
        XCTAssertEqual(decide(memory: 4 * 1024 * 1024 * 1024).reason, "low_memory")
        XCTAssertTrue(decide(memory: enough).supported)
    }

    /// The 6 GB phones (which report a little under 6 GiB) pass; 4 GB fail.
    func testThresholdSitsBetweenFourAndSixGigabytePhones() {
        XCTAssertGreaterThan(enough, 4 * 1024 * 1024 * 1024)
        XCTAssertLessThan(enough, 6 * 1024 * 1024 * 1024)
    }

    /// The first failing check names the reason, in the documented order.
    func testReasonPrecedence() {
        XCTAssertEqual(decide(os: 26, coreAI: false, memory: 0, simulator: true).reason, "os_too_old")
        XCTAssertEqual(decide(coreAI: false, memory: 0, simulator: true).reason, "simulator")
        XCTAssertEqual(decide(coreAI: false, memory: 0).reason, "no_core_ai")
    }

    /// AppTests run on a simulator: the live gate must refuse it there.
    func testCurrentRefusesTheSimulator() {
        let gate = PocketTTSSupport.current()
        XCTAssertFalse(gate.supported)
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        XCTAssertEqual(gate.reason, os < 27 ? "os_too_old" : "simulator")
    }

    // MARK: - Manifest

    func testPinnedRevisions() {
        XCTAssertEqual(PocketTTSManifest.bundlesRepo, "rahulrachuri/pocket-tts-coreai")
        XCTAssertEqual(PocketTTSManifest.bundlesRevision, "d774360b912aa70d217e34204cef1cebfdadadd1")
        XCTAssertEqual(PocketTTSManifest.weightsRepo, "kyutai/pocket-tts-without-voice-cloning")
        XCTAssertEqual(PocketTTSManifest.weightsRevision, "e041936c75475d350b405bc870bcf7c22da4e9e6")
        XCTAssertEqual(PocketTTSManifest.voice, "marius")
        XCTAssertEqual(PocketTTSManifest.dtype, "float16")
    }

    /// Path, size and SHA-256 of every file, as read from the HF API on 2026-11-24.
    func testPinnedFileList() {
        let expected: [(PocketTTSFile.Repo, String, Int, String)] = [
            (.bundles, "config.json", 309, "ed23711e4b56b39e548824cb1bb5308e1cfd2df20b60a1902be6d18f00c13b15"),
            (.bundles, "flow_decoder_float16_lsd1.aimodel/main.hash", 32, "377c05705eabf03b6ce8d3436ac40f62c228b7fec45aa417eb6ca9309771c4d2"),
            (.bundles, "flow_decoder_float16_lsd1.aimodel/main.mlirb", 19_575_240, "7e4147e4c2216e88d111080cd21dc60edc033db680496a7413bdf2f12368e7b4"),
            (.bundles, "flow_decoder_float16_lsd1.aimodel/metadata.json", 132, "9be04d06a4e1829144be3f80f4d4166788b5a27eaf20fd876d66bd6cd70e4c30"),
            (.bundles, "flowlm_float16_s512.aimodel/main.hash", 32, "8b71dd5313c7275e430982f3098fa5d9b5605f66b2b78ae1404adfe323539284"),
            (.bundles, "flowlm_float16_s512.aimodel/main.mlirb", 151_252_631, "06ea9405cf52be6dafd53d8092b398dfcd2f1f2f32a82b1dd14081ab442f9b61"),
            (.bundles, "flowlm_float16_s512.aimodel/metadata.json", 132, "f5f8b8a28523c2e227c2f99c140d6b603ae4902a67a116847813b7320535fd23"),
            (.bundles, "mimi_decoder_float32_ring272_outer_q_gs.aimodel/main.hash", 32, "90f5c20a0995ae8a6ccee233934e4369acf7ebd5e32df013d9c28cd0b33ebda6"),
            (
                .bundles, "mimi_decoder_float32_ring272_outer_q_gs.aimodel/main.mlirb", 41_288_791,
                "1bef37bd9ca5ae0d42a876c043a76c6cf3804df8eede7e9d76e9dcda08849b7e"
            ),
            (
                .bundles, "mimi_decoder_float32_ring272_outer_q_gs.aimodel/metadata.json", 132,
                "a68817599da1e9dee0a32fbe74b3079a140c5a0480960c14f6cf71bd0bb0cfbb"
            ),
            (.weights, "languages/english/embeddings/marius.safetensors", 6_194_424, "04f84efcb77a0547ba582c058db496f7ff4920891d49d37b9950d128422582a8"),
            (.weights, "languages/english/model.safetensors", 219_029_196, "be9c6b4876d3f30740a8225dfcaa2e43dc4aeb753c15272735bee16bbb4abb0a"),
            (.weights, "languages/english/tokenizer.model", 59_339, "d461765ae179566678c93091c5fa6f2984c31bbe990bf1aa62d92c64d91bc3f6"),
        ]
        let actual = PocketTTSManifest.files
        XCTAssertEqual(actual.count, expected.count)
        for (file, want) in zip(actual, expected) {
            XCTAssertEqual(file, PocketTTSFile(repo: want.0, path: want.1, size: want.2, sha256: want.3), want.1)
        }
    }

    func testTotalBytesIsTheSumOfTheFiles() {
        XCTAssertEqual(PocketTTSManifest.totalBytes, 437_400_422)
        XCTAssertEqual(PocketTTSManifest.files.reduce(0) { $0 + $1.size }, PocketTTSManifest.totalBytes)
    }

    func testEveryDigestIsLowercaseHexSHA256AndPathsAreUnique() {
        for file in PocketTTSManifest.files {
            XCTAssertEqual(file.sha256.count, 64, file.path)
            XCTAssertTrue(file.sha256.allSatisfy { "0123456789abcdef".contains($0) }, file.path)
        }
        let keys = PocketTTSManifest.files.map { "\($0.repo)/\($0.path)" }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    /// The first-use download carries exactly one voice embedding, the
    /// default; every other voice is fetched only when picked.
    func testOnlyThePinnedVoiceIsDownloaded() {
        let voices = PocketTTSManifest.files.filter { $0.path.hasPrefix("languages/english/embeddings/") }
        XCTAssertEqual(voices.map(\.path), ["languages/english/embeddings/\(PocketTTSManifest.voice).safetensors"])
        XCTAssertFalse(PocketTTSManifest.files.contains { $0.path.contains("float32_lsd1") || $0.path.contains("flowlm_float32") })
    }

    func testResolveURLsUseTheRepoRevision() {
        let bundle = PocketTTSManifest.files.first { $0.repo == .bundles }!
        XCTAssertEqual(
            PocketTTSManifest.url(for: bundle)?.absoluteString,
            "https://huggingface.co/rahulrachuri/pocket-tts-coreai/resolve/d774360b912aa70d217e34204cef1cebfdadadd1/config.json")
        let weight = PocketTTSManifest.files.first { $0.repo == .weights }!
        XCTAssertEqual(
            PocketTTSManifest.url(for: weight)?.absoluteString,
            "https://huggingface.co/kyutai/pocket-tts-without-voice-cloning/resolve/e041936c75475d350b405bc870bcf7c22da4e9e6/"
                + "languages/english/embeddings/marius.safetensors")
    }

    // MARK: - Voices (task 01a20fdd stage 4)

    /// Every built-in voice of the pinned weights, as the HF tree API lists
    /// `languages/english/embeddings/` at e041936c (26 files).
    private static let pinnedVoiceNames: Set<String> = [
        "alba", "anna", "azelma", "bill_boerst", "caro_davy", "charles", "cosette", "eponine", "estelle", "eve", "fantine",
        "george", "giovanni", "jane", "javert", "jean", "juergen", "lola", "marius", "mary", "michael", "paul",
        "peter_yearsley", "rafael", "stuart_bell", "vera",
    ]

    func testTheManifestListsTheTwentyLicensedVoicesTheDefaultFirst() {
        let names = PocketTTSManifest.voices.map(\.name)
        XCTAssertEqual(
            names,
            [
                "marius", "javert", "bill_boerst", "caro_davy", "peter_yearsley", "stuart_bell", "estelle", "alba", "anna", "vera",
                "fantine", "charles", "paul", "eponine", "azelma", "george", "mary", "jane", "michael", "eve",
            ])
        XCTAssertEqual(Set(names).count, names.count)
        for voice in PocketTTSManifest.voices {
            XCTAssertEqual(voice.sha256.count, 64, voice.name)
            XCTAssertTrue(voice.sha256.allSatisfy { "0123456789abcdef".contains($0) }, voice.name)
            XCTAssertEqual(voice.file.repo, .weights)
            XCTAssertEqual(voice.file.path, "languages/english/embeddings/\(voice.name).safetensors")
            XCTAssertTrue((3_000_000...9_000_000).contains(voice.size), voice.name)
        }
        let marius = PocketTTSManifest.files.first { $0.path.hasSuffix("/marius.safetensors") }
        XCTAssertEqual(PocketTTSManifest.voices.first?.file, marius, "the default is the one the model download carries")
        XCTAssertEqual(PocketTTSManifest.voices.reduce(0) { $0 + $1.size }, 130_622_296)
        let alba = PocketTTSManifest.voice(named: "alba")
        XCTAssertEqual(alba?.size, 6_194_424)
        XCTAssertEqual(alba?.sha256, "69c32db63ca56843d994f81f343f62e0bf2d73f7e4c9bc73e44bb1110b1d8845")
        XCTAssertEqual(
            alba.flatMap { PocketTTSManifest.url(for: $0.file) }?.absoluteString,
            "https://huggingface.co/kyutai/pocket-tts-without-voice-cloning/resolve/e041936c75475d350b405bc870bcf7c22da4e9e6/"
                + "languages/english/embeddings/alba.safetensors")
    }

    /// Each source folder and the licence kyutai/tts-voices states for it.
    func testEveryListedVoiceComesFromACC0OrCCBYFolderOfTTSVoices() {
        let licences: [String: PocketTTSVoice.Licence] = [
            "voice-donations": .cc0, "voice-zero": .cc0, "unmute-prod-website": .cc0, "alba-mackenna": .ccBy4, "vctk": .ccBy4,
        ]
        for voice in PocketTTSManifest.voices {
            let folder = String(voice.source.split(separator: "/").first ?? "")
            XCTAssertEqual(licences[folder], voice.licence, "\(voice.name): \(voice.source)")
        }
    }

    /// cosette (expresso) and jean (ears) are CC BY-NC; giovanni, lola,
    /// juergen and rafael have no proven licence. None is ever listed or
    /// resolvable, and listed plus excluded is the whole pinned catalogue.
    func testNoNonCommercialOrUnprovenVoiceIsEverListed() {
        let excluded = Set(PocketTTSManifest.excludedVoices.keys)
        XCTAssertEqual(excluded, ["cosette", "jean", "giovanni", "lola", "juergen", "rafael"])
        let listed = Set(PocketTTSManifest.voices.map(\.name))
        XCTAssertTrue(listed.isDisjoint(with: excluded))
        XCTAssertEqual(listed.union(excluded), Self.pinnedVoiceNames)
        for name in excluded {
            XCTAssertNil(PocketTTSManifest.voice(named: name), name)
            XCTAssertNil(PocketVoice.entry(for: name), name)
            XCTAssertNil(PocketVoice.voice(for: PocketVoice.prefix + name), name)
        }
        XCTAssertFalse(PocketTTSManifest.voices.contains { $0.source.hasPrefix("expresso/") || $0.source.hasPrefix("ears/") })
        XCTAssertFalse(PocketVoice.entries.contains { $0.id.hasSuffix(":cosette") || $0.id.hasSuffix(":jean") })
    }

    func testPickerRowsReadPocketTTSAndTheVoice() {
        XCTAssertEqual(PocketVoice.entries.count, 20)
        XCTAssertEqual(PocketVoice.entry.name, "Pocket TTS (Marius)")
        XCTAssertEqual(PocketVoice.entry(for: "bill_boerst")?.name, "Pocket TTS (Bill Boerst)")
        XCTAssertEqual(PocketVoice.entry(for: "bill_boerst")?.id, "pocket-tts:bill_boerst")
        XCTAssertTrue(PocketVoice.entries.allSatisfy { $0.quality == .neural && $0.language == "en" && $0.name.hasPrefix("Pocket TTS (") })
    }

    /// The vendored VoiceGain covers eight voices (two of them excluded);
    /// every other listed one carries a measured RMS and is levelled to 0.10.
    func testVoicesOutsideTheVendoredGainAreLevelledWithAPeakClamp() {
        let vendored: Set<String> = ["alba", "azelma", "cosette", "eponine", "fantine", "javert", "jean", "marius"]
        for voice in PocketTTSManifest.voices {
            XCTAssertEqual(voice.measuredRMS == nil, vendored.contains(voice.name), voice.name)
        }
        XCTAssertEqual(PocketLoudness.gain(for: "peter_yearsley"), 0.10 / 0.026, accuracy: 1e-9)
        XCTAssertEqual(PocketLoudness.gain(for: "marius"), 1)
        let quiet: [Float] = [0.01, -0.02, 0.026]
        let up = PocketLoudness.level(quiet, voice: "peter_yearsley", vendoredGain: false)
        XCTAssertEqual(up[2], 0.1, accuracy: 1e-6)
        let loud: [Float] = [0.5, -0.4]
        let clamped = PocketLoudness.level(loud, voice: "stuart_bell", vendoredGain: false)
        XCTAssertEqual(clamped.map(abs).max() ?? 0, 0.99, accuracy: 1e-6, "the peak is clamped")
        XCTAssertEqual(PocketLoudness.level(quiet, voice: "peter_yearsley", vendoredGain: true), quiet, "never gained twice")
    }
}
