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

/// `burrow://open?host=<host>&path=<path>`: the widgets' deep link. The
/// app opens `https://<host><path>` in that install. The path is an
/// allow-list, so a link cannot steer the shell anywhere but the two pages
/// the widgets point at.
struct DeepLink: Equatable {
    static let scheme = "burrow"
    static let action = "open"
    static let allowedPaths: Set<String> = ["/", "/inbox", "/tasks"]

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
              let host = InstallStore.normalizeHost(rawHost) else { return nil }
        let path = items.first(where: { $0.name == "path" })?.value ?? "/"
        guard Self.allowedPaths.contains(path) else { return nil }
        self.init(host: host, path: path)
    }
}
