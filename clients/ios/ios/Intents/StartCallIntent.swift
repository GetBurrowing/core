import AppIntents
import Foundation

// "Start a meeting with X" (task 01a111bb stage 6): the iOS 27 phone-domain
// call. A call is a new meeting that rings the people in it (the server's
// `:meeting_started` rule), joined natively here through MeetingLauncher.

/// Who a call goes to: one person, or everyone in a conversation.
enum CallTarget: Equatable {
    case person(id: String, name: String, isAgent: Bool)
    case conversation(id: String, name: String)

    var name: String {
        switch self {
        case .person(_, let name, _), .conversation(_, let name): return name
        }
    }
}

/// The work behind a call, with no App Intents types in the way.
struct CallActions {
    typealias Confirm = IntentActions.Confirm

    var env: IntentEnvironment = .current

    /// Starts a meeting that rings `target`, joins it, and returns what
    /// the person hears. A person: `invitee_user_ids: [uuid]`. A
    /// conversation: `confirm` first (it names the conversation and says it
    /// rings everyone in it), then `invite_space_id`. An agent: refused
    /// before any request. `video` still starts audio, and says so.
    func start(_ target: CallTarget, video: Bool, confirm: Confirm) async throws -> String {
        let actions = IntentActions(env: env)
        let meeting: CreatedMeeting
        let host: String
        switch target {
        case .person(let id, _, let isAgent):
            guard !isAgent else { throw IntentFailure.cannotCallAgents }
            let ref = try actions.ref(id)
            host = ref.host
            meeting = try await create(host) { try await env.client.createMeeting(host: ref.host, spaceID: nil, inviteeUserIDs: [ref.uuid]) }
        case .conversation(let id, let name):
            let ref = try actions.ref(id)
            host = ref.host
            try await confirm(IntentCopy.callConversationConfirm(name: name))
            meeting = try await create(host) { try await env.client.createMeeting(host: ref.host, spaceID: nil, inviteSpaceID: ref.uuid) }
        }
        guard let link = DeepLink.meeting(host: host, slug: meeting.slug) else { throw IntentFailure.notFound }
        MeetingLauncher.open(host: host, meetingID: meeting.id, fallback: link, installs: env.installs)
        return IntentCopy.callStarted(name: target.name, video: video)
    }

    private func create(_ host: String, _ body: () async throws -> CreatedMeeting) async throws -> CreatedMeeting {
        do {
            let meeting = try await body()
            IntentLog.route("create_call", host: host, status: 201)
            return meeting
        } catch {
            IntentLog.route("create_call", host: host, status: EntityCatalog.status(of: error))
            throw IntentFailure.from(error, host: host, env: env)
        }
    }
}

// MARK: - iOS 27 schema types

/// The phone schema's person: the same `<host>|<uuid>` people as the
/// messages domain (PersonQuery), as a separate type because an entity has
/// one schema.
@available(iOS 27, *)
@AppEntity(schema: .phone.phonePerson)
struct CallPersonEntity {
    static let defaultQuery = CallPersonQuery()

    let id: String
    var person: IntentPerson
    var kind: String
    var subtitle: String

    var isAgent: Bool { kind == "agent" }
    var name: String {
        if case .displayName(let name) = person.name { return name }
        return "Someone"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)", image: .init(systemName: isAgent ? "cpu" : "person.crop.circle"))
    }

    init(id: String, name: String, kind: String, subtitle: String) {
        self.id = id
        self.kind = kind
        self.subtitle = subtitle
        self.person = PersonEntity.intentPerson(id: id, name: name)
    }

    init(_ entity: PersonEntity) {
        self.init(id: entity.id, name: entity.name, kind: entity.kind, subtitle: entity.subtitle)
    }
}

@available(iOS 27, *)
struct CallPersonQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CallPersonEntity] {
        try await PersonQuery().entities(for: identifiers).map(CallPersonEntity.init)
    }

    func suggestedEntities() async throws -> [CallPersonEntity] {
        try await PersonQuery().suggestedEntities().map(CallPersonEntity.init)
    }

    func entities(matching string: String) async throws -> [CallPersonEntity] {
        try await PersonQuery().entities(matching: string).map(CallPersonEntity.init)
    }
}

@available(iOS 27, *)
@AppEnum(schema: .phone.audioVisualMode)
enum CallAudioVisualMode: String {
    case audio
    case video

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.audio: "Audio", .video: "Video"]
}

@available(iOS 27, *)
@UnionValue
enum CallDestination {
    case person(CallPersonEntity)
    case people([CallPersonEntity])
}

@available(iOS 27, *)
@AppIntent(schema: .phone.startCall)
struct StartCallIntent: AudioRecordingIntent, AudioStartingIntent {
    var destination: CallDestination
    var audioVisualMode: CallAudioVisualMode

    /// Burrow's own extra (Shortcuts only): a group call to everyone in a
    /// conversation, confirmed first. Overrides `destination` when set.
    @Parameter(title: "Conversation")
    var conversation: ConversationEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target: CallTarget
        if let conversation {
            target = .conversation(id: conversation.id, name: conversation.displayName)
        } else {
            switch destination {
            case .person(let person):
                target = .person(id: person.id, name: person.name, isAgent: person.isAgent)
            case .people(let people):
                guard people.count == 1, let person = people.first else { throw IntentFailure.notFound }
                target = .person(id: person.id, name: person.name, isAgent: person.isAgent)
            }
        }
        let text = try await CallActions().start(target, video: audioVisualMode == .video) { prompt in
            try await requestConfirmation(
                result: .result(dialog: IntentDialog("\(prompt)")),
                confirmationActionName: .custom(
                    acceptLabel: "Call", acceptAlternatives: ["Yes"], denyLabel: "Cancel", denyAlternatives: ["No"], destructive: false))
        }
        return .result(dialog: IntentDialog("\(text)"))
    }
}
