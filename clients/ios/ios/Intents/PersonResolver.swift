import AppIntents
import Foundation

// Matching the person Siri hands Burrow to a Burrow person (task 01a111bb
// stage 7, review round 2).
//
// At 4aff9b54 Burrow accepted a system person ONLY when its identifier was
// exactly `.applicationDefined("<host>|<uuid>")`. Anything else (a display
// name with an unknown identifier, a contact id, a bare uuid) threw a bare
// `notFound` inside the system's value conversion, which Siri speaks as a
// generic "there's a problem", and nothing was logged. Now every shape is
// tried, in order, and each step logs its outcome (kinds and case names
// only, never a name, a handle or an id):
//
//   1. the identifier, as `<host>|<uuid>` or as a bare uuid on a signed-in
//      install;
//   2. an application-defined handle, the same way;
//   3. the spoken name: Burrow people already fetched in this process
//      (the index refresh fills that), else the server's search on every
//      signed-in install. A full-name or given-name match wins over a
//      substring match.
//
// One match is used, unless someone on another signed-in install answers to
// the same name (round 8, `confirmInstall`). Several make the intent ask
// which (requestChoice). None is said out loud with the name ("Burrow
// couldn't find anyone named …").

/// What a system person matched among Burrow's people.
@available(iOS 27, *)
enum PersonMatch {
    case one(MessagePersonEntity)
    case several([MessagePersonEntity])
    case none(name: String?)

    var ids: [String] {
        switch self {
        case .one(let person): return [person.id]
        case .several(let people): return people.map(\.id)
        case .none: return []
        }
    }
}

@available(iOS 27, *)
enum PersonResolver {
    /// Picks one of several people (the intent's requestChoice).
    typealias Choose = (_ name: String, _ people: [MessagePersonEntity]) async throws -> MessagePersonEntity

    /// The identifier's kind, for the log.
    static func kind(of person: IntentPerson) -> String {
        switch person.identifier {
        case .applicationDefined(let raw):
            if EntityRef(raw) != nil { return "app_id" }
            return UUID(uuidString: raw) != nil ? "app_bare_uuid" : "app_other"
        case .contact: return "contact"
        case .unknown: return "unknown"
        }
    }

    /// The name the person was spoken as, if any.
    static func spokenName(_ person: IntentPerson) -> String? {
        let name: String?
        switch person.name {
        case .displayName(let value): name = value
        case .components(let components): name = PersonNameComponentsFormatter().string(from: components)
        case .unknown: name = nil
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func resolve(_ person: IntentPerson, site: String, env: IntentEnvironment = .current) async -> PersonMatch {
        IntentLog.step(site, "identifier=\(kind(of: person))")
        if case .applicationDefined(let raw) = person.identifier, let found = await byID(raw, env: env) {
            IntentLog.step(site, "matched=identifier")
            return .one(found)
        }
        if let handle = person.handle, case .applicationDefined(let raw) = handle.value, let found = await byID(raw, env: env) {
            IntentLog.step(site, "matched=handle")
            return .one(found)
        }
        guard let name = spokenName(person) else {
            IntentLog.step(site, "matched=none reason=no_name")
            return .none(name: nil)
        }
        let candidates = await byName(name, env: env)
        switch candidates.count {
        case 0:
            IntentLog.step(site, "matched=none reason=no_name_match")
            return .none(name: name)
        case 1:
            IntentLog.step(site, "matched=name")
            return .one(candidates[0])
        default:
            IntentLog.step(site, "matched=several count=\(candidates.count)")
            return .several(candidates)
        }
    }

    /// `<host>|<uuid>` on a saved install, or a bare uuid on any signed-in
    /// install (only when it names exactly one person).
    static func byID(_ raw: String, env: IntentEnvironment) async -> MessagePersonEntity? {
        if let ref = EntityRef(raw) {
            guard env.install(ref.host) != nil else { return nil }
            if let cached = PeopleCache.shared.entity(for: raw) { return cached }
            return try? await MessagePersonEntityQuery().entities(for: [raw]).first
        }
        guard UUID(uuidString: raw) != nil else { return nil }
        let ids = env.signedInHosts.map { EntityRef(host: $0, uuid: raw.lowercased()).id }
        let cached = ids.compactMap { PeopleCache.shared.entity(for: $0) }
        if cached.count == 1 { return cached[0] }
        let found = (try? await MessagePersonEntityQuery().entities(for: ids)) ?? []
        return found.count == 1 ? found[0] : nil
    }

    /// Burrow people on signed-in installs who answer to `name`.
    static func byName(_ name: String, env: IntentEnvironment) async -> [MessagePersonEntity] {
        let hosts = Set(env.signedInHosts)
        let known = PeopleCache.shared.all().filter { EntityRef($0.id).map { hosts.contains($0.host) } ?? false }
        let fromCache = best(known, for: name)
        if !fromCache.isEmpty { return fromCache }
        let searched = (try? await MessagePersonEntityQuery(installScope: nil).entities(matching: name)) ?? []
        return best(searched, for: name)
    }

    /// Exact full-name or given-name matches if there are any, otherwise
    /// people whose name contains `name`. Case- and accent-insensitive.
    static func best(_ people: [MessagePersonEntity], for name: String) -> [MessagePersonEntity] {
        let exact = exact(people, for: name)
        if !exact.isEmpty { return exact }
        let wanted = fold(name)
        return unique(people.filter { fold($0.name).contains(wanted) })
    }

    /// Full-name or given-name matches only. Case- and accent-insensitive.
    static func exact(_ people: [MessagePersonEntity], for name: String) -> [MessagePersonEntity] {
        let wanted = fold(name)
        return unique(
            people.filter { person in
                let full = fold(person.name)
                return full == wanted || full.split(separator: " ").first.map(String.init) == wanted
            })
    }

    // MARK: Same name on another install (round 8)
    //
    // Measured on a test iPad (iOS 27.0.1, 2026-10-14), signed in to prod
    // and suite-exp: "Message Sam" went to suite-exp's Sam, not prod's
    // Sam Taylor. Siri searched the index, took the FIRST of two indexed
    // Jordans and handed Burrow that one entity (`.messagePerson`), which was
    // used as is, so the "which one?" prompt never ran. Now a person found
    // ANY way is checked against the other signed-in installs before it is
    // used: a person there who answers to the same name makes the intent ask
    // (the prompt's subtitles name the org and the install). A name nobody
    // else answers to is never asked about.
    //
    // The name checked is what the person was called: the spoken name when
    // Burrow has it; for an entity Siri resolved itself it is not passed on,
    // so the entity's GIVEN name for a human (the index lists it as an
    // alternate name, and it is how Siri matched "Sam" to both) and the
    // full name for an agent. So "Sam" collides with "Sam Taylor".
    // "Sam Taylor" spoken does not collide with "Sam Smith".

    /// The name `person` was most likely called by, when Burrow was not told.
    static func calledName(_ person: MessagePersonEntity) -> String {
        guard !person.isAgent, let given = person.name.split(separator: " ").first.map(String.init), !given.isEmpty else { return person.name }
        return given
    }

    /// People on the OTHER signed-in installs who answer to `spoken` (or,
    /// without it, to `calledName(person)`): those already fetched in this
    /// process, and the server's search on each of those installs.
    static func namesakes(of person: MessagePersonEntity, spoken: String?, env: IntentEnvironment) async -> [MessagePersonEntity] {
        guard let home = EntityRef(person.id)?.host else { return [] }
        let hosts = env.signedInHosts.filter { $0 != home }
        guard !hosts.isEmpty else { return [] }
        let name = spoken ?? calledName(person)
        let onHosts = { (entity: MessagePersonEntity) in EntityRef(entity.id).map { hosts.contains($0.host) } ?? false }
        let cached = PeopleCache.shared.all().filter(onHosts)
        let catalog = EntityCatalog(env: env)
        let searched = PeopleCache.shared.remember(
            await catalog.people(hosts: hosts, query: name).map { MessagePersonEntity($0.person, host: $0.host, env: env) })
        return exact(cached + searched, for: name).filter { $0.id != person.id }
    }

    /// `person`, unless someone on another signed-in install answers to the
    /// same name: then `choose` picks among them (this person first).
    static func confirmInstall(
        _ person: MessagePersonEntity, spoken: String?, site: String, env: IntentEnvironment = .current, choose: Choose
    ) async throws -> MessagePersonEntity {
        let others = await namesakes(of: person, spoken: spoken, env: env)
        guard !others.isEmpty else { return person }
        IntentLog.step(site, "matched=several_installs count=\(others.count + 1)")
        return try await choose(spoken ?? calledName(person), Array(([person] + others).prefix(5)))
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
    }

    private static func unique(_ people: [MessagePersonEntity]) -> [MessagePersonEntity] {
        var seen = Set<String>()
        return people.filter { seen.insert($0.id).inserted }
    }

    /// True when the identifier or handle is a `<host>|<uuid>` on a saved
    /// install (resolution then never reads the name).
    static func isBurrowID(_ person: IntentPerson, env: IntentEnvironment) -> Bool {
        var raws: [String] = []
        if case .applicationDefined(let raw) = person.identifier { raws.append(raw) }
        if let handle = person.handle, case .applicationDefined(let raw) = handle.value { raws.append(raw) }
        return raws.contains { raw in EntityRef(raw).map { env.install($0.host) != nil } ?? false }
    }

    /// One Burrow person for `person`, asking `choose` when several match.
    /// Throws a spoken failure that names the person when none does.
    static func require(_ person: IntentPerson, site: String, env: IntentEnvironment = .current, choose: Choose) async throws -> MessagePersonEntity {
        switch await resolve(person, site: site, env: env) {
        case .one(let found):
            // A spoken name matched one person, perhaps from this process's
            // cache of ONE install: the other installs are asked too. A
            // Burrow id (identifier or handle) names its install already.
            guard let name = spokenName(person), !isBurrowID(person, env: env) else { return found }
            return try await confirmInstall(found, spoken: name, site: site, env: env, choose: choose)
        case .several(let people):
            return try await choose(spokenName(person) ?? "them", Array(people.prefix(5)))
        case .none(let name):
            throw IntentFailure.personNotFound(name: name)
        }
    }
}
