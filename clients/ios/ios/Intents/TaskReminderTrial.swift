// The reminders-schema trial for Burrow tasks (task 01a111bb stage 6).
// Compiled ONLY under BURROW_TASKS_TRIAL, which project.yml sets for Debug
// builds; a Release build contains none of it. Nothing else references
// these types: project -> list, request -> title, description -> note.
// App target only (BURROW_APP): see the note in MessagingIntents.swift.
#if BURROW_TASKS_TRIAL && BURROW_APP
    import AppIntents
    import Foundation
    import GeoToolbox

    @available(iOS 27, *)
    @AppEntity(schema: .reminders.list)
    struct TaskReminderTrialList {
        static let defaultQuery = TaskReminderTrialListQuery()

        /// `<host>|<project uuid>`.
        let id: String
        var name: String
        var type: TaskReminderTrialListType

        var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

        init(_ project: ProjectEntity) {
            id = project.id
            name = project.name
            type = .standard
        }
    }

    @available(iOS 27, *)
    struct TaskReminderTrialListQuery: EntityStringQuery {
        func entities(for identifiers: [String]) async throws -> [TaskReminderTrialList] {
            try await ProjectQuery().entities(for: identifiers).map(TaskReminderTrialList.init)
        }

        func suggestedEntities() async throws -> [TaskReminderTrialList] {
            try await ProjectQuery().suggestedEntities().map(TaskReminderTrialList.init)
        }

        func entities(matching string: String) async throws -> [TaskReminderTrialList] {
            try await ProjectQuery().entities(matching: string).map(TaskReminderTrialList.init)
        }
    }

    @available(iOS 27, *)
    @AppEnum(schema: .reminders.listType)
    enum TaskReminderTrialListType: String {
        case standard

        static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.standard: "Project"]
    }

    /// The created task, as the schema's reminder. Only the title and the
    /// project are real; the rest is what a new Burrow task has.
    @available(iOS 27, *)
    @AppEntity(schema: .reminders.reminder)
    struct TaskReminderTrialReminder {
        static let defaultQuery = TaskReminderTrialReminderQuery()

        /// `<host>|<task uuid>`.
        let id: String
        var title: String
        var note: AttributedString?
        var tags: Set<String>
        var urls: [URL]
        var dueDate: DateComponents?
        var recurrence: Calendar.RecurrenceRule?
        var isCompleted: Bool
        var isFlagged: Bool?
        var creationDate: Date?
        var completionDate: Date?
        var list: TaskReminderTrialList
        var locationTrigger: TaskReminderTrialLocation?

        var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

        init(id: String, title: String, list: TaskReminderTrialList) {
            self.id = id
            self.title = title
            note = nil
            tags = []
            urls = []
            dueDate = nil
            recurrence = nil
            isCompleted = false
            isFlagged = nil
            creationDate = nil
            completionDate = nil
            self.list = list
            locationTrigger = nil
        }
    }

    @available(iOS 27, *)
    struct TaskReminderTrialReminderQuery: EntityStringQuery {
        func entities(for identifiers: [String]) async throws -> [TaskReminderTrialReminder] { [] }
        func entities(matching string: String) async throws -> [TaskReminderTrialReminder] { [] }
    }

    @available(iOS 27, *)
    @AppEntity(schema: .reminders.section)
    struct TaskReminderTrialSection {
        static let defaultQuery = TaskReminderTrialSectionQuery()

        let id: String
        var name: String
        var list: TaskReminderTrialList

        var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    }

    @available(iOS 27, *)
    struct TaskReminderTrialSectionQuery: EntityStringQuery {
        func entities(for identifiers: [String]) async throws -> [TaskReminderTrialSection] { [] }
        func entities(matching string: String) async throws -> [TaskReminderTrialSection] { [] }
    }

    @available(iOS 27, *)
    @AppEntity(schema: .reminders.locationTrigger)
    struct TaskReminderTrialLocation {
        static let defaultQuery = TaskReminderTrialLocationQuery()

        let id: String
        var place: PlaceDescriptor
        var event: TaskReminderTrialLocationEvent

        var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Location") }
    }

    @available(iOS 27, *)
    struct TaskReminderTrialLocationQuery: EntityStringQuery {
        func entities(for identifiers: [String]) async throws -> [TaskReminderTrialLocation] { [] }
        func entities(matching string: String) async throws -> [TaskReminderTrialLocation] { [] }
    }

    @available(iOS 27, *)
    @AppEnum(schema: .reminders.locationTriggerEvent)
    enum TaskReminderTrialLocationEvent: String {
        case arrive
        case depart

        static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.arrive: "Arrive", .depart: "Depart"]
    }

    @available(iOS 27, *)
    @AppIntent(schema: .reminders.createReminder)
    struct TaskReminderTrialCreateIntent {
        var title: String
        var list: TaskReminderTrialList?
        var note: AttributedString?
        var isFlagged: Bool?
        var images: [IntentFile]
        var tags: Set<String>
        var urls: [URL]
        var dueDate: DateComponents?
        var recurrence: Calendar.RecurrenceRule?
        var locationTrigger: TaskReminderTrialLocation?
        var section: TaskReminderTrialSection?

        func perform() async throws -> some ReturnsValue<TaskReminderTrialReminder> & ProvidesDialog {
            guard let list else { throw IntentFailure.notFound }
            let project = ProjectEntity(id: list.id, name: list.name, subtitle: "")
            let created = try await IntentActions().createTask(in: project, title: title)
            let host = EntityRef(list.id)?.host ?? ""
            let reminder = TaskReminderTrialReminder(id: EntityRef(host: host, uuid: created.id).id, title: created.title, list: list)
            return .result(value: reminder, dialog: IntentDialog("\(IntentCopy.taskCreated(title: created.title, project: list.name))"))
        }
    }
#endif
