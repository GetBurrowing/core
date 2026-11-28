import Foundation

/// Why a widget has nothing to show (task 01a21e75, device rev 1): the step
/// that failed, as a short code the widget prints under "Not loaded yet" or
/// "Sign in to Burrow". Never a host, a name, a token or any text from the
/// server: only a step and, for an HTTP answer, its status.
///
/// - `no install`: no install is saved in the App Group (the app never
///   wrote the install list where the widget reads it).
/// - `no token`: installs are saved but none has a bearer in the shared
///   Keychain group.
/// - `HTTP <status>`: the install answered with that status (404: the
///   install's server does not have the widget endpoint yet).
/// - `decode`: a 2xx whose body did not decode.
/// - `timeout`, `network <code>`: no answer.
enum WidgetDiagnosis {
    static let noInstall = "no install"
    static let noToken = "no token"

    static func code(for error: Error) -> String {
        if let failure = error as? BurrowAPIClient.Failure {
            switch failure {
            case .notSignedIn: return noToken
            case .status(let status), .refused(let status, _): return "HTTP \(status)"
            case .badResponse: return "decode"
            case .tooLarge: return "too large"
            }
        }
        if error is InstallFanout.TimedOut { return "timeout" }
        if let url = error as? URLError { return "network \(url.errorCode)" }
        return "network"
    }

    /// The code for a widget covering `installs` of `saved`, given each
    /// host's last failure (`failures`): nil when there is nothing to report.
    static func summary(saved: [Install], installs: [Install], signedIn: (String) -> Bool, failures: [String: String]) -> String? {
        guard !saved.isEmpty, !installs.isEmpty else { return noInstall }
        let live = installs.filter { signedIn($0.host) }
        guard !live.isEmpty else { return noToken }
        let codes = live.compactMap { failures[$0.host] }
        guard !codes.isEmpty else { return nil }
        // The same code on every failing install reads once.
        let unique = codes.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return unique.joined(separator: " · ")
    }
}

/// Each install's last widget-fetch failure, in the App Group, keyed by
/// host (device-local; the host is never shown). Cleared on success.
struct WidgetDiagnosisStore {
    private static let key = "burrow.widget.diagnosis.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: InstallStore.appGroup)) {
        self.defaults = defaults ?? .standard
    }

    var failures: [String: String] { defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:] }

    func record(_ code: String?, for host: String) {
        var all = failures
        all[host] = code
        defaults.set(all, forKey: Self.key)
    }
}
