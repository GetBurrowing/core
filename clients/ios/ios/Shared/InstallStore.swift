import CryptoKit
import Foundation

/// One Burrow install the app can open. Each install has its own spaces and
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
/// The app ships no install list. A fresh install starts empty, and the
/// person adds their own install. Once `suite.installs.v1` is written, the
/// saved list is authoritative: an install the person removed stays removed.
///
/// Migration from builds that listed built-in installs (task 01a12787).
/// Those builds never wrote the built-in rows. They were virtual and
/// appeared whenever `suite.installs.v1` was absent, so on first read of an
/// absent key this store runs a one-shot migration and then persists the
/// result, so it never runs again:
///
/// - A preseeded row cannot be told apart from a user-saved one without
///   shipping the hostnames, and the app must not ship them. So the store
///   keys on evidence of USE instead: a bearer in the Keychain (signed in)
///   or an explicit selection.
/// - LEGACY means the old build ran: `suite.installs.confirmed.v1` is true
///   or `suite.installs.selected.v1` is set. A legacy store adopts the
///   selected host plus every host holding a Keychain bearer, normalized
///   and de-duplicated in that order. A store that is not legacy is a fresh
///   install and starts empty.
/// - A saved list, which anyone who ever added, renamed or removed an
///   install has, is kept WHOLE, including any built-in rows it
///   materialised. Those people were internal testers and can remove the
///   rows by hand. That is the price of never deleting a saved install.
/// - The one case that loses a row is a legacy person who only pressed
///   Continue on the implicit first row and never signed in. They hold no
///   bearer and no explicit selection, so there is nothing to sign out of,
///   and they land on the add-your-install flow.
/// - The LEGACY gate exists because iOS Keychain items SURVIVE app
///   deletion. Without it, a reinstall on a device that once signed in
///   would resurrect old hosts on what should be a clean first launch.
/// - Old builds also WROTE the built-in rows: their picker refreshed each
///   row's name on first display, which saved the virtual list. So a saved
///   list made only of the old built-in hosts, none of which holds a bearer,
///   is treated as never saved: it, the selection and the confirmation are
///   cleared once, and that person lands on the add-your-install flow. Any
///   list with another host, or with a bearer for any built-in host, is kept
///   WHOLE. The built-in hosts are recognised by the SHA-256 of the
///   normalized host (`legacyDefaultHostHashes`), never by name, so no
///   hostname ships. A renamed built-in row cannot be told from a probed
///   one; the bearer, not the name, is the signal of real use.
///   `suite.installs.defaults_checked.v1` makes this run once, so an install
///   added afterwards (even a built-in host) stays.
/// - The share extension and the widgets construct this store too. The
///   migration is a pure function of (App Group defaults, Keychain hosts),
///   so whichever process runs first writes the same list.
final class InstallStore {
    static let appGroup = "group.com.kobo-ai.burrow"

    private enum Key {
        static let installs = "suite.installs.v1"
        static let selected = "suite.installs.selected.v1"
        static let confirmed = "suite.installs.confirmed.v1"
        static let appInstallID = "suite.app_install_id.v1"
        static let defaultsChecked = "suite.installs.defaults_checked.v1"
    }

    /// SHA-256 (lowercase hex) of each normalized pre-2026-10 built-in
    /// install host. Hashes, not names: the app ships no hostname.
    static let legacyDefaultHostHashes: Set<String> = [
        "bf8aedd7f65fd728e9ebfec07705bc51e26ae0f54a35e00e8b2ed514b2bb664e",
        "11a3b9f3cee6dab41a8d8ded38d71da667774c858c9eb82c3c596b21b6273717",
        "c3d59dfdd4a743b27afbfd9fe449cbe919dd425ac7dcabee8790365371c2dde3",
    ]

    static func hostHash(_ host: String) -> String {
        SHA256.hash(data: Data(host.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// True for a pre-2026-10 built-in install host.
    static func isLegacyDefault(_ host: String) -> Bool {
        guard let normalized = normalizeHost(host) else { return false }
        return legacyDefaultHostHashes.contains(hostHash(normalized))
    }

    /// True when `host`, normalized, has its SHA-256 in `hashes`.
    static func isLegacyHost(_ host: String, in hashes: Set<String>) -> Bool {
        guard let normalized = normalizeHost(host) else { return false }
        return hashes.contains(hostHash(normalized))
    }

    static let shared = InstallStore()

    private let defaults: UserDefaults
    private let injectedTokenHosts: TokenHostListing?
    private let legacyHostHashes: Set<String>

    /// `tokenHosts` lists the hosts holding a bearer, for the one-time
    /// migration only. Nil means `KeychainTokenStore.shared`, resolved only
    /// when the migration needs it. `legacyHostHashes` is the digest set the
    /// migration treats as former built-in hosts: production uses the shipped
    /// `legacyDefaultHostHashes`, and tests inject digests of example.com
    /// hosts, so no test carries a real former host.
    init(
        defaults: UserDefaults? = UserDefaults(suiteName: InstallStore.appGroup),
        tokenHosts: TokenHostListing? = nil,
        legacyHostHashes: Set<String> = InstallStore.legacyDefaultHostHashes
    ) {
        self.defaults = defaults ?? .standard
        self.injectedTokenHosts = tokenHosts
        self.legacyHostHashes = legacyHostHashes
    }

    var installs: [Install] {
        guard let data = defaults.data(forKey: Key.installs),
            let saved = try? JSONDecoder().decode([Install].self, from: data)
        else {
            return clearUntouchedDefaults(migrateLegacyInstalls())
        }
        return defaults.bool(forKey: Key.defaultsChecked) ? saved : clearUntouchedDefaults(saved)
    }

    /// Once per store: a list made only of old built-in hosts, none holding
    /// a bearer, is treated as never saved. See the type's doc comment. The
    /// Keychain is read only for such a list.
    private func clearUntouchedDefaults(_ list: [Install]) -> [Install] {
        defer { defaults.set(true, forKey: Key.defaultsChecked) }
        guard !list.isEmpty, list.allSatisfy({ Self.isLegacyHost($0.host, in: legacyHostHashes) }) else { return list }
        let tokenHosts = injectedTokenHosts ?? KeychainTokenStore.shared
        let signedIn = Set(tokenHosts.storedHosts().compactMap(Self.normalizeHost))
        guard !list.contains(where: { signedIn.contains($0.host) }) else { return list }
        save([])
        defaults.removeObject(forKey: Key.selected)
        defaults.removeObject(forKey: Key.confirmed)
        return []
    }

    /// Runs when `suite.installs.v1` is absent. See the type's doc comment.
    private func migrateLegacyInstalls() -> [Install] {
        let selected = defaults.string(forKey: Key.selected)
        let isLegacy = defaults.bool(forKey: Key.confirmed) || selected != nil
        var adopted: [Install] = []
        if isLegacy {
            let tokenHosts = injectedTokenHosts ?? KeychainTokenStore.shared
            let candidates = (selected.map { [$0] } ?? []) + tokenHosts.storedHosts()
            for host in candidates.compactMap(Self.normalizeHost)
            where !adopted.contains(where: { $0.host == host }) {
                adopted.append(Install(host: host, name: nil))
            }
        }
        save(adopted)
        return adopted
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

    /// Called after an install is removed. The app sets it to forget the
    /// install's Spotlight entries; extensions leave it nil.
    static var didRemove: ((String) -> Void)?

    func remove(host: String) {
        defer { Self.didRemove?(host) }
        var list = installs
        list.removeAll { $0.host == host }
        save(list)
        if defaults.string(forKey: Key.selected) == host {
            defaults.removeObject(forKey: Key.selected)
        }
        // Its unread count must not keep the icon badge up (task 01a1261e).
        InstallUnreadStore.clear(host, in: defaults)
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
                label.unicodeScalars.allSatisfy({ allowed.contains($0) })
            else { return nil }
        }
        return text
    }
}
