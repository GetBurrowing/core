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

/// What the plugin needs from a reply voice: the system voice
/// (`ReplySpeaker`) or Pocket TTS (`PocketSpeaker`).
@MainActor
protocol VoiceSpeaking: AnyObject {
    var onEvent: ((ReplySpeechEvent) -> Void)? { get set }
    /// True from `speak` / `begin` until the reply finishes or stops.
    var isSpeaking: Bool { get }
    /// Stops any utterance in flight (`stopped`, reason `replaced`), then
    /// speaks `text` in the voice `voiceID` (nil: the language's system voice).
    func speak(id: String, text: String, voiceID: String?)
    /// Streaming (task 01a20fdd stage 2): stops any reply in flight
    /// (`replaced`) and opens reply `id`; its parts follow by `append`.
    func begin(id: String, voiceID: String?)
    /// One part of reply `id` (a sentence), spoken in `seq` order as soon as
    /// it can be. Ignored unless `id` is the open reply.
    func append(id: String, seq: Int, text: String)
    /// No more parts for `id`: `finished` follows the last one.
    func finish(id: String)
    /// Stops the reply in flight, if any, sending `stopped` with `reason`.
    func stop(reason: String)
}

/// Orders a streamed reply's parts by `seq`: a part is released only once
/// every earlier one has been. Pure, so it is unit-tested.
struct ReplyPartQueue {
    private var next = 0
    private var held: [Int: String] = [:]

    var isEmpty: Bool { held.isEmpty }

    /// The parts that are now in order, starting with this one if it is next.
    /// A repeated or old seq is dropped.
    mutating func add(seq: Int, text: String) -> [String] {
        guard seq >= next, held[seq] == nil else { return [] }
        held[seq] = text
        var ready: [String] = []
        while let part = held.removeValue(forKey: next) {
            ready.append(part)
            next += 1
        }
        return ready
    }

    /// Everything still held, in seq order (the reply is final).
    mutating func flush() -> [String] {
        let rest = held.keys.sorted().compactMap { held[$0] }
        if let last = held.keys.max() { next = last + 1 }
        held = [:]
        return rest
    }
}

/// The agent's reply, read by an on-device system voice for the current
/// language (task 01a20dc5): the one the page picked, else the best installed
/// (ReplyVoicePicker). No bundled voice, no network. The text is never logged.
/// A streamed reply queues one utterance per part (task 01a20fdd stage 2), so
/// the system voice also starts on the first sentence.
@MainActor
final class ReplySpeaker: NSObject, VoiceSpeaking {
    var onEvent: ((ReplySpeechEvent) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()

    private struct Reply {
        let id: String
        let voice: AVSpeechSynthesisVoice?
        var parts = ReplyPartQueue()
        /// Queued and not yet finished.
        var utterances: [AVSpeechUtterance] = []
        var final = false
        var started = false
    }

    /// The reply in flight.
    private var current: Reply?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { current != nil }

    func speak(id: String, text: String, voiceID: String?) {
        begin(id: id, voiceID: voiceID)
        append(id: id, seq: 0, text: text)
        finish(id: id)
    }

    func begin(id: String, voiceID: String?) {
        stop(reason: "replaced")
        let voice =
            voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        current = Reply(id: id, voice: voice)
    }

    func append(id: String, seq: Int, text: String) {
        guard current?.id == id else { return }
        let ready = current?.parts.add(seq: seq, text: text) ?? []
        queue(ready)
    }

    func finish(id: String) {
        guard current?.id == id else { return }
        current?.final = true
        queue(current?.parts.flush() ?? [])
        finishIfDone()
    }

    private func queue(_ texts: [String]) {
        for text in texts where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = current?.voice
            current?.utterances.append(utterance)
            synthesizer.speak(utterance)
        }
    }

    func stop(reason: String) {
        guard let current else { return }
        // Cleared first: the delegate's didCancel for each queued utterance is
        // then ignored, so the page gets exactly one `stopped`, with this reason.
        self.current = nil
        synthesizer.stopSpeaking(at: .immediate)
        onEvent?(ReplySpeechEvent(id: current.id, state: .stopped, reason: reason))
    }

    private func owns(_ utterance: AVSpeechUtterance) -> Bool {
        current?.utterances.contains { $0 === utterance } ?? false
    }

    private func started(_ utterance: AVSpeechUtterance) {
        guard owns(utterance), current?.started == false, let id = current?.id else { return }
        current?.started = true
        onEvent?(ReplySpeechEvent(id: id, state: .started))
    }

    private func finished(_ utterance: AVSpeechUtterance) {
        guard owns(utterance) else { return }
        current?.utterances.removeAll { $0 === utterance }
        finishIfDone()
    }

    private func finishIfDone() {
        guard let reply = current, reply.final, reply.utterances.isEmpty else { return }
        current = nil
        onEvent?(ReplySpeechEvent(id: reply.id, state: .finished))
    }

    private func cancelled(_ utterance: AVSpeechUtterance) {
        guard owns(utterance), let id = current?.id else { return }
        current = nil
        onEvent?(ReplySpeechEvent(id: id, state: .stopped, reason: "system"))
    }
}

extension ReplySpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.started(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Only an utterance the system cancelled reaches here still current.
        Task { @MainActor in self.cancelled(utterance) }
    }
}
