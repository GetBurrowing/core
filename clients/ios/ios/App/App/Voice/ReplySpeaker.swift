import AVFoundation

/// One change in a spoken reply, sent to the page as the `speech` event.
struct ReplySpeechEvent: Equatable {
    enum State: String {
        case started, finished, stopped, unheard
    }

    let id: String
    let state: State
    var reason: String?

    var data: [String: Any] {
        var data: [String: Any] = ["id": id, "state": state.rawValue]
        if let reason { data["reason"] = reason }
        return data
    }
}

/// What the plugin needs from the system voice.
@MainActor
protocol VoiceSpeaking: AnyObject {
    var onEvent: ((ReplySpeechEvent) -> Void)? { get set }
    /// True from `speak` until the utterance finishes or stops.
    var isSpeaking: Bool { get }
    /// Stops any utterance in flight (`stopped`, reason `replaced`), then
    /// speaks `text` in the voice `voiceID` (nil: the language's system voice).
    func speak(id: String, text: String, voiceID: String?)
    /// Stops the utterance in flight, if any, sending `stopped` with `reason`.
    func stop(reason: String)
}

/// The agent's reply, read by an on-device system voice for the current
/// language (task 01a20dc5): the one the page picked, else the best installed
/// (ReplyVoicePicker). No bundled voice, no network. The text is never logged.
@MainActor
final class ReplySpeaker: NSObject, VoiceSpeaking {
    var onEvent: ((ReplySpeechEvent) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance in flight and its page id.
    private var current: (utterance: AVSpeechUtterance, id: String)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { current != nil }

    func speak(id: String, text: String, voiceID: String?) {
        stop(reason: "replaced")
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice =
            voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        current = (utterance, id)
        synthesizer.speak(utterance)
    }

    func stop(reason: String) {
        guard let current else { return }
        // Cleared first: the delegate's didCancel for it is then ignored, so
        // the page gets exactly one `stopped`, with this reason.
        self.current = nil
        synthesizer.stopSpeaking(at: .immediate)
        onEvent?(ReplySpeechEvent(id: current.id, state: .stopped, reason: reason))
    }

    private func id(of utterance: AVSpeechUtterance) -> String? {
        guard let current, current.utterance === utterance else { return nil }
        return current.id
    }

    private func started(_ utterance: AVSpeechUtterance) {
        guard let id = id(of: utterance) else { return }
        onEvent?(ReplySpeechEvent(id: id, state: .started))
    }

    private func ended(_ utterance: AVSpeechUtterance, _ state: ReplySpeechEvent.State, reason: String? = nil) {
        guard let id = id(of: utterance) else { return }
        current = nil
        onEvent?(ReplySpeechEvent(id: id, state: state, reason: reason))
    }
}

extension ReplySpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.started(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.ended(utterance, .finished) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Only an utterance the system cancelled reaches here still current.
        Task { @MainActor in self.ended(utterance, .stopped, reason: "system") }
    }
}
