import Foundation

/// The phone app's Recents shows a Burrow call by its CallKit handle (the
/// meeting name, or a ring's caller name). A tap there comes back as an
/// `INStartCallIntent` carrying only that handle, so the handle's meeting
/// is remembered here: ids and a host, never a credential. The newest
/// `limit` handles are kept.
enum RecentCalls {
    struct Entry: Codable, Equatable {
        let host: String
        let meetingID: String
        let spaceID: String?
        let at: Date
    }

    static let limit = 20
    static let key = "suite.recent_calls.v1"
    static var defaults: UserDefaults = .standard

    static func record(handle: String, host: String, meetingID: String, spaceID: String?, now: Date = Date()) {
        guard !handle.isEmpty, !host.isEmpty else { return }
        var all = load()
        all[handle] = Entry(host: host, meetingID: meetingID, spaceID: spaceID, at: now)
        if all.count > limit {
            let keep = all.sorted { $0.value.at > $1.value.at }.prefix(limit)
            all = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }

    static func lookup(handle: String) -> Entry? { load()[handle] }

    private static func load() -> [String: Entry] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }
}
