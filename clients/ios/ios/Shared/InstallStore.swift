import Foundation

/// One Suite install the app can open. Each install has its own spaces and
/// its own sign-in, so the host is the identity of everything per-install:
/// the Keychain account for its bearer, the web view's origin, and the
/// `install_host` a push payload routes by.
struct Install: Codable, Equatable, Identifiable {
    var host: String
    /// The install's own app name from `/manifest.json`, once fetched.
    var name: String? = nil

    var id: String { host }
    var displayName: String { name ?? host }
    var baseURL: URL { URL(string: "https://\(host)")! }
    var manifestURL: URL { baseURL.appendingPathComponent("manifest.json") }
    var healthURL: URL { baseURL.appendingPathComponent("health") }
    var iconURL: URL { baseURL.appendingPathComponent("branding/current/apple_touch") }
}

/// The saved install list and the current selection, persisted in the App
/// Group's UserDefaults so the share extension and widgets read the same
/// list the app writes.
///
/// First launch pre-lists the three internal installs with
/// suite.example.com selected (canvas open question 2: pre-list all three,
/// internal testers only). After that the saved list is authoritative: a
/// default the person removed stays removed.
final class InstallStore {
    static let appGroup = "group.com.kobo-ai.burrow"
    static let defaultHosts = ["suite.example.com", "suite.example.com", "suite.milv.life"]

    private enum Key {
        static let installs = "suite.installs.v1"
        static let selected = "suite.installs.selected.v1"
        static let confirmed = "suite.installs.confirmed.v1"
        static let appInstallID = "suite.app_install_id.v1"
    }

    static let shared = InstallStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: InstallStore.appGroup)) {
        self.defaults = defaults ?? .standard
    }

    var installs: [Install] {
        guard let data = defaults.data(forKey: Key.installs),
              let saved = try? JSONDecoder().decode([Install].self, from: data) else {
            return Self.defaultHosts.map { Install(host: $0, name: nil) }
        }
        return saved
    }

    var selectedHost: String? {
        let list = installs
        if let host = defaults.string(forKey: Key.selected), list.contains(where: { $0.host == host }) {
            return host
        }
        return list.first?.host
    }

    var selectedInstall: Install? {
        guard let host = selectedHost else { return nil }
        return installs.first { $0.host == host }
    }

    /// True once the person has pressed Continue at least once. Until then
    /// the app opens on the install picker.
    var hasConfirmedSelection: Bool {
        defaults.bool(forKey: Key.confirmed)
    }

    /// A stable per-device id the server keys this app's session and APNs
    /// device row on. Not a secret.
    var appInstallID: String {
        if let id = defaults.string(forKey: Key.appInstallID) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Key.appInstallID)
        return id
    }

    func select(_ host: String) {
        guard installs.contains(where: { $0.host == host }) else { return }
        defaults.set(host, forKey: Key.selected)
    }

    func confirmSelection() {
        defaults.set(true, forKey: Key.confirmed)
    }

    /// Adds (or keeps) an install and selects it.
    @discardableResult
    func add(host rawHost: String, name: String? = nil) -> Install? {
        guard let host = Self.normalizeHost(rawHost) else { return nil }
        var list = installs
        if let index = list.firstIndex(where: { $0.host == host }) {
            if let name { list[index].name = name }
        } else {
            list.append(Install(host: host, name: name))
        }
        save(list)
        select(host)
        return list.first { $0.host == host }
    }

    func updateName(_ name: String?, for host: String) {
        var list = installs
        guard let index = list.firstIndex(where: { $0.host == host }), list[index].name != name else { return }
        list[index].name = name
        save(list)
    }

    func remove(host: String) {
        var list = installs
        list.removeAll { $0.host == host }
        save(list)
        if defaults.string(forKey: Key.selected) == host {
            defaults.removeObject(forKey: Key.selected)
        }
    }

    private func save(_ list: [Install]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Key.installs)
        }
    }

    /// Turns what someone typed after the fixed `https://` prefix into a bare
    /// lowercase host. Rejects anything that is not a plausible DNS name:
    /// the picker only ever talks HTTPS to a host, never to a path or a port.
    static func normalizeHost(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        if text.hasSuffix(".") { text.removeLast() }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, text.count <= 253 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in labels {
            guard !label.isEmpty, label.count <= 63,
                  !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        }
        return text
    }
}
