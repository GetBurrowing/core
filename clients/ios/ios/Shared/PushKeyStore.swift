import CryptoKit
import Foundation
import Security

/// The device's X25519 keypair for sealed push previews, ONE PER INSTALL
/// HOST (task 01a1261e stage 4).
///
/// An install seals each notification's text to this device's public key
/// (`Platform.Push.Seal`), so the push relay in between carries nothing it
/// can read. Per install, so signing out of one install deletes only its key
/// and two installs cannot correlate this device by its key.
///
/// - The PRIVATE key lives in the Keychain only, in the shared access group
///   (`$(AppIdentifierPrefix)com.kobo-ai.burrow.shared`) so the Notification
///   Service Extension can open a push the app registered for. It is
///   `ThisDeviceOnly`: never in a backup, never synced, never sent anywhere.
/// - The PUBLIC key goes to the install in `POST /api/app/devices` as
///   `push_public_key`, base64url without padding.
/// - Nothing here logs.
struct PushKeyStore {
    static let service = "com.kobo-ai.burrow.pushkey"
    static let shared = PushKeyStore()

    let accessGroup: String

    init(accessGroup: String = KeychainTokenStore.bundleAccessGroup) {
        self.accessGroup = accessGroup
    }

    static func account(_ host: String) -> String { "push-key:\(host)" }

    /// The stored private key for `host`, or nil.
    func privateKey(for host: String) -> Curve25519.KeyAgreement.PrivateKey? {
        var query = baseQuery(host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    /// The public key to register for `host`, creating the keypair on first
    /// use. Nil only if the Keychain refused the write: the caller then
    /// registers without a key (the server sends no preview), never with one
    /// whose private half was not stored.
    func publicKey(for host: String) -> String? {
        if let existing = privateKey(for: host) {
            return Self.base64url(existing.publicKey.rawRepresentation)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        var add = baseQuery(host)
        add[kSecValueData as String] = key.rawRepresentation
        // The NSE opens pushes on a locked phone after the first unlock.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        return Self.base64url(key.publicKey.rawRepresentation)
    }

    /// Forget `host`'s key (sign-out). Idempotent.
    func remove(for host: String) {
        SecItemDelete(baseQuery(host) as CFDictionary)
    }

    private func baseQuery(_ host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account(host),
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64url text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}
