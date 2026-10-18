import Foundation
import Security

/// Where a caller reads an install's bearer from. The API client takes one
/// of these so tests can hand it an in-memory store; production uses
/// `KeychainTokenStore.shared`.
protocol TokenStore {
    func token(for host: String) -> String?
}

/// A token store the app can also forget a host's bearer in: sign-out, and
/// a handoff the server refused with 401.
protocol MutableTokenStore: TokenStore {
    func remove(for host: String)
}

/// Lists the install hosts that hold a bearer, without reading any bearer.
/// `InstallStore` uses it to carry signed-in installs across the upgrade
/// that removed the built-in install list.
protocol TokenHostListing {
    func storedHosts() -> [String]
}

/// The app's bearer tokens, one per install, in the Keychain ONLY.
///
/// - account = the install host, so each install keeps its own session;
/// - access group = `$(AppIdentifierPrefix)com.kobo-ai.burrow.shared`,
///   declared in `keychain-access-groups` by the app, the share extension and
///   the widgets, so all three read the item the app's sign-in wrote;
/// - never UserDefaults, never the App Group container, never logged.
///   Nothing in this file prints a token.
///
/// The access group carries the team prefix, which only the build knows, so
/// each target's Info.plist passes it in as `BurrowKeychainAccessGroup`.
struct KeychainTokenStore: MutableTokenStore, TokenHostListing {
    static let service = "com.kobo-ai.burrow.session"
    static let accessGroupSuffix = "com.kobo-ai.burrow.shared"
    static let infoPlistKey = "BurrowKeychainAccessGroup"

    static let shared = KeychainTokenStore()

    /// The access group from the running target's Info.plist. A target
    /// built without it is misconfigured: fail loudly in Debug rather than
    /// fall back to a private keychain the other targets cannot read.
    static var bundleAccessGroup: String {
        let value = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String ?? ""
        assert(
            value.hasSuffix(accessGroupSuffix) && value.count > accessGroupSuffix.count,
            "\(infoPlistKey) must be $(AppIdentifierPrefix)\(accessGroupSuffix)")
        return value
    }

    let accessGroup: String

    init(accessGroup: String = KeychainTokenStore.bundleAccessGroup) {
        self.accessGroup = accessGroup
    }

    func token(for host: String) -> String? {
        var query = baseQuery(host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func store(_ token: String, for host: String) -> Bool {
        let update: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            // The widgets refresh in the background on a locked phone.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(baseQuery(host) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = baseQuery(host)
        add.merge(update) { _, new in new }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func remove(for host: String) {
        SecItemDelete(baseQuery(host) as CFDictionary)
    }

    /// Every account (install host) with a bearer in this service and access
    /// group. Asks for attributes ONLY: the query never sets
    /// `kSecReturnData`, so no bearer is read, and nothing is logged.
    func storedHosts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
            let attributes = items as? [[String: Any]]
        else { return [] }
        return attributes.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func baseQuery(_ host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: host,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }
}
