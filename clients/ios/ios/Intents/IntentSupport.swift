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
    }

    static func count(_ name: String, host: String, count: Int) {
        logger.info("intent fetch=\(name, privacy: .public) host=\(host, privacy: .public) count=\(count)")
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

/// Spotlight entries per install: the host is the domain identifier, so
/// signing out of (or removing) an install deletes exactly its entries.
enum SpotlightIndex {
    static func removeAll(host: String, index: CSSearchableIndex = .default()) {
        index.deleteSearchableItems(withDomainIdentifiers: [host]) { _ in }
    }
}
