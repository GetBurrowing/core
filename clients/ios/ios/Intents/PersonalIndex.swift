import AppIntents
import CoreSpotlight
import Foundation

// The proactive personal index (task 01a111bb stage 7).
//
// Measured on Rowan's iPad (iPadOS 27.0.1, review of 37737c21): Siri resolves
// a spoken person or conversation in the messages schema ONLY against what
// is already on the device. It never called PersonQuery.entities(matching:)
// or ConversationQuery, so "Message Dalton…" failed while the server would
// have answered `?q=Dalton`. Xcode 27.0's AppIntentSchemas.sqlite says why
// the index is the input: the `messages.MessagePerson` schema maps its
// `person` property to the Spotlight key `primaryRecipients`, and
// `messages.ConversationEntity` maps `displayName` to `displayName`.
//
// So each signed-in install's people (the server's directory: recent
// collaborators, space mates, org mates and agents, external-scoped
// server-side) and conversations are indexed proactively: after sign-in,
// on every people or spaces fetch (EntityCatalog), and when the app comes to
// the foreground (at most every `foregroundInterval` per host). Every item
// carries its host as the domain identifier, so sign-out deletes exactly
// that install's entries (SpotlightIndex.removeAll), and a refresh still in
// flight cannot put them back (SpotlightIndex suppression).
//
// Sign-in also publishes the install's agents to the App Shortcut phrases
// ("Ask {agent} in Burrow") at once, instead of waiting for a background
// with a changed digest.

/// How many entities one refresh fetched for a host.
struct PersonalIndexCounts: Equatable {
    var people = 0
    var conversations = 0
    var agents = 0
}

struct PersonalIndexRefresh {
    static let foregroundInterval: TimeInterval = 15 * 60
    private static let refreshedAtPrefix = "burrow.personal-index.refreshed-at.v1."

    var env: IntentEnvironment = .current
    var shortcuts: ShortcutParameterRefresh = .shared
    /// Timestamps only, per host: never a name or an id.
    var defaults: UserDefaults = .standard

    /// Fetches `host`'s people directory, spaces and agents with its own
    /// bearer. The fetches index (EntityCatalog) and record the agent and
    /// space digests for the App Shortcut phrases.
    @discardableResult
    func refresh(host: String) async -> PersonalIndexCounts {
        guard env.install(host) != nil, env.client.isSignedIn(host: host) else { return PersonalIndexCounts() }
        let catalog = EntityCatalog(env: env)
        let people = await catalog.people(hosts: [host], directory: true)
        let spaces = await catalog.spaceRows(hosts: [host])
        let agents = await catalog.agents(hosts: [host])
        defaults.set(env.now(), forKey: Self.refreshedAtPrefix + host)
        return PersonalIndexCounts(people: people.count, conversations: spaces.count, agents: agents.count)
    }

    /// After a sign-in to `host`: lift its sign-out suppression, index it,
    /// and refresh the App Shortcut phrases now so its agents are speakable.
    @discardableResult
    func didSignIn(host: String) async -> PersonalIndexCounts {
        SpotlightIndex.allow(host: host)
        let counts = await refresh(host: host)
        shortcuts.refreshNow()
        return counts
    }

    /// The app came to the foreground: refresh every signed-in install whose
    /// last refresh is older than `foregroundInterval`. Never touches the
    /// App Shortcut phrases (they refresh on background, if changed).
    @discardableResult
    func refreshStale() async -> [String: PersonalIndexCounts] {
        var done: [String: PersonalIndexCounts] = [:]
        for host in env.signedInHosts where isStale(host) {
            done[host] = await refresh(host: host)
        }
        return done
    }

    /// Sign-out or removal: the next foreground refreshes this host afresh.
    func forget(host: String) {
        defaults.removeObject(forKey: Self.refreshedAtPrefix + host)
    }

    func isStale(_ host: String) -> Bool {
        guard let at = defaults.object(forKey: Self.refreshedAtPrefix + host) as? Date else { return true }
        return env.now().timeIntervalSince(at) >= Self.foregroundInterval
    }
}

/// Indexing for the iOS 27 messages and phone entities, called from the
/// catalog's fetch path. Below iOS 27 there is nothing to index here.
enum PersonalIndex {
    static func index(people: [SuitePerson], host: String, env: IntentEnvironment) {
        guard #available(iOS 27, *) else { return }
        let entities = people.map { PersonEntity($0, host: host, env: env) }
        PeopleCache.shared.remember(entities)
        // The messages person is transient since task 01a111bb round 5
        // (as Apple's own MessagePerson adopters are), so it is no longer
        // indexed; Siri matches a spoken name through its importer.
        // "Start a meeting with X" uses the phone schema's own person type;
        // agents cannot be called, so only humans are indexed for it.
        SpotlightIndexer.index(entities.filter { !$0.isAgent }.map(CallPersonEntity.init), host: host)
    }

    /// Named spaces only, not DMs or groups (which the server names after
    /// the other member). Xcode 27.0's schema processor refuses a
    /// conversation as a send destination ("Parameter 'destination' does
    /// not match required AppSchemaIntent type 'MessageDestinationCases:
    /// (Array<Person> | Schema<MessagePerson> | Array<Schema<MessagePerson>>)'"),
    /// so an indexed conversation named "Dalton" could only compete with
    /// the person Dalton for the spoken name.
    static func index(spaces: [SuiteSpace], host: String, env: IntentEnvironment) {
        guard #available(iOS 27, *) else { return }
        SpotlightIndexer.index(spaces.filter { !$0.isDirectMessage && $0.kind != "group" }.map { ConversationEntity($0, host: host, env: env) }, host: host)
    }

    /// Other names Spotlight may match a person by: the full name and, for a
    /// human, the given name ("Dalton" for "Dalton Rourke").
    static func alternateNames(person name: String, isAgent: Bool) -> [String] {
        var names = [name]
        if !isAgent, let given = PersonNameComponentsFormatter().personNameComponents(from: name)?.givenName,
            !given.isEmpty, given != name
        {
            names.append(given)
        }
        return names
    }
}
