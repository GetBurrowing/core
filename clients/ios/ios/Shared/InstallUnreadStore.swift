import Foundation

extension Notification.Name {
    /// Posted when the per-install unread counts may have changed (a
    /// reconcile finished, a push arrived in the foreground). The shell turns
    /// it into the web event `burrowInstallBadges`; the picker reloads.
    static let burrowInstallBadgesChanged = Notification.Name("burrowInstallBadgesChanged")
}

/// One install's unread count as this device last learned it.
struct InstallUnread: Codable, Equatable {
    /// The install's Chat unread total (`Chat.total_unread_for_viewer/1`).
    var count: Int
    /// The server's time for that count (`unread_as_of` / `as_of`). Writes
    /// compare it: only a NEWER count replaces a stored one.
    var asOf: Date
    /// The last refresh of this install failed; `count` is the last one known.
    var stale: Bool = false
}

/// Per-install unread counts (task 01a1261e stage 4), in the App Group so
/// the app and the Notification Service Extension share one number.
///
/// - Push payloads (`unread_count` / `unread_as_of`) and the reconcile on
///   open (`GET /api/app/counts` `unread` / `as_of`) both write here. A write
///   lands only if its `asOf` is newer than the stored one, so a late,
///   older push cannot bring back a count the API already cleared.
/// - `total` sums only installs still in `InstallStore`, so a removed
///   install cannot keep the icon badge up; `InstallStore.remove(host:)`
///   also clears its entry.
/// - The ONE source for the unread number on this device. Separate from
///   `CountsCache`, which is the widgets' approvals/tasks cache.
final class InstallUnreadStore {
    static let keyPrefix = "suite.unread.v1."
    static let shared = InstallUnreadStore()

    private let defaults: UserDefaults
    private let hosts: () -> [String]

    init(
        defaults: UserDefaults? = UserDefaults(suiteName: InstallStore.appGroup),
        hosts: (() -> [String])? = nil
    ) {
        let resolved = defaults ?? .standard
        self.defaults = resolved
        self.hosts = hosts ?? { InstallStore(defaults: resolved).installs.map(\.host) }
    }

    func entry(for host: String) -> InstallUnread? {
        guard let data = defaults.data(forKey: Self.keyPrefix + host) else { return nil }
        return try? JSONDecoder().decode(InstallUnread.self, from: data)
    }

    /// Store `count` for `host` if `asOf` is newer than what is stored.
    /// Returns whether it was applied. A count that loses the comparison
    /// still clears `stale` when `clearStale` is set (a successful refresh
    /// proves the host is reachable even if a push beat it).
    @discardableResult
    func write(count: Int, asOf: Date, for host: String, clearStale: Bool = false) -> Bool {
        let current = entry(for: host)
        if let current, asOf <= current.asOf {
            if clearStale, current.stale {
                save(InstallUnread(count: current.count, asOf: current.asOf, stale: false), for: host)
            }
            return false
        }
        save(InstallUnread(count: max(0, count), asOf: asOf, stale: false), for: host)
        return true
    }

    /// The last refresh of `host` failed: keep its count, mark it stale.
    func markStale(_ host: String) {
        guard var current = entry(for: host) else { return }
        current.stale = true
        save(current, for: host)
    }

    func remove(_ host: String) {
        defaults.removeObject(forKey: Self.keyPrefix + host)
    }

    /// Sum over the installs still saved, for the icon badge.
    var total: Int {
        hosts().reduce(0) { $0 + (entry(for: $1)?.count ?? 0) }
    }

    /// Whether any install OTHER than `selectedHost` has unread: the web
    /// shell's switcher dot (`SuiteNative.installBadges`).
    func othersUnread(selectedHost: String?) -> Bool {
        hosts().contains { $0 != selectedHost && (entry(for: $0)?.count ?? 0) > 0 }
    }

    /// Every saved install's entry, keyed by host.
    func entries() -> [String: InstallUnread] {
        var result: [String: InstallUnread] = [:]
        for host in hosts() {
            if let entry = entry(for: host) { result[host] = entry }
        }
        return result
    }

    private func save(_ entry: InstallUnread, for host: String) {
        if let data = try? JSONEncoder().encode(entry) {
            defaults.set(data, forKey: Self.keyPrefix + host)
        }
    }

    /// Clears `host`'s entry in `defaults` (for `InstallStore.remove`).
    static func clear(_ host: String, in defaults: UserDefaults) {
        defaults.removeObject(forKey: keyPrefix + host)
    }

    /// The server's ISO-8601 time (`2026-10-10T15:00:00.123456Z`, any number
    /// of fraction digits, or none), or nil.
    static func parseDate(_ value: Any?) -> Date? {
        guard var text = value as? String, !text.isEmpty else { return nil }
        // ISO8601DateFormatter takes at most millisecond fractions.
        if let dot = text.firstIndex(of: "."),
            let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." })
        {
            let fraction = text[text.index(after: dot)..<end]
            text.replaceSubrange(dot..<end, with: "." + String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
