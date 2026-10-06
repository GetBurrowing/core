import XCTest

@testable import App

/// Virtual time for ask-an-agent: `sleep` advances `now` and returns.
final class VirtualClock: IntentSleeper {
    var now = Date(timeIntervalSince1970: 1_000_000)
    private(set) var sleeps = 0

    func sleep(seconds: Double) async throws {
        sleeps += 1
        now = now.addingTimeInterval(seconds)
    }
}

private struct Declined: Error {}

final class IntentsTests: XCTestCase {
    private let a = "a.example.com"
    private let b = "b.example.com"
    private let agentID = "0a0a0a0a-0000-4000-8000-000000000001"
    private let dmID = "0d0d0d0d-0000-4000-8000-000000000001"
    private var defaultsName = ""
    private var saved: (IntentEnvironment, Bool, ((String, String, [String]) -> Void)?)!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        defaultsName = "IntentsTests.\(UUID().uuidString)"
        saved = (IntentEnvironment.current, IntentHooks.indexesSpotlight, IntentHooks.didFetchEntities)
        IntentHooks.indexesSpotlight = false
        IntentHooks.didFetchEntities = nil
    }

    override func tearDown() {
        IntentEnvironment.current = saved.0
        IntentHooks.indexesSpotlight = saved.1
        IntentHooks.didFetchEntities = saved.2
        UserDefaults().removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    /// An environment whose install list is exactly `hosts`, with the given
    /// bearers, a stubbed network and virtual time.
    private func env(tokens: [String: String], hosts: [String], clock: VirtualClock = VirtualClock()) -> IntentEnvironment {
        let defaults = UserDefaults(suiteName: defaultsName)!
        let store = InstallStore(defaults: defaults)
        let removeHook = InstallStore.didRemove
        InstallStore.didRemove = nil
        defer { InstallStore.didRemove = removeHook }
        for host in hosts { store.add(host: host) }
        for host in InstallStore.defaultHosts where !hosts.contains(host) { store.remove(host: host) }
        XCTAssertEqual(store.installs.map(\.host), hosts)
        return IntentEnvironment(
            client: SuiteAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: tokens)),
            installs: store, sleeper: clock, now: { clock.now }, lastMeetingSpaces: LastMeetingSpaceStore(defaults: defaults))
    }

    private func json(_ text: String) -> Data { Data(text.utf8) }

    private func spacesBody(_ id: String, _ name: String) -> Data {
        json(#"{"spaces":[{"id":"\#(id)","name":"\#(name)","slug":null,"kind":"channel","agents":[]}]}"#)
    }

    private func approval(_ host: String, plan: Bool = true) -> ApprovalEntity {
        ApprovalEntity(
            id: EntityRef(host: host, uuid: "ab000000-0000-4000-8000-000000000001").id, title: "Burrow iOS: App Intents", isPlan: plan,
            spaceName: "Burrow iOS", subtitle: "")
    }

    private func space(_ host: String) -> SpaceEntity {
        SpaceEntity(
            id: EntityRef(host: host, uuid: "5a000000-0000-4000-8000-000000000001").id, name: "Internal Fabrikam SXI", isDirectMessage: false,
            pathSegment: "sxi", subtitle: "Space")
    }

    private func agent(_ host: String) -> AgentEntity {
        AgentEntity(id: EntityRef(host: host, uuid: agentID).id, name: "Saru", subtitle: "Agent")
    }

    // MARK: Install isolation

    /// Install A is used FIRST, so anything that remembered "the" bearer or
    /// "the" host (the e03cc922 lesson) would have A's in hand when B's
    /// entity is resolved and acted on. B's requests must carry only B's.
    func testEntityResolutionUsesTheEntitysOwnHostBearerAfterAnotherInstall() async throws {
        IntentEnvironment.current = env(tokens: [a: "token-for-a", b: "token-for-b"], hosts: [a, b])
        StubURLProtocol.respond = { request in
            let host = request.url?.host ?? ""
            switch request.url?.path {
            case "/api/app/spaces": return (200, self.spacesBody(host == self.a ? "sa" : "sb", "Space on \(host)"))
            default: return (200, self.json(#"{"status":"approved"}"#))
            }
        }

        let fromA = try await SpaceQuery().entities(for: ["\(a)|sa"])
        XCTAssertEqual(fromA.map(\.id), ["\(a)|sa"])
        let usedA = StubURLProtocol.requests.count
        XCTAssertEqual(usedA, 1)

        let fromB = try await SpaceQuery().entities(for: ["\(b)|sb"])
        XCTAssertEqual(fromB.map(\.name), ["Space on \(b)"])
        let text = try await IntentActions().approve(approval(b)) { _ in }
        XCTAssertEqual(text, "Approved. Agents are starting.")

        let afterA = Array(StubURLProtocol.requests.dropFirst(usedA))
        XCTAssertEqual(afterA.count, 2)
        for request in afterA {
            XCTAssertEqual(request.url?.host, b)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-for-b")
        }
        XCTAssertEqual(afterA.last?.url?.path, "/api/app/approvals/ab000000-0000-4000-8000-000000000001/approve")
    }

    /// A mixed batch resolves each id on its own host, once per host.
    func testMixedBatchResolvesEachIdOnItsOwnHost() async throws {
        IntentEnvironment.current = env(tokens: [a: "token-for-a", b: "token-for-b"], hosts: [a, b])
        StubURLProtocol.respond = { request in
            let host = request.url?.host ?? ""
            return (200, self.spacesBody(host == self.a ? "sa" : "sb", host))
        }
        let found = try await SpaceQuery().entities(for: ["\(b)|sb", "\(a)|sa", "\(a)|missing"])
        XCTAssertEqual(found.map(\.id), ["\(b)|sb", "\(a)|sa"])
        let byHost = Dictionary(grouping: StubURLProtocol.requests, by: { $0.url?.host ?? "" })
        XCTAssertEqual(byHost[a]?.count, 1)
        XCTAssertEqual(byHost[b]?.count, 1)
        XCTAssertEqual(byHost[a]?.first?.value(forHTTPHeaderField: "Authorization"), "Bearer token-for-a")
        XCTAssertEqual(byHost[b]?.first?.value(forHTTPHeaderField: "Authorization"), "Bearer token-for-b")
    }

    func testUnknownHostIdIsNotFoundWithNoRequest() async throws {
        IntentEnvironment.current = env(tokens: [a: "token-for-a", "evil.example.com": "token-evil"], hosts: [a])

        let spaces = try await SpaceQuery().entities(for: ["evil.example.com|sa", "no-separator", "\(a)|", "|sa"])
        XCTAssertEqual(spaces.count, 0)
        let tasks = try await TaskQuery().entities(for: ["evil.example.com|t1"])
        XCTAssertEqual(tasks.count, 0)

        var asked = false
        do {
            _ = try await IntentActions().approve(approval("evil.example.com")) { _ in asked = true }
            XCTFail("an unknown host must not resolve")
        } catch let failure as IntentFailure {
            XCTAssertEqual(failure, .notFound)
        }
        XCTAssertFalse(asked, "nothing to confirm for an entity that does not resolve")
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    // MARK: Confirmation before any request

    func testDeclinedConfirmationMakesZeroRequests() async throws {
        let environment = env(tokens: [a: "token-for-a", b: "token-for-b"], hosts: [a, b])
        let actions = IntentActions(env: environment)
        var prompts: [String] = []
        let decline: IntentActions.Confirm = { prompt in
            prompts.append(prompt)
            throw Declined()
        }

        await assertThrowsAsync(try await actions.approve(self.approval(a), confirm: decline))
        await assertThrowsAsync(try await actions.reject(self.approval(a, plan: false), note: "Tighten the copy", confirm: decline))
        await assertThrowsAsync(try await actions.send(self.space(a), message: "On my way", confirm: decline))

        XCTAssertEqual(StubURLProtocol.requests.count, 0, "a declined confirmation sends nothing")
        // Two installs saved: the install is named in confirmations.
        XCTAssertEqual(
            prompts,
            [
                "Approve the plan Burrow iOS: App Intents in Burrow iOS on a.example.com? Agents start building as soon as you approve.",
                "Reject the review Burrow iOS: App Intents in Burrow iOS on a.example.com? It goes back to the agent with your note.",
                "Send \"On my way\" to Internal Fabrikam SXI on a.example.com?",
            ])
    }

    func testRejectWithABlankNoteIsRefusedBeforeConfirmationOrRequest() async throws {
        let actions = IntentActions(env: env(tokens: [a: "token-for-a"], hosts: [a]))
        var asked = false
        do {
            _ = try await actions.reject(approval(a, plan: false), note: "  \n ") { _ in asked = true }
            XCTFail("a blank note must be refused")
        } catch let failure as IntentFailure {
            XCTAssertEqual(failure, .emptyNote)
        }
        XCTAssertFalse(asked)
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    func testSingleInstallConfirmationOmitsTheInstall() async throws {
        let actions = IntentActions(env: env(tokens: [a: "token-for-a"], hosts: [a]))
        StubURLProtocol.respond = { _ in (201, self.json(#"{"message":{"id":"m1"}}"#)) }
        var prompt = ""
        let text = try await actions.send(space(a), message: "On my way") { prompt = $0 }
        XCTAssertEqual(prompt, "Send \"On my way\" to Internal Fabrikam SXI?")
        XCTAssertEqual(text, "Sent to Internal Fabrikam SXI.")
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.path, "/api/app/spaces/5a000000-0000-4000-8000-000000000001/messages")
        XCTAssertEqual(StubURLProtocol.requests.first?.httpMethod, "POST")
    }

    // MARK: Already handled

    func testConflictMapsToAlreadyHandled() async throws {
        let actions = IntentActions(env: env(tokens: [a: "token-for-a"], hosts: [a]))
        StubURLProtocol.respond = { _ in (409, self.json(#"{"error":"already_handled","by":"Rowan Ellis"}"#)) }
        let named = try await actions.approve(approval(a)) { _ in }
        XCTAssertEqual(named, "Already approved by Rowan Ellis.")

        StubURLProtocol.respond = { _ in (409, self.json(#"{"error":"already_handled","by":null}"#)) }
        let unnamed = try await actions.reject(approval(a), note: "No", confirm: { _ in })
        XCTAssertEqual(unnamed, "Already handled.")
    }

    func testFailuresMapToSpokenCopy() async throws {
        let actions = IntentActions(env: env(tokens: [a: "token-for-a"], hosts: [a]))
        StubURLProtocol.respond = { _ in (503, Data()) }
        do {
            _ = try await actions.approve(approval(a)) { _ in }
            XCTFail("expected a failure")
        } catch let failure as IntentFailure {
            XCTAssertEqual(failure.message, "Burrow couldn't reach a.example.com. Try again in a moment.")
        }
        StubURLProtocol.respond = { _ in (401, Data()) }
        do {
            _ = try await actions.approve(approval(a)) { _ in }
            XCTFail("expected a failure")
        } catch let failure as IntentFailure {
            XCTAssertEqual(failure.message, "You're signed out of Burrow. Open the app to sign in.")
        }
    }

    // MARK: Start a meeting

    func testStartMeetingNoProjectIsSpokenAndSuccessRemembersTheSpace() async throws {
        let environment = env(tokens: [a: "token-for-a"], hosts: [a])
        let actions = IntentActions(env: environment)
        StubURLProtocol.respond = { _ in (422, self.json(#"{"error":"no_project"}"#)) }
        do {
            _ = try await actions.startMeeting(host: a, spaceID: "s1")
            XCTFail("expected no_project")
        } catch let failure as IntentFailure {
            XCTAssertEqual(failure, .noProject(install: a))
        }
        XCTAssertNil(environment.lastMeetingSpaces.spaceID(for: a))

        StubURLProtocol.respond = { _ in (201, self.json(#"{"id":"m1","slug":"standup-1","path":"/meetings/standup-1"}"#)) }
        let link = try await actions.startMeeting(host: a, spaceID: "s1")
        XCTAssertEqual(link, DeepLink(host: a, path: "/meetings/standup-1"))
        XCTAssertEqual(environment.lastMeetingSpaces.spaceID(for: a), "s1")
        XCTAssertNil(environment.lastMeetingSpaces.spaceID(for: b), "remembered per host")
    }

    // MARK: Ask an agent

    private func askResponder(polls: [String]) -> (URLRequest) -> (Int, Data) {
        var pollIndex = 0
        let lock = NSLock()
        return { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/dm") {
                return (200, self.json(#"{"space_id":"\#(self.dmID)","path_segment":"\#(self.dmID)"}"#))
            }
            if request.httpMethod == "POST" {
                return (201, self.json(#"{"message":{"id":"q0"}}"#))
            }
            lock.lock()
            defer { lock.unlock() }
            let body = pollIndex < polls.count ? polls[pollIndex] : "[]"
            pollIndex += 1
            return (200, self.json(#"{"messages":\#(body)}"#))
        }
    }

    func testAskAgentReturnsThatAgentsReplyAtPollThreeIgnoringOthers() async throws {
        let clock = VirtualClock()
        let actions = IntentActions(env: env(tokens: [a: "token-for-a"], hosts: [a], clock: clock))
        StubURLProtocol.respond = askResponder(polls: [
            "[]",
            #"[{"id":"m1","author_type":"user","author_id":"u1","content":"Following."},"#
                + #"{"id":"m2","author_type":"agent","author_id":"0a0a0a0a-0000-4000-8000-000000000999","content":"Not me."}]"#,
            #"[{"id":"m3","author_type":"agent","author_id":"\#(agentID)","content":"Yes. The copy is final. Ship it today."}]"#,
        ])

        let outcome = try await actions.askAgent(agent(a), question: "Is the banner copy final?")

        XCTAssertEqual(outcome, .reply("Yes. The copy is final. Ship it today."))
        XCTAssertEqual(IntentCopy.agentSays(agent: "Saru", reply: "Yes. The copy is final. Ship it today."), "Saru says: Yes. The copy is final.")
        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.count, 5, "dm, post, three polls")
        guard requests.count == 5 else { return }
        XCTAssertEqual(requests[0].url?.path, "/api/app/agents/\(agentID)/dm")
        XCTAssertEqual(requests[1].url?.path, "/api/app/spaces/\(dmID)/messages")
        XCTAssertEqual(requests[2].url?.query, "after=q0")
        XCTAssertEqual(requests[4].url?.query, "after=m2", "the cursor moves past messages already seen")
        XCTAssertEqual(clock.sleeps, 3)
    }

    func testAskAgentTimesOutAfterTheWindowWithNoExtraRequest() async throws {
        let clock = VirtualClock()
        let start = clock.now
        let actions = IntentActions(env: env(tokens: [a: "token-for-a"], hosts: [a], clock: clock))
        StubURLProtocol.respond = askResponder(polls: [])

        let outcome = try await actions.askAgent(agent(a), question: "Is the banner copy final?")

        XCTAssertEqual(outcome, .timedOut)
        let polls = Int(AskAgent.replyWindow / AskAgent.pollInterval)
        XCTAssertEqual(polls, 10)
        XCTAssertEqual(StubURLProtocol.requests.count, 2 + polls, "no request once the window has passed")
        XCTAssertEqual(clock.now.timeIntervalSince(start), AskAgent.replyWindow + AskAgent.pollInterval)
        XCTAssertEqual(IntentCopy.agentTimedOut(agent: "Saru"), "Saru is still working on it. Burrow will notify you.")
    }

    // MARK: Copy and entities

    func testWaitingSummaryRowsAndDialog() {
        func approvalRow(_ n: Int) -> (id: String, approval: SuiteApproval) {
            (
                "\(a)|ap\(n)",
                SuiteApproval(
                    id: "ap\(n)", kind: "plan", title: "Plan \(n)", spaceName: "Burrow iOS", spacePathSegment: nil, taskID: nil, insertedAt: nil,
                    summary: nil)
            )
        }
        let tasks = (1...3).map { SuiteTask(id: "t\($0)", title: "Task \($0)", status: "in_progress", projectName: "Core") }
        let summary = WaitingSummary(approvals: [approvalRow(1), approvalRow(2)], tasks: tasks)
        XCTAssertEqual(summary.rows.map(\.title), ["Plan 1", "Plan 2", "Task 1"])
        XCTAssertEqual(summary.rows.map(\.symbol), ["checkmark.seal", "checkmark.seal", "checklist"])
        XCTAssertEqual(summary.more, 2)
        XCTAssertEqual(IntentCopy.andMore(summary.more), "And 2 more")
        XCTAssertEqual(summary.dialog, "You have 2 approvals and 3 tasks. The first is Plan 1.")
        XCTAssertEqual(WaitingSummary(approvals: [], tasks: []).dialog, "Nothing is waiting for you.")
        XCTAssertEqual(WaitingSummary(approvals: [approvalRow(1)], tasks: []).dialog, "You have 1 approval. The first is Plan 1.")
    }

    func testSubtitlesLeadWithTheTypeAndNameTheInstallOnlyWhenSeveral() {
        let single = env(tokens: [:], hosts: [a])
        let space = SuiteSpace(id: "s1", name: "Saru", kind: "dm")
        XCTAssertEqual(SpaceEntity(space, host: a, env: single).subtitle, "Direct message")
        XCTAssertEqual(SpaceEntity(space, host: a, env: single).pathSegment, "s1", "no path_segment: the id, never a slug")
        let task = SuiteTask(id: "t1", title: "Ship", status: "in_progress", projectName: "Core")
        XCTAssertEqual(TaskEntity(task, host: a, env: single).subtitle, "Task in Core, in_progress")

        UserDefaults().removePersistentDomain(forName: defaultsName)
        let multi = env(tokens: [:], hosts: [a, b])
        multi.installs.updateName("Fabrikam Suite", for: b)
        XCTAssertEqual(
            AgentEntity(SuiteAgent(id: "g1", name: "Saru", slug: nil, role: "historian"), host: b, env: multi).subtitle, "Agent, historian, Fabrikam Suite")
        XCTAssertEqual(SpaceEntity(SuiteSpace(id: "s2", name: "SXI", kind: "channel"), host: b, env: multi).id, "\(b)|s2")
    }

    func testEntityRefParsesOnlyHostPipeUUID() {
        XCTAssertEqual(EntityRef("a.example.com|abc"), EntityRef(host: "a.example.com", uuid: "abc"))
        XCTAssertNil(EntityRef("abc"))
        XCTAssertNil(EntityRef("a.example.com|"))
        XCTAssertNil(EntityRef("|abc"))
        XCTAssertNil(EntityRef("A.Example.com|abc"), "hosts are stored normalised")
        XCTAssertNil(EntityRef("a.example.com/x|abc"))
        XCTAssertNil(EntityRef("a.example.com|abc|def"))
    }

    func testWebViewPagesNameTheirEntity() {
        let id = "5a000000-0000-4000-8000-000000000001"
        let page = { (path: String) in URL(string: "https://\(self.a)\(path)") }
        XCTAssertEqual(EntityActivity.target(for: page("/chat/\(id)"), host: a, spaceIDsBySegment: [:]), .space(id: "\(a)|\(id)"))
        XCTAssertEqual(EntityActivity.target(for: page("/chat/sxi"), host: a, spaceIDsBySegment: ["sxi": id]), .space(id: "\(a)|\(id)"))
        XCTAssertNil(EntityActivity.target(for: page("/chat/unknown"), host: a, spaceIDsBySegment: [:]))
        XCTAssertEqual(EntityActivity.target(for: page("/tasks/\(id)"), host: a, spaceIDsBySegment: [:]), .task(id: "\(a)|\(id)"))
        XCTAssertNil(EntityActivity.target(for: page("/tasks"), host: a, spaceIDsBySegment: [:]))
        XCTAssertNil(EntityActivity.target(for: URL(string: "https://\(b)/tasks/\(id)"), host: a, spaceIDsBySegment: [:]))
    }

    func testDeepLinksForEntitiesUseThePathSegment() {
        XCTAssertEqual(DeepLink.space(host: a, pathSegment: "0d0d0d0d-0000-4000-8000-000000000001")?.path, "/chat/0d0d0d0d-0000-4000-8000-000000000001")
        XCTAssertNil(DeepLink.space(host: a, pathSegment: "../admin"))
    }
}

/// `XCTAssertThrowsError` for async expressions.
func assertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
