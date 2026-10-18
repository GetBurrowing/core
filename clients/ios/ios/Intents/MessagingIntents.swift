import AppIntents
import Foundation
import GeoToolbox

// BURROW_APP: set for the App target only (project.yml). Siri refuses a
// schema intent that more than one bundle declares (ToolDiscoveryError 4,
// "Multiple flow tools found"), and ../Intents is compiled into
// BurrowWidgets and NotificationService too, so every schema intent and
// everything that names one is App-only (task 01a111bb).
#if BURROW_APP

// The iOS 27 messages domain (task 01a111bb stage 3). Apple makes this
// domain all-or-nothing: an app that adopts one of its five schemas must
// adopt all five, and the build checks it. So all five are here, and each
// is a thin wrapper over MessagingActions (which builds and is tested on
// every runtime).
//
// The old SendMessageIntent (with its `space` parameter) is untouched and
// keeps serving existing Shortcuts on every iOS version.

private func spoken(_ text: String) -> IntentDialog {
    IntentDialog("\(text)")
}

@available(iOS 27, *)
extension MessageDestination {
    /// The one Burrow destination this union names, or nil when it names
    /// none Burrow can send to (a group of several people, or a contact
    /// that is not a Burrow person).
    var burrowDestination: MessageDestinationRef? {
        switch self {
        case .messagePerson(let person):
            return .person(id: person.id, name: person.name, isAgent: person.isAgent)
        case .messagePeople(let people):
            guard people.count == 1, let person = people.first else { return nil }
            return .person(id: person.id, name: person.name, isAgent: person.isAgent)
        case .people(let people):
            guard people.count == 1, case .applicationDefined(let id) = people[0].identifier,
                let person = PeopleCache.shared.entity(for: id)
            else { return nil }
            return .person(id: person.id, name: person.name, isAgent: person.isAgent)
        }
    }

    /// The case name, for the log.
    var caseName: String {
        switch self {
        case .people(let people): return "people(\(people.count))"
        case .messagePerson: return "messagePerson"
        case .messagePeople(let people): return "messagePeople(\(people.count))"
        }
    }

    /// The one Burrow person this destination names (task 01a111bb stage
    /// 7): a system person or an unresolved entity through PersonResolver,
    /// asking `choose` when several match. A resolved entity is the one Siri
    /// picked from the index, which on two installs may be the wrong
    /// namesake (round 8, "Message Sam"): unless `confirmsInstall` is
    /// false (a Shortcut that set the Install), it is used only if no one
    /// on another signed-in install answers to the same name, else `choose`
    /// asks (PersonResolver.confirmInstall). Throws a spoken failure, never
    /// a bare one, and logs each step.
    func resolvedBurrowDestination(
        site: String, env: IntentEnvironment = .current, confirmsInstall: Bool = true, choose: PersonResolver.Choose
    ) async throws -> MessageDestinationRef {
        IntentLog.step(site, "destination=\(caseName)")
        let person: MessagePersonEntity
        switch self {
        case .messagePerson(let entity):
            person = entity
        case .messagePeople(let people):
            guard people.count == 1 else {
                IntentLog.step(site, "refused=several_recipients")
                throw IntentFailure.onePersonAtATime
            }
            person = people[0]
        case .people(let people):
            guard people.count == 1 else {
                IntentLog.step(site, "refused=several_recipients")
                throw IntentFailure.onePersonAtATime
            }
            person = MessagePersonEntity(unresolved: people[0])
        }
        let found: MessagePersonEntity
        if person.isUnresolved {
            found = try await PersonResolver.require(person.person, site: site, env: env, choose: choose)
        } else if confirmsInstall {
            found = try await PersonResolver.confirmInstall(person, spoken: nil, site: site, env: env, choose: choose)
        } else {
            found = person
        }
        return .person(id: found.id, name: found.name, isAgent: found.isAgent)
    }
}

/// Builds the "which one?" prompt for an intent: up to five people, each
/// with its subtitle (org and install), plus Cancel.
@available(iOS 27, *)
func choosePerson<I: AppIntent>(_ intent: I, name: String, people: [MessagePersonEntity]) async throws -> MessagePersonEntity {
    let options = people.map { IntentChoiceOption(title: LocalizedStringResource(stringLiteral: "\($0.name), \($0.subtitle)")) }
    let picked = try await intent.requestChoice(between: options + [.cancel], dialog: IntentDialog("Which \(name)?"))
    guard let index = options.firstIndex(of: picked) else { throw CancellationError() }
    IntentLog.step("person.choose", "picked=\(index)")
    return people[index]
}

// MARK: - Send

// The Xcode 27.0 (27A266a) SDK's metadata processor accepts the schema
// destination only as `people | messagePerson | messagePeople`
// ("Parameter 'destination' does not match required AppSchemaIntent type
// 'MessageDestinationCases:(Array<Person> | Schema<MessagePerson> |
// Array<Schema<MessagePerson>>)'"), although AppIntentSchemas.sqlite also
// lists a `conversation` case. So a schema send goes to a PERSON (their DM).
// Sending to a named space stays with the old SendMessageIntent and its
// "Message <space> in Burrow" phrase. ConversationEntity is still adopted:
// the message schema requires it.
// The processor accepts the cases in any order; the entity cases come first
// (see MessageDestination).

@available(iOS 27, *)
@AppIntent(schema: .messages.sendMessage)
struct MessagesSendIntent {
    var content: AttributedString?
    var destination: MessageDestination
    var subject: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var locations: [PlaceDescriptor]
    var links: [URL]
    var scheduledDate: Date?

    /// Burrow's own extra (Shortcuts only; Siri never fills it): narrows the
    /// person suggestions to one install. A person names its own install.
    @Parameter(title: "Install")
    var install: InstallEntity?

    func perform() async throws -> some ReturnsValue<[MessageEntity]> & ProvidesDialog {
        // A Shortcut that set the Install chose the person within it.
        let target = try await destination.resolvedBurrowDestination(site: "send", confirmsInstall: install == nil) { name, people in
            try await choosePerson(self, name: name, people: people)
        }
        let text = content.map { String($0.characters) } ?? ""
        // No confirmation of our own: Siri already shows its "Send / Cancel"
        // confirmation for this schema intent before calling perform(), and a
        // second one made the operator confirm the same message twice (iOS 27.0.1,
        // 2026-10-14). The legacy SendMessageIntent still confirms.
        let sent = try await MessagingActions().send(to: target, text: text) { _ in }
        let entity = MessagingIntentSupport.messageEntity(for: sent, destination: destination)
        MessageRegistry.shared.remember(entity)
        IntentHooks.didSucceed?(self)
        // Fire and forget, to agents too (product decision, 2026-10-14): the agent's reply
        // arrives as a normal notification, not through this intent. Waiting
        // for it showed Siri's progress bar for up to 90 s. Ask is the intent
        // that waits for and speaks a reply.
        return .result(value: [entity], dialog: spoken(IntentCopy.sent(space: target.name)))
    }
}

// MARK: - Draft

/// Opens the conversation in Burrow. The text is NOT pre-filled: the web
/// composer has no draft hand-off from a deep link today, so a pre-fill
/// would mean new web plumbing. Opening the conversation is what ships.
@available(iOS 27, *)
@AppIntent(schema: .messages.draftMessage)
struct MessagesDraftIntent {
    var destination: MessageDestination?
    var subject: AttributedString?
    var content: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var locations: [PlaceDescriptor]
    var links: [URL]
    var scheduledDate: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = IntentEnvironment.current
        guard let destination else {
            guard let host = env.installs.selectedHost else {
                IntentLog.step("draft", "refused=no_selected_install")
                throw IntentFailure.signedOut
            }
            IntentNavigator.open(DeepLink(host: host, path: "/chat"))
            return .result(dialog: spoken(IntentCopy.draftOpened))
        }
        let target = try await destination.resolvedBurrowDestination(site: "draft") { name, people in
            try await choosePerson(self, name: name, people: people)
        }
        let link = try await MessagingIntentSupport.conversationLink(for: target, env: env)
        IntentNavigator.open(link)
        return .result(dialog: spoken(IntentCopy.draftOpened))
    }
}

// MARK: - Edit, unsend, read status

@available(iOS 27, *)
@AppIntent(schema: .messages.editSentMessage)
struct MessagesEditIntent {
    var message: MessageEntity
    var content: AttributedString

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await MessagingActions().edit(messageID: message.id, text: String(content.characters))
        return .result(dialog: spoken(text))
    }
}

@available(iOS 27, *)
@AppIntent(schema: .messages.unsendMessage)
struct MessagesUnsendIntent {
    var message: MessageEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await MessagingActions().unsend(messageID: message.id)
        return .result(dialog: spoken(text))
    }
}

@available(iOS 27, *)
@AppIntent(schema: .messages.setMessageReadStatus)
struct MessagesSetReadStatusIntent {
    var message: MessageEntity
    var isRead: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await MessagingActions().setRead(
            messageID: message.id, conversationID: message.conversation.id, isRead: isRead)
        return .result(dialog: spoken(text))
    }
}

// MARK: - Support

@available(iOS 27, *)
enum MessagingIntentSupport {
    /// The sent message as an entity: ids, conversation and author only.
    /// The schema destination is always a person, so the conversation is
    /// that person's DM.
    static func messageEntity(for sent: SentMessageRef, destination: MessageDestination) -> MessageEntity {
        let env = IntentEnvironment.current
        let host = EntityRef(sent.id)?.host ?? ""
        let conversation = ConversationEntity(
            id: sent.conversationID, name: destination.burrowDestination?.name ?? "Direct message", org: nil, isDirectMessage: true,
            pathSegment: EntityRef(sent.conversationID)?.uuid ?? "", install: env.disambiguator(host))
        let me = MessagePersonEntity(id: EntityRef(host: host, uuid: "me").id, name: "Me", kind: "user", subtitle: "")
        return MessageEntity(id: sent.id, conversation: conversation, author: me, date: env.now())
    }

    /// The conversation to open for a draft: the space itself, or the
    /// person's DM (found or created).
    static func conversationLink(for target: MessageDestinationRef, env: IntentEnvironment) async throws -> DeepLink {
        let ref = try IntentActions(env: env).ref(target.entityID)
        let segment: String
        switch target {
        case .conversation:
            segment = ref.uuid
        case .person(_, _, let isAgent):
            do {
                segment =
                    isAgent
                    ? try await env.client.dmWithAgent(host: ref.host, agentID: ref.uuid).spaceID
                    : try await env.client.personDM(host: ref.host, userID: ref.uuid).spaceID
            } catch {
                throw IntentFailure.from(error, host: ref.host, env: env)
            }
        }
        guard let link = DeepLink.space(host: ref.host, pathSegment: segment) else { throw IntentFailure.notFound }
        return link
    }
}
#endif
