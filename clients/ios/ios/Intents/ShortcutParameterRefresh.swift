import CryptoKit
import Foundation

/// Decides when the app refreshes its App Shortcuts' parameter phrases
/// ("Ask {agent} in Burrow", "Message {space} in Burrow").
///
/// `updateAppShortcutParameters()` makes the system re-query
/// `AgentQuery`/`SpaceQuery.suggestedEntities` across EVERY signed-in
/// install. Called from the entity-fetch path, resolving one install's
/// entity sent requests to all the others, and the re-query's own fetches
/// called it again: a storm of 20-30 requests a second (review of
/// 5b5c9895). So:
/// - fetches only RECORD what they saw (`record`), and never refresh;
/// - a refresh happens from `refreshIfNeeded`, which the app calls when
///   its scene goes to the background (never from an intent or a query), only
///   when the agent or space set changed since the last refresh, or none
///   has happened yet; at most once per `minimumInterval`; and from
///   `refreshNow`, right after a sign-in;
/// - what the system's own re-query fetches during `settleWindow` after a
///   refresh is what the refresh already published: it never marks dirty.
///
/// Stores SHA-256 digests and timestamps only: never a name or a token.
final class ShortcutParameterRefresh {
    /// The routes whose entities appear in App Shortcut phrases.
    static let routes: Set<String> = ["agents", "spaces"]
    static let minimumInterval: TimeInterval = 60
    static let settleWindow: TimeInterval = 30

    /// The app's instance. A var so tests can give it their own defaults.
    static var shared = ShortcutParameterRefresh()

    private static let digestPrefix = "suite.shortcuts.digest.v1."
    private static let dirtyKey = "suite.shortcuts.dirty.v1"
    private static let refreshedAtKey = "suite.shortcuts.refreshed-at.v1"

    let defaults: UserDefaults
    let now: () -> Date
    /// The system call. Injected so tests can count it and simulate the
    /// re-query it causes.
    var update: () -> Void
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init, update: @escaping () -> Void = {}) {
        self.defaults = defaults
        self.now = now
        self.update = update
    }

    /// A successful fetch of `route` from `host` returned entities with
    /// these keys (id and name). Never calls `update`.
    func record(route: String, host: String, keys: [String]) {
        guard Self.routes.contains(route) else { return }
        let digest = Self.digest(keys)
        let key = Self.digestPrefix + route + "." + host
        lock.lock()
        defer { lock.unlock() }
        guard defaults.string(forKey: key) != digest else { return }
        defaults.set(digest, forKey: key)
        if let refreshedAt = lastRefresh, now().timeIntervalSince(refreshedAt) < Self.settleWindow { return }
        defaults.set(true, forKey: Self.dirtyKey)
    }

    /// An install was signed out of or removed: its agents and spaces must
    /// leave the phrases at the next refresh.
    func forget(host: String) {
        lock.lock()
        defer { lock.unlock() }
        for route in Self.routes { defaults.removeObject(forKey: Self.digestPrefix + route + "." + host) }
        defaults.set(true, forKey: Self.dirtyKey)
    }

    /// Calls `update` if the set changed (or no refresh ever ran) and the
    /// last refresh is at least `minimumInterval` old. Returns whether it did.
    @discardableResult
    func refreshIfNeeded() -> Bool {
        lock.lock()
        let due: Bool = {
            if let refreshedAt = lastRefresh {
                return defaults.bool(forKey: Self.dirtyKey) && now().timeIntervalSince(refreshedAt) >= Self.minimumInterval
            }
            return true
        }()
        if due {
            defaults.set(now(), forKey: Self.refreshedAtKey)
            defaults.set(false, forKey: Self.dirtyKey)
        }
        lock.unlock()
        // Outside the lock: the re-query it causes may call `record`.
        if due { update() }
        return due
    }

    /// Refreshes now, whatever the digests say: only after a sign-in
    /// (PersonalIndexRefresh.didSignIn), whose fetch just recorded the new
    /// install's agents (task 01a111bb stage 7: a newly added install's
    /// agents were never speakable until a later background). Never called
    /// from a fetch, so the system's re-query cannot loop back here.
    func refreshNow() {
        lock.lock()
        defaults.set(now(), forKey: Self.refreshedAtKey)
        defaults.set(false, forKey: Self.dirtyKey)
        lock.unlock()
        update()
    }

    private var lastRefresh: Date? { defaults.object(forKey: Self.refreshedAtKey) as? Date }

    static func digest(_ keys: [String]) -> String {
        let joined = keys.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
