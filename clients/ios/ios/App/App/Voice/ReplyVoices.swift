import AVFoundation

/// One on-device system voice the reply can be read in (task 01a20dc5).
/// Only voices already on the phone are listed; nothing is downloaded and
/// no voice is bundled.
struct ReplyVoice: Equatable {
    /// Best first: premium, then enhanced, then default.
    enum Quality: String, CaseIterable {
        case premium, enhanced, `default`

        var rank: Int {
            switch self {
            case .premium: 0
            case .enhanced: 1
            case .default: 2
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

    private static func languagePart(_ language: String) -> String {
        String(language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }
}
