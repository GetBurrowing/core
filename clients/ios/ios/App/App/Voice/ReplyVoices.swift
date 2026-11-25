import AVFoundation

/// One on-device system voice the reply can be read in (task 01a20dc5).
/// Only voices already on the phone are listed; nothing is downloaded and
/// no voice is bundled.
struct ReplyVoice: Equatable {
    /// Best first: neural (Pocket TTS, task 01a20fdd), premium, enhanced, default.
    enum Quality: String, CaseIterable {
        case neural, premium, enhanced, `default`

        var rank: Int {
            switch self {
            case .neural: 0
            case .premium: 1
            case .enhanced: 2
            case .default: 3
            }
        }
    }

    let id: String
    let name: String
    let quality: Quality
    let language: String

    var data: [String: Any] {
        ["id": id, "name": name, "quality": quality.rawValue, "language": language]
    }
}

/// The phone's installed voices; injected by tests.
protocol ReplyVoiceCatalog {
    /// Every installed voice, any language.
    func installedVoices() -> [ReplyVoice]
}

/// `AVSpeechSynthesisVoice.speechVoices()`: what iOS has installed.
struct SystemReplyVoiceCatalog: ReplyVoiceCatalog {
    func installedVoices() -> [ReplyVoice] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            ReplyVoice(
                id: voice.identifier, name: voice.name, quality: Self.quality(voice.quality),
                language: voice.language)
        }
    }

    static func quality(_ quality: AVSpeechSynthesisVoiceQuality) -> ReplyVoice.Quality {
        switch quality {
        case .premium: .premium
        case .enhanced: .enhanced
        default: .default
        }
    }
}

/// Which voice reads a reply. Pure, so the rules are unit-tested.
enum ReplyVoicePicker {
    /// The voices for `language` (e.g. "en-US"): its language ("en"), the
    /// exact region first within a quality, best quality first, then by name.
    static func voices(for language: String, in all: [ReplyVoice]) -> [ReplyVoice] {
        let base = languagePart(language)
        return all.filter { languagePart($0.language) == base }
            .sorted { lhs, rhs in
                if lhs.quality.rank != rhs.quality.rank { return lhs.quality.rank < rhs.quality.rank }
                let lhsExact = lhs.language == language
                let rhsExact = rhs.language == language
                if lhsExact != rhsExact { return lhsExact }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// The default: the best installed voice for the language.
    static func best(for language: String, in all: [ReplyVoice]) -> ReplyVoice? {
        voices(for: language, in: all).first
    }

    /// The voice to speak with. A requested voice that is not installed falls
    /// back to the default, and says so (`fellBack`).
    static func resolve(requested: String?, language: String, in all: [ReplyVoice]) -> (
        voice: ReplyVoice?, fellBack: Bool
    ) {
        if let requested, !requested.isEmpty {
            if let voice = all.first(where: { $0.id == requested }) { return (voice, false) }
            return (best(for: language, in: all), true)
        }
        return (best(for: language, in: all), false)
    }

    /// Picking Pocket TTS (task 01a20fdd stage 2): it reads the reply only
    /// when its model is `ready`. Otherwise the best system voice reads it,
    /// with `fellBack: true` and `reason` `model_not_ready` (downloading,
    /// compiling, failed or absent) or `unsupported` (the gate said no). Any
    /// other request resolves as `resolve(requested:language:in:)`.
    static func resolve(requested: String?, language: String, in all: [ReplyVoice], pocket: PocketVoice.Availability) -> (
        voice: ReplyVoice?, fellBack: Bool, reason: String?
    ) {
        guard let requested, PocketVoice.isPocket(requested) else {
            let (voice, fellBack) = resolve(requested: requested, language: language, in: all)
            return (voice, fellBack, nil)
        }
        switch pocket {
        case .ready: return (PocketVoice.entry, false, nil)
        case .notReady: return (best(for: language, in: all), true, "model_not_ready")
        case .unsupported: return (best(for: language, in: all), true, "unsupported")
        }
    }

    static func languagePart(_ language: String) -> String {
        String(language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }
}

/// The Pocket TTS row in the voice list (task 01a20fdd stage 2): one built-in
/// English voice, listed only where `PocketTTSSupport` says supported.
enum PocketVoice {
    enum Availability: Equatable {
        case unsupported, notReady, ready
    }

    static let prefix = "pocket-tts:"
    static let id = prefix + PocketTTSManifest.voice
    static let entry = ReplyVoice(id: id, name: "Pocket TTS (\(PocketTTSManifest.voice.capitalized))", quality: .neural, language: "en")

    static func isPocket(_ id: String) -> Bool { id.hasPrefix(prefix) }

    /// English only: the pinned checkpoint is `languages/english`.
    static func speaks(_ language: String) -> Bool { ReplyVoicePicker.languagePart(language) == "en" }
}
