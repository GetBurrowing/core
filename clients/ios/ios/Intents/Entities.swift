import AppIntents
import CoreSpotlight
import Foundation

// App Entities for Siri, Shortcuts and Spotlight (task 01a10db6 stage 3).
//
// Every entity but the install has the id `<host>|<uuid>` (EntityRef): the
// host names the install whose bearer every request for it uses. An id
// whose host is not a saved install resolves to nothing. Display copy:
// canvas 01a10db8, "Spotlight entities".

// MARK: - Install

struct InstallEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Install"
    static var defaultQuery = InstallQuery()

    /// The install host.
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(id)", image: .init(systemName: "server.rack"))
    }

    init(_ install: Install) {
        id = install.host
        name = install.displayName
    }
}

struct InstallQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [InstallEntity] {
        let installs = IntentEnvironment.current.installs.installs
        return identifiers.compactMap { host in installs.first { $0.host == host }.map(InstallEntity.init) }
    }

    func suggestedEntities() async throws -> [InstallEntity] {
        IntentEnvironment.current.installs.installs.map(InstallEntity.init)
    }

    func defaultResult() async -> InstallEntity? {
        IntentEnvironment.current.installs.selectedInstall.map(InstallEntity.init)
    }
}

// MARK: - Space and DM

struct SpaceEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Space"
    static var defaultQuery = SpaceQuery()

    let id: String
    let name: String
    let isDirectMessage: Bool
    /// `Chat.space_path_segment/1`, for `/chat/<segment>`.
    let pathSegment: String
    let subtitle: String

    var ref: EntityRef? { EntityRef(id) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)", subtitle: "\(subtitle)",
            image: .init(systemName: isDirectMessage ? "bubble.left.and.bubble.right" : "number"))
    }

    init(id: String, name: String, isDirectMessage: Bool, pathSegment: String, subtitle: String) {
        self.id = id
        self.name = name
        self.isDirectMessage = isDirectMessage
        self.pathSegment = pathSegment
        self.subtitle = subtitle
    }

    init(_ space: SuiteSpace, host: String, env: IntentEnvironment) {
        self.init(
            id: EntityRef(host: host, uuid: space.id).id,
            name: space.name,
            isDirectMessage: space.isDirectMessage,
            pathSegment: space.linkSegment,
            subtitle: IntentCopy.subtitle(
                [space.isDirectMessage ? "Direct message" : "Space", space.org?.name], install: env.disambiguator(host)))
    }
}

struct SpaceQuery: EntityStringQuery {
    // A spoken space name is matched across every signed-in install, as
    // Siri needs; when the intent's Install parameter is set, only there.
    @IntentParameterDependency<SendMessageIntent>(\.$install) var sendMessage
    @IntentParameterDependency<StartMeetingIntent>(\.$install) var startMeeting

    /// Set by tests in place of the dependencies above.
    var installScope: String?

    private var scope: String? { installScope ?? sendMessage?.install.id ?? startMeeting?.install.id }

    func entities(for identifiers: [String]) async throws -> [SpaceEntity] {
        await EntityCatalog().resolve(identifiers) { await EntityCatalog().spaces(hosts: [$0]) }
    }

    func suggestedEntities() async throws -> [SpaceEntity] {
        let catalog = EntityCatalog()
        return await catalog.spaces(hosts: catalog.hosts(scope: scope))
    }

    func entities(matching string: String) async throws -> [SpaceEntity] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}

// MARK: - Task

struct TaskEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Task"
    static var defaultQuery = TaskQuery()

    let id: String
    let title: String
    let subtitle: String

    var ref: EntityRef? { EntityRef(id) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)", image: .init(systemName: "checklist"))
    }

    init(id: String, title: String, subtitle: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }

    init(_ task: SuiteTask, host: String, env: IntentEnvironment) {
        let lead = task.projectName.map { "Task in \($0)" } ?? "Task"
        self.init(
            id: EntityRef(host: host, uuid: task.id).id, title: task.title,
            subtitle: IntentCopy.subtitle([lead, task.status], install: env.disambiguator(host)))
    }
}

struct TaskQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TaskEntity] {
        await EntityCatalog().resolve(identifiers) { await EntityCatalog().tasks(hosts: [$0], limit: 50) }
    }

    func suggestedEntities() async throws -> [TaskEntity] {
        let catalog = EntityCatalog()
        return await catalog.tasks(hosts: catalog.env.signedInHosts)
    }

    func entities(matching string: String) async throws -> [TaskEntity] {
        let catalog = EntityCatalog()
        return await catalog.tasks(hosts: catalog.env.signedInHosts, query: string)
    }
}

// MARK: - Approval

struct ApprovalEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Approval"
    static var defaultQuery = ApprovalQuery()

    let id: String
    let title: String
    let isPlan: Bool
    let spaceName: String?
    let subtitle: String

    var ref: EntityRef? { EntityRef(id) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)", image: .init(systemName: "checkmark.seal"))
    }

    init(id: String, title: String, isPlan: Bool, spaceName: String?, subtitle: String) {
        self.id = id
        self.title = title
        self.isPlan = isPlan
        self.spaceName = spaceName
        self.subtitle = subtitle
    }

    init(_ approval: SuiteApproval, host: String, env: IntentEnvironment) {
        var lead = approval.isPlan ? "Plan to approve" : "Review to approve"
        if let space = approval.spaceName, !space.isEmpty { lead += " in \(space)" }
        self.init(
            id: EntityRef(host: host, uuid: approval.id).id, title: approval.title, isPlan: approval.isPlan,
            spaceName: approval.spaceName,
            subtitle: IntentCopy.subtitle([lead, EntityCatalog.age(approval.insertedAt, now: env.now())], install: env.disambiguator(host)))
    }
}

struct ApprovalQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ApprovalEntity] {
        await EntityCatalog().resolve(identifiers) { await EntityCatalog().approvals(hosts: [$0]) }
    }

    func suggestedEntities() async throws -> [ApprovalEntity] {
        let catalog = EntityCatalog()
        return await catalog.approvals(hosts: catalog.env.signedInHosts)
    }

    func entities(matching string: String) async throws -> [ApprovalEntity] {
        try await suggestedEntities().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }
}

// MARK: - Meeting

struct MeetingEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Meeting"
    static var defaultQuery = MeetingQuery()

    let id: String
    let name: String
    let slug: String
    let subtitle: String

    var ref: EntityRef? { EntityRef(id) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)", image: .init(systemName: "video"))
    }

    init(id: String, name: String, slug: String, subtitle: String) {
        self.id = id
        self.name = name
        self.slug = slug
        self.subtitle = subtitle
    }

    init(_ meeting: SuiteMeeting, host: String, env: IntentEnvironment) {
        self.init(
            id: EntityRef(host: host, uuid: meeting.id).id, name: meeting.name, slug: meeting.slug,
            subtitle: IntentCopy.subtitle(
                ["Meeting", EntityCatalog.dayAndTime(meeting.startsAt), meeting.spaceName], install: env.disambiguator(host)))
    }
}

struct MeetingQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MeetingEntity] {
        await EntityCatalog().resolve(identifiers) { await EntityCatalog().meetings(hosts: [$0]) }
    }

    func suggestedEntities() async throws -> [MeetingEntity] {
        let catalog = EntityCatalog()
        return await catalog.meetings(hosts: catalog.env.signedInHosts)
    }

    func entities(matching string: String) async throws -> [MeetingEntity] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}

// MARK: - Project

/// A project that holds meetings and tasks (task 01a111bb stage 6). The
/// subtitle names the org, so same-named projects in two orgs differ.
struct ProjectEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
    static var defaultQuery = ProjectQuery()

    let id: String
    let name: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)", image: .init(systemName: "folder"))
    }

    init(id: String, name: String, subtitle: String) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
    }

    init(_ project: SuiteProject, host: String, env: IntentEnvironment) {
        self.init(
            id: EntityRef(host: host, uuid: project.id).id, name: project.name,
            subtitle: IntentCopy.subtitle(["Project", project.org?.name], install: env.disambiguator(host)))
    }
}

struct ProjectQuery: EntityStringQuery {
    @IntentParameterDependency<StartMeetingIntent>(\.$install) var startMeeting
    @IntentParameterDependency<CreateTaskIntent>(\.$install) var createTask

    /// Set by tests in place of the dependencies above.
    var installScope: String?

    init() {}

    init(installScope: String?) { self.installScope = installScope }

    private var scope: String? { installScope ?? startMeeting?.install.id ?? createTask?.install.id }

    func entities(for identifiers: [String]) async throws -> [ProjectEntity] {
        await EntityCatalog().resolve(identifiers) { await EntityCatalog().projects(hosts: [$0]) }
    }

    func suggestedEntities() async throws -> [ProjectEntity] {
        let catalog = EntityCatalog()
        return await catalog.projects(hosts: catalog.hosts(scope: scope))
    }

    func entities(matching string: String) async throws -> [ProjectEntity] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}

// MARK: - Agent

struct AgentEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static var defaultQuery = AgentQuery()

    let id: String
    let name: String
    let subtitle: String

    var ref: EntityRef? { EntityRef(id) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)", image: .init(systemName: "cpu"))
    }

    init(id: String, name: String, subtitle: String) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
    }

    init(_ agent: SuiteAgent, host: String, env: IntentEnvironment) {
        self.init(
            id: EntityRef(host: host, uuid: agent.id).id, name: agent.name,
            subtitle: IntentCopy.subtitle(["Agent", agent.role], install: env.disambiguator(host)))
    }
}

struct AgentQuery: EntityStringQuery {
    // Every signed-in install, or only the Ask intent's Install when set.
    @IntentParameterDependency<AskAgentIntent>(\.$install) var askAgent

    /// Set by tests in place of the dependency above.
    var installScope: String?

    private var scope: String? { installScope ?? askAgent?.install.id }

    func entities(for identifiers: [String]) async throws -> [AgentEntity] {
        await EntityCatalog().resolve(identifiers) { await EntityCatalog().agents(hosts: [$0]) }
    }

    func suggestedEntities() async throws -> [AgentEntity] {
        let catalog = EntityCatalog()
        return await catalog.agents(hosts: catalog.hosts(scope: scope))
    }

    func entities(matching string: String) async throws -> [AgentEntity] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}

// MARK: - Spotlight

@available(iOS 18, *)
extension SpaceEntity: IndexedEntity {}

@available(iOS 18, *)
extension TaskEntity: IndexedEntity {}

@available(iOS 18, *)
extension ApprovalEntity: IndexedEntity {}

@available(iOS 18, *)
extension MeetingEntity: IndexedEntity {}

@available(iOS 18, *)
extension AgentEntity: IndexedEntity {}

// iOS 27 (task 01a111bb stage 4): the entities a person shares with
// others are syncable (their `<host>|<uuid>` id is the server's, the same on
// every device) and owned as `.shared` (they live in a workspace). People
// and conversations are indexed too, through SpotlightIndexer, so their
// entries carry the host as the domain identifier like every other entry.

@available(iOS 27, *)
extension TaskEntity: SyncableEntity, OwnershipProvidingEntity {
    var ownership: EntityOwnership { .shared }
}

@available(iOS 27, *)
extension MeetingEntity: SyncableEntity, OwnershipProvidingEntity {
    var ownership: EntityOwnership { .shared }
}

@available(iOS 18, *)
enum SpotlightIndexer {
    /// Indexes one install's entities under the host as the domain
    /// identifier, so `SpotlightIndex.removeAll(host:)` drops exactly them.
    static func index<E: IndexedEntity>(_ entities: [E], host: String, expires: Date? = nil) {
        guard IntentHooks.indexesSpotlight, !entities.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems(items(entities, host: host, expires: expires)) { _ in }
    }

    /// Entities whose ids name their own host (`<host>|<uuid>`), indexed
    /// per host. An id that names no host is not indexed.
    static func indexByHost<E: IndexedEntity>(_ entities: [E]) where E.ID == String {
        let groups = Dictionary(grouping: entities.compactMap { entity in EntityRef(entity.id).map { ($0.host, entity) } }, by: \.0)
        for (host, rows) in groups { index(rows.map(\.1), host: host) }
    }

    /// The searchable items for one install's entities.
    static func items<E: IndexedEntity>(_ entities: [E], host: String, expires: Date? = nil) -> [CSSearchableItem] {
        entities.map { entity -> CSSearchableItem in
            let item = CSSearchableItem(appEntity: entity)
            item.domainIdentifier = host
            if let expires { item.expirationDate = expires }
            return item
        }
    }
}

// MARK: - Catalog

/// Loads entities from each install with that install's own bearer.
struct EntityCatalog {
    var env: IntentEnvironment = .current

    /// `/chat/<segment>` -> space uuid, per host, from the last spaces
    /// fetch: lets the web view's current page name its entity.
    static var spaceIDsBySegment: [String: [String: String]] = [:]

    /// Resolves `<host>|<uuid>` ids: each known host is loaded once with
    /// its own bearer; unknown hosts and unmatched ids are dropped.
    func resolve<E: AppEntity>(_ identifiers: [String], load: (String) async -> [E]) async -> [E] where E.ID == String {
        let refs = identifiers.compactMap(EntityRef.init).filter { env.install($0.host) != nil }
        var found: [String: E] = [:]
        for host in Self.unique(refs.map(\.host)) {
            for entity in await load(host) { found[entity.id] = entity }
        }
        return identifiers.compactMap { found[$0] }
    }

    /// The hosts a query searches: the given install alone when one is
    /// set (and signed in), otherwise every signed-in install.
    func hosts(scope: String?) -> [String] {
        let signedIn = env.signedInHosts
        guard let scope else { return signedIn }
        return signedIn.filter { $0 == scope }
    }

    func spaces(hosts: [String]) async -> [SpaceEntity] {
        await load("spaces", hosts: hosts) { host in
            let spaces = try await env.client.spaces(host: host)
            Self.spaceIDsBySegment[host] = Dictionary(spaces.map { ($0.linkSegment, $0.id) }, uniquingKeysWith: { first, _ in first })
            let entities = spaces.map { SpaceEntity($0, host: host, env: env) }
            IntentHooks.didFetchEntities?("spaces", host, entities.map { "\($0.id)\t\($0.name)" })
            if #available(iOS 18, *) { SpotlightIndexer.index(entities, host: host) }
            return entities
        }
    }

    /// People to message on each host (task 01a111bb): `query` searches
    /// server-side (`?q=`), so a person who is not among the recent
    /// collaborators is still found by name; nil lists recent collaborators.
    func people(hosts: [String], query: String? = nil) async -> [(host: String, person: SuitePerson)] {
        await load("people", hosts: hosts) { host in
            let people = try await env.client.people(host: host, query: query)
            if query == nil {
                IntentHooks.didFetchEntities?("people", host, people.map { "\(EntityRef(host: host, uuid: $0.id).id)\t\($0.name)" })
            }
            return people.map { (host: host, person: $0) }
        }
    }

    /// Every space on each host, as raw rows (for conversation entities).
    func spaceRows(hosts: [String]) async -> [(host: String, space: SuiteSpace)] {
        await load("spaces", hosts: hosts) { host in
            let spaces = try await env.client.spaces(host: host)
            Self.spaceIDsBySegment[host] = Dictionary(spaces.map { ($0.linkSegment, $0.id) }, uniquingKeysWith: { first, _ in first })
            IntentHooks.didFetchEntities?("spaces", host, spaces.map { "\(EntityRef(host: host, uuid: $0.id).id)\t\($0.name)" })
            return spaces.map { (host: host, space: $0) }
        }
    }

    func projects(hosts: [String]) async -> [ProjectEntity] {
        await load("projects", hosts: hosts) { host in
            try await env.client.projects(host: host).projects.map { ProjectEntity($0, host: host, env: env) }
        }
    }

    func tasks(hosts: [String], query: String? = nil, limit: Int? = nil) async -> [TaskEntity] {
        await load("tasks", hosts: hosts) { host in
            let entities = try await env.client.tasks(host: host, query: query, limit: limit).map { TaskEntity($0, host: host, env: env) }
            if #available(iOS 18, *), query == nil { SpotlightIndexer.index(entities, host: host) }
            return entities
        }
    }

    func approvals(hosts: [String]) async -> [ApprovalEntity] {
        await load("approvals", hosts: hosts) { host in
            let entities = try await env.client.approvals(host: host).map { ApprovalEntity($0, host: host, env: env) }
            // An approval is settled within hours; let Spotlight drop it.
            if #available(iOS 18, *) { SpotlightIndexer.index(entities, host: host, expires: env.now().addingTimeInterval(86_400)) }
            return entities
        }
    }

    func meetings(hosts: [String]) async -> [MeetingEntity] {
        await load("meetings", hosts: hosts) { host in
            let entities = try await env.client.meetings(host: host).map { MeetingEntity($0, host: host, env: env) }
            if #available(iOS 18, *) { SpotlightIndexer.index(entities, host: host) }
            return entities
        }
    }

    func agents(hosts: [String]) async -> [AgentEntity] {
        await load("agents", hosts: hosts) { host in
            let entities = try await env.client.agents(host: host).map { AgentEntity($0, host: host, env: env) }
            IntentHooks.didFetchEntities?("agents", host, entities.map { "\($0.id)\t\($0.name)" })
            if #available(iOS 18, *) { SpotlightIndexer.index(entities, host: host) }
            return entities
        }
    }

    /// One fetch per host; a host that fails contributes nothing.
    private func load<E>(_ route: String, hosts: [String], fetch: (String) async throws -> [E]) async -> [E] {
        var all: [E] = []
        for host in Self.unique(hosts) where env.install(host) != nil {
            do {
                let list = try await fetch(host)
                IntentLog.count(route, host: host, count: list.count)
                all += list
            } catch {
                IntentLog.route(route, host: host, status: Self.status(of: error))
            }
        }
        return all
    }

    static func status(of error: Error) -> Int {
        switch error {
        case SuiteAPIClient.Failure.status(let status), SuiteAPIClient.Failure.refused(let status, _): return status
        default: return 0
        }
    }

    private static func unique(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }
    }

    // MARK: Formatting

    static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: value) { return date }
        // Naive timestamps (no zone) are UTC on the server.
        return plain.date(from: value + "Z")
    }

    static func age(_ value: String?, now: Date) -> String? {
        guard let date = parseDate(value) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func dayAndTime(_ value: String?) -> String? {
        guard let date = parseDate(value) else { return nil }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
