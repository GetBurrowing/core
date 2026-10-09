import AppIntents
import Foundation

// Personal-context donations (task 01a111bb stage 4).
//
// Rules this file keeps:
// - ONLY actions the person took by hand in Burrow's UI are donated: a
//   message sent or a task approved in the web view (the SuiteNative.donate
//   bridge), a call started or answered, a notification reply, a space or
//   task opened, and the agent of an Ask. Intent runs (Siri, Shortcuts) are
//   NOT re-donated: the system already knows about them.
// - A donation carries RECIPIENTS ONLY, never content. A send is donated as
//   the schema send with `content` unset; there is no path from an event to
//   a value with a message, question, note, subject or attachment.
// - Every donation's identifier is recorded per host (DonationLedger), so
//   signing out of one install deletes exactly its donations.

/// Someone a message went to, by raw uuid (the host is the event's).
struct DonationRecipient: Equatable, Sendable {
    /// "user" or "agent".
    let type: String
    let id: String
}

/// A UI-initiated action, ids only.
enum DonationEvent: Equatable, Sendable {
    case messageSent(host: String, spaceID: String, recipients: [DonationRecipient])
    case taskOpened(host: String, taskID: String)
    case meetingJoined(host: String, meetingID: String, name: String?, slug: String?)
    case spaceOpened(host: String, spaceID: String)
    case askedAgent(host: String, agentID: String)

    var host: String {
        switch self {
        case .messageSent(let host, _, _), .taskOpened(let host, _), .meetingJoined(let host, _, _, _),
            .spaceOpened(let host, _), .askedAgent(let host, _):
            return host
        }
    }

    /// The most recipients one donation names (the server caps at 10 too).
    static let maxRecipients = 10

    /// A `PlatformWeb.NativeDonation` payload from the web view. Only the
    /// kind's allow-listed id keys are read, each must be a UUID, and any
    /// other key (a title, a body, a name) is ignored.
    static func fromBridge(_ payload: [String: Any], host: String) -> DonationEvent? {
        func uuid(_ key: String) -> String? {
            guard let value = payload[key] as? String, UUID(uuidString: value) != nil else { return nil }
            return value.lowercased()
        }
        switch payload["kind"] as? String {
        case "message_sent":
            guard let space = uuid("space_id") else { return nil }
            let raw = payload["recipient_ids"] as? [[String: Any]] ?? []
            let recipients = raw.compactMap { row -> DonationRecipient? in
                guard let type = row["type"] as? String, type == "user" || type == "agent",
                    let id = row["id"] as? String, UUID(uuidString: id) != nil
                else { return nil }
                return DonationRecipient(type: type, id: id.lowercased())
            }
            return .messageSent(host: host, spaceID: space, recipients: Array(recipients.prefix(maxRecipients)))
        case "task_created", "approval_acted":
            return uuid("task_id").map { .taskOpened(host: host, taskID: $0) }
        case "meeting_started":
            return uuid("meeting_id").map { .meetingJoined(host: host, meetingID: $0, name: nil, slug: nil) }
        default:
            return nil
        }
    }
}

/// A person a send donation names: the `<host>|<uuid>` id and the display
/// name, nothing else.
struct DonationPerson: Equatable, Sendable {
    let id: String
    let name: String
    let kind: String
}

/// What one event donates. There is deliberately no case with text.
enum DonationValue {
    /// A send to these people, with no content (iOS 27 schema send).
    case message(recipients: [DonationPerson])
    case space(SpaceEntity)
    case task(TaskEntity)
    case meeting(MeetingEntity)

    /// The intent value donated, or nil where this OS has no such intent.
    func intent() -> (any AppIntent)? {
        switch self {
        case .message(let recipients):
            guard #available(iOS 27, *), !recipients.isEmpty else { return nil }
            return DonationIntents.send(to: recipients)
        case .space(let space): return OpenSpaceIntent(target: space)
        case .task(let task): return OpenTaskIntent(target: task)
        case .meeting(let meeting): return OpenMeetingIntent(target: meeting)
        }
    }
}

@available(iOS 27, *)
enum DonationIntents {
    /// The schema send to `recipients` with every content parameter unset.
    static func send(to recipients: [DonationPerson]) -> MessagesSendIntent {
        let people = recipients.map { PersonEntity(id: $0.id, name: $0.name, kind: $0.kind, subtitle: "") }
        var intent = MessagesSendIntent()
        intent.destination = people.count == 1 ? .messagePerson(people[0]) : .messagePeople(people)
        // Every non-optional parameter is set (empty), or reading it traps.
        intent.attachments = []
        intent.locations = []
        intent.links = []
        return intent
    }
}

/// Looks up the display name an entity needs. Live: the entity queries
/// (cache, then that host's own fetch). Tests: a fake.
protocol DonationResolving: Sendable {
    func space(host: String, id: String) async -> SpaceEntity?
    func task(host: String, id: String) async -> TaskEntity?
    func meeting(host: String, id: String) async -> MeetingEntity?
    func person(host: String, id: String, type: String) async -> DonationPerson?
}

enum DonationPolicy {
    /// The recipients-only values `event` donates.
    static func values(for event: DonationEvent, resolver: DonationResolving) async -> [DonationValue] {
        switch event {
        case .messageSent(let host, let spaceID, let recipients):
            if #available(iOS 27, *), !recipients.isEmpty {
                var people: [DonationPerson] = []
                for recipient in recipients {
                    if let person = await resolver.person(host: host, id: recipient.id, type: recipient.type) { people.append(person) }
                }
                if !people.isEmpty { return [.message(recipients: people)] }
            }
            return await resolver.space(host: host, id: spaceID).map { [.space($0)] } ?? []
        case .taskOpened(let host, let taskID):
            return await resolver.task(host: host, id: taskID).map { [.task($0)] } ?? []
        case .meetingJoined(let host, let meetingID, let name, let slug):
            if let name, let slug {
                let id = EntityRef(host: host, uuid: meetingID).id
                return [.meeting(MeetingEntity(id: id, name: name, slug: slug, subtitle: "Meeting"))]
            }
            return await resolver.meeting(host: host, id: meetingID).map { [.meeting($0)] } ?? []
        case .spaceOpened(let host, let spaceID):
            return await resolver.space(host: host, id: spaceID).map { [.space($0)] } ?? []
        case .askedAgent(let host, let agentID):
            // The agent alone: a send to them with no question.
            guard #available(iOS 27, *), let agent = await resolver.person(host: host, id: agentID, type: "agent") else { return [] }
            return [.message(recipients: [agent])]
        }
    }

    /// The parameters of `intent` that carry content, or a marker for an
    /// intent type that is not allow-listed for donation. Empty means the
    /// intent is safe to donate.
    static func contentParameters(of intent: any AppIntent) -> [String] {
        switch intent {
        case is OpenSpaceIntent, is OpenTaskIntent, is OpenMeetingIntent:
            return []
        case is SendMessageIntent:
            return ["message"]
        case is AskAgentIntent:
            return ["question"]
        case let reject as RejectIntent:
            return reject.note == nil ? ["intent:RejectIntent"] : ["note"]
        default:
            if #available(iOS 27, *), let send = intent as? MessagesSendIntent {
                var set: [String] = []
                if send.content != nil { set.append("content") }
                if send.subject != nil { set.append("subject") }
                if !send.attachments.isEmpty { set.append("attachments") }
                if send.audioMessage != nil { set.append("audioMessage") }
                if !send.links.isEmpty { set.append("links") }
                if !send.locations.isEmpty { set.append("locations") }
                return set
            }
            return ["intent:\(type(of: intent))"]
        }
    }
}

// MARK: - Donating and forgetting

/// The system's donation store, behind a seam so tests see every call.
/// Identifiers are opaque strings (a JSON-encoded IntentDonationIdentifier).
protocol DonationManaging: Sendable {
    func donate(_ intent: any AppIntent) async throws -> String
    func deleteDonations(_ identifiers: [String]) async throws
}

struct LiveDonationManager: DonationManaging {
    func donate(_ intent: any AppIntent) async throws -> String {
        let identifier = try await donateOpened(intent)
        return String(decoding: try JSONEncoder().encode(identifier), as: UTF8.self)
    }

    private func donateOpened<I: AppIntent>(_ intent: I) async throws -> IntentDonationIdentifier {
        try await IntentDonationManager.shared.donate(intent: intent)
    }

    func deleteDonations(_ identifiers: [String]) async throws {
        let decoded = identifiers.compactMap { try? JSONDecoder().decode(IntentDonationIdentifier.self, from: Data($0.utf8)) }
        guard !decoded.isEmpty else { return }
        if #available(iOS 26.4, *) {
            try await IntentDonationManager.shared.deleteDonations(matching: .donationIdentifiers(decoded))
        } else {
            for identifier in decoded {
                try await IntentDonationManager.shared.deleteDonations(matching: .donationIdentifier(identifier))
            }
        }
    }
}

/// Donation identifiers per install host, in the App Group store. Ids only.
struct DonationLedger {
    static let key = "burrow.donations.v1"
    let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: InstallStore.appGroup)) {
        self.defaults = defaults
    }

    var all: [String: [String]] {
        defaults?.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
    }

    func ids(for host: String) -> [String] { all[host] ?? [] }

    func record(_ id: String, host: String) {
        var map = all
        map[host, default: []].append(id)
        defaults?.set(map, forKey: Self.key)
    }

    func clear(host: String) {
        var map = all
        map[host] = nil
        defaults?.set(map, forKey: Self.key)
    }
}

/// Turns events into donations and forgets a host's donations.
final class Donations: @unchecked Sendable {
    static var shared = Donations()

    let manager: DonationManaging
    let ledger: DonationLedger
    let resolver: DonationResolving
    /// Whether `host` is still a saved install (a donation that lands after
    /// its install was removed is deleted at once).
    let isSaved: @Sendable (String) -> Bool
    private let lock = NSLock()
    private var lastEvent: DonationEvent?

    init(
        manager: DonationManaging = LiveDonationManager(), ledger: DonationLedger = DonationLedger(),
        resolver: DonationResolving = LiveDonationResolver(),
        isSaved: @escaping @Sendable (String) -> Bool = { IntentEnvironment.current.install($0) != nil }
    ) {
        self.manager = manager
        self.ledger = ledger
        self.resolver = resolver
        self.isSaved = isSaved
    }

    /// Donates `event` unless it repeats the previous one (a page reload).
    @discardableResult
    func donate(_ event: DonationEvent) -> Task<Void, Never> {
        let repeated = lock.withLock {
            defer { lastEvent = event }
            return lastEvent == event
        }
        guard !repeated else { return Task {} }
        return Task { await self.perform(event) }
    }

    func perform(_ event: DonationEvent) async {
        for value in await DonationPolicy.values(for: event, resolver: resolver) {
            guard let intent = value.intent() else { continue }
            await record(intent, host: event.host)
        }
    }

    /// Donates one intent and records its identifier under `host`. Refuses
    /// any intent that carries content.
    func record(_ intent: any AppIntent, host: String) async {
        guard DonationPolicy.contentParameters(of: intent).isEmpty else { return }
        guard let id = try? await manager.donate(intent) else { return }
        let saved = lock.withLock {
            let saved = isSaved(host)
            if saved { ledger.record(id, host: host) }
            return saved
        }
        if !saved { try? await manager.deleteDonations([id]) }
    }

    /// Deletes every donation recorded for `host`, and only those. The
    /// ledger entry survives a failed delete so a later sign-out retries.
    func forget(host: String) async {
        let ids = lock.withLock {
            if lastEvent?.host == host { lastEvent = nil }
            return ledger.ids(for: host)
        }
        guard !ids.isEmpty else { return }
        do {
            try await manager.deleteDonations(ids)
            lock.withLock { ledger.clear(host: host) }
        } catch {
            IntentLog.route("donations.delete", host: host, status: 0)
        }
    }
}

/// Names from the entity queries: the in-memory caches, then that host's
/// own fetch with its own bearer. An unknown host resolves to nothing.
struct LiveDonationResolver: DonationResolving {
    func space(host: String, id: String) async -> SpaceEntity? {
        try? await SpaceQuery().entities(for: [EntityRef(host: host, uuid: id).id]).first
    }

    func task(host: String, id: String) async -> TaskEntity? {
        try? await TaskQuery().entities(for: [EntityRef(host: host, uuid: id).id]).first
    }

    func meeting(host: String, id: String) async -> MeetingEntity? {
        try? await MeetingQuery().entities(for: [EntityRef(host: host, uuid: id).id]).first
    }

    func person(host: String, id: String, type: String) async -> DonationPerson? {
        guard #available(iOS 27, *) else { return nil }
        let ref = EntityRef(host: host, uuid: id).id
        if let person = try? await PersonQuery().entities(for: [ref]).first {
            return DonationPerson(id: person.id, name: person.name, kind: person.kind)
        }
        if type == "agent", let agent = try? await AgentQuery().entities(for: [ref]).first {
            return DonationPerson(id: agent.id, name: agent.name, kind: "agent")
        }
        return nil
    }
}
