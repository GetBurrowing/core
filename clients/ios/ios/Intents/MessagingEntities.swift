import AppIntents
import CoreSpotlight
import CoreTransferable
import Foundation
import GeoToolbox
import LinkPresentation

// The iOS 27 messages-domain entities (task 01a111bb stage 3): a person
// (human or agent), a conversation (space or DM) and a sent message. Every
// type here is iOS 27 only; nothing below 27 sees them, and the existing
// SpaceEntity / AgentEntity keep serving older Shortcuts.
//
// Ids are `<host>|<uuid>` (EntityRef), exactly like every other entity, so
// a person or conversation from install A never resolves against install B.
// Fetches go through EntityCatalog, so ShortcutParameterRefresh's digests
// still see them. A message entity holds no body: the schema allows it to
// be empty, and Burrow never persists message text on the device.

// MARK: - Person

// Named MessagePersonEntity (task 01a111bb stage 7, round 6), exactly as
// Siri's own SiriMessagesFlowTools names its `.messages.messagePerson`
// entity in the iOS 27.0 runtime, whose CreateDraftMessageTool is the one
// failing "Type identifier conformance" on our person. Apple forum thread
// 844294 (FB24604095): `.photos.editAsset` only works when the asset
// entity is named exactly `AssetEntity`, which looks like type-name
// matching. It was `PersonEntity` before; Spotlight items indexed under
// that name are orphaned (domain = host, dropped at sign-out) and the
// next per-host refresh indexes this type; round 8's
// SpotlightIndexMigration deletes them once (hydrating one failed on
// a test iPad). The query follows the SDK
// documentation's `<Entity>Query` naming (MessagePerson ->
// MessagePersonQuery); Apple's runtime adopters have no query.
@available(iOS 27, *)
@AppEntity(schema: .messages.messagePerson)
struct MessagePersonEntity {
    static let defaultQuery = MessagePersonEntityQuery()

    /// `<host>|<user or agent uuid>`.
    let id: String
    /// The schema's person: the display name, and the `<host>|<uuid>` id as
    /// both identifier and handle. Nothing else (no email, no phone).
    ///
    /// The indexing key is the schema's (`AppIntentSchemas.sqlite` declares
    /// `person` with `indexingKey: primaryRecipients`), and it is what puts
    /// `spotlightAttributeKey: primaryRecipients` on `person` in the built
    /// Metadata.appintents, as ChatKit's MessagePerson and
    /// SiriMessagesFlowTools' MessagePersonEntity carry it. Without it Siri's
    /// planner failed converting MessagePersonEntity ("Type identifier conformance
    /// failed", FlowToolTransformationError 3; iPadOS 27).
    /// MessagePersonEntityMetadataTests pins it.
    @Property(indexingKey: \.primaryRecipients)
    var person: IntentPerson
    /// `user` or `agent`. An agent's DM opens through `/agents/:id/dm`.
    var kind: String
    var subtitle: String

    var isAgent: Bool { kind == "agent" }
    /// A system person the import could not match to ONE Burrow person:
    /// carried to `perform`, which can ask which one or say who it couldn't
    /// find (an import can do neither).
    var isUnresolved: Bool { kind == Self.unresolvedKind }
    static let unresolvedKind = "unresolved"
    var name: String {
        if let name = PersonResolver.spokenName(person) { return name }
        return "Someone"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)", image: .init(systemName: isAgent ? "cpu" : "person.crop.circle"))
    }

    init(id: String, name: String, kind: String, subtitle: String) {
        self.id = id
        self.kind = kind
        self.subtitle = subtitle
        self.person = Self.intentPerson(id: id, name: name)
    }

    /// Wraps a system person that matched no single Burrow person.
    init(unresolved person: IntentPerson) {
        self.id = Self.unresolvedKind + EntityRef.separator.description + UUID().uuidString
        self.kind = Self.unresolvedKind
        self.subtitle = ""
        self.person = person
    }

    init(_ person: SuitePerson, host: String, env: IntentEnvironment) {
        let lead = person.isAgent ? "Agent" : "Person"
        self.init(
            id: EntityRef(host: host, uuid: person.id).id, name: person.name, kind: person.kind,
            subtitle: IntentCopy.subtitle([lead, person.orgNames.first], install: env.disambiguator(host)))
    }

    static func intentPerson(id: String, name: String) -> IntentPerson {
        IntentPerson(
            identifier: .applicationDefined(id),
            name: .displayName(name),
            handle: IntentPerson.Handle(applicationDefined: id))
    }

    /// To and from the system's `IntentPerson`: out as the schema person;
    /// in as the Burrow person it matches (PersonResolver: id, handle, then
    /// name). The import NEVER throws (task 01a111bb stage 7): a throw here
    /// reached Siri as a generic "there's a problem" with nothing logged.
    /// No match or several matches are carried to `perform` unresolved.
    ///
    /// `exporting:` MUST stay the key path to the STORED schema property
    /// `person` (the one property Apple's own MessagePerson entities declare,
    /// in ChatKit and SiriMessagesFlowTools), not a computed one: round 3's
    /// traced `exportedPerson` is gone, so the export itself is untraced.
    /// Xcode 27's metadata extractor
    /// reads this declaration as syntax and takes the IntentValue type from
    /// the key path only: with a closure it records NO exportable or
    /// importable type, Siri's structured-data fetch then logs "Failed to
    /// extract Person for PersonEntity(...)" (its name then) and the send never starts
    /// (iPadOS 27.0.1, "Message Dalton saying ..."). With `\MessagePersonEntity.person`
    /// it records `com.apple.appintents.IntentPerson` both ways
    /// (MessagePersonEntityMetadataTests pins it).
    static var transferRepresentation: some TransferRepresentation {
        IntentValueRepresentation(
            exporting: \MessagePersonEntity.person,
            importing: { (person: IntentPerson) in
                if case .one(let found) = await PersonResolver.resolve(person, site: "person.import") { return found }
                return MessagePersonEntity(unresolved: person)
            })
    }
}

@available(iOS 27, *)
extension MessagePersonEntity: Transferable {}

// Indexed (stage 4) under the host as the domain identifier, syncable (the
// id is the server's) and `.shared` (a person in a workspace).
@available(iOS 27, *)
extension MessagePersonEntity: IndexedEntity, SyncableEntity, OwnershipProvidingEntity {
    var ownership: EntityOwnership { .shared }

    /// The schema's mapping (`person` -> `primaryRecipients`, declared by
    /// `@Property(indexingKey:)` on `person`), plus the name
    /// as display name and the given name as an alternate, so "Dalton"
    /// matches "Dalton Rourke" (task 01a111bb stage 7).
    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.displayName = name
        set.alternateNames = PersonalIndex.alternateNames(person: name, isAgent: isAgent)
        return set
    }
}

@available(iOS 27, *)
struct MessagePersonEntityQuery: EntityStringQuery {
    // Suggestions are scoped once the send's Install is chosen; unset still
    // searches every install, which Siri needs to resolve a spoken name.
    // The dependency's `install` reads as non-optional although the
    // parameter is optional, hence `dep?.install.id`.
    // MessagesSendIntent is App-only (BURROW_APP, see MessagingIntents.swift).
    #if BURROW_APP
        @IntentParameterDependency<MessagesSendIntent>(\.$install) var send
    #endif

    /// Set by tests in place of the dependency above.
    var installScope: String?

    init() {}

    init(installScope: String?) { self.installScope = installScope }

    #if BURROW_APP
        private var scope: String? { installScope ?? send?.install.id }
    #else
        private var scope: String? { installScope }
    #endif

    /// Each id resolves on ITS host only: a person found earlier (search,
    /// suggestions or the index refresh) from the in-memory cache, otherwise
    /// in that host's people directory (the set the device indexes). An
    /// unknown host makes no request, and its ids are purged from Spotlight
    /// (round 8: Siri kept handing back a removed install's people, whose
    /// hydration could only fail).
    func entities(for identifiers: [String]) async throws -> [MessagePersonEntity] {
        IntentLog.step("person.query", "ids=\(identifiers.count)")
        let catalog = EntityCatalog()
        SpotlightIndex.purge(ids: identifiers, env: catalog.env)
        let cache = PeopleCache.shared
        var missing: [String] = []
        var found: [String: MessagePersonEntity] = [:]
        for id in identifiers {
            guard let ref = EntityRef(id), catalog.env.install(ref.host) != nil else { continue }
            if let hit = cache.entity(for: id) { found[id] = hit } else { missing.append(id) }
        }
        if !missing.isEmpty {
            let loaded = await catalog.resolve(missing) { host in
                await catalog.people(hosts: [host], directory: true).map { MessagePersonEntity($0.person, host: $0.host, env: catalog.env) }
            }
            for entity in loaded { found[entity.id] = entity }
        }
        let result = identifiers.compactMap { found[$0] }
        Self.trace(identifiers, result: result, cacheHits: identifiers.count - missing.count, env: catalog.env)
        return result
    }

    /// The SHAPE of a lookup, for the trace (task 01a111bb stage 7, round
    /// 3): counts and booleans only, never a uuid, a host or a name.
    static func trace(_ identifiers: [String], result: [MessagePersonEntity], cacheHits: Int, env: IntentEnvironment) {
        for id in identifiers {
            let ref = EntityRef(id)
            let segments = id.split(separator: EntityRef.separator, omittingEmptySubsequences: false).count
            let installKnown = ref.map { env.install($0.host) != nil } ?? false
            let uuidOK = ref.map { UUID(uuidString: $0.uuid) != nil } ?? false
            IntentLog.step(
                "person.query",
                "req len=\(id.count) segments=\(segments) parsed=\(ref != nil) install=\(installKnown) uuid=\(uuidOK)")
        }
        let returned = result.map(\.id)
        let match = returned == identifiers
        let personIDsMatch = result.allSatisfy { entity in
            if case .applicationDefined(let raw) = entity.person.identifier { return raw == entity.id }
            return false
        }
        IntentLog.step(
            "person.query",
            "result count=\(result.count) cacheHits=\(cacheHits) idsMatch=\(match) personIdMatch=\(personIDsMatch) kinds=\(result.map(\.kind).joined(separator: ","))")
    }

    /// Recent collaborators: the people the person actually talks to. The
    /// fetch indexes them (EntityCatalog.people).
    func suggestedEntities() async throws -> [MessagePersonEntity] {
        IntentLog.step("person.query", "suggested")
        let catalog = EntityCatalog()
        return PeopleCache.shared.remember(
            await catalog.people(hosts: catalog.hosts(scope: scope)).map { MessagePersonEntity($0.person, host: $0.host, env: catalog.env) })
    }

    /// The server's search (`?q=`), never a filter over the suggestions, so
    /// someone outside the recent set is still found by name.
    func entities(matching string: String) async throws -> [MessagePersonEntity] {
        IntentLog.step("person.query", "matching")
        let catalog = EntityCatalog()
        return PeopleCache.shared.remember(
            await catalog.people(hosts: catalog.hosts(scope: scope), query: string)
                .map { MessagePersonEntity($0.person, host: $0.host, env: catalog.env) })
    }
}

/// People this process has fetched, by `<host>|<uuid>` id, so a person found
/// by search resolves again when Siri hands the id back. Names and kinds
/// only, in memory, never persisted.
@available(iOS 27, *)
final class PeopleCache: @unchecked Sendable {
    static let shared = PeopleCache()
    private let lock = NSLock()
    private var entities: [String: MessagePersonEntity] = [:]

    @discardableResult
    func remember(_ list: [MessagePersonEntity]) -> [MessagePersonEntity] {
        lock.lock()
        for entity in list { entities[entity.id] = entity }
        lock.unlock()
        return list
    }

    func entity(for id: String) -> MessagePersonEntity? {
        lock.lock()
        defer { lock.unlock() }
        return entities[id]
    }

    func all() -> [MessagePersonEntity] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entities.values)
    }

    func removeAll(host: String) {
        lock.lock()
        entities = entities.filter { EntityRef($0.key)?.host != host }
        lock.unlock()
    }
}

// MARK: - Conversation

@available(iOS 27, *)
@AppEntity(schema: .messages.conversation)
struct ConversationEntity {
    static let defaultQuery = ConversationQuery()

    /// `<host>|<space uuid>`.
    let id: String
    var recipients: [MessagePersonEntity]
    /// "general · Acme": the org tells same-named spaces apart.
    var displayName: String
    var previewText: AttributedString
    var conversationName: String?
    var isRead: Bool
    var attributes: Set<ConversationAttributeEnum>
    var dateLastActive: Date?

    var pathSegment: String
    var subtitle: String
    var isDirectMessage: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName)", subtitle: "\(subtitle)",
            image: .init(systemName: isDirectMessage ? "bubble.left.and.bubble.right" : "number"))
    }

    init(id: String, name: String, org: String?, isDirectMessage: Bool, pathSegment: String, install: String?) {
        // Plain stored properties first: the schema properties are
        // macro-generated wrappers, assignable only once these are set.
        self.id = id
        self.pathSegment = pathSegment
        self.isDirectMessage = isDirectMessage
        self.subtitle = IntentCopy.subtitle([isDirectMessage ? "Direct message" : "Space", org], install: install)
        self.recipients = []
        self.displayName = IntentCopy.conversationTitle(name: name, org: org)
        self.previewText = AttributedString("")
        self.conversationName = name
        self.isRead = true
        self.attributes = []
        self.dateLastActive = nil
    }

    init(_ space: SuiteSpace, host: String, env: IntentEnvironment) {
        self.init(
            id: EntityRef(host: host, uuid: space.id).id, name: space.name, org: space.org?.name,
            isDirectMessage: space.isDirectMessage, pathSegment: space.linkSegment, install: env.disambiguator(host))
    }
}

@available(iOS 27, *)
struct ConversationQuery: EntityStringQuery {
    /// Set by tests in place of an Install dependency.
    var installScope: String?

    /// An id on an install that is no longer saved resolves to nothing and
    /// is purged from Spotlight, as for a person.
    func entities(for identifiers: [String]) async throws -> [ConversationEntity] {
        let catalog = EntityCatalog()
        SpotlightIndex.purge(ids: identifiers, env: catalog.env)
        return await catalog.resolve(identifiers) { host in
            await catalog.spaceRows(hosts: [host]).map { ConversationEntity($0.space, host: $0.host, env: catalog.env) }
        }
    }

    /// Every conversation; the fetch indexes them (EntityCatalog.spaceRows).
    func suggestedEntities() async throws -> [ConversationEntity] {
        let catalog = EntityCatalog()
        return await catalog.spaceRows(hosts: catalog.hosts(scope: installScope))
            .map { ConversationEntity($0.space, host: $0.host, env: catalog.env) }
    }

    func entities(matching string: String) async throws -> [ConversationEntity] {
        try await suggestedEntities().filter {
            $0.displayName.localizedCaseInsensitiveContains(string) || ($0.conversationName ?? "").localizedCaseInsensitiveContains(string)
        }
    }
}

@available(iOS 27, *)
extension ConversationEntity: IndexedEntity, SyncableEntity, OwnershipProvidingEntity {
    var ownership: EntityOwnership { .shared }

    /// The schema's mapping, plus the bare name ("general") as an alternate
    /// to the org-qualified display name ("general · Acme").
    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.alternateNames = [displayName, conversationName].compactMap { $0 }
        return set
    }
}

// The system may ask for a reindex (iOS 27 `IndexedEntityQuery`): every
// signed-in install's directory and conversations are fetched again, which
// indexes them per host.

@available(iOS 27, *)
extension MessagePersonEntityQuery: IndexedEntityQuery {
    func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        _ = try await entities(for: identifiers)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        let catalog = EntityCatalog()
        _ = await catalog.people(hosts: catalog.env.signedInHosts, directory: true)
    }
}

@available(iOS 27, *)
extension ConversationQuery: IndexedEntityQuery {
    func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        _ = try await entities(for: identifiers)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        let catalog = EntityCatalog()
        _ = await catalog.spaceRows(hosts: catalog.env.signedInHosts)
    }
}

// MARK: - Message

@available(iOS 27, *)
@AppEntity(schema: .messages.message)
struct MessageEntity {
    static let defaultQuery = MessageQuery()

    /// `<host>|<message uuid>`.
    let id: String
    var messageType: MessageTypeEnum
    var author: MessagePersonEntity
    var isRead: Bool
    var attributes: Set<MessageAttributeEnum>
    var conversation: ConversationEntity
    var date: Date
    var subject: AttributedString?
    /// Always nil: Burrow never holds a message body on the device.
    var body: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var customAttachments: [CustomAttachmentEntity]
    var locations: [PlaceDescriptor]
    var links: [LinkMetadata]
    var messageEffect: MessageEffectEnum?
    var reaction: MessageReaction?
    var referencedMessage: MessageEntity?
    var notificationIdentifier: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Message", subtitle: "\(conversation.displayName)", image: .init(systemName: "text.bubble"))
    }

    init(id: String, conversation: ConversationEntity, author: MessagePersonEntity, date: Date = Date()) {
        self.id = id
        self.messageType = .unspecified
        self.author = author
        self.isRead = true
        self.attributes = []
        self.conversation = conversation
        self.date = date
        self.subject = nil
        self.body = nil
        self.attachments = []
        self.audioMessage = nil
        self.customAttachments = []
        self.locations = []
        self.links = []
        self.messageEffect = nil
        self.reaction = nil
        self.referencedMessage = nil
        self.notificationIdentifier = nil
    }
}

/// Messages are not listed or searched: an id comes from a notification or
/// a send result, and resolves only on its own host. With no body on the
/// device, an id resolves to a message in its conversation.
@available(iOS 27, *)
struct MessageQuery: EntityStringQuery {
    /// No message is searchable by text: Burrow holds no bodies here.
    func entities(matching string: String) async throws -> [MessageEntity] { [] }

    func entities(for identifiers: [String]) async throws -> [MessageEntity] {
        let env = IntentEnvironment.current
        return identifiers.compactMap { id in
            guard let ref = EntityRef(id), env.install(ref.host) != nil else { return nil }
            return MessageRegistry.shared.entity(for: id)
        }
    }
}

/// The messages this process sent or was handed by a notification, by id:
/// conversation and author only, never text. In memory, never persisted.
@available(iOS 27, *)
final class MessageRegistry: @unchecked Sendable {
    static let shared = MessageRegistry()
    private let lock = NSLock()
    private var entities: [String: MessageEntity] = [:]

    func remember(_ entity: MessageEntity) {
        lock.lock()
        entities[entity.id] = entity
        lock.unlock()
    }

    func entity(for id: String) -> MessageEntity? {
        lock.lock()
        defer { lock.unlock() }
        return entities[id]
    }
}

// MARK: - Custom attachment (required by the message schema; Burrow sends none)

@available(iOS 27, *)
@AppEntity(schema: .messages.customAttachment)
struct CustomAttachmentEntity: TransientAppEntity {
    var sourceName: AttributedString?
    var description: AttributedString?

    init() {
        sourceName = nil
        description = nil
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Attachment") }
}

// MARK: - Enums the schema names

@available(iOS 27, *)
@AppEnum(schema: .messages.messageType)
enum MessageTypeEnum: String {
    case unspecified

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.unspecified: "Message"]
}

@available(iOS 27, *)
@AppEnum(schema: .messages.messageAttribute)
enum MessageAttributeEnum: String {
    case edited

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.edited: "Edited"]
}

@available(iOS 27, *)
@AppEnum(schema: .messages.conversationAttribute)
enum ConversationAttributeEnum: String {
    case directMessage

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.directMessage: "Direct message"]
}

@available(iOS 27, *)
@AppEnum(schema: .messages.messageEffect)
enum MessageEffectEnum: String {
    case none

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.none: "None"]
}

@available(iOS 27, *)
@AppEnum(schema: .messages.customReaction)
enum ReactionEnum: String {
    case like

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.like: "Like"]
}

@available(iOS 27, *)
@UnionValue
enum MessageReaction {
    case customReaction(ReactionEnum)
    case attributedString(AttributedString)
}

// MARK: - Destination (send and draft)

// Xcode 27.0's metadata processor requires these three cases
// (`Array<Person> | Schema<MessagePerson> | Array<Schema<MessagePerson>>`;
// it refused `messagePerson | messagePeople | conversation`), but not their
// order. The ENTITY cases come first (task 01a111bb stage 7, round
// 4), in the order Siri's own SiriMessagesFlowTools declares its send
// destination in the iOS 27.0 runtime (MessagePersonEntity,
// [MessagePersonEntity], ConversationEntity); ChatKit's is (conversation,
// MessagePerson, [MessagePerson]). Neither has a `[Person]` case. While
// `people([IntentPerson])` came first, Siri resolved Dalton to a
// MessagePersonEntity through MessagePersonEntityQuery, then failed converting him into this
// union (FlowToolTransformationError Code=3) without calling the app.

@available(iOS 27, *)
@UnionValue
enum MessageDestination {
    case messagePerson(MessagePersonEntity)
    case messagePeople([MessagePersonEntity])
    case people([IntentPerson])
}
