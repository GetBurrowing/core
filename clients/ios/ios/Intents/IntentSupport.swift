import CoreSpotlight
import Foundation
import os

/// An App Intents entity id: `<host>|<uuid>`. The host is part of the id so
/// every request for the entity goes to the install it came from, with that
/// install's bearer, and never to whichever install happens to be selected.
struct EntityRef: Hashable {
    static let separator: Character = "|"

    let host: String
    let uuid: String

    init(host: String, uuid: String) {
        self.host = host
        self.uuid = uuid
    }

    /// Parses `<host>|<uuid>`. The host must already be a normalised host
    /// (what `InstallStore.normalizeHost` returns) and the uuid non-empty.
    init?(_ id: String) {
        guard let bar = id.firstIndex(of: Self.separator) else { return nil }
        let host = String(id[..<bar])
        let uuid = String(id[id.index(after: bar)...])
        guard !uuid.isEmpty, !uuid.contains(Self.separator), InstallStore.normalizeHost(host) == host else { return nil }
        self.init(host: host, uuid: uuid)
    }

    var id: String { "\(host)\(Self.separator)\(uuid)" }
}

/// Waits between ask-an-agent polls. Injected so tests run on virtual time.
protocol IntentSleeper {
    func sleep(seconds: Double) async throws
}

struct TaskSleeper: IntentSleeper {
    func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// The space a meeting was last started for, per install host, in the App
/// Group: its id, and its name for the Start meeting control's value line.
struct LastMeetingSpaceStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: InstallStore.appGroup)) {
        self.defaults = defaults ?? .standard
    }

    private func key(_ host: String) -> String { "suite.intents.last-meeting-space.v1.\(host)" }

    func spaceID(for host: String) -> String? { defaults.string(forKey: key(host)) }

    func spaceName(for host: String) -> String? { defaults.string(forKey: key(host) + ".name") }

    func set(_ spaceID: String, name: String? = nil, for host: String) {
        defaults.set(spaceID, forKey: key(host))
        if let name { defaults.set(name, forKey: key(host) + ".name") }
    }

    func remove(for host: String) {
        defaults.removeObject(forKey: key(host))
        defaults.removeObject(forKey: key(host) + ".name")
    }
}

/// Everything an intent reaches outside itself. `current` is what the
/// running intents and entity queries use; tests swap it.
struct IntentEnvironment {
    var client: SuiteAPIClient
    var installs: InstallStore
    var sleeper: IntentSleeper
    var now: () -> Date
    var lastMeetingSpaces: LastMeetingSpaceStore

    static var live: IntentEnvironment {
        IntentEnvironment(
            client: .shared, installs: .shared, sleeper: TaskSleeper(), now: Date.init, lastMeetingSpaces: LastMeetingSpaceStore())
    }

    static var current = IntentEnvironment.live

    /// The saved install for `host`, or nil: an entity naming a host that is
    /// not in the install list resolves to nothing.
    func install(_ host: String) -> Install? {
        installs.installs.first { $0.host == host }
    }

    /// Hosts that are saved AND hold a bearer, in list order.
    var signedInHosts: [String] {
        installs.installs.map(\.host).filter { client.isSignedIn(host: $0) }
    }

    var isMultiInstall: Bool { installs.installs.count > 1 }

    func installName(_ host: String) -> String {
        install(host)?.displayName ?? host
    }

    /// The install name to add to a subtitle or confirmation: only when more
    /// than one install is saved (canvas, Multi-install disambiguation).
    func disambiguator(_ host: String) -> String? {
        isMultiInstall ? installName(host) : nil
    }
}

/// What an intent says when it cannot finish. Siri speaks
/// `localizedStringResource`; copy is the canvas's "Siri spoken responses".
enum IntentFailure: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case notFound
    case signedOut
    case unreachable(install: String)
    case noProject(install: String)
    case emptyMessage
    case emptyNote
    /// 409 `frozen` on an edit: an agent began work on the message.
    case messageFrozen(by: String?)
    /// 422 `not_supported` on mark-unread.
    case cannotMarkUnread
    /// A call to an agent (task 01a111bb stage 6).
    case cannotCallAgents
    /// 422 `too_many_invitees`.
    case tooManyInvitees
    /// No Burrow person answers to the name Siri heard (task 01a111bb
    /// stage 7). Spoken with the name; never logged.
    case personNotFound(name: String?)
    /// A schema send to several people: Burrow messages one at a time.
    case onePersonAtATime

    var message: String {
        switch self {
        case .notFound: return "Burrow couldn't find that. It may have been removed or belong to an install you've signed out of."
        case .signedOut: return "You're signed out of Burrow. Open the app to sign in."
        case .unreachable(let install): return "Burrow couldn't reach \(install). Try again in a moment."
        case .noProject(let install): return "There's no project on \(install) to hold a meeting. Create a project, then try again."
        case .emptyMessage: return "There's nothing to send."
        case .emptyNote: return "A rejection needs a note for the agent."
        case .messageFrozen(let by):
            guard let by, !by.isEmpty else { return "An agent began work on that message, so it can't be edited. Send a follow-up instead." }
            return "\(by) began work on that message, so it can't be edited. Send a follow-up instead."
        case .cannotMarkUnread: return "Burrow can't mark messages unread."
        case .cannotCallAgents: return "Burrow can't call agents yet."
        case .tooManyInvitees: return "That's too many people for one call."
        case .personNotFound(let name):
            guard let name else { return "Burrow couldn't tell who that is. Try their full name." }
            return "Burrow couldn't find anyone named \(name). Try their full name."
        case .onePersonAtATime: return "Burrow can message one person at a time."
        }
    }

    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }

    /// Maps a client error for `host` to what the person hears.
    static func from(_ error: Error, host: String, env: IntentEnvironment) -> Error {
        if error is IntentFailure || error is CancellationError { return error }
        switch error {
        case SuiteAPIClient.Failure.notSignedIn,
            SuiteAPIClient.Failure.status(401),
            SuiteAPIClient.Failure.refused(status: 401, code: _):
            return IntentFailure.signedOut
        case SuiteAPIClient.Failure.status(404), SuiteAPIClient.Failure.refused(status: 404, code: _):
            return IntentFailure.notFound
        case SuiteAPIClient.Failure.refused(status: 422, code: "agent_not_callable"):
            return IntentFailure.cannotCallAgents
        case SuiteAPIClient.Failure.refused(status: 422, code: "too_many_invitees"):
            return IntentFailure.tooManyInvitees
        case SuiteAPIClient.Failure.refused(status: 422, code: "no_project"):
            return IntentFailure.noProject(install: env.installName(host))
        default:
            return IntentFailure.unreachable(install: env.installName(host))
        }
    }
}

/// The only logging in the intents: route names, HTTP status, counts and
/// host. Never a token, a message, a question, a reply or approval content
/// (IntentSourceScanTests fails the build of any log line that tries).
enum IntentLog {
    static let logger = Logger(subsystem: "com.kobo-ai.burrow", category: "intents")

    static func route(_ name: String, host: String, status: Int) {
        logger.info("intent route=\(name, privacy: .public) host=\(host, privacy: .public) status=\(status)")
        IntentTrace.append("route=\(name) host=\(host) status=\(status)")
    }

    static func count(_ name: String, host: String, count: Int) {
        logger.info("intent fetch=\(name, privacy: .public) host=\(host, privacy: .public) count=\(count)")
        IntentTrace.append("fetch=\(name) host=\(host) count=\(count)")
    }

    /// A step inside an intent: where it is, and a fixed detail (a case
    /// name, an identifier kind, a reason). Callers pass only constants and
    /// counts: never a name, a handle, an id or text.
    static func step(_ site: String, _ detail: String) {
        logger.notice("intent step=\(site, privacy: .public) \(detail, privacy: .public)")
        IntentTrace.append("step=\(site) \(detail)")
    }
}

/// Debug builds only (task 01a111bb stage 7, round 3): every IntentLog line
/// also goes to `Library/Caches/intent-trace.log` in the process's own
/// container, with the pid, so a perform in ANY process (the system can
/// launch a fresh background instance for an intent) is visible afterwards:
/// `xcrun devicectl device copy from --domain-type appDataContainer
/// --domain-identifier com.kobo-ai.burrow --source Library/Caches/intent-trace.log`.
/// Same content as the os_log lines: constants, counts and hosts only.
/// Release builds compile this to nothing.
enum IntentTrace {
    #if DEBUG
        private static let lock = NSLock()
        private static let url: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("intent-trace.log")
        private static let stamp = ISO8601DateFormatter()
    #endif

    static func append(_ line: String) {
        #if DEBUG
            guard let url else { return }
            lock.lock()
            defer { lock.unlock() }
            let entry = "\(stamp.string(from: Date())) pid=\(ProcessInfo.processInfo.processIdentifier) \(line)\n"
            guard let data = entry.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        #endif
    }

    /// The build's git sha (Info.plist `BurrowGitSHA`, set from the
    /// `BURROW_GIT_SHA` build setting), or "unset".
    static var buildSHA: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "BurrowGitSHA") as? String ?? ""
        return value.isEmpty ? "unset" : value
    }
}

/// Hands an opened entity to the app's scene. The app sets `handler` once
/// its shell exists; until then (a cold launch) the link waits in
/// `pending`. The install is selected first, the way push routing by
/// `install_host` does.
enum IntentNavigator {
    static var handler: ((DeepLink) -> Void)?
    private static var pending: DeepLink?

    static func open(_ link: DeepLink, installs: InstallStore = .shared) {
        installs.select(link.host)
        if let handler {
            handler(link)
        } else {
            pending = link
        }
    }

    static func takePending() -> DeepLink? {
        defer { pending = nil }
        return pending
    }
}

/// App-side hooks the shared intent code calls. The app sets them; the
/// widget extension leaves them nil.
enum IntentHooks {
    /// After an open, send, ask or start succeeded: the app donates it.
    static var didSucceed: ((Any) -> Void)?
    /// After a successful fetch of `route` from `host`, with each entity's
    /// id and name: the app records it for ShortcutParameterRefresh. It must
    /// never refresh the App Shortcuts from here (that re-queries every
    /// install, and the re-query lands back here).
    static var didFetchEntities: ((_ route: String, _ host: String, _ keys: [String]) -> Void)?
    /// Only the app process indexes Spotlight.
    static var indexesSpotlight = false
}

/// Where Spotlight items go. The app uses the system index; tests swap in
/// an in-memory one to count what was indexed per host.
protocol SearchableIndexStore: AnyObject {
    func index(_ items: [CSSearchableItem])
    func deleteDomains(_ domains: [String])
}

/// The system's default Spotlight index.
final class SystemSearchableIndex: SearchableIndexStore {
    func index(_ items: [CSSearchableItem]) {
        CSSearchableIndex.default().indexSearchableItems(items) { _ in }
    }

    func deleteDomains(_ domains: [String]) {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: domains) { _ in }
    }
}

/// Spotlight entries per install: the host is the domain identifier, so
/// signing out of (or removing) an install deletes exactly its entries.
///
/// A host that was signed out of is SUPPRESSED until it signs in again
/// (task 01a111bb stage 7): an index refresh still in flight when the person
/// signs out must not put that install's people back after the delete.
enum SpotlightIndex {
    static var store: SearchableIndexStore = SystemSearchableIndex()
    private static let lock = NSLock()
    private static var suppressed: Set<String> = []

    static func removeAll(host: String) {
        lock.withLock { _ = suppressed.insert(host) }
        store.deleteDomains([host])
    }

    /// The install was signed in to (again): its entries may be indexed.
    static func allow(host: String) {
        lock.withLock { _ = suppressed.remove(host) }
    }

    static func isSuppressed(_ host: String) -> Bool {
        lock.withLock { suppressed.contains(host) }
    }
}
