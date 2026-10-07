import Foundation

/// Ask-an-agent timing (canvas open question 3: designed for about 20 s,
/// set by engineering against Siri's own timeout). On iOS 27 the ask runs
/// as a long-running intent (task 01a111bb stage 5) and waits 90 s.
enum AskAgent {
    static let replyWindow: TimeInterval = 20
    static let longReplyWindow: TimeInterval = 90
    static let pollInterval: TimeInterval = 2

    /// The window for an OS: 90 s where the intent is long-running (iOS 27),
    /// otherwise exactly the old 20 s.
    static func window(longRunning: Bool) -> TimeInterval {
        longRunning ? longReplyWindow : replyWindow
    }

    /// This runtime's window.
    static var currentWindow: TimeInterval {
        if #available(iOS 27, *) { return window(longRunning: true) }
        return window(longRunning: false)
    }
}

/// The body of a Start Meeting POST: at most one of space and project.
struct MeetingRequest: Equatable {
    let host: String
    let spaceID: String?
    let spaceName: String?
    let projectID: String?
}

/// What asking an agent came to.
enum AskOutcome: Equatable {
    case reply(String)
    case timedOut
}

/// The work behind each intent, with no App Intents types in the way so it
/// is testable. `confirm` is the intent's `requestConfirmation`: it throws
/// when the person declines, and nothing is sent before it returns.
struct IntentActions {
    typealias Confirm = (_ prompt: String) async throws -> Void

    var env: IntentEnvironment = .current

    /// The entity's host, if it is a saved install. Anything else is
    /// not-found, before any request.
    func ref(_ id: String) throws -> EntityRef {
        guard let ref = EntityRef(id), env.install(ref.host) != nil else { throw IntentFailure.notFound }
        return ref
    }

    func approve(_ approval: ApprovalEntity, confirm: Confirm) async throws -> String {
        let ref = try ref(approval.id)
        try await confirm(
            IntentCopy.approveConfirm(isPlan: approval.isPlan, title: approval.title, space: approval.spaceName, install: env.disambiguator(ref.host)))
        let outcome = try await call("approve", ref.host) { try await env.client.approve(host: ref.host, approvalID: ref.uuid) }
        switch outcome {
        case .done: return IntentCopy.approved(isPlan: approval.isPlan)
        case .alreadyHandled(let by): return IntentCopy.alreadyHandled(by: by)
        }
    }

    func reject(_ approval: ApprovalEntity, note: String, confirm: Confirm) async throws -> String {
        let ref = try ref(approval.id)
        // The agent needs the note to act on; refused before any request.
        let feedback = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feedback.isEmpty else { throw IntentFailure.emptyNote }
        try await confirm(
            IntentCopy.rejectConfirm(isPlan: approval.isPlan, title: approval.title, space: approval.spaceName, install: env.disambiguator(ref.host)))
        let outcome = try await call("reject", ref.host) {
            try await env.client.reject(host: ref.host, approvalID: ref.uuid, feedback: feedback)
        }
        switch outcome {
        case .done: return IntentCopy.rejected
        case .alreadyHandled(let by): return IntentCopy.alreadyHandled(by: by)
        }
    }

    func send(_ space: SpaceEntity, message: String, confirm: Confirm) async throws -> String {
        let ref = try ref(space.id)
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IntentFailure.emptyMessage }
        try await confirm(IntentCopy.sendConfirm(message: text, space: space.name, install: env.disambiguator(ref.host)))
        _ = try await call("send_message", ref.host) { try await env.client.sendText(host: ref.host, spaceID: ref.uuid, text: text) }
        return IntentCopy.sent(space: space.name)
    }

    func whatsWaiting(host: String) async throws -> WaitingSummary {
        guard env.install(host) != nil else { throw IntentFailure.notFound }
        let approvals = try await call("approvals", host) { try await env.client.approvals(host: host) }
        let tasks = try await call("tasks", host) { try await env.client.tasks(host: host) }
        return WaitingSummary(approvals: approvals.map { (EntityRef(host: host, uuid: $0.id).id, $0) }, tasks: tasks)
    }

    /// Starts a meeting on `host`; remembers the space for next time.
    func startMeeting(host: String, spaceID: String?, spaceName: String? = nil) async throws -> DeepLink {
        try await startMeetingDetails(host: host, spaceID: spaceID, spaceName: spaceName).link
    }

    /// `startMeeting`, also returning the new meeting's id so the app can
    /// join it natively (MeetingLauncher).
    func startMeetingDetails(
        host: String, spaceID: String?, spaceName: String? = nil, projectID: String? = nil
    ) async throws -> (link: DeepLink, meetingID: String) {
        guard env.install(host) != nil else { throw IntentFailure.notFound }
        let meeting = try await call("create_meeting", host) {
            try await env.client.createMeeting(host: host, spaceID: spaceID, projectID: projectID)
        }
        if let spaceID { env.lastMeetingSpaces.set(spaceID, name: spaceName, for: host) }
        guard let link = DeepLink.meeting(host: host, slug: meeting.slug) else { throw IntentFailure.notFound }
        return (link, meeting.id)
    }

    /// Creates a task titled `title` in `project`, on the project's host.
    func createTask(in project: ProjectEntity, title: String) async throws -> CreatedTask {
        let ref = try ref(project.id)
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IntentFailure.emptyMessage }
        return try await call("create_task", ref.host) {
            try await env.client.createTask(host: ref.host, projectID: ref.uuid, title: text, description: nil)
        }
    }

    /// What Start Meeting posts (task 01a111bb stage 6). A legacy Shortcut's
    /// space wins (POST `space_id`, as before); then a chosen project; with
    /// neither, the install's projects decide: a non-null
    /// `last_meeting_project_id` lets the server reuse it with no question,
    /// and only a null one asks for a project (`askProject`). The remembered
    /// meeting space (LastMeetingSpaceStore) is not consulted.
    func meetingRequest(
        host: String, space: SpaceEntity?, project: ProjectEntity?, askProject: () async throws -> ProjectEntity
    ) async throws -> MeetingRequest {
        if let space {
            let ref = try ref(space.id)
            return MeetingRequest(host: ref.host, spaceID: ref.uuid, spaceName: space.name, projectID: nil)
        }
        if let project {
            let ref = try ref(project.id)
            return MeetingRequest(host: ref.host, spaceID: nil, spaceName: nil, projectID: ref.uuid)
        }
        guard env.install(host) != nil else { throw IntentFailure.notFound }
        let projects = try await call("projects", host) { try await env.client.projects(host: host) }
        if projects.lastMeetingProjectID != nil {
            return MeetingRequest(host: host, spaceID: nil, spaceName: nil, projectID: nil)
        }
        let picked = try ref(try await askProject().id)
        guard picked.host == host else { throw IntentFailure.notFound }
        return MeetingRequest(host: host, spaceID: nil, spaceName: nil, projectID: picked.uuid)
    }

    /// Opens the person's DM with the agent, posts the question, then polls
    /// every `AskAgent.pollInterval` for at most `window`, returning the
    /// first message THAT agent wrote after the question. Anyone else's
    /// message is skipped. After the window: `.timedOut`, and no further
    /// request (the reply arrives by push, as an ordinary chat notification).
    /// A cancelled task, or `isCancelled` turning true (the intent's cancel
    /// handler), throws CancellationError before the next poll is sent.
    /// Only the outcome and the elapsed seconds are logged.
    func askAgent(
        _ agent: AgentEntity, question: String, window: TimeInterval = AskAgent.currentWindow,
        isCancelled: @escaping () -> Bool = { false }, progress: ((Double) -> Void)? = nil
    ) async throws -> AskOutcome {
        let ref = try ref(agent.id)
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IntentFailure.emptyMessage }
        let dm = try await call("agent_dm", ref.host) { try await env.client.dmWithAgent(host: ref.host, agentID: ref.uuid) }
        let posted = try await call("send_message", ref.host) { try await env.client.sendText(host: ref.host, spaceID: dm.spaceID, text: text) }
        return try await awaitAgentReply(
            host: ref.host, agentUUID: ref.uuid, spaceID: dm.spaceID, after: posted, window: window, isCancelled: isCancelled,
            progress: progress)
    }

    /// Waits for `agentUUID`'s first message after `after` in `spaceID`,
    /// polling every `AskAgent.pollInterval` for up to `window`. Shared by
    /// Ask and by a schema send to an agent (task 01a111bb stage 7), so both
    /// log the same `ask_outcome` line: outcome and seconds, never text.
    func awaitAgentReply(
        host: String, agentUUID: String, spaceID: String, after: String, window: TimeInterval = AskAgent.currentWindow,
        isCancelled: @escaping () -> Bool = { false }, progress: ((Double) -> Void)? = nil
    ) async throws -> AskOutcome {
        let ref = EntityRef(host: host, uuid: agentUUID)
        var cursor = after
        let start = env.now()
        func finish(_ outcome: AskOutcome) -> AskOutcome {
            let seconds = Int(env.now().timeIntervalSince(start).rounded())
            switch outcome {
            case .reply: IntentLog.count("ask_outcome.answered", host: ref.host, count: seconds)
            case .timedOut: IntentLog.count("ask_outcome.timed_out", host: ref.host, count: seconds)
            }
            return outcome
        }
        while true {
            try await env.sleeper.sleep(seconds: AskAgent.pollInterval)
            if Task.isCancelled || isCancelled() { throw CancellationError() }
            let elapsed = env.now().timeIntervalSince(start)
            guard elapsed <= window else { return finish(.timedOut) }
            progress?(min(1, elapsed / window))
            let messages: [SuiteMessage]
            do {
                messages = try await env.client.messagesAfter(host: ref.host, spaceID: spaceID, after: cursor)
            } catch {
                // The question is posted; a failed poll is not a failed ask.
                IntentLog.route("poll_messages", host: ref.host, status: EntityCatalog.status(of: error))
                continue
            }
            if let last = messages.last { cursor = last.id }
            if let reply = messages.first(where: { $0.authorType == "agent" && $0.authorID == ref.uuid }) {
                return finish(.reply(reply.content ?? ""))
            }
        }
    }

    /// Runs one request, logging only the route, host and outcome, and
    /// turning a failure into what the person hears.
    private func call<T>(_ route: String, _ host: String, _ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            IntentLog.route(route, host: host, status: 200)
            return value
        } catch {
            IntentLog.route(route, host: host, status: EntityCatalog.status(of: error))
            throw IntentFailure.from(error, host: host, env: env)
        }
    }
}
