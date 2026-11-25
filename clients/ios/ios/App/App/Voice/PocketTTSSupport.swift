import Foundation

/// One file Pocket TTS needs, pinned to a Hugging Face revision.
struct PocketTTSFile: Equatable {
    enum Repo: Equatable {
        case bundles, weights
    }

    let repo: Repo
    let path: String
    let size: Int
    /// SHA-256 of the content. LFS files: the `lfs.oid` the HF tree API
    /// reports at the pinned revision. The small non-LFS files (the API gives
    /// only their git blob id): computed from the pinned `resolve` download,
    /// whose `git hash-object` matched the API's blob id (task 01a20fdd stage 1).
    let sha256: String
}

/// One built-in Pocket TTS voice (task 01a20fdd stage 4): its embedding in
/// the pinned weights, the kyutai/tts-voices clip it was computed from, and
/// that clip's licence.
struct PocketTTSVoice: Equatable {
    enum Licence: String {
        case cc0 = "CC0"
        case ccBy4 = "CC BY 4.0"
    }

    let name: String
    let size: Int
    let sha256: String
    /// The clip's path in kyutai/tts-voices.
    let source: String
    let licence: Licence
    /// Median RMS of three sentences at unity gain, measured on rock with the
    /// vendored host (fp16, seed 0) for the voices the vendored `VoiceGain`
    /// table does not cover; nil where it does. `PocketLoudness` levels them
    /// to the same 0.10 target.
    var measuredRMS: Double? = nil

    var file: PocketTTSFile {
        PocketTTSFile(repo: .weights, path: "languages/english/embeddings/\(name).safetensors", size: size, sha256: sha256)
    }

    /// "bill_boerst" -> "Bill Boerst".
    var displayName: String { name.split(separator: "_").map { $0.capitalized }.joined(separator: " ") }
}

/// What Pocket TTS downloads on first use (task 01a20fdd stage 1): fp16
/// bundles, Kyutai's English checkpoint and tokenizer, and the default voice. Read
/// from the HF API on 2026-11-24. Licences and sources: PocketTTS/THIRD_PARTY.md.
enum PocketTTSManifest {
    /// Core AI bundles, CC BY 4.0, ungated.
    static let bundlesRepo = "rahulrachuri/pocket-tts-coreai"
    static let bundlesRevision = "d774360b912aa70d217e34204cef1cebfdadadd1"
    /// Kyutai's checkpoint without voice cloning, CC BY 4.0, ungated. This is
    /// the revision the bundles were converted from (their README) and the one
    /// the vendored host pins; newer revisions change model.safetensors.
    static let weightsRepo = "kyutai/pocket-tts-without-voice-cloning"
    static let weightsRevision = "e041936c75475d350b405bc870bcf7c22da4e9e6"
    /// The default voice, downloaded with the model. Its source is
    /// kyutai/tts-voices voice-donations/Selfie.wav (the weights README at the
    /// pinned revision), which that repo licenses CC0.
    static let voice = "marius"

    /// Every built-in voice of the pinned weights whose source clip in
    /// kyutai/tts-voices is CC0 or CC BY 4.0 (task 01a20fdd stage 4), the
    /// default first. Each one's source is proven in PocketTTS/THIRD_PARTY.md.
    /// Size and SHA-256 are the `lfs.oid` of
    /// `languages/english/embeddings/<name>.safetensors` at `weightsRevision`
    /// (HF tree API, 2026-11-25), re-hashed from the pinned download. Only
    /// the default comes with the model; any other is fetched when picked.
    static let voices: [PocketTTSVoice] = [
        PocketTTSVoice(
            name: "marius", size: 6_194_424, sha256: "04f84efcb77a0547ba582c058db496f7ff4920891d49d37b9950d128422582a8", source: "voice-donations/Selfie.wav",
            licence: .cc0),
        PocketTTSVoice(
            name: "javert", size: 6_194_424, sha256: "0ae88e03ca4e76a0e16cbf321a807428febda9d9e9bc0358c02e7f9c9e2c263b", source: "voice-donations/Butter.wav",
            licence: .cc0),
        PocketTTSVoice(
            name: "bill_boerst", size: 6_735_096, sha256: "75610127d44e0b05b442154f80f89f993df235aecc6cad7070f11000d006c188",
            source: "voice-zero/bill_boerst.wav", licence: .cc0, measuredRMS: 0.044),
        PocketTTSVoice(
            name: "caro_davy", size: 5_260_536, sha256: "a5961b63a2e7a5cfd7edc383aa9042fb70fd14a9dee6310cdc633881a7f2449a", source: "voice-zero/caro_davy.wav",
            licence: .cc0, measuredRMS: 0.062),
        PocketTTSVoice(
            name: "peter_yearsley", size: 3_736_816, sha256: "dd977a6e15591e347c9a23fa7cc09e35a65b462917f5eeb162baff6dc9e3f685",
            source: "voice-zero/peter_yearsley.wav", licence: .cc0, measuredRMS: 0.026),
        PocketTTSVoice(
            name: "stuart_bell", size: 5_260_536, sha256: "5a49da7ca5df05d02587ec4a0981c0d318e045f68e24423c4203ce474d9b33dc",
            source: "voice-zero/stuart_bell.wav", licence: .cc0, measuredRMS: 0.021),
        PocketTTSVoice(
            name: "estelle", size: 8_258_808, sha256: "ccebef7f51762c7fc08870f5ecf268e8713551ae2c9f7984ddaec0c1e1c77153",
            source: "unmute-prod-website/developpeuse-3.wav", licence: .cc0, measuredRMS: 0.097),
        PocketTTSVoice(
            name: "alba", size: 6_194_424, sha256: "69c32db63ca56843d994f81f343f62e0bf2d73f7e4c9bc73e44bb1110b1d8845", source: "alba-mackenna/casual.wav",
            licence: .ccBy4),
        PocketTTSVoice(
            name: "anna", size: 7_816_440, sha256: "5ea82f78db006c9fd34e32ddd5aae82674b5b32646097977436458d00af80dfa", source: "vctk/p228_023_enhanced.wav",
            licence: .ccBy4, measuredRMS: 0.116),
        PocketTTSVoice(
            name: "vera", size: 6_735_096, sha256: "4bf50ddd957b5d218b264fdcf18efbbc7384d12da3eca98ca19b9e8dd6976acc", source: "vctk/p229_023_enhanced.wav",
            licence: .ccBy4, measuredRMS: 0.085),
        PocketTTSVoice(
            name: "fantine", size: 6_538_488, sha256: "51a8a4355d7f912d4959e4b1918314fda85ad47eba0a33a1d78a4a505d3465f5", source: "vctk/p244_023_enhanced.wav",
            licence: .ccBy4),
        PocketTTSVoice(
            name: "charles", size: 6_194_424, sha256: "299edc20182eeccfbf94e308626f259da4fbf339daa8d5905218f2b1774639b8", source: "vctk/p254_023_enhanced.wav",
            licence: .ccBy4, measuredRMS: 0.100),
        PocketTTSVoice(
            name: "paul", size: 6_980_856, sha256: "ed7a019168f94dfe77009f1b0de59387abc6fbb0db954d38ce722ecb77da61aa", source: "vctk/p259_023_enhanced.wav",
            licence: .ccBy4, measuredRMS: 0.102),
        PocketTTSVoice(
            name: "eponine", size: 6_931_704, sha256: "bda3b76a384ff355fe0350736387765946304ae8ca16e59f60ea3296a1c99cc6", source: "vctk/p262_023_enhanced.wav",
            licence: .ccBy4),
        PocketTTSVoice(
            name: "azelma", size: 7_963_896, sha256: "9f3e69f29075f991fd47774566865ef0e0e637cb5a35992c9919761b5b84b1de", source: "vctk/p303_023_enhanced.wav",
            licence: .ccBy4),
        PocketTTSVoice(
            name: "george", size: 6_243_576, sha256: "0c1c6c57c55a98d81254b33728150c7776f40647fe95258d1a6c1a02780b5d02", source: "vctk/p315_023_enhanced.wav",
            licence: .ccBy4, measuredRMS: 0.082),
        PocketTTSVoice(
            name: "mary", size: 6_194_424, sha256: "a8f2adf260cab966fe0a113d6b549d6efdeaa79de544ae0ff34b5b6a41445a59", source: "vctk/p333_023_enhanced.wav",
            licence: .ccBy4, measuredRMS: 0.111),
        PocketTTSVoice(
            name: "jane", size: 7_374_072, sha256: "37386227ca8ec5bf1b8e516c13d132ce5ff5437a304fe90129a1c62f41d9a008", source: "vctk/p339_023_enhanced.wav",
            licence: .ccBy4, measuredRMS: 0.090),
        PocketTTSVoice(
            name: "michael", size: 7_275_768, sha256: "8937f724ac4719b9aa51ea0ba1f18f9de0af7a663ad6263558266c1a53c9722d", source: "vctk/p360_023_enhanced.wav",
            licence: .ccBy4, measuredRMS: 0.082),
        PocketTTSVoice(
            name: "eve", size: 6_538_488, sha256: "ea9c2faf862a6c9d2cb61910fdf02842ae56940382cc8c1000fdb1b43269692b", source: "vctk/p361_023_enhanced.wav",
            licence: .ccBy4, measuredRMS: 0.077),
    ]

    /// Built-in voices of the pinned weights that are never listed or
    /// downloaded, and why (PocketTTS/THIRD_PARTY.md).
    static let excludedVoices: [String: String] = [
        "cosette": "expresso/ in kyutai/tts-voices: CC BY-NC 4.0, non-commercial",
        "jean": "ears/ in kyutai/tts-voices: CC BY-NC 4.0, non-commercial",
        "giovanni": "clip in the gated kyutai/pocket-tts repo, not kyutai/tts-voices: no licence for it",
        "lola": "clip in the gated kyutai/pocket-tts repo, not kyutai/tts-voices: no licence for it",
        "juergen": "clip in the gated kyutai/pocket-tts repo, not kyutai/tts-voices: no licence for it",
        "rafael": "clip in the gated kyutai/pocket-tts repo, not kyutai/tts-voices: no licence for it",
    ]

    /// The listed voice called `name`, or nil.
    static func voice(named name: String) -> PocketTTSVoice? { voices.first { $0.name == name } }
    static let dtype = "float16"

    static let files: [PocketTTSFile] = [
        PocketTTSFile(repo: .bundles, path: "config.json", size: 309, sha256: "ed23711e4b56b39e548824cb1bb5308e1cfd2df20b60a1902be6d18f00c13b15"),
        PocketTTSFile(
            repo: .bundles, path: "flow_decoder_float16_lsd1.aimodel/main.hash", size: 32,
            sha256: "377c05705eabf03b6ce8d3436ac40f62c228b7fec45aa417eb6ca9309771c4d2"),
        PocketTTSFile(
            repo: .bundles, path: "flow_decoder_float16_lsd1.aimodel/main.mlirb", size: 19_575_240,
            sha256: "7e4147e4c2216e88d111080cd21dc60edc033db680496a7413bdf2f12368e7b4"),
        PocketTTSFile(
            repo: .bundles, path: "flow_decoder_float16_lsd1.aimodel/metadata.json", size: 132,
            sha256: "9be04d06a4e1829144be3f80f4d4166788b5a27eaf20fd876d66bd6cd70e4c30"),
        PocketTTSFile(
            repo: .bundles, path: "flowlm_float16_s512.aimodel/main.hash", size: 32,
            sha256: "8b71dd5313c7275e430982f3098fa5d9b5605f66b2b78ae1404adfe323539284"),
        PocketTTSFile(
            repo: .bundles, path: "flowlm_float16_s512.aimodel/main.mlirb", size: 151_252_631,
            sha256: "06ea9405cf52be6dafd53d8092b398dfcd2f1f2f32a82b1dd14081ab442f9b61"),
        PocketTTSFile(
            repo: .bundles, path: "flowlm_float16_s512.aimodel/metadata.json", size: 132,
            sha256: "f5f8b8a28523c2e227c2f99c140d6b603ae4902a67a116847813b7320535fd23"),
        PocketTTSFile(
            repo: .bundles, path: "mimi_decoder_float32_ring272_outer_q_gs.aimodel/main.hash", size: 32,
            sha256: "90f5c20a0995ae8a6ccee233934e4369acf7ebd5e32df013d9c28cd0b33ebda6"),
        PocketTTSFile(
            repo: .bundles, path: "mimi_decoder_float32_ring272_outer_q_gs.aimodel/main.mlirb", size: 41_288_791,
            sha256: "1bef37bd9ca5ae0d42a876c043a76c6cf3804df8eede7e9d76e9dcda08849b7e"),
        PocketTTSFile(
            repo: .bundles, path: "mimi_decoder_float32_ring272_outer_q_gs.aimodel/metadata.json", size: 132,
            sha256: "a68817599da1e9dee0a32fbe74b3079a140c5a0480960c14f6cf71bd0bb0cfbb"),
        PocketTTSFile(
            repo: .weights, path: "languages/english/embeddings/marius.safetensors", size: 6_194_424,
            sha256: "04f84efcb77a0547ba582c058db496f7ff4920891d49d37b9950d128422582a8"),
        PocketTTSFile(
            repo: .weights, path: "languages/english/model.safetensors", size: 219_029_196,
            sha256: "be9c6b4876d3f30740a8225dfcaa2e43dc4aeb753c15272735bee16bbb4abb0a"),
        PocketTTSFile(
            repo: .weights, path: "languages/english/tokenizer.model", size: 59_339,
            sha256: "d461765ae179566678c93091c5fa6f2984c31bbe990bf1aa62d92c64d91bc3f6"),
    ]

    /// Every byte of `files`: what a first use downloads.
    static let totalBytes = 437_400_422

    static func revision(of repo: PocketTTSFile.Repo) -> String {
        repo == .bundles ? bundlesRevision : weightsRevision
    }

    static func repoID(of repo: PocketTTSFile.Repo) -> String {
        repo == .bundles ? bundlesRepo : weightsRepo
    }

    /// `https://huggingface.co/<repo>/resolve/<revision>/<path>`.
    static func url(for file: PocketTTSFile) -> URL? {
        URL(string: "https://huggingface.co/\(repoID(of: file.repo))/resolve/\(revision(of: file.repo))/\(file.path)")
    }
}

/// Whether this iPhone can run Pocket TTS, and if not, why. Mirrors
/// `VoiceCapability.decide`. Where the answer is no, the reply is read by a
/// system voice exactly as before.
enum PocketTTSSupport {
    /// Below this much physical memory the gate says `low_memory`.
    ///
    /// Where 5 GiB comes from: the DEBUG probe (PocketTTSProbe.swift) on
    /// iPhone19,4, iOS 27.2.1, 11,570 MB physical memory, 2026-11-24 23:37Z
    /// (task 01a20fdd stage 1). The app's phys_footprint peaked at 582 MB,
    /// during the first warm-up synthesis right after the first load (534 MB
    /// at load, 445 MB while verifying the download, 220 MB for a 26 s
    /// paragraph). footprint + os_proc_available_memory stayed at 3,375 MB,
    /// so that phone's jetsam limit is about 29% of its RAM. Headroom: 2x the
    /// peak (1,164 MB) must fit beside the shell. At the same ratio (an
    /// inference, NOT measured on other phones) a 6 GB iPhone, which reports
    /// about 5.5 GiB, gets about 1.6 GB and passes; a 4 GB one gets about
    /// 1.1 GB, under 2x the peak, and is refused. 5 GiB sits between the two.
    static let minimumPhysicalMemoryBytes: UInt64 = 5 * 1024 * 1024 * 1024

    /// The OS major Pocket TTS needs (Core AI).
    static let minimumOSMajor = 27

    /// os_too_old | simulator | no_core_ai | low_memory, or nil when supported.
    static func decide(osMajor: Int, hasCoreAI: Bool, physicalMemoryBytes: UInt64, isSimulator: Bool) -> (
        supported: Bool, reason: String?
    ) {
        let reason: String?
        if osMajor < minimumOSMajor {
            reason = "os_too_old"
        } else if isSimulator {
            reason = "simulator"
        } else if !hasCoreAI {
            reason = "no_core_ai"
        } else if physicalMemoryBytes < minimumPhysicalMemoryBytes {
            reason = "low_memory"
        } else {
            reason = nil
        }
        return (reason == nil, reason)
    }

    /// The gate for this process.
    static func current() -> (supported: Bool, reason: String?) {
        #if targetEnvironment(simulator)
            let isSimulator = true
        #else
            let isSimulator = false
        #endif
        return decide(
            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, hasCoreAI: coreAILoaded(),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, isSimulator: isSimulator)
    }

    /// CoreAI is weak-linked into the app, so on an OS that ships it dyld has
    /// already loaded it; RTLD_NOLOAD only asks, never loads.
    private static func coreAILoaded() -> Bool {
        #if canImport(CoreAI)
            guard let handle = dlopen("/System/Library/Frameworks/CoreAI.framework/CoreAI", RTLD_NOLOAD) else { return false }
            dlclose(handle)
            return true
        #else
            return false
        #endif
    }
}
