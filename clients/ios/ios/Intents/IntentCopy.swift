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

    // MARK: Messages domain (task 01a111bb)

    static let messageEdited = "Edited."
    static let messageUnsent = "Unsent."
    static let markedRead = "Marked as read."
    static let draftOpened = "Opened in Burrow."

    /// A conversation's spoken title: "general · Acme". The org tells two
    /// same-named spaces in two orgs apart; a DM or org-less space is its
    /// name alone.
    static func conversationTitle(name: String, org: String?) -> String {
        guard let org, !org.isEmpty else { return name }
        return "\(name) · \(org)"
    }

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

    /// What Siri reads aloud for an agent's reply: `SpokenReply.text`, so
    /// markdown never reaches the voice and a long reply is cut short. The
    /// chat and the snippet keep the full reply.
    static func agentSays(agent: String, reply: String) -> String {
        let spoken = SpokenReply.text(reply)
        guard !spoken.isEmpty else { return "\(agent) replied. \(fullReplyInBurrow)" }
        return "\(agent) says: \(spoken)"
    }

    /// Added after a spoken reply that was cut short.
    static let fullReplyInBurrow = "The full reply is in Burrow."

    /// The line posted after a question asked through Siri's Ask. The
    /// message API has no field the agent sees and the chat hides, so the
    /// request rides in the message itself, after the question.
    static let askedByVoice =
        "(Asked by voice through Siri, which reads the reply aloud: please answer in one to three short plain sentences, "
        + "with no markdown, lists, links, code or tables.)"

    /// The text an Ask posts: the question, a blank line, then `askedByVoice`.
    static func voiceQuestion(_ question: String) -> String { "\(question)\n\n\(askedByVoice)" }

    /// Siri's follow-up when an Ask has no question yet.
    static func whatShouldIAsk(agent: String) -> String { "What should I ask \(agent)?" }

    static func agentTimedOut(agent: String) -> String {
        "\(agent) is still working on it. Burrow will notify you."
    }

    static let whichProjectForMeeting = "Which project is the meeting for?"
    static let whatIsTheTask = "What's the task?"

    static func taskCreated(title: String, project: String) -> String { "Created \"\(title)\" in \(project)." }

    /// The confirmation before a group call rings everyone in it.
    static func callConversationConfirm(name: String) -> String {
        "Call \(name)? This rings everyone in it, up to 25 people."
    }

    static func callStarted(name: String, video: Bool) -> String {
        video ? "Calling \(name). Burrow calls are audio only, so this is an audio call." : "Calling \(name)."
    }

    /// iOS 27, after the 90 s window: the reply comes as a notification.
    static func agentReplyWillNotify(agent: String) -> String {
        "\(agent) is still working on it. The reply will arrive as a notification."
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

/// An agent's reply as Siri should speak it. Pure, so every rule is
/// testable. Markdown becomes plain speech: heading, bold, italic, strike
/// and code marks go; fenced code blocks, rules, bare URLs and table
/// separator rows are dropped; a link or image keeps only its text; each
/// bullet, numbered item, heading and table row becomes its own sentence
/// (table cells joined with commas); whitespace collapses to single spaces.
/// Then the text is capped at `cap` characters, cut at a sentence boundary
/// (a word boundary if the first sentence alone is longer), and
/// `IntentCopy.fullReplyInBurrow` is added when anything was cut.
enum SpokenReply {
    static let cap = 300

    static func text(_ reply: String, cap: Int = SpokenReply.cap) -> String {
        capped(plain(reply), at: cap)
    }

    /// The reply with its markdown turned into plain sentences, uncapped.
    static func plain(_ reply: String) -> String {
        var units: [String] = []
        var paragraph: [String] = []
        var inFence = false
        func endParagraph() {
            let joined = paragraph.joined(separator: " ")
            paragraph = []
            if let unit = sentence(joined) { units.append(unit) }
        }
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                endParagraph()
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if line.isEmpty || matches(line, #"^([-*_])(\s*\1){2,}$"#) {
                endParagraph()
                continue
            }
            if let item = structural(line) {
                endParagraph()
                if let unit = sentence(item) { units.append(unit) }
            } else {
                paragraph.append(replacing(line, #"^(>\s?)+"#, with: ""))
            }
        }
        endParagraph()
        var text = units.joined(separator: " ")
        text = replacing(text, #"\s+"#, with: " ")
        text = replacing(text, #"\s+([.,!?;:])"#, with: "$1")
        text = text.trimmingCharacters(in: .whitespaces)
        if let last = text.last, ":;,-\u{2013}\u{2014}".contains(last) { text = String(text.dropLast()) + "." }
        return text
    }

    /// A heading, list item or table row with its marker removed, or nil
    /// for a line of running text. A table separator row comes back empty.
    private static func structural(_ line: String) -> String? {
        if line.hasPrefix("|") || line.hasSuffix("|") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if cells.allSatisfy({ matches($0, #"^:?-+:?$"#) }) { return "" }
            return cells.joined(separator: ", ")
        }
        if matches(line, #"^#{1,6}\s"#) {
            return replacing(replacing(line, #"^#{1,6}\s+"#, with: ""), #"\s+#+$"#, with: "")
        }
        if matches(line, #"^([-*+\x{2022}]|\d{1,3}[.)])\s"#) {
            let item = replacing(line, #"^([-*+\x{2022}]|\d{1,3}[.)])\s+"#, with: "")
            return replacing(item, #"^\[[ xX]\]\s+"#, with: "")
        }
        return nil
    }

    /// `text` with inline markdown removed and ending in punctuation, or nil
    /// when nothing speakable is left (a URL-only line, say).
    private static func sentence(_ text: String) -> String? {
        var line = replacing(text, #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1")
        line = replacing(line, #"\[([^\]]+)\]\([^)]*\)"#, with: "$1")
        line = replacing(line, #"<(https?://|mailto:)[^>]*>"#, with: "")
        line = replacing(line, #"(https?://|www\.)[^\s)\]>]+"#, with: "")
        line = replacing(line, #"`+([^`]*)`+"#, with: "$1")
        line = replacing(line, #"(\*\*|__)(.+?)\1"#, with: "$2")
        line = replacing(line, #"~~(.+?)~~"#, with: "$1")
        line = replacing(line, #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, with: "$1")
        line = replacing(line, #"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#, with: "$1")
        line = replacing(line, #"\*{2,}|`"#, with: "")
        line = replacing(line, #"\(\s*\)"#, with: "")
        line = replacing(line, #"\s+"#, with: " ").trimmingCharacters(in: .whitespaces)
        guard line.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let body = line.trimmingCharacters(in: CharacterSet(charactersIn: ")]\"'\u{201D}\u{2019}"))
        if let last = body.last, ".!?:\u{2026}".contains(last) { return line }
        return line + "."
    }

    /// At most `cap` characters of whole sentences, plus the full-reply line
    /// when anything was cut.
    static func capped(_ text: String, at cap: Int) -> String {
        guard text.count > cap else { return text }
        var kept = ""
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sentence, _, _, stop in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty else { return }
            let next = kept.isEmpty ? sentence : "\(kept) \(sentence)"
            guard next.count <= cap else {
                stop = true
                return
            }
            kept = next
        }
        if kept.isEmpty {
            let head = String(text.prefix(cap))
            let words = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
            kept = words.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-")) + "\u{2026}"
        }
        return "\(kept) \(IntentCopy.fullReplyInBurrow)"
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func replacing(_ text: String, _ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
