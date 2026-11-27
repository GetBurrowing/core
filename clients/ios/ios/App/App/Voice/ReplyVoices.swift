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
    /// when its model, and the picked voice, are `ready`. Otherwise the best system voice reads it,
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
        // A Pocket id that is not a listed voice (an excluded one included)
        // is never spoken: the default reads, as for a missing system voice.
        guard let entry = PocketVoice.voice(for: requested).flatMap({ PocketVoice.entry(for: $0.name) }) else {
            return (best(for: language, in: all), true, "unknown_voice")
        }
        switch pocket {
        case .ready: return (entry, false, nil)
        case .notReady: return (best(for: language, in: all), true, "model_not_ready")
        case .unsupported: return (best(for: language, in: all), true, "unsupported")
        }
    }

    static func languagePart(_ language: String) -> String {
        String(language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }
}

/// The Pocket TTS rows in the voice list: one per built-in voice in
/// `PocketTTSManifest.voices` (task 01a20fdd stages 2 and 4), English only,
/// listed only where `PocketTTSSupport` says supported.
enum PocketVoice {
    enum Availability: Equatable {
        case unsupported, notReady, ready
    }

    static let prefix = "pocket-tts:"
    /// The default voice's id, downloaded with the model.
    static let id = prefix + PocketTTSManifest.voice
    static let entry = entry(for: PocketTTSManifest.voice)!

    /// Every listed voice, the default first.
    static var entries: [ReplyVoice] { PocketTTSManifest.voices.compactMap { entry(for: $0.name) } }

    static func isPocket(_ id: String) -> Bool { id.hasPrefix(prefix) }

    /// The listed voice an id names; nil for anything not in the manifest
    /// (an excluded voice included).
    static func voice(for id: String) -> PocketTTSVoice? {
        guard isPocket(id) else { return nil }
        return PocketTTSManifest.voice(named: String(id.dropFirst(prefix.count)))
    }

    /// "Pocket TTS (<Voice>)".
    static func entry(for name: String) -> ReplyVoice? {
        guard let voice = PocketTTSManifest.voice(named: name) else { return nil }
        return ReplyVoice(id: prefix + voice.name, name: "Pocket TTS (\(voice.displayName))", quality: .neural, language: "en")
    }

    /// English only: the pinned checkpoint is `languages/english`.
    static func speaks(_ language: String) -> Bool { ReplyVoicePicker.languagePart(language) == "en" }
}
