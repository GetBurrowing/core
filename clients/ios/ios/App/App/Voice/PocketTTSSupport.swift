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

/// What Pocket TTS downloads on first use (task 01a20fdd stage 1): fp16
/// bundles, Kyutai's English checkpoint and tokenizer, and ONE voice. Read
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
    /// The built-in voice. Its source is kyutai/tts-voices
    /// voice-donations/Selfie.wav (the weights README at the pinned revision),
    /// which that repo licenses CC0.
    static let voice = "marius"
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
