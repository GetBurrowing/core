import XCTest

@testable import App

private struct Declined: Error {}

/// Task 01a111bb stage 3: the messages domain. MessagingActions and the API
/// client run on every runtime; the iOS 27 entity queries are gated.
final class MessagingTests: XCTestCase {
    private let a = "a.example.com"
    private let b = "b.example.com"
    private let personID = "9e000000-0000-4000-8000-000000000001"
    private let agentID = "0a0a0a0a-0000-4000-8000-000000000001"
    private let spaceID = "5a000000-0000-4000-8000-000000000001"
    private let dmID = "0d0d0d0d-0000-4000-8000-000000000001"
    private let messageID = "3e000000-0000-4000-8000-000000000001"
    private var defaultsName = ""
    private var saved: IntentEnvironment!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        defaultsName = "MessagingTests.\(UUID().uuidString)"
        saved = IntentEnvironment.current
    }

    override func tearDown() {
        IntentEnvironment.current = saved
        UserDefaults().removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    private func env(tokens: [String: String], hosts: [String]) -> IntentEnvironment {
        let defaults = UserDefaults(suiteName: defaultsName)!
        let store = InstallStore(defaults: defaults)
        let removeHook = InstallStore.didRemove
        InstallStore.didRemove = nil
        defer { InstallStore.didRemove = removeHook }
        for host in hosts { store.add(host: host) }
        let clock = VirtualClock()
        return IntentEnvironment(
            client: SuiteAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: tokens)),
            installs: store, sleeper: clock, now: { clock.now }, lastMeetingSpaces: LastMeetingSpaceStore(defaults: defaults))
    }

    private func json(_ text: String) -> Data { Data(text.utf8) }

    private func generalInTwoOrgs(host: String) -> Data {
        json(
            #"{"spaces":["#
                + #"{"id":"g1","name":"general","kind":"channel","path_segment":"g1","agents":[],"org":{"id":"o1","name":"Fabrikam"}},"#
                + #"{"id":"g2","name":"general","kind":"channel","path_segment":"g2","agents":[],"org":{"id":"o2","name":"Red Star"}},"#
                + #"{"id":"d1","name":"Dalton","kind":"dm","path_segment":"d1","agents":[],"org":null}]}"#)
    }

    // MARK: API client

    func testSpacesDecodeOrgAndToleratesAnOlderServerWithout() throws {
        struct Body: Decodable { let spaces: [SuiteSpace] }
        let new = try JSONDecoder().decode(Body.self, from: generalInTwoOrgs(host: a)).spaces
        XCTAssertEqual(new.map { $0.org?.name }, ["Fabrikam", "Red Star", nil])

        let old = try JSONDecoder().decode(Body.self, from: json(#"{"spaces":[{"id":"s","name":"general","agents":[]}]}"#)).spaces
        XCTAssertNil(old[0].org)

        let odd = try JSONDecoder().decode(Body.self, from: json(#"{"spaces":[{"id":"s","name":"general","org":"weird"}]}"#)).spaces
        XCTAssertNil(odd[0].org, "a malformed org must not fail the whole list")
    }

    func testRoutesAndBodies() async throws {
        let client = env(tokens: [a: "token-for-a"], hosts: [a]).client
        StubURLProtocol.respond = { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("GET", "/api/app/people"):
                return (200, self.json(#"{"people":[{"id":"p","kind":"user","name":"Priya","org_names":["Fabrikam"],"dm_space_id":null}]}"#))
            case ("POST", "/api/app/people/p/dm"): return (200, self.json(#"{"space_id":"d","path_segment":"d"}"#))
            case ("GET", "/api/app/projects"):
                return (200, self.json(#"{"projects":[{"id":"pr","name":"Burrow","org":{"id":"o","name":"Fabrikam"}}],"last_meeting_project_id":null}"#))
            case ("PATCH", _): return (409, self.json(#"{"error":"frozen","by":"Dalton"}"#))
            case ("DELETE", _): return (204, Data())
            case ("POST", "/api/app/spaces/s/read"): return (422, self.json(#"{"error":"not_supported"}"#))
            case ("POST", "/api/app/tasks"): return (201, self.json(#"{"id":"t","title":"Ship","path":"/tasks/t"}"#))
            default: return (500, Data())
            }
        }
        let people = try await client.people(host: a, query: "Pri ya")
        XCTAssertEqual(people, [SuitePerson(id: "p", kind: "user", name: "Priya", orgNames: ["Fabrikam"])])
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.query, "q=Pri%20ya")
        let dm = try await client.personDM(host: a, userID: "p")
        XCTAssertEqual(dm.spaceID, "d")
        let projects = try await client.projects(host: a)
        XCTAssertNil(projects.lastMeetingProjectID)
        XCTAssertEqual(projects.projects.first?.org?.name, "Fabrikam")
        let edit = try await client.editMessage(host: a, messageID: "m", text: "x")
        XCTAssertEqual(edit, .frozen(by: "Dalton"))
        try await client.unsendMessage(host: a, messageID: "m")
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.path, "/api/app/messages/m")
        let unread = try await client.markRead(host: a, spaceID: "s", messageID: "m", read: false)
        XCTAssertEqual(unread, .notSupported)
        let task = try await client.createTask(host: a, projectID: "pr", title: "Ship", description: nil)
        XCTAssertEqual(task.id, "t")
    }

    // MARK: Send: nothing before the confirm

    func testNothingIsPostedBeforeTheConfirmForAPersonOrAConversation() async throws {
        let actions = MessagingActions(env: env(tokens: [a: "token-for-a"], hosts: [a]))
        let decline: IntentActions.Confirm = { _ in throw Declined() }

        await assertThrowsAsync(
            try await actions.send(to: .person(id: "\(self.a)|\(self.personID)", name: "Priya", isAgent: false), text: "Welcome", confirm: decline))
        await assertThrowsAsync(
            try await actions.send(to: .person(id: "\(self.a)|\(self.agentID)", name: "Helper", isAgent: true), text: "Hi", confirm: decline))
        await assertThrowsAsync(
            try await actions.send(to: .conversation(id: "\(self.a)|\(self.spaceID)", name: "general · Fabrikam"), text: "Lunch", confirm: decline))

        XCTAssertEqual(StubURLProtocol.requests.count, 0, "a declined send makes no request, not even the DM lookup")
    }

    func testSendToAPersonOpensTheirDMThenPostsAndReturnsTheMessageOnThatHost() async throws {
        let actions = MessagingActions(env: env(tokens: [a: "token-for-a"], hosts: [a]))
        StubURLProtocol.respond = { request in
            if request.url?.path.hasSuffix("/dm") == true { return (200, self.json(#"{"space_id":"\#(self.dmID)","path_segment":"\#(self.dmID)"}"#)) }
            return (201, self.json(#"{"message":{"id":"\#(self.messageID)"}}"#))
        }
        var confirmed = ""
        let sent = try await actions.send(to: .person(id: "\(a)|\(personID)", name: "Priya", isAgent: false), text: " Welcome aboard ") {
            confirmed = $0
        }
        XCTAssertEqual(confirmed, "Send \"Welcome aboard\" to Priya?")
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path ?? "" }, ["/api/app/people/\(personID)/dm", "/api/app/spaces/\(dmID)/messages"])
        XCTAssertEqual(sent, SentMessageRef(id: "\(a)|\(messageID)", conversationID: "\(a)|\(dmID)"))

        StubURLProtocol.reset()
        StubURLProtocol.respond = { request in
            if request.url?.path.hasSuffix("/dm") == true { return (200, self.json(#"{"space_id":"\#(self.dmID)","path_segment":null}"#)) }
            return (201, self.json(#"{"message":{"id":"m2"}}"#))
        }
        _ = try await actions.send(to: .person(id: "\(a)|\(agentID)", name: "Helper", isAgent: true), text: "Status?") { _ in }
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.path, "/api/app/agents/\(agentID)/dm", "an agent's DM opens through /agents")
    }

    func testEditFrozenSpeaksWhoBeganWorkAndUnreadIsRefused() async throws {
        let actions = MessagingActions(env: env(tokens: [a: "token-for-a"], hosts: [a]))
        StubURLProtocol.respond = { _ in (409, self.json(#"{"error":"frozen","by":"Dalton"}"#)) }
        do {
            _ = try await actions.edit(messageID: "\(a)|\(messageID)", text: "fixed")
            XCTFail("a frozen edit must fail")
        } catch let failure as IntentFailure {
            XCTAssertEqual(failure.message, "Dalton began work on that message, so it can't be edited. Send a follow-up instead.")
        }

        StubURLProtocol.respond = { _ in (422, self.json(#"{"error":"not_supported"}"#)) }
        do {
            _ = try await actions.setRead(messageID: "\(a)|\(messageID)", conversationID: "\(a)|\(spaceID)", isRead: false)
            XCTFail("unread is not supported")
        } catch let failure as IntentFailure {
            XCTAssertEqual(failure.message, "Burrow can't mark messages unread.")
        }

        StubURLProtocol.respond = { _ in (200, self.json(#"{"read":true}"#)) }
        let read = try await actions.setRead(messageID: "\(a)|\(messageID)", conversationID: "\(a)|\(spaceID)", isRead: true)
        XCTAssertEqual(read, "Marked as read.")
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.path, "/api/app/spaces/\(spaceID)/read")
    }

    /// Install isolation: host A is exercised FIRST, then an id on host B is
    /// acted on. Every request after A's must go to B with B's bearer.
    func testAHostBIdNeverReachesHostAAfterAIsUsed() async throws {
        let environment = env(tokens: [a: "token-for-a", b: "token-for-b"], hosts: [a, b])
        let actions = MessagingActions(env: environment)
        StubURLProtocol.respond = { request in
            if request.url?.path.hasSuffix("/dm") == true { return (200, self.json(#"{"space_id":"\#(self.dmID)","path_segment":null}"#)) }
            return (201, self.json(#"{"message":{"id":"\#(self.messageID)"}}"#))
        }
        _ = try await actions.send(to: .person(id: "\(a)|\(personID)", name: "Priya", isAgent: false), text: "on A") { _ in }
        let usedA = StubURLProtocol.requests.count
        XCTAssertEqual(usedA, 2)

        _ = try await actions.send(to: .person(id: "\(b)|\(personID)", name: "Priya", isAgent: false), text: "on B") { _ in }
        _ = try await actions.unsend(messageID: "\(b)|\(messageID)")

        let afterA = Array(StubURLProtocol.requests.dropFirst(usedA))
        XCTAssertEqual(afterA.count, 3)
        for request in afterA {
            XCTAssertEqual(request.url?.host, b)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-for-b")
        }

        // An id on a host that is not a saved install makes no request.
        let before = StubURLProtocol.requests.count
        await assertThrowsAsync(try await actions.unsend(messageID: "evil.example.com|\(self.messageID)"))
        XCTAssertEqual(StubURLProtocol.requests.count, before)
    }

    // MARK: Old Shortcuts

    func testTheOldSendMessageIntentPathStillResolvesASpaceAndSends() async throws {
        IntentEnvironment.current = env(tokens: [a: "token-for-a"], hosts: [a])
        StubURLProtocol.respond = { request in
            if request.url?.path == "/api/app/spaces" { return (200, self.generalInTwoOrgs(host: self.a)) }
            return (201, self.json(#"{"message":{"id":"m1"}}"#))
        }
        let spaces = try await SpaceQuery().entities(for: ["\(a)|g2"])
        let space = try XCTUnwrap(spaces.first)
        XCTAssertEqual(space.subtitle, "Space, Red Star", "the org rides the existing entity's subtitle")
        let text = try await IntentActions().send(space, message: "Lunch at noon") { _ in }
        XCTAssertEqual(text, "Sent to general.")
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.path, "/api/app/spaces/g2/messages")
    }

    // MARK: iOS 27 entity queries

    func testGeneralInTwoOrgsGivesTwoConversationsThatReadApart() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27 entities") }
        IntentEnvironment.current = env(tokens: [a: "token-for-a"], hosts: [a])
        StubURLProtocol.respond = { _ in (200, self.generalInTwoOrgs(host: self.a)) }

        let conversations = try await ConversationQuery().entities(matching: "general")
        XCTAssertEqual(conversations.map(\.displayName), ["general · Fabrikam", "general · Red Star"])
        XCTAssertNotEqual(conversations[0].displayRepresentation.title, conversations[1].displayRepresentation.title)
        XCTAssertEqual(conversations.map(\.subtitle), ["Space, Fabrikam", "Space, Red Star"])
    }

    func testAPersonOutsideTheSuggestionsIsFoundByTheServerSearch() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27 entities") }
        IntentEnvironment.current = env(tokens: [a: "token-for-a"], hosts: [a])
        StubURLProtocol.respond = { request in
            if request.url?.query?.contains("q=") == true {
                return (200, self.json(#"{"people":[{"id":"\#(self.personID)","kind":"user","name":"Priya","org_names":[]}]}"#))
            }
            return (200, self.json(#"{"people":[{"id":"\#(self.agentID)","kind":"agent","name":"Burrow Helper","org_names":[]}]}"#))
        }
        let suggested = try await MessagePersonEntityQuery().suggestedEntities()
        XCTAssertEqual(suggested.map(\.name), ["Burrow Helper"])

        let found = try await MessagePersonEntityQuery().entities(matching: "Priya")
        XCTAssertEqual(found.map(\.id), ["\(a)|\(personID)"])
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.query, "q=Priya", "matching asks the server, not the suggestion list")

        // The id Siri hands back resolves again, on its own host.
        let again = try await MessagePersonEntityQuery().entities(for: ["\(a)|\(personID)"])
        XCTAssertEqual(again.map(\.name), ["Priya"])
    }

    func testPersonQueryScopedToAnInstallNeverAsksTheOtherHost() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("iOS 27 entities") }
        IntentEnvironment.current = env(tokens: [a: "token-for-a", b: "token-for-b"], hosts: [a, b])
        StubURLProtocol.respond = { _ in (200, self.json(#"{"people":[]}"#)) }

        _ = try await MessagePersonEntityQuery(installScope: a).suggestedEntities()
        let usedA = StubURLProtocol.requests.count
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.host }, [a])

        _ = try await MessagePersonEntityQuery(installScope: b).entities(matching: "Dalton")
        let afterA = StubURLProtocol.requests.dropFirst(usedA)
        XCTAssertEqual(afterA.map { $0.url?.host }, [b])
        XCTAssertEqual(afterA.first?.value(forHTTPHeaderField: "Authorization"), "Bearer token-for-b")

        // A person id on host B resolves only against host B.
        StubURLProtocol.reset()
        StubURLProtocol.respond = { _ in (200, self.json(#"{"people":[]}"#)) }
        _ = try await MessagePersonEntityQuery().entities(for: ["\(b)|unknown-person"])
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.host }, [b])
    }
}
