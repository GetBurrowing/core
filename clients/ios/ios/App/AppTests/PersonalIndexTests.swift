import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers
import XCTest

@testable import App

/// Spotlight in memory: items by unique identifier, deletable by domain.
final class MemorySearchableIndex: SearchableIndexStore {
    private let lock = NSLock()
    private var items: [String: CSSearchableItem] = [:]

    func index(_ new: [CSSearchableItem]) {
        lock.withLock { for item in new { items[item.uniqueIdentifier] = item } }
    }

    func deleteDomains(_ domains: [String]) {
        lock.withLock {
            deletedDomains += domains
            items = items.filter { !domains.contains($0.value.domainIdentifier ?? "") }
        }
    }

    /// Ids deleted as app entities, in call order.
    private(set) var deletedEntityIDs: [String] = []
    private(set) var deletedDomains: [String] = []
    private(set) var deleteAllCount = 0

    func deleteEntities(_ ids: [String]) {
        lock.withLock { deletedEntityIDs += ids }
    }

    func deleteAll() async throws {
        lock.withLock {
            deleteAllCount += 1
            items = [:]
        }
    }

    func seed(_ item: CSSearchableItem) {
        lock.withLock { items[item.uniqueIdentifier] = item }
    }

    var count: Int { lock.withLock { items.count } }

    func items(host: String) -> [CSSearchableItem] {
        lock.withLock { items.values.filter { $0.domainIdentifier == host } }
    }

    /// The display names of `host`'s items.
    func names(host: String) -> Set<String> {
        Set(items(host: host).compactMap { $0.attributeSet.displayName ?? $0.attributeSet.title })
    }
}

/// Task 01a111bb stage 7 (review of 37737c21, findings 1, 2, 3 and 5): Siri
/// on iOS 27.0.1 resolves a spoken person or conversation only against the
/// device's index, so each install's people directory and conversations are
/// indexed proactively at sign-in, its agents are published to the App
/// Shortcut phrases at once, and sign-out of one install removes only its
/// entries.
final class PersonalIndexTests: XCTestCase {
    private let a = "a.example.com"
    private let b = "b.example.com"
    private let daltonID = "da000000-0000-4000-8000-000000000001"
    private let priyaID = "9e000000-0000-4000-8000-000000000002"
    private let helperID = "0a0a0a0a-0000-4000-8000-000000000001"
    /// Priya's id on install B: a bare uuid then names exactly one person.
    private let priyaIDOnB = "9e000000-0000-4000-8000-00000000000b"
    /// Hosts whose server predates the directory (it answers 404).
    private var noDirectory: Set<String> = []
    private var defaultsName = ""
    private var memory = MemorySearchableIndex()
    private var updates = 0
    private var refresh: ShortcutParameterRefresh!
    private var saved: (IntentEnvironment, Bool, ((String, String, [String]) -> Void)?, SearchableIndexStore)!
    private var savedLedger: IndexedIDLedger!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        defaultsName = "PersonalIndexTests.\(UUID().uuidString)"
        saved = (IntentEnvironment.current, IntentHooks.indexesSpotlight, IntentHooks.didFetchEntities, SpotlightIndex.store)
        memory = MemorySearchableIndex()
        SpotlightIndex.store = memory
        savedLedger = SpotlightIndex.ledger
        SpotlightIndex.ledger = IndexedIDLedger(defaults: defaults)
        IntentHooks.indexesSpotlight = true
        updates = 0
        refresh = ShortcutParameterRefresh(defaults: defaults, update: { [unowned self] in self.updates += 1 })
        // The app's wiring: a fetch records what it saw, never refreshes.
        IntentHooks.didFetchEntities = { [unowned self] route, host, keys in self.refresh.record(route: route, host: host, keys: keys) }
        IntentEnvironment.current = env()
        StubURLProtocol.respond = { [unowned self] request in self.respond(request) }
    }

    override func tearDown() {
        IntentEnvironment.current = saved.0
        IntentHooks.indexesSpotlight = saved.1
        IntentHooks.didFetchEntities = saved.2
        SpotlightIndex.store = saved.3
        SpotlightIndex.ledger = savedLedger
        UserDefaults().removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    private var defaults: UserDefaults { UserDefaults(suiteName: defaultsName)! }

    private func env() -> IntentEnvironment {
        let store = InstallStore(defaults: defaults)
        let removeHook = InstallStore.didRemove
        InstallStore.didRemove = nil
        defer { InstallStore.didRemove = removeHook }
        for host in [a, b] { store.add(host: host) }
        for host in InstallStore.defaultHosts where ![a, b].contains(host) { store.remove(host: host) }
        return IntentEnvironment(
            client: SuiteAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: [a: "token-for-a", b: "token-for-b"])),
            installs: store, sleeper: VirtualClock(), now: { Date(timeIntervalSince1970: 4_000_000) },
            lastMeetingSpaces: LastMeetingSpaceStore(defaults: defaults))
    }

    private func indexer() -> PersonalIndexRefresh {
        PersonalIndexRefresh(env: IntentEnvironment.current, shortcuts: refresh, defaults: defaults)
    }

    /// Each host answers with its own people: Dalton (a collaborator),
    /// Priya (an org mate with NO shared space, listed only by the
    /// directory) and the agent Burrow Helper; one conversation, general.
    private func respond(_ request: URLRequest) -> (Int, Data) {
        let host = request.url?.host ?? ""
        let tag = host == a ? "A" : "B"
        switch request.url?.path ?? "" {
        case "/api/app/people":
            let directory = request.url?.query == "scope=directory"
            if directory && noDirectory.contains(host) { return (404, Data(#"{"error":"not_found"}"#.utf8)) }
            var people = [#"{"id":"\#(daltonID)","kind":"user","name":"Dalton \#(tag)","org_names":["Fabrikam"]}"#]
            if directory {
                people.append(#"{"id":"\#(tag == "A" ? priyaID : priyaIDOnB)","kind":"user","name":"Priya \#(tag)","org_names":["Fabrikam"]}"#)
                people.append(#"{"id":"\#(helperID)","kind":"agent","name":"Burrow Helper \#(tag)","org_names":[]}"#)
            }
            return (200, Data(#"{"people":[\#(people.joined(separator: ","))]}"#.utf8))
        case "/api/app/spaces":
            return (
                200,
                Data(
                    #"{"spaces":[{"id":"5a000000-0000-4000-8000-000000000001","name":"general","kind":"channel","path_segment":"g","agents":[],"org":{"id":"o","name":"Fabrikam \#(tag)"}}]}"#
                        .utf8)
            )
        case "/api/app/agents":
            return (200, Data(#"{"agents":[{"id":"\#(helperID)","name":"Burrow Helper \#(tag)","slug":null,"role":"agent"}]}"#.utf8))
        default:
            return (404, Data())
        }
    }

    private func requests(host: String, path: String) -> [URLRequest] {
        StubURLProtocol.requests.filter { $0.url?.host == host && $0.url?.path == path }
    }

    // MARK: Finding 1 and 3: indexed at sign-in, an org mate included

    func testSignInIndexesTheHostsPeopleAndConversationsIncludingAnOrgMateWithNoSharedSpace() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("MessagePersonEntity and ConversationEntity are iOS 27") }
        let counts = await indexer().didSignIn(host: a)

        XCTAssertEqual(counts, PersonalIndexCounts(people: 3, conversations: 1, agents: 1))
        XCTAssertEqual(requests(host: a, path: "/api/app/people").map(\.url?.query), ["scope=directory"])
        XCTAssertTrue(requests(host: b, path: "/api/app/people").isEmpty, "a sign-in to A asks nothing of B")

        let items = memory.items(host: a)
        XCTAssertGreaterThan(items.count, 0)
        XCTAssertEqual(Set(items.map(\.domainIdentifier)), [a])
        let names = memory.names(host: a)
        XCTAssertTrue(names.contains("Priya A"), "the org mate with no shared space is indexed: \(names)")
        XCTAssertTrue(names.contains("Dalton A"))
        XCTAssertTrue(names.contains("Burrow Helper A"), "agents are people Siri can message")
        XCTAssertTrue(names.contains(where: { $0.hasPrefix("general") }), "the conversation is indexed: \(names)")
        // Persons (message + call for humans), the agent once, one
        // conversation, plus the legacy SpaceEntity and AgentEntity.
        let priya = items.filter { ($0.attributeSet.displayName ?? "") == "Priya A" }
        XCTAssertEqual(priya.count, 2, "Priya as a message person and as a call person")
        XCTAssertEqual(priya.first?.attributeSet.alternateNames?.contains("Priya"), true, "the given name is an alternate")
        XCTAssertEqual(memory.items(host: b).count, 0)
    }

    func testTheCacheResolvesAnIndexedPersonWithNoFurtherRequest() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27") }
        await indexer().didSignIn(host: a)
        let before = StubURLProtocol.requests.count
        let found = try await MessagePersonEntityQuery().entities(for: [EntityRef(host: a, uuid: priyaID).id])
        XCTAssertEqual(found.map(\.name), ["Priya A"])
        XCTAssertEqual(StubURLProtocol.requests.count, before)
    }

    func testAColdProcessResolvesAnOrgMateByIdThroughTheDirectory() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27") }
        PeopleCache.shared.removeAll(host: a)
        let found = try await MessagePersonEntityQuery().entities(for: [EntityRef(host: a, uuid: priyaID).id])
        XCTAssertEqual(found.map(\.name), ["Priya A"], "Priya is outside the recent collaborators; the directory has her")
        XCTAssertEqual(requests(host: a, path: "/api/app/people").last?.url?.query, "scope=directory")
    }

    // MARK: Finding 2: agents published to the phrases at sign-in

    func testSignInPublishesTheInstallsAgentsToTheShortcutPhrasesAtOnce() async {
        await indexer().didSignIn(host: a)
        XCTAssertEqual(requests(host: a, path: "/api/app/agents").count, 1)
        XCTAssertEqual(updates, 1, "the App Shortcut parameters refresh right after sign-in, not at a later background")

        // A foreground refresh fetches but never refreshes the phrases.
        let done = await indexer().refreshStale()
        XCTAssertEqual(Set(done.keys), [b], "A was just refreshed; only B is stale")
        XCTAssertEqual(updates, 1)
        XCTAssertFalse(refresh.refreshIfNeeded(), "B's fetch landed inside the settle window: nothing is dirty")
    }

    // MARK: Finding 2 (b): a schema send to an agent waits for its reply

    func testASendToAnAgentReadsThatAgentsReplyAfterTheSentMessage() async throws {
        let space = "d0000000-0000-4000-8000-000000000001"
        StubURLProtocol.respond = { request in
            guard request.url?.path == "/api/app/spaces/\(space)/messages" else { return (404, Data()) }
            // A human's message first, then the agent's reply.
            return (
                200,
                Data(
                    #"{"messages":[{"id":"m2","author_type":"user","author_id":"u","content":"me too"},"#
                        .utf8)
                    + Data(#"{"id":"m3","author_type":"agent","author_id":"\#(self.helperID)","content":"Green."}]}"#.utf8)
            )
        }
        let outcome = try await IntentActions(env: IntentEnvironment.current).awaitAgentReply(
            host: a, agentUUID: helperID, spaceID: space, after: "m1", window: AskAgent.longReplyWindow)
        XCTAssertEqual(outcome, .reply("Green."))
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.query, "after=m1", "polls after the sent message")
        XCTAssertEqual(Set(StubURLProtocol.requests.compactMap { $0.url?.host }), [a])
    }

    // MARK: Finding 5: sign-out of A removes only A's entries

    func testSignOutOfARemovesAsEntriesOnlyAndALateRefreshCannotPutThemBack() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27") }
        await indexer().didSignIn(host: a)
        await indexer().didSignIn(host: b)
        let bBefore = Set(memory.items(host: b).map(\.uniqueIdentifier))
        XCTAssertGreaterThan(memory.items(host: a).count, 0, "positive control: A was indexed")
        XCTAssertGreaterThan(bBefore.count, 0, "positive control: B was indexed")

        let manager = FakeDonationManager()
        let donations = Donations(
            manager: manager, ledger: DonationLedger(defaults: defaults), resolver: FakeDonationResolver(), isSaved: { _ in true })
        await IntentAppHooks.forget(host: a, donations: donations).value

        XCTAssertEqual(memory.items(host: a).count, 0, "A's people and conversations are gone")
        XCTAssertEqual(Set(memory.items(host: b).map(\.uniqueIdentifier)), bBefore, "B's entries survive A's sign-out")

        // A refresh of A that was in flight at sign-out lands afterwards.
        await indexer().refresh(host: a)
        XCTAssertEqual(memory.items(host: a).count, 0, "a signed-out install is not re-indexed")

        // Signing in again lifts it.
        await indexer().didSignIn(host: a)
        XCTAssertGreaterThan(memory.items(host: a).count, 0)
    }

    // MARK: Wiring: the app calls the refresh at sign-in and on foreground

    /// The hooks above are only as good as their call sites, which run a
    /// real sign-in and a real scene: pin them by source, in the function
    /// they must run in.
    func testSignInAndForegroundCallTheIndexRefresh() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")
        func body(of function: String, in file: String) throws -> String {
            let source = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            guard let start = source.range(of: function) else { return "" }
            let rest = source[start.upperBound...]
            let end = rest.range(of: "\n    func ") ?? rest.range(of: "\n    static func ")
            return String(rest[..<(end?.lowerBound ?? rest.endIndex)])
        }
        let exchange = try body(of: "static func exchange(", in: "AuthSession.swift")
        XCTAssertFalse(exchange.isEmpty, "positive control: the scan found AuthSession.exchange")
        let stored = try XCTUnwrap(exchange.range(of: "KeychainTokenStore.shared.store("))
        let signIn = try XCTUnwrap(exchange.range(of: "IntentAppHooks.didSignIn(host: host)"), "sign-in must index the install")
        XCTAssertLessThan(stored.lowerBound, signIn.lowerBound, "indexed after the bearer is stored")

        let active = try body(of: "func sceneDidBecomeActive(", in: "SceneDelegate.swift")
        XCTAssertFalse(active.isEmpty)
        XCTAssertTrue(active.contains("IntentAppHooks.didBecomeActive()"), "foreground must refresh stale installs")
    }

    // MARK: Round 2: a person shaped the way Siri hands it back

    private func siriPerson(_ identifier: IntentPerson.Identifier, name: String?) -> IntentPerson {
        IntentPerson(identifier: identifier, name: name.map { .displayName($0) } ?? .unknown, handle: nil)
    }

    @available(iOS 27, *)
    private func noChoice(_ name: String, _ people: [MessagePersonEntity]) async throws -> MessagePersonEntity {
        XCTFail("asked which \(name) among \(people.count)")
        throw CancellationError()
    }

    func testASiriPersonWithNoBurrowIdResolvesByName() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27") }
        await indexer().didSignIn(host: a)
        // A display name only, as an unknown identifier: Siri's likeliest shape.
        let unknown = try await MessageDestination.people([siriPerson(.unknown, name: "Priya A")])
            .resolvedBurrowDestination(site: "test", choose: noChoice)
        XCTAssertEqual(unknown.entityID, EntityRef(host: a, uuid: priyaID).id)

        // A contact identifier, the given name only.
        let contact = try await MessageDestination.people([siriPerson(.contact("ABC-123"), name: "priya a")])
            .resolvedBurrowDestination(site: "test", choose: noChoice)
        XCTAssertEqual(contact.entityID, EntityRef(host: a, uuid: priyaID).id)

        // An unresolved entity carried from the import resolves the same way.
        let carried = try await MessageDestination.messagePerson(MessagePersonEntity(unresolved: siriPerson(.unknown, name: "Dalton A")))
            .resolvedBurrowDestination(site: "test", choose: noChoice)
        XCTAssertEqual(carried.entityID, EntityRef(host: a, uuid: daltonID).id)
    }

    func testABareUuidResolvesOnTheInstallThatHasIt() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27") }
        await indexer().didSignIn(host: a)
        await indexer().didSignIn(host: b)
        let target = try await MessageDestination.people([siriPerson(.applicationDefined(priyaIDOnB), name: nil)])
            .resolvedBurrowDestination(site: "test", choose: noChoice)
        XCTAssertEqual(target.entityID, EntityRef(host: b, uuid: priyaIDOnB).id)
    }

    func testTwoPeopleWithTheSpokenNameAreAskedAbout() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27") }
        await indexer().didSignIn(host: a)
        await indexer().didSignIn(host: b)
        var asked: (String, [String])?
        let target = try await MessageDestination.people([siriPerson(.unknown, name: "Dalton")])
            .resolvedBurrowDestination(site: "test") { name, people in
                asked = (name, people.map(\.name).sorted())
                return people.first { $0.name == "Dalton B" }!
            }
        XCTAssertEqual(asked?.0, "Dalton")
        XCTAssertEqual(asked?.1, ["Dalton A", "Dalton B"], "a given-name match on both installs is asked, not guessed")
        XCTAssertEqual(target.entityID, EntityRef(host: b, uuid: daltonID).id)
    }

    func testNobodyByThatNameIsSaidWithTheName() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27") }
        await indexer().didSignIn(host: a)
        do {
            _ = try await MessageDestination.people([siriPerson(.unknown, name: "Zed")])
                .resolvedBurrowDestination(site: "test", choose: noChoice)
            XCTFail("resolved a person nobody is named")
        } catch let failure as IntentFailure {
            XCTAssertEqual(failure, .personNotFound(name: "Zed"))
            XCTAssertTrue(failure.message.contains("Zed"))
        }
        XCTAssertFalse(
            requests(host: a, path: "/api/app/people").filter { $0.url?.query == "q=Zed" }.isEmpty,
            "the server's search is asked before giving up")
    }

    func testACallToAPersonWithNoBurrowIdResolvesByName() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27") }
        await indexer().didSignIn(host: a)
        var foreign = CallPersonEntity(id: "contact-xyz", name: "Dalton A", kind: "user", subtitle: "")
        foreign.person = siriPerson(.contact("contact-xyz"), name: "Dalton A")
        let found = try await CallPersonResolution.resolve(foreign, choose: noChoice)
        XCTAssertEqual(found.id, EntityRef(host: a, uuid: daltonID).id)
    }

    // MARK: Round 8, bug A: a name on two installs is asked about

    /// Rowan's iPad, signed in to prod and suite-exp: "Message Harper" went to
    /// suite-exp's Harper, the first of the two indexed Jordans Siri found,
    /// handed to Burrow as a resolved entity and used as is.
    @available(iOS 27, *)
    private func jordans() {
        PeopleCache.shared.removeAll(host: a)
        PeopleCache.shared.removeAll(host: b)
        StubURLProtocol.respond = { [unowned self] request in
            guard request.url?.path == "/api/app/people" else { return (404, Data()) }
            let people =
                request.url?.host == self.a
                ? #"[{"id":"\#(self.jordanOnA)","kind":"user","name":"Harper","org_names":["Exp"]},"#
                    + #"{"id":"\#(self.inesOnA)","kind":"user","name":"Ines Alvarez","org_names":["Exp"]}]"#
                : #"[{"id":"\#(self.jordanOnB)","kind":"user","name":"Harper Parker","org_names":["Fabrikam"]}]"#
            return (200, Data(#"{"people":\#(people)}"#.utf8))
        }
    }

    private let jordanOnA = "70000000-0000-4000-8000-00000000000a"
    private let jordanOnB = "70000000-0000-4000-8000-00000000000b"
    private let inesOnA = "1e000000-0000-4000-8000-00000000000a"

    @available(iOS 27, *)
    private func entity(_ uuid: String, on host: String, name: String) -> MessagePersonEntity {
        MessagePersonEntity(id: EntityRef(host: host, uuid: uuid).id, name: name, kind: "user", subtitle: "Person")
    }

    func testAPersonSiriPickedIsAskedAboutWhenAnotherInstallHasTheSameName() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27") }
        jordans()
        defer { PeopleCache.shared.removeAll(host: a); PeopleCache.shared.removeAll(host: b) }
        var asked: (String, [String])?
        let target = try await MessageDestination.messagePerson(entity(jordanOnA, on: a, name: "Harper"))
            .resolvedBurrowDestination(site: "test") { name, people in
                asked = (name, people.map(\.id))
                return people[1]
            }
        XCTAssertEqual(asked?.0, "Harper")
        XCTAssertEqual(
            asked?.1, [EntityRef(host: a, uuid: jordanOnA).id, EntityRef(host: b, uuid: jordanOnB).id],
            "Siri's pick first, then the namesake on the other install")
        XCTAssertEqual(target.entityID, EntityRef(host: b, uuid: jordanOnB).id, "the person chosen is the one messaged")

        // The other way round: Siri picked Harper Parker; A's Harper answers too.
        var askedAgain = false
        _ = try await MessageDestination.messagePeople([entity(jordanOnB, on: b, name: "Harper Parker")])
            .resolvedBurrowDestination(site: "test") { _, people in
                askedAgain = true
                return people[0]
            }
        XCTAssertTrue(askedAgain)

        // A Shortcut that scoped the send to one install is not asked.
        let scoped = try await MessageDestination.messagePerson(entity(jordanOnA, on: a, name: "Harper"))
            .resolvedBurrowDestination(site: "test", confirmsInstall: false, choose: noChoice)
        XCTAssertEqual(scoped.entityID, EntityRef(host: a, uuid: jordanOnA).id)
    }

    func testAPersonWhoseNameIsUniqueAcrossInstallsIsNotAskedAbout() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27") }
        jordans()
        defer { PeopleCache.shared.removeAll(host: a); PeopleCache.shared.removeAll(host: b) }
        let target = try await MessageDestination.messagePerson(entity(inesOnA, on: a, name: "Ines Alvarez"))
            .resolvedBurrowDestination(site: "test", choose: noChoice)
        XCTAssertEqual(target.entityID, EntityRef(host: a, uuid: inesOnA).id)
        XCTAssertFalse(requests(host: b, path: "/api/app/people").isEmpty, "positive control: the other install was searched")
    }

    func testASpokenNameMatchedFromOneInstallsCacheIsCheckedOnTheOther() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27") }
        jordans()
        defer { PeopleCache.shared.removeAll(host: a); PeopleCache.shared.removeAll(host: b) }
        // Only A's people are in this process's cache.
        PeopleCache.shared.remember([entity(jordanOnA, on: a, name: "Harper")])
        var asked: [String] = []
        _ = try await MessageDestination.people([siriPerson(.unknown, name: "Harper")])
            .resolvedBurrowDestination(site: "test") { _, people in
                asked = people.map(\.name)
                return people[0]
            }
        XCTAssertEqual(asked, ["Harper", "Harper Parker"])
    }

    // MARK: Round 8, bug B: a removed install's entities leave Spotlight by id

    func testRemovingAnInstallDeletesItsIndexedEntitiesByIdAsWellAsByDomain() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27") }
        await indexer().didSignIn(host: a)
        await indexer().didSignIn(host: b)
        XCTAssertFalse(SpotlightIndex.ledger.ids(host: a).isEmpty, "positive control: A's ids were recorded")

        await IntentAppHooks.forget(host: a, donations: Donations(
            manager: FakeDonationManager(), ledger: DonationLedger(defaults: defaults), resolver: FakeDonationResolver(), isSaved: { _ in true })).value

        let deleted = Set(memory.deletedEntityIDs)
        for uuid in [daltonID, priyaID, helperID] {
            XCTAssertTrue(deleted.contains(EntityRef(host: a, uuid: uuid).id), "A's \(uuid) is deleted as an app entity")
        }
        XCTAssertTrue(deleted.contains(EntityRef(host: a, uuid: "5a000000-0000-4000-8000-000000000001").id), "A's conversation too")
        XCTAssertFalse(deleted.contains { $0.hasPrefix(b + "|") }, "B's entities are untouched")
        XCTAssertTrue(memory.deletedDomains.contains(a))
        XCTAssertTrue(SpotlightIndex.ledger.ids(host: a).isEmpty)
        XCTAssertFalse(SpotlightIndex.ledger.ids(host: b).isEmpty)
    }

    func testHydratingAPersonOnARemovedInstallPurgesItFromSpotlight() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27") }
        await indexer().didSignIn(host: a)
        let gone = "gone.example.com"
        let stale = EntityRef(host: gone, uuid: daltonID).id
        let live = EntityRef(host: a, uuid: daltonID).id
        let found = try await MessagePersonEntityQuery().entities(for: [stale, live])
        XCTAssertEqual(found.map(\.id), [live])
        XCTAssertEqual(memory.deletedEntityIDs, [stale], "the removed install's id is purged, the live one kept")
        XCTAssertEqual(memory.deletedDomains, [gone])
        XCTAssertGreaterThan(memory.items(host: a).count, 0)

        _ = try await ConversationQuery().entities(for: [EntityRef(host: gone, uuid: "5a000000-0000-4000-8000-000000000001").id])
        XCTAssertEqual(memory.deletedEntityIDs.count, 2, "a stale conversation is purged too")
    }

    // MARK: Round 8, bug C: one rebuild after an index schema change

    func testTheFirstForegroundAfterAnUpdateRebuildsTheIndexOnce() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27") }
        // An item from an older build (type PersonEntity) on an install
        // since removed, and a stale one on A.
        let legacy = CSSearchableItem(uniqueIdentifier: "legacy-person", domainIdentifier: "gone.example.com", attributeSet: CSSearchableItemAttributeSet(contentType: .content))
        let old = CSSearchableItem(uniqueIdentifier: "old-a", domainIdentifier: a, attributeSet: CSSearchableItemAttributeSet(contentType: .content))
        memory.seed(legacy)
        memory.seed(old)
        let migration = SpotlightIndexMigration(env: IntentEnvironment.current, defaults: defaults, refresh: indexer())
        XCTAssertTrue(migration.isNeeded)

        _ = await IntentAppHooks.didBecomeActive(refresh: indexer(), migration: migration).value

        XCTAssertEqual(memory.deleteAllCount, 1)
        XCTAssertEqual(memory.items(host: "gone.example.com").count, 0, "the older build's item is gone")
        XCTAssertFalse(memory.items(host: a).contains { $0.uniqueIdentifier == "old-a" })
        XCTAssertTrue(memory.names(host: a).contains("Dalton A"), "A is indexed afresh")
        XCTAssertTrue(memory.names(host: b).contains("Dalton B"), "and B")
        XCTAssertEqual(defaults.integer(forKey: SpotlightIndexMigration.versionKey), SpotlightIndexMigration.currentVersion)

        // Later launches leave the index alone.
        let before = StubURLProtocol.requests.count
        let again = await migration.runIfNeeded()
        XCTAssertNil(again)
        XCTAssertEqual(memory.deleteAllCount, 1)
        XCTAssertEqual(StubURLProtocol.requests.count, before)
    }

    // MARK: Round 2: an install whose server has no directory

    func testAnInstallWithoutTheDirectoryStillIndexesItsCollaborators() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27") }
        noDirectory = [b]
        let counts = await indexer().didSignIn(host: b)
        XCTAssertEqual(
            requests(host: b, path: "/api/app/people").map { $0.url?.query ?? "" }, ["scope=directory", ""],
            "the 404 falls back to the recent collaborators")
        XCTAssertEqual(counts.people, 1)
        XCTAssertTrue(memory.names(host: b).contains("Dalton B"))
    }
}

/// Task 01a111bb stage 7, round 3: on iPadOS 27.0.1 Siri resolved "Message
/// Dalton saying ..." to the right MessagePersonEntity, then logged "Failed to
/// extract Person for PersonEntity(...)" (its name then) and never ran the send. The cause
/// is in the BUILT metadata, not the Swift: Xcode 27's extractor records a
/// value representation's IntentPerson type only from a key path
/// (`exporting: \MessagePersonEntity.person`); a closure records nothing. This
/// reads the host app's own Metadata.appintents, so it fails if the
/// declaration goes back to a closure.
final class MessagePersonEntityMetadataTests: XCTestCase {
    func testMessagePersonEntityIsRecordedAsIntentPersonExportableAndImportable() throws {
        let url = Bundle.main.bundleURL.appendingPathComponent("Metadata.appintents/extract.actionsdata")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entities = try XCTUnwrap(root["entities"] as? [String: Any])
        let person = try XCTUnwrap(entities["MessagePersonEntity"] as? [String: Any], "MessagePersonEntity missing from the app's metadata")
        let transfer = try XCTUnwrap(person["transferableContentTypes"] as? [String: Any])
        func types(_ key: String) -> [String] {
            ((transfer[key] as? [[String: Any]]) ?? []).compactMap { $0["contentType"] as? String }
        }
        XCTAssertEqual(types("exportableTypes"), ["com.apple.appintents.IntentPerson"], "Siri cannot extract a Person from MessagePersonEntity")
        XCTAssertEqual(types("importableTypes"), ["com.apple.appintents.IntentPerson"], "Siri cannot hand an IntentPerson back to MessagePersonEntity")
    }

    /// The iOS 27 schema declares MessagePerson's `person` with indexing key
    /// `primaryRecipients`; Apple's adopters carry it as
    /// `spotlightAttributeKey`, and without it Siri's planner fails
    /// converting MessagePersonEntity ("Type identifier conformance failed").
    func testPersonPropertyCarriesThePrimaryRecipientsSpotlightKey() throws {
        let url = Bundle.main.bundleURL.appendingPathComponent("Metadata.appintents/extract.actionsdata")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entities = try XCTUnwrap(root["entities"] as? [String: Any])
        let entity = try XCTUnwrap(entities["MessagePersonEntity"] as? [String: Any])
        let properties = try XCTUnwrap(entity["properties"] as? [[String: Any]])
        let person = try XCTUnwrap(properties.first { $0["identifier"] as? String == "person" }, "MessagePersonEntity has no `person` property")
        XCTAssertEqual(person["spotlightAttributeKey"] as? String, "primaryRecipients")
    }
}
