import AppIntents
import CoreSpotlight
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
        lock.withLock { items = items.filter { !domains.contains($0.value.domainIdentifier ?? "") } }
    }

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

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        defaultsName = "PersonalIndexTests.\(UUID().uuidString)"
        saved = (IntentEnvironment.current, IntentHooks.indexesSpotlight, IntentHooks.didFetchEntities, SpotlightIndex.store)
        memory = MemorySearchableIndex()
        SpotlightIndex.store = memory
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
        guard #available(iOS 27, *) else { throw XCTSkip("PersonEntity and ConversationEntity are iOS 27") }
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
        let found = try await PersonQuery().entities(for: [EntityRef(host: a, uuid: priyaID).id])
        XCTAssertEqual(found.map(\.name), ["Priya A"])
        XCTAssertEqual(StubURLProtocol.requests.count, before)
    }

    func testAColdProcessResolvesAnOrgMateByIdThroughTheDirectory() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27") }
        PeopleCache.shared.removeAll(host: a)
        let found = try await PersonQuery().entities(for: [EntityRef(host: a, uuid: priyaID).id])
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
    private func noChoice(_ name: String, _ people: [PersonEntity]) async throws -> PersonEntity {
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
        let carried = try await MessageDestination.messagePerson(PersonEntity(unresolved: siriPerson(.unknown, name: "Dalton A")))
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
/// Dalton saying ..." to the right PersonEntity, then logged "Failed to
/// extract Person for PersonEntity(...)" and never ran the send. The cause
/// is in the BUILT metadata, not the Swift: Xcode 27's extractor records a
/// value representation's IntentPerson type only from a key path
/// (`exporting: \PersonEntity.person`); a closure records nothing. This
/// reads the host app's own Metadata.appintents, so it fails if the
/// declaration goes back to a closure.
final class PersonEntityMetadataTests: XCTestCase {
    func testPersonEntityIsRecordedAsIntentPersonExportableAndImportable() throws {
        let url = Bundle.main.bundleURL.appendingPathComponent("Metadata.appintents/extract.actionsdata")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entities = try XCTUnwrap(root["entities"] as? [String: Any])
        let person = try XCTUnwrap(entities["PersonEntity"] as? [String: Any], "PersonEntity missing from the app's metadata")
        let transfer = try XCTUnwrap(person["transferableContentTypes"] as? [String: Any])
        func types(_ key: String) -> [String] {
            ((transfer[key] as? [[String: Any]]) ?? []).compactMap { $0["contentType"] as? String }
        }
        XCTAssertEqual(types("exportableTypes"), ["com.apple.appintents.IntentPerson"], "Siri cannot extract a Person from PersonEntity")
        XCTAssertEqual(types("importableTypes"), ["com.apple.appintents.IntentPerson"], "Siri cannot hand an IntentPerson back to PersonEntity")
    }

    /// The iOS 27 schema declares MessagePerson's `person` with indexing key
    /// `primaryRecipients`; Apple's adopters carry it as
    /// `spotlightAttributeKey`, and without it Siri's planner fails
    /// converting PersonEntity ("Type identifier conformance failed").
    func testPersonPropertyCarriesThePrimaryRecipientsSpotlightKey() throws {
        let url = Bundle.main.bundleURL.appendingPathComponent("Metadata.appintents/extract.actionsdata")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entities = try XCTUnwrap(root["entities"] as? [String: Any])
        let entity = try XCTUnwrap(entities["PersonEntity"] as? [String: Any])
        let properties = try XCTUnwrap(entity["properties"] as? [[String: Any]])
        let person = try XCTUnwrap(properties.first { $0["identifier"] as? String == "person" }, "PersonEntity has no `person` property")
        XCTAssertEqual(person["spotlightAttributeKey"] as? String, "primaryRecipients")
    }
}
