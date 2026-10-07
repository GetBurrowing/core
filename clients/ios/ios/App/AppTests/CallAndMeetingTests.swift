import XCTest

@testable import App

private struct Declined: Error {}

/// Task 01a111bb stage 6: calls to a person or a group, Start Meeting's
/// project choice, Create Task, and the Debug-only reminders trial.
final class CallAndMeetingTests: XCTestCase {
    private let a = "a.example.com"
    private let b = "b.example.com"
    private let person = "9e000000-0000-4000-8000-000000000001"
    private let agent = "0a0a0a0a-0000-4000-8000-000000000001"
    private let group = "5a000000-0000-4000-8000-000000000001"
    private let project = "7b000000-0000-4000-8000-000000000001"
    private let meeting = #"{"id":"m0000000-0000-4000-8000-000000000001","slug":"call-1"}"#
    private var defaultsName = ""
    private var savedLauncher: ((String, String) -> Void)?
    private var launched: [(host: String, meetingID: String)] = []

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        defaultsName = "CallAndMeetingTests.\(UUID().uuidString)"
        savedLauncher = MeetingLauncher.start
        launched = []
        MeetingLauncher.start = { [weak self] host, id in self?.launched.append((host, id)) }
    }

    override func tearDown() {
        MeetingLauncher.start = savedLauncher
        UserDefaults().removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    private func env(hosts: [String]) -> IntentEnvironment {
        let defaults = UserDefaults(suiteName: defaultsName)!
        let store = InstallStore(defaults: defaults)
        let removeHook = InstallStore.didRemove
        InstallStore.didRemove = nil
        defer { InstallStore.didRemove = removeHook }
        for host in hosts { store.add(host: host) }
        for host in InstallStore.defaultHosts where !hosts.contains(host) { store.remove(host: host) }
        let clock = VirtualClock()
        var tokens: [String: String] = [:]
        for host in hosts { tokens[host] = "token-for-\(host)" }
        return IntentEnvironment(
            client: SuiteAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: tokens)),
            installs: store, sleeper: clock, now: { clock.now }, lastMeetingSpaces: LastMeetingSpaceStore(defaults: defaults))
    }

    private func respond(projects lastMeetingProjectID: String?) {
        let last = lastMeetingProjectID.map { "\"\($0)\"" } ?? "null"
        let projects =
            #"{"projects":[{"id":"\#(project)","name":"Burrow iOS","org":{"id":"o1","name":"Fabrikam"}}],"last_meeting_project_id":\#(last)}"#
        let meeting = self.meeting
        StubURLProtocol.respond = { request in
            if request.url?.path == "/api/app/projects" { return (200, Data(projects.utf8)) }
            return (201, Data(meeting.utf8))
        }
    }

    // MARK: Calls

    func testACallToAPersonPostsExactlyThatInviteeThenJoins() async throws {
        respond(projects: nil)
        let actions = CallActions(env: env(hosts: [a]))
        var confirmed = 0
        let text = try await actions.start(.person(id: "\(a)|\(person)", name: "Priya", isAgent: false), video: false) { _ in confirmed += 1 }

        XCTAssertEqual(confirmed, 0, "a one-to-one call needs no confirm")
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.path, "/api/app/meetings")
        XCTAssertEqual(StubURLProtocol.requests.first?.httpMethod, "POST")
        let body = try XCTUnwrap(StubURLProtocol.json(at: 0))
        XCTAssertEqual(body["invitee_user_ids"] as? [String], [person])
        XCTAssertNil(body["invite_space_id"])
        XCTAssertEqual(launched.map(\.host), [a])
        XCTAssertEqual(launched.map(\.meetingID), ["m0000000-0000-4000-8000-000000000001"])
        XCTAssertEqual(text, "Calling Priya.")
    }

    func testAGroupCallConfirmsNamingTheGroupThenPostsInviteSpace() async throws {
        respond(projects: nil)
        let actions = CallActions(env: env(hosts: [a]))
        var prompts: [String] = []
        var requestsAtConfirm = -1
        _ = try await actions.start(.conversation(id: "\(a)|\(group)", name: "design · Fabrikam"), video: false) { prompt in
            prompts.append(prompt)
            requestsAtConfirm = StubURLProtocol.requests.count
        }
        XCTAssertEqual(prompts, ["Call design · Fabrikam? This rings everyone in it, up to 25 people."])
        XCTAssertEqual(requestsAtConfirm, 0, "nothing is posted before the confirm")
        let body = try XCTUnwrap(StubURLProtocol.json(at: 0))
        XCTAssertEqual(body["invite_space_id"] as? String, group)
        XCTAssertNil(body["invitee_user_ids"])
        XCTAssertEqual(launched.count, 1)
    }

    func testADeclinedGroupCallPostsNothing() async {
        respond(projects: nil)
        do {
            _ = try await CallActions(env: env(hosts: [a])).start(.conversation(id: "\(a)|\(group)", name: "design"), video: false) { _ in
                throw Declined()
            }
            XCTFail("declined")
        } catch {}
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
        XCTAssertEqual(launched.count, 0)
    }

    func testAnAgentCannotBeCalledAndNothingIsPosted() async {
        respond(projects: nil)
        do {
            _ = try await CallActions(env: env(hosts: [a])).start(.person(id: "\(a)|\(agent)", name: "Saru", isAgent: true), video: false) { _ in }
            XCTFail("an agent call must be refused")
        } catch let failure as IntentFailure {
            XCTAssertEqual(failure, .cannotCallAgents)
            XCTAssertEqual(failure.message, "Burrow can't call agents yet.")
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
        XCTAssertEqual(launched.count, 0)
    }

    func testAVideoCallStartsAudioAndSaysSo() async throws {
        respond(projects: nil)
        let text = try await CallActions(env: env(hosts: [a])).start(.person(id: "\(a)|\(person)", name: "Priya", isAgent: false), video: true) { _ in }
        XCTAssertEqual(text, "Calling Priya. Burrow calls are audio only, so this is an audio call.")
    }

    // MARK: Start Meeting's project

    private func startMeeting(space: SpaceEntity? = nil, project: ProjectEntity? = nil, asked: inout Int) async throws {
        let actions = IntentActions(env: env(hosts: [a]))
        var count = 0
        let picked = ProjectEntity(id: "\(a)|\(self.project)", name: "Burrow iOS", subtitle: "")
        let request = try await actions.meetingRequest(host: a, space: space, project: project) {
            count += 1
            return picked
        }
        asked = count
        _ = try await actions.startMeetingDetails(
            host: request.host, spaceID: request.spaceID, spaceName: request.spaceName, projectID: request.projectID)
    }

    private func meetingPostBody() throws -> [String: Any] {
        let index = try XCTUnwrap(StubURLProtocol.requests.firstIndex { $0.url?.path == "/api/app/meetings" })
        return try XCTUnwrap(StubURLProtocol.json(at: index))
    }

    func testStartMeetingDoesNotAskWhenTheLastMeetingsProjectIsKnown() async throws {
        respond(projects: project)
        var asked = -1
        try await startMeeting(asked: &asked)
        XCTAssertEqual(asked, 0)
        let body = try meetingPostBody()
        XCTAssertNil(body["project_id"], "the server reuses the last meeting's project")
        XCTAssertNil(body["space_id"])
    }

    func testStartMeetingAsksWhenThereIsNoLastMeetingProject() async throws {
        respond(projects: nil)
        var asked = -1
        try await startMeeting(asked: &asked)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(try meetingPostBody()["project_id"] as? String, project)
    }

    func testAChosenProjectIsPostedWithoutAsking() async throws {
        respond(projects: nil)
        var asked = -1
        try await startMeeting(project: ProjectEntity(id: "\(a)|\(project)", name: "Burrow iOS", subtitle: ""), asked: &asked)
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(try meetingPostBody()["project_id"] as? String, project)
    }

    func testALegacySpaceShortcutStillPostsSpaceID() async throws {
        respond(projects: nil)
        var asked = -1
        let space = SpaceEntity(id: "\(a)|\(group)", name: "design", isDirectMessage: false, pathSegment: "design", subtitle: "")
        try await startMeeting(space: space, asked: &asked)
        XCTAssertEqual(asked, 0)
        let body = try meetingPostBody()
        XCTAssertEqual(body["space_id"] as? String, group)
        XCTAssertNil(body["project_id"])
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.path == "/api/app/projects" }, "no project lookup")
    }

    // MARK: Projects and tasks

    func testProjectSubtitlesCarryTheOrg() async {
        respond(projects: nil)
        let single = await EntityCatalog(env: env(hosts: [a])).projects(hosts: [a])
        XCTAssertEqual(single.map(\.subtitle), ["Project, Fabrikam"])
        XCTAssertEqual(single.map(\.id), ["\(a)|\(project)"])
        let both = await EntityCatalog(env: env(hosts: [a, b])).projects(hosts: [a])
        XCTAssertEqual(both.first?.subtitle.hasPrefix("Project, Fabrikam, "), true, "plus the install when there are several")
    }

    func testCreateTaskPostsTheTitleToTheProjectsHost() async throws {
        StubURLProtocol.respond = { _ in (201, Data(#"{"id":"t1","title":"Write the brief","path":"/tasks/t1"}"#.utf8)) }
        let created = try await IntentActions(env: env(hosts: [a])).createTask(
            in: ProjectEntity(id: "\(a)|\(project)", name: "Burrow iOS", subtitle: ""), title: "  Write the brief ")
        XCTAssertEqual(created.title, "Write the brief")
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.host, a)
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.path, "/api/app/tasks")
        let body = try XCTUnwrap(StubURLProtocol.json(at: 0))
        XCTAssertEqual(body["project_id"] as? String, project)
        XCTAssertEqual(body["title"] as? String, "Write the brief")
    }

    // MARK: The reminders trial is Debug only

    /// project.yml sets BURROW_TASKS_TRIAL for Debug only. Reads the
    /// generated project, so a flag added to Release in project.yml (and
    /// regenerated) fails here as well as in the nm check.
    func testTheTasksTrialFlagIsDebugOnly() throws {
        let pbxproj = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App.xcodeproj/project.pbxproj")
        let text = try String(contentsOf: pbxproj, encoding: .utf8)
        // Each XCBuildConfiguration block: `name = Debug;` or `name = Release;`.
        let blocks = text.components(separatedBy: "isa = XCBuildConfiguration;").dropFirst()
        var debugWithFlag = 0
        for block in blocks {
            let body = block.components(separatedBy: "};\n\t\t};").first ?? block
            let hasFlag = body.contains("BURROW_TASKS_TRIAL")
            if body.contains("name = Release;") { XCTAssertFalse(hasFlag, "a Release configuration sets BURROW_TASKS_TRIAL") }
            if body.contains("name = Debug;"), hasFlag { debugWithFlag += 1 }
        }
        XCTAssertGreaterThan(blocks.count, 2, "read the project's configurations")
        XCTAssertEqual(debugWithFlag, 1, "the project-level Debug configuration sets it")
    }
}
