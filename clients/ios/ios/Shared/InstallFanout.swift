import Foundation

/// One install's answer in a fan-out (task 01a21e75 stage 3).
enum InstallResult<T> {
    /// A fresh answer.
    case ok(T)
    /// The request failed or timed out. `lastKnown` is what this device
    /// cached for the install before, with when it was fetched.
    case unreachable(lastKnown: T?, fetchedAt: Date?)
    /// No bearer for the install: it was never requested.
    case signedOut

    var value: T? {
        switch self {
        case .ok(let value): return value
        case .unreachable(let lastKnown, _): return lastKnown
        case .signedOut: return nil
        }
    }
}

/// Fetches the same route from every install, each with its OWN bearer.
///
/// - Each request is built by `fetch(host)`, which goes through
///   `BurrowAPIClient.authorizedRequest(host:path:)` for that host, so one
///   install's token is never sent to another host.
/// - A signed-out host (`isSignedIn(host:)` false) is never requested.
/// - At most `maxConcurrent` requests are in flight, and each is given up
///   after `timeout` seconds, so a widget timeline stays inside WidgetKit's
///   refresh budget however many installs are saved.
/// - Results come back in the order of `installs`.
enum InstallFanout {
    static let defaultMaxConcurrent = 3
    static let defaultTimeout: TimeInterval = 10

    static func fetch<T: Sendable>(
        installs: [Install],
        client: BurrowAPIClient,
        maxConcurrent: Int = defaultMaxConcurrent,
        timeout: TimeInterval = defaultTimeout,
        lastKnown: (String) -> (T, Date)? = { _ in nil },
        fetch: @escaping @Sendable (String) async throws -> T
    ) async -> [(install: Install, result: InstallResult<T>)] {
        var results: [String: InstallResult<T>] = [:]
        let signedIn = installs.filter { client.isSignedIn(host: $0.host) }
        for install in installs where !signedIn.contains(install) {
            results[install.host] = .signedOut
        }

        let answered: [String: T] = await withTaskGroup(of: (String, T?).self) { group in
            var answers: [String: T] = [:]
            var pending = signedIn.makeIterator()
            func startNext() -> Bool {
                guard let install = pending.next() else { return false }
                let host = install.host
                group.addTask { (host, try? await withTimeout(timeout) { try await fetch(host) }) }
                return true
            }
            for _ in 0..<max(1, maxConcurrent) {
                if !startNext() { break }
            }
            while let (host, value) = await group.next() {
                if let value { answers[host] = value }
                _ = startNext()
            }
            return answers
        }

        for install in signedIn {
            if let value = answered[install.host] {
                results[install.host] = .ok(value)
            } else {
                let known = lastKnown(install.host)
                results[install.host] = .unreachable(lastKnown: known?.0, fetchedAt: known?.1)
            }
        }
        return installs.map { (install: $0, result: results[$0.host] ?? .signedOut) }
    }

    struct TimedOut: Error {}

    /// `operation`, or `TimedOut` after `seconds`.
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimedOut() }
            return first
        }
    }
}

extension BurrowAPIClient {
    /// `counts(host:completion:)` as async, for the fan-out.
    func fetchCounts(host: String) async throws -> BurrowCounts {
        try await withCheckedThrowingContinuation { continuation in
            counts(host: host) { continuation.resume(with: $0) }
        }
    }
}
