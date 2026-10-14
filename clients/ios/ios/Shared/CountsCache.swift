import Foundation

/// `GET /api/app/counts`: approvals waiting on the person and tasks assigned
/// to them and open.
struct SuiteCounts: Codable, Equatable {
    var approvals: Int
    var tasks: Int
    /// When THIS device received the counts. Staleness is measured from the
    /// device's own clock, so a server clock that disagrees with the phone
    /// cannot make an old count look fresh. (The server's `as_of` is the
    /// same instant give or take the round trip.)
    var fetchedAt: Date
    /// The Chat unread total (task 01a1261e), OPTIONAL: an older server, and
    /// a counts entry cached before this field existed, decode without it.
    var unread: Int? = nil
    /// The server's `as_of` for these counts, compared against push
    /// `unread_as_of` in `InstallUnreadStore` (newer wins). Optional as above.
    var asOf: Date? = nil

    func count(_ kind: SlabKind) -> Int {
        switch kind {
        case .approvals: return approvals
        case .tasks: return tasks
        }
    }
}

/// The last counts per install host, in the App Group, so the widgets can
/// show the last good number (as stale) when a refresh fails. Counts are not
/// secrets; the bearer that fetched them never touches this store.
struct CountsCache {
    private static let keyPrefix = "suite.counts.v1."
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: InstallStore.appGroup)) {
        self.defaults = defaults ?? .standard
    }

    func counts(for host: String) -> SuiteCounts? {
        guard let data = defaults.data(forKey: Self.keyPrefix + host) else { return nil }
        return try? Self.decoder.decode(SuiteCounts.self, from: data)
    }

    func write(_ counts: SuiteCounts, for host: String) {
        if let data = try? Self.encoder.encode(counts) {
            defaults.set(data, forKey: Self.keyPrefix + host)
        }
    }

    func remove(for host: String) {
        defaults.removeObject(forKey: Self.keyPrefix + host)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// `burrow://open?host=<host>&path=<path>`: a deep link into one install.
/// The app opens `https://<host><path>` in that install, with that
/// install's own bearer and handoff (the host travels in the link, so a
/// link never borrows another install's sign-in).
///
/// The path is validated against a fixed set of shapes, so a link cannot
/// steer the shell anywhere else:
/// `/`, `/inbox`, `/tasks`, `/tasks/<uuid>`, `/chat/<segment>`, `/meetings`,
/// `/meetings/<segment>`, where a segment is `[A-Za-z0-9_-]{1,128}`. That
/// alphabet has no `.`, `/`, `%`, `?` or `#`, so `..`, `//`, a
/// percent-encoded slash and a smuggled query or fragment all fail.
/// Spaces use the server's `path_segment` (`Chat.space_path_segment/1`),
/// never a slug: a DM has no slug and its segment is a bare UUID.
struct DeepLink: Equatable {
    static let scheme = "burrow"
    static let action = "open"
    static let maxSegmentLength = 128

    let host: String
    let path: String

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.action
        components.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "path", value: path)]
        return components.url!
    }

    /// The page in the install the link opens.
    var destination: URL { URL(string: "https://\(host)\(path)")! }

    init(host: String, path: String) {
        self.host = host
        self.path = path
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == Self.action,
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let rawHost = items.first(where: { $0.name == "host" })?.value,
            let host = InstallStore.normalizeHost(rawHost)
        else { return nil }
        let path = items.first(where: { $0.name == "path" })?.value ?? "/"
        guard Self.isAllowed(path: path) else { return nil }
        self.init(host: host, path: path)
    }

    // MARK: Constructors (App Intents, stage 3)

    /// A space or DM, by the server's `path_segment`.
    static func space(host: String, pathSegment: String) -> DeepLink? {
        validated(host: host, path: "/chat/\(pathSegment)")
    }

    /// One task, by its UUID.
    static func task(host: String, id: String) -> DeepLink? {
        validated(host: host, path: "/tasks/\(id)")
    }

    /// One meeting, by its slug.
    static func meeting(host: String, slug: String) -> DeepLink? {
        validated(host: host, path: "/meetings/\(slug)")
    }

    private static func validated(host: String, path: String) -> DeepLink? {
        guard let host = InstallStore.normalizeHost(host), isAllowed(path: path) else { return nil }
        return DeepLink(host: host, path: path)
    }

    // MARK: Validation

    static func isAllowed(path: String) -> Bool {
        switch path {
        case "/", "/inbox", "/tasks", "/meetings": return true
        default: break
        }
        // Exactly "/<section>/<one segment>": split keeps empty pieces, so
        // "//x", "/chat/" and "/chat/a/b" all come out the wrong shape.
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty else { return false }
        let segment = parts[2]
        switch parts[1] {
        case "chat", "meetings": return isSegment(segment)
        case "tasks": return isUUID(segment)
        default: return false
        }
    }

    static func isSegment<S: StringProtocol>(_ segment: S) -> Bool {
        guard (1...maxSegmentLength).contains(segment.utf8.count) else { return false }
        return segment.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"):
                return true
            default:
                return false
            }
        }
    }

    /// 8-4-4-4-12 hex digits, either case.
    static func isUUID<S: StringProtocol>(_ segment: S) -> Bool {
        let groups = segment.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.utf8.count) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { $0.allSatisfy(\.isHexDigit) } && segment.allSatisfy(\.isASCII)
    }
}
