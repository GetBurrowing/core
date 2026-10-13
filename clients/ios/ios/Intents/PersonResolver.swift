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
// One match is used. Several make the intent ask which (requestChoice). None
// is said out loud with the name ("Burrow couldn't find anyone named …").

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
        let wanted = fold(name)
        let exact = people.filter { person in
            let full = fold(person.name)
            return full == wanted || full.split(separator: " ").first.map(String.init) == wanted
        }
        if !exact.isEmpty { return unique(exact) }
        return unique(people.filter { fold($0.name).contains(wanted) })
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
    }

    private static func unique(_ people: [MessagePersonEntity]) -> [MessagePersonEntity] {
        var seen = Set<String>()
        return people.filter { seen.insert($0.id).inserted }
    }

    /// One Burrow person for `person`, asking `choose` when several match.
    /// Throws a spoken failure that names the person when none does.
    static func require(_ person: IntentPerson, site: String, env: IntentEnvironment = .current, choose: Choose) async throws -> MessagePersonEntity {
        switch await resolve(person, site: site, env: env) {
        case .one(let found):
            return found
        case .several(let people):
            return try await choose(spokenName(person) ?? "them", Array(people.prefix(5)))
        case .none(let name):
            throw IntentFailure.personNotFound(name: name)
        }
    }
}
