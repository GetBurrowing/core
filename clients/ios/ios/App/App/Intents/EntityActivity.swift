import AppIntents
import Foundation

/// The entity the web view is showing, so Apple Intelligence's onscreen
/// understanding can name it: `/chat/<segment>` is a space, `/tasks/<id>`
/// a task. A chat segment is mapped to its space id through the last spaces
/// fetch, unless it is already a UUID (a DM, an org space).
enum EntityActivity {
    enum Target: Equatable {
        case space(id: String)
        case task(id: String)
    }

    static let activityType = "com.kobo-ai.burrow.viewing"

    static func target(for url: URL?, host: String, spaceIDsBySegment: [String: String]) -> Target? {
        guard let url, url.host?.lowercased() == host.lowercased() else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty else { return nil }
        let segment = String(parts[2])
        switch parts[1] {
        case "chat":
            guard DeepLink.isSegment(segment) else { return nil }
            if DeepLink.isUUID(segment) { return .space(id: EntityRef(host: host, uuid: segment.lowercased()).id) }
            return spaceIDsBySegment[segment].map { .space(id: EntityRef(host: host, uuid: $0).id) }
        case "tasks":
            guard DeepLink.isUUID(segment) else { return nil }
            return .task(id: EntityRef(host: host, uuid: segment.lowercased()).id)
        default:
            return nil
        }
    }

    /// An activity annotated with the entity, or nil off an entity page.
    static func activity(for url: URL?, host: String) -> NSUserActivity? {
        guard #available(iOS 18.2, *),
            let target = target(for: url, host: host, spaceIDsBySegment: EntityCatalog.spaceIDsBySegment[host] ?? [:])
        else { return nil }
        let activity = NSUserActivity(activityType: activityType)
        switch target {
        case .space(let id): activity.appEntityIdentifier = EntityIdentifier(for: SpaceEntity.self, identifier: id)
        case .task(let id): activity.appEntityIdentifier = EntityIdentifier(for: TaskEntity.self, identifier: id)
        }
        return activity
    }
}
