import Foundation

/// What Siri and Shortcuts say, from the canvas "Burrow iOS: intents,
/// widgets and iPad" (01a10db8), "Siri spoken responses" table. Pure, so
/// every line is testable.
enum IntentCopy {
    // MARK: Send message

    static func sendConfirm(message: String, space: String, install: String?) -> String {
        "Send \"\(message)\" to \(space)\(on(install))?"
    }

    static func sent(space: String) -> String { "Sent to \(space)." }

    // MARK: Approve and reject

    static func approveConfirm(isPlan: Bool, title: String, space: String?, install: String?) -> String {
        let consequence =
            isPlan
            ? "Agents start building as soon as you approve."
            : "The agent carries on as soon as you approve."
        return "Approve the \(noun(isPlan)) \(title)\(inSpace(space))\(on(install))? \(consequence)"
    }

    static func approved(isPlan: Bool) -> String {
        isPlan ? "Approved. Agents are starting." : "Approved."
    }

    /// Reject asks for the note in the same breath as it names the item.
    static func rejectNotePrompt(isPlan: Bool, title: String, space: String?, install: String?) -> String {
        "Reject the \(noun(isPlan)) \(title)\(inSpace(space))\(on(install))? It goes back to the agent with your note. What should the note say?"
    }

    static func rejectConfirm(isPlan: Bool, title: String, space: String?, install: String?) -> String {
        "Reject the \(noun(isPlan)) \(title)\(inSpace(space))\(on(install))? It goes back to the agent with your note."
    }

    static let rejected = "Rejected and sent back with your note."

    /// 409 `already_handled`. `by` is null when nobody is named (a plan
    /// that was rejected rather than approved).
    static func alreadyHandled(by name: String?) -> String {
        guard let name, !name.isEmpty else { return "Already handled." }
        return "Already approved by \(name)."
    }

    // MARK: What's waiting

    static let nothingWaiting = "Nothing is waiting for you."

    /// Approvals and tasks: the API counts both and nothing else (the
    /// canvas sample's "mentions" has no count behind it).
    static func waiting(approvals: Int, tasks: Int, firstTitle: String?) -> String {
        var parts: [String] = []
        if approvals > 0 { parts.append(plural(approvals, "approval")) }
        if tasks > 0 { parts.append(plural(tasks, "task")) }
        guard !parts.isEmpty else { return nothingWaiting }
        var line = "You have \(parts.joined(separator: " and "))."
        if let firstTitle, !firstTitle.isEmpty { line += " The first is \(firstTitle)." }
        return line
    }

    static func andMore(_ count: Int) -> String { "And \(count) more" }

    // MARK: Ask an agent

    static func agentSays(agent: String, reply: String) -> String {
        let lead = firstSentences(reply, count: 2)
        let end = lead.last.map { ".!?".contains($0) } ?? true
        return "\(agent) says: \(lead)\(end ? "" : ".")"
    }

    static func agentTimedOut(agent: String) -> String {
        "\(agent) is still working on it. Burrow will notify you."
    }

    static func agentWorking(agent: String) -> String { "\(agent) is working" }

    static func agentTimedOutSnippet(agent: String) -> String {
        "\(agent) is still working. Burrow will notify you when the reply is ready."
    }

    // MARK: Meetings

    static func meetingStarted(space: String?) -> String {
        guard let space, !space.isEmpty else { return "Starting a meeting." }
        return "Starting a meeting for \(space)."
    }

    static let whichSpaceForMeeting = "Which space is the meeting for?"

    // MARK: Entity subtitles (canvas "Spotlight entities")

    /// Subtitles lead with the type word; with more than one install the
    /// install name goes last.
    static func subtitle(_ parts: [String?], install: String?) -> String {
        (parts + [install]).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: Helpers

    static func firstSentences(_ text: String, count: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var sentences: [String] = []
        trimmed.enumerateSubstrings(in: trimmed.startIndex..<trimmed.endIndex, options: .bySentences) { sentence, _, _, stop in
            if let sentence { sentences.append(sentence.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if sentences.count >= count { stop = true }
        }
        return sentences.isEmpty ? trimmed : sentences.joined(separator: " ")
    }

    static func plural(_ count: Int, _ word: String) -> String {
        "\(count) \(word)\(count == 1 ? "" : "s")"
    }

    private static func noun(_ isPlan: Bool) -> String { isPlan ? "plan" : "review" }

    private static func inSpace(_ space: String?) -> String {
        guard let space, !space.isEmpty else { return "" }
        return " in \(space)"
    }

    private static func on(_ install: String?) -> String {
        guard let install, !install.isEmpty else { return "" }
        return " on \(install)"
    }
}
