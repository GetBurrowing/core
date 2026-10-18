import AppIntents
import SwiftUI

// App Intents (task 01a10db6 stage 3). Compiled into the app AND the
// widget extension, so a widget button (stage 4) runs the same type.
//
// Rules every intent here keeps:
// - an approving, rejecting or sending intent asks `requestConfirmation`
//   before any request (IntentActions takes it as `confirm`);
// - approve and reject need an unlocked device (`authenticationPolicy`);
// - a request goes to the entity's own host with that host's bearer.

/// A dialog from runtime text. Interpolated, so the text is a value, never
/// a localisation key or a format string.
private func dialog(_ text: String) -> IntentDialog {
    IntentDialog("\(text)")
}

private func selectedHost(_ install: InstallEntity?) throws -> String {
    let env = IntentEnvironment.current
    guard let host = install?.id ?? env.installs.selectedHost, env.install(host) != nil else { throw IntentFailure.notFound }
    return host
}

// MARK: - Open

struct OpenSpaceIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Space"
    static var description = IntentDescription("Opens a space or direct message in Burrow.")
    static var openAppWhenRun = true

    @Parameter(title: "Space")
    var target: SpaceEntity

    init() {}

    init(target: SpaceEntity) { self.target = target }

    @MainActor
    func perform() async throws -> some IntentResult {
        let ref = try IntentActions().ref(target.id)
        guard let link = DeepLink.space(host: ref.host, pathSegment: target.pathSegment) else { throw IntentFailure.notFound }
        IntentNavigator.open(link)
        IntentHooks.didSucceed?(self)
        return .result()
    }
}

struct OpenTaskIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Task"
    static var description = IntentDescription("Opens a task in Burrow.")
    static var openAppWhenRun = true

    @Parameter(title: "Task")
    var target: TaskEntity

    init() {}

    init(target: TaskEntity) { self.target = target }

    @MainActor
    func perform() async throws -> some IntentResult {
        let ref = try IntentActions().ref(target.id)
        guard let link = DeepLink.task(host: ref.host, id: ref.uuid) else { throw IntentFailure.notFound }
        IntentNavigator.open(link)
        IntentHooks.didSucceed?(self)
        return .result()
    }
}

/// Opening a meeting is joining it: a native call in the app
/// (MeetingLauncher), or the meeting's web page where no launcher exists.
struct OpenMeetingIntent: OpenIntent {
    static var title: LocalizedStringResource = "Join Meeting"
    static var description = IntentDescription("Opens a meeting in Burrow to join it.")
    static var openAppWhenRun = true

    @Parameter(title: "Meeting")
    var target: MeetingEntity

    init() {}

    init(target: MeetingEntity) { self.target = target }

    @MainActor
    func perform() async throws -> some IntentResult {
        let ref = try IntentActions().ref(target.id)
        guard let link = DeepLink.meeting(host: ref.host, slug: target.slug) else { throw IntentFailure.notFound }
        MeetingLauncher.open(host: ref.host, meetingID: ref.uuid, fallback: link)
        IntentHooks.didSucceed?(self)
        return .result()
    }
}

/// "Show my approvals": the approvals list in the app.
struct ShowApprovalsIntent: AppIntent {
    static var title: LocalizedStringResource = "Show My Approvals"
    static var description = IntentDescription("Opens what is waiting for your approval.")
    static var openAppWhenRun = true

    @Parameter(title: "Install")
    var install: InstallEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentNavigator.open(DeepLink(host: try selectedHost(install), path: SlabKind.approvals.path))
        IntentHooks.didSucceed?(self)
        return .result()
    }
}

/// "Show my tasks": the task list in the app.
struct ShowTasksIntent: AppIntent {
    static var title: LocalizedStringResource = "Show My Tasks"
    static var description = IntentDescription("Opens your tasks.")
    static var openAppWhenRun = true

    @Parameter(title: "Install")
    var install: InstallEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentNavigator.open(DeepLink(host: try selectedHost(install), path: SlabKind.tasks.path))
        IntentHooks.didSucceed?(self)
        return .result()
    }
}

// MARK: - Send

struct SendMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Message"
    static var description = IntentDescription("Sends a message to a space or direct message.")

    @Parameter(title: "Space")
    var space: SpaceEntity

    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true))
    var message: String

    /// Only disambiguates: a space names its own install.
    @Parameter(title: "Install")
    var install: InstallEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$message) to \(\.$space)")
    }

    init() {}

    init(space: SpaceEntity, message: String) {
        self.space = space
        self.message = message
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let env = IntentEnvironment.current
        let install = EntityRef(space.id).flatMap { env.disambiguator($0.host) }
        let text = try await IntentActions().send(space, message: message) { prompt in
            try await requestConfirmation(
                result: .result(
                    dialog: dialog(prompt),
                    view: ConfirmSnippetView.send(message: message, space: space.name, install: install)),
                confirmationActionName: .send)
        }
        IntentHooks.didSucceed?(self)
        return .result(dialog: dialog(text), view: DoneSnippetView(text: text))
    }
}

// MARK: - Approve and reject

struct ApproveIntent: AppIntent {
    static var title: LocalizedStringResource = "Approve Plan"
    static var description = IntentDescription("Approves a plan or review that is waiting on you.")
    /// Approving needs an unlocked device (canvas open question 4).
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Approval")
    var approval: ApprovalEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Approve \(\.$approval)")
    }

    init() {}

    init(approval: ApprovalEntity) { self.approval = approval }

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let env = IntentEnvironment.current
        let install = EntityRef(approval.id).flatMap { env.disambiguator($0.host) }
        let text = try await IntentActions().approve(approval) { prompt in
            try await requestConfirmation(
                result: .result(
                    dialog: dialog(prompt),
                    view: ConfirmSnippetView.approve(isPlan: approval.isPlan, title: approval.title, space: approval.spaceName, install: install)),
                confirmationActionName: .custom(
                    acceptLabel: "Approve", acceptAlternatives: ["Yes"], denyLabel: "Cancel", denyAlternatives: ["No"], destructive: false))
        }
        return .result(dialog: dialog(text), view: DoneSnippetView(text: text))
    }
}

struct RejectIntent: AppIntent {
    static var title: LocalizedStringResource = "Reject"
    static var description = IntentDescription("Sends a plan or review back to the agent with a note.")
    /// Rejecting needs an unlocked device (canvas open question 4).
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Approval")
    var approval: ApprovalEntity

    @Parameter(title: "Note", inputOptions: String.IntentInputOptions(multiline: true))
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Reject \(\.$approval) with \(\.$note)")
    }

    init() {}

    init(approval: ApprovalEntity) { self.approval = approval }

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let env = IntentEnvironment.current
        let actions = IntentActions(env: env)
        let ref = try actions.ref(approval.id)
        let install = env.disambiguator(ref.host)
        var text = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            text = try await $note.requestValue(
                dialog(IntentCopy.rejectNotePrompt(isPlan: approval.isPlan, title: approval.title, space: approval.spaceName, install: install)))
        }
        let result = try await actions.reject(approval, note: text) { prompt in
            try await requestConfirmation(
                result: .result(
                    dialog: dialog(prompt),
                    view: ConfirmSnippetView.reject(isPlan: approval.isPlan, title: approval.title, space: approval.spaceName, install: install)),
                confirmationActionName: .custom(
                    acceptLabel: "Reject", acceptAlternatives: ["Yes"], denyLabel: "Cancel", denyAlternatives: ["No"], destructive: false))
        }
        return .result(dialog: dialog(result), view: DoneSnippetView(text: result))
    }
}

// MARK: - What's waiting

struct WhatsWaitingIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Waiting"
    static var description = IntentDescription("Tells you which approvals and tasks are waiting on you.")

    @Parameter(title: "Install")
    var install: InstallEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let host = try selectedHost(install)
        let summary = try await IntentActions().whatsWaiting(host: host)
        return .result(
            dialog: dialog(summary.dialog),
            view: WaitingSnippetView(summary: summary) { row in
                if let id = row.approvalID {
                    let entity = ApprovalEntity(id: id, title: row.title, isPlan: row.kind == .plan, spaceName: row.space, subtitle: "")
                    HStack(spacing: 8) {
                        Button("Approve", intent: ApproveIntent(approval: entity))
                            .buttonStyle(BurrowApproveButtonStyle())
                        Button("Reject", intent: RejectIntent(approval: entity))
                            .buttonStyle(BurrowRejectButtonStyle())
                    }
                }
            })
    }
}

// MARK: - Start a meeting

struct StartMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Meeting"
    static var description = IntentDescription("Starts a meeting now and opens it in Burrow.")
    static var openAppWhenRun = true

    /// The meeting's project (task 01a111bb stage 6). Left empty, the server
    /// reuses the project of the install's last meeting; only an install
    /// with no meeting yet asks for one.
    @Parameter(title: "Project")
    var project: ProjectEntity?

    /// Deprecated, kept only so existing Shortcuts that set it keep working:
    /// a space still POSTs `space_id`. Not in the summary.
    @Parameter(title: "Space (deprecated)")
    var space: SpaceEntity?

    @Parameter(title: "Install")
    var install: InstallEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Start a meeting in \(\.$project)") {
            \.$install
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let actions = IntentActions()
        let host = space == nil && project == nil ? try selectedHost(install) : ""
        let request = try await actions.meetingRequest(host: host, space: space, project: project) {
            try await $project.requestValue(dialog(IntentCopy.whichProjectForMeeting))
        }
        let started = try await actions.startMeetingDetails(
            host: request.host, spaceID: request.spaceID, spaceName: request.spaceName, projectID: request.projectID)
        MeetingLauncher.open(host: request.host, meetingID: started.meetingID, fallback: started.link)
        IntentHooks.didSucceed?(self)
        return .result(dialog: dialog(IntentCopy.meetingStarted(space: space?.name)))
    }
}

// MARK: - Create a task

/// "Create a task in Burrow" (task 01a111bb stage 6), iOS 17+: a project and
/// a title, asking for the title when it is missing. POSTs /api/app/tasks.
struct CreateTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Task"
    static var description = IntentDescription("Creates a task in a Burrow project.")

    @Parameter(title: "Project")
    var project: ProjectEntity

    @Parameter(title: "Title")
    var taskTitle: String?

    @Parameter(title: "Install")
    var install: InstallEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Create \(\.$taskTitle) in \(\.$project)") {
            \.$install
        }
    }

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        var text = taskTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { text = try await $taskTitle.requestValue(dialog(IntentCopy.whatIsTheTask)) }
        let created = try await IntentActions().createTask(in: project, title: text)
        return .result(dialog: dialog(IntentCopy.taskCreated(title: created.title, project: project.name)))
    }
}

// MARK: - Ask an agent

struct AskAgentIntent: AppIntent, ProgressReportingIntent {
    static var title: LocalizedStringResource = "Ask an Agent"
    static var description = IntentDescription("Asks an agent a question in your direct message and reads the reply.")

    @Parameter(title: "Agent")
    var agent: AgentEntity

    @Parameter(title: "Question", inputOptions: String.IntentInputOptions(multiline: true))
    var question: String

    /// Only disambiguates: an agent names its own install.
    @Parameter(title: "Install")
    var install: InstallEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$agent) \(\.$question)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        IntentLog.step("ask", "start")
        progress.totalUnitCount = 100
        let outcome: AskOutcome
        let timedOut: String
        if #available(iOS 27, *) {
            outcome = try await askInBackground()
            timedOut = IntentCopy.agentReplyWillNotify(agent: agent.name)
        } else {
            outcome = try await IntentActions().askAgent(agent, question: question) { fraction in
                progress.completedUnitCount = Int64(fraction * 100)
            }
            timedOut = IntentCopy.agentTimedOut(agent: agent.name)
        }
        IntentHooks.didSucceed?(self)
        switch outcome {
        case .reply(let reply):
            return .result(
                dialog: dialog(IntentCopy.agentSays(agent: agent.name, reply: reply)),
                view: AskAgentSnippetView(agent: agent.name, question: question, state: .reply(reply)))
        case .timedOut:
            return .result(
                dialog: dialog(timedOut),
                view: AskAgentSnippetView(agent: agent.name, question: question, state: .timedOut))
        }
    }
}

// iOS 27 (task 01a111bb stage 5): the SAME intent type becomes long-running
// and cancellable, so existing Shortcuts keep working. The poll runs as a
// background task for up to 90 s, reports progress on each poll, and a
// `.timeout` or `.userCancelled` cancel ends it before the next request.
@available(iOS 27, *)
extension AskAgentIntent: LongRunningIntent, CancellableIntent {
    func askInBackground() async throws -> AskOutcome {
        let cancelled = AskCancelFlag()
        let agent = agent
        let question = question
        let progress = progress
        return try await performBackgroundTask(
            operation: {
                try await IntentActions().askAgent(
                    agent, question: question, window: AskAgent.longReplyWindow, isCancelled: { cancelled.isSet }
                ) { fraction in
                    progress.completedUnitCount = Int64(fraction * 100)
                }
            },
            onCancel: { reason in
                cancelled.set()
                IntentLog.route(reason == .timeout ? "ask_cancel_timeout" : "ask_cancel_user", host: "-", status: 0)
            })
    }
}

/// Set once by an intent's cancel handler; read before each poll.
final class AskCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}
