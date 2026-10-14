import AppIntents
import CoreSpotlight
import Foundation

// The proactive personal index (task 01a111bb stage 7).
//
// Measured on Rowan's iPad (iPadOS 27.0.1, review of 37737c21): Siri resolves
// a spoken person or conversation in the messages schema ONLY against what
// is already on the device. It never called MessagePersonEntityQuery.entities(matching:)
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

/// A one-time rebuild of Burrow's Spotlight index, keyed on an index-schema
/// version in UserDefaults (task 01a111bb stage 7, round 8).
///
/// Measured on Rowan's iPad (iOS 27.0.1, 2026-10-14): Siri still found items
/// indexed by older builds under the OLD type name `PersonEntity` (renamed
/// MessagePersonEntity in 0b5b5e85d), and hydrating them failed ("Entity
/// hydration failed"), as it did for a removed install's people. On the
/// first launch after an update that raises `currentVersion`, every Burrow
/// item is deleted and every signed-in install is indexed afresh.
///
/// Why deleteAll and not a targeted delete: AppIntents deletes by entity
/// TYPE (`deleteAppEntities(ofType:)`), and the stale type no longer exists
/// in the binary, so it cannot be named. A delete by domain needs every
/// domain ever used, and a removed install's host is no longer known (and
/// the domain delete alone is what failed to clear the removed install).
/// `deleteAllSearchableItems` is the one call that reaches all of them; it
/// is scoped to this app's own items, and every entry it removes is
/// re-created from the server right after (tasks, meetings and approvals
/// on their next fetch). Raise `currentVersion` whenever an indexed type is
/// renamed or its id shape changes.
struct SpotlightIndexMigration {
    static let currentVersion = 2
    static let versionKey = "burrow.spotlight.index-schema-version"

    var env: IntentEnvironment = .current
    var defaults: UserDefaults = .standard
    var refresh: PersonalIndexRefresh = PersonalIndexRefresh()

    var isNeeded: Bool { defaults.integer(forKey: Self.versionKey) < Self.currentVersion }

    /// Returns the hosts re-indexed, or nil when nothing was needed (or the
    /// delete failed; the next launch tries again).
    @discardableResult
    func runIfNeeded() async -> [String]? {
        guard isNeeded else { return nil }
        do {
            try await SpotlightIndex.store.deleteAll()
        } catch {
            IntentLog.step("index.migrate", "refused=delete_failed")
            return nil
        }
        SpotlightIndex.ledger.removeAll()
        defaults.set(Self.currentVersion, forKey: Self.versionKey)
        // Unconditionally, not refreshStale: a foreground refresh that
        // finished moments ago indexed into what was just deleted.
        let hosts = env.signedInHosts
        for host in hosts {
            await refresh.refresh(host: host)
        }
        IntentLog.step("index.migrate", "version=\(Self.currentVersion) installs=\(hosts.count)")
        return hosts
    }
}

/// Indexing for the iOS 27 messages and phone entities, called from the
/// catalog's fetch path. Below iOS 27 there is nothing to index here.
enum PersonalIndex {
    static func index(people: [SuitePerson], host: String, env: IntentEnvironment) {
        guard #available(iOS 27, *) else { return }
        let entities = people.map { MessagePersonEntity($0, host: host, env: env) }
        PeopleCache.shared.remember(entities)
        SpotlightIndexer.index(entities, host: host)
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
