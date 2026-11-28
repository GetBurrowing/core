import AVFoundation
import Foundation

/// The reply voice the person last chose in the Voice tab (device rev 3,
/// task 01a21e75): a system voice id or a Pocket TTS id. The page keeps its
/// pick in web storage and passes it with every reply it asks the plugin to
/// read, so `BurrowVoicePlugin` records it here, in the App Group, each
/// time. A turn started from the Voice control or widget has no page and
/// reads it back, so its reply is spoken in the same voice. A voice id only:
/// never text.
struct ReplyVoiceChoice {
    static let key = "burrow.voice.reply.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: InstallStore.appGroup)) {
        self.defaults = defaults ?? .standard
    }

    var voiceID: String? { defaults.string(forKey: Self.key).flatMap { $0.isEmpty ? nil : $0 } }

    /// Records a pick; a reply sent with no voice leaves the last pick as it is.
    func record(_ voiceID: String?) {
        guard let voiceID, !voiceID.isEmpty, voiceID != self.voiceID else { return }
        defaults.set(voiceID, forKey: Self.key)
    }
}

/// The voice a native turn's reply is read in: the stored choice, resolved
/// exactly as the Voice tab resolves it (`ReplyVoicePicker`). A Pocket TTS
/// pick is read by Pocket TTS whenever its model and voice are on the
/// phone; only when they are not (or the phone cannot run it) does the best
/// system voice read, as in the tab.
enum NativeReplyVoice {
    struct Pick: Equatable {
        let pocket: Bool
        let voiceID: String?
        let reason: String?
    }

    static func pick(choice: String?, language: String, installed: [ReplyVoice], pocket: PocketVoice.Availability) -> Pick {
        let resolved = ReplyVoicePicker.resolve(requested: choice, language: language, in: installed, pocket: pocket)
        let id = resolved.voice?.id
        return Pick(pocket: id.map(PocketVoice.isPocket) ?? false, voiceID: id, reason: resolved.reason)
    }

    /// Whether the stored Pocket voice can be read now, from the files on disk.
    @MainActor
    static func pocketAvailability(_ choice: String?, supported: Bool = PocketTTSSupport.current().supported) -> PocketVoice.Availability {
        guard let choice, PocketVoice.isPocket(choice), supported else { return .unsupported }
        let root = PocketModelStore.defaultRoot()
        let model = PocketModelStore(root: root, fetcher: HTTPRangeFetcher(), engine: PocketVoiceFileLoader())
        guard model.state == .ready else { return .notReady }
        guard let voice = PocketVoice.voice(for: choice), voice.name != PocketTTSManifest.voice else { return .ready }
        let file = PocketModelStore(root: root, files: [voice.file], fetcher: HTTPRangeFetcher(), engine: PocketVoiceFileLoader())
        return file.state == .ready ? .ready : .notReady
    }

    /// The live pick for this phone.
    @MainActor
    static func current(choice: ReplyVoiceChoice = ReplyVoiceChoice()) -> Pick {
        let stored = choice.voiceID
        return pick(
            choice: stored, language: AVSpeechSynthesisVoice.currentLanguageCode(), installed: SystemReplyVoiceCatalog().installedVoices(),
            pocket: pocketAvailability(stored))
    }
}
