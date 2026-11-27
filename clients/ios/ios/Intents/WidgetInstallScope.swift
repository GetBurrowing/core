import AppIntents
import Foundation
import WidgetKit

/// "All installs" or one saved install, as a widget configuration value.
struct InstallScopeEntity: AppEntity {
    static let allID = "all"
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Installs"
    static var defaultQuery = InstallScopeQuery()

    /// `all`, or an install host.
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static let all = InstallScopeEntity(id: allID, name: "All installs")

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var scope: WidgetScope { id == Self.allID ? .all : .pinned(id) }
}

struct InstallScopeQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [InstallScopeEntity] {
        let options = Self.options(IntentEnvironment.current.installs.installs)
        return identifiers.compactMap { id in options.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [InstallScopeEntity] {
        Self.options(IntentEnvironment.current.installs.installs)
    }

    func defaultResult() async -> InstallScopeEntity? { .all }

    /// All installs first, then each saved install by its display label
    /// (never a hostname).
    static func options(_ installs: [Install]) -> [InstallScopeEntity] {
        [.all] + installs.map { InstallScopeEntity(id: $0.host, name: InstallLabel.name(for: $0.host, installs: installs)) }
    }
}

/// The configuration of My tasks, Overview and the feed widgets.
struct WidgetScopeIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Installs"
    static var description = IntentDescription("Show every signed-in Burrow install, or one.")

    @Parameter(title: "Installs")
    var scope: InstallScopeEntity?

    init() {}

    init(scope: InstallScopeEntity?) { self.scope = scope }

    var widgetScope: WidgetScope { scope?.scope ?? .all }
}
