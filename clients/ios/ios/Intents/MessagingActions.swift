import Foundation

// The work behind the iOS 27 messages-domain intents (task 01a111bb), with
// no iOS 27 or App Intents types in the way so it builds and is testable on
// every runtime. Each schema intent in MessagingIntents.swift is a thin
// wrapper over one of these.
//
// Rules kept here:
// - every id is `<host>|<uuid>` and every request goes to that host only;
// - a send asks `confirm` BEFORE any request, a person's DM included;
// - nothing logs a message, a name or a question (IntentLog only).

/// Who a message goes to: a person (human or agent) or a conversation.
enum MessageDestinationRef: Equatable {
    case person(id: String, name: String, isAgent: Bool)
    case conversation(id: String, name: String)

    var entityID: String {
        switch self {
        case .person(let id, _, _), .conversation(let id, _): return id
        }
    }

    var name: String {
        switch self {
        case .person(_, let name, _), .conversation(_, let name): return name
        }
    }
}

/// A sent message: its id, and the conversation it is in.
struct SentMessageRef: Equatable {
    /// `<host>|<message uuid>`.
    let id: String
    /// `<host>|<space uuid>`.
    let conversationID: String
}

/// What the messages-domain intents need from Burrow, in plain values.
struct MessagingActions {
    var env: IntentEnvironment = .current

    private var actions: IntentActions { IntentActions(env: env) }

    /// Sends `text`. A person's DM is found or created first (an agent's
    /// through `/agents/:id/dm`, a human's through `/people/:id/dm`); a
    /// conversation is posted to directly. `confirm` runs before ANY
    /// request.
    func send(to destination: MessageDestinationRef, text raw: String, confirm: IntentActions.Confirm) async throws -> SentMessageRef {
        let ref = try actions.ref(destination.entityID)
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IntentFailure.emptyMessage }
        try await confirm(IntentCopy.sendConfirm(message: text, space: destination.name, install: env.disambiguator(ref.host)))

        let spaceID: String
        switch destination {
        case .conversation:
            spaceID = ref.uuid
        case .person(_, _, let isAgent):
            if isAgent {
                spaceID = try await call("agent_dm", ref.host) { try await env.client.dmWithAgent(host: ref.host, agentID: ref.uuid) }.spaceID
            } else {
                spaceID = try await call("person_dm", ref.host) { try await env.client.personDM(host: ref.host, userID: ref.uuid) }.spaceID
            }
        }
        let messageID = try await call("send_message", ref.host) { try await env.client.sendText(host: ref.host, spaceID: spaceID, text: text) }
        return SentMessageRef(
            id: EntityRef(host: ref.host, uuid: messageID).id, conversationID: EntityRef(host: ref.host, uuid: spaceID).id)
    }

    /// Edits a sent message. A message an agent began work on answers the
    /// server's 409, spoken with the name of who began it.
    func edit(messageID: String, text raw: String) async throws -> String {
        let ref = try actions.ref(messageID)
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IntentFailure.emptyMessage }
        let outcome = try await call("edit_message", ref.host) { try await env.client.editMessage(host: ref.host, messageID: ref.uuid, text: text) }
        switch outcome {
        case .edited: return IntentCopy.messageEdited
        case .frozen(let by): throw IntentFailure.messageFrozen(by: by)
        }
    }

    func unsend(messageID: String) async throws -> String {
        let ref = try actions.ref(messageID)
        try await call("unsend_message", ref.host) { try await env.client.unsendMessage(host: ref.host, messageID: ref.uuid) }
        return IntentCopy.messageUnsent
    }

    /// Marks read up to the message. Unread is not something Burrow can
    /// do: the server answers 422 `not_supported`, and that is what is said.
    func setRead(messageID: String, conversationID: String, isRead: Bool) async throws -> String {
        let ref = try actions.ref(messageID)
        guard let conversation = EntityRef(conversationID), conversation.host == ref.host else { throw IntentFailure.notFound }
        let outcome = try await call("mark_read", ref.host) {
            try await env.client.markRead(host: ref.host, spaceID: conversation.uuid, messageID: ref.uuid, read: isRead)
        }
        switch outcome {
        case .marked: return IntentCopy.markedRead
        case .notSupported: throw IntentFailure.cannotMarkUnread
        }
    }

    private func call<T>(_ route: String, _ host: String, _ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            IntentLog.route(route, host: host, status: 200)
            return value
        } catch {
            IntentLog.route(route, host: host, status: EntityCatalog.status(of: error))
            throw IntentFailure.from(error, host: host, env: env)
        }
    }
}
