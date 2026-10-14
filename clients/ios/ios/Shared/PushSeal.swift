import CryptoKit
import Foundation

/// Opens a sealed push preview (task 01a1261e stage 4): the `sealed` value
/// an install's `Platform.Push.Seal` produced.
///
/// HPKE (RFC 9180) base mode, DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 /
/// AES-128-GCM. CryptoKit has no predefined constant for that suite, so it
/// is built from its three parts. `info` is `burrow push v1` and the AAD is
/// the payload's `install_host`: a blob moved under another install's host
/// does not open. The blob is base64url(enc (32 bytes) || ciphertext || tag).
///
/// The plaintext is the JSON of the install's FCM data map, every value a
/// string. Any failure (wrong key, wrong host, tampering, bad JSON) is nil;
/// nothing is logged.
enum PushSeal {
    static let info = Data("burrow push v1".utf8)
    static let encapsulatedKeyBytes = 32

    static var ciphersuite: HPKE.Ciphersuite {
        HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_128)
    }

    /// The plaintext bytes, or nil.
    static func openData(_ sealed: String, installHost: String, key: Curve25519.KeyAgreement.PrivateKey) -> Data? {
        guard let blob = PushKeyStore.data(base64url: sealed), blob.count > encapsulatedKeyBytes else { return nil }
        let enc = blob.prefix(encapsulatedKeyBytes)
        let ciphertext = blob.dropFirst(encapsulatedKeyBytes)
        do {
            var recipient = try HPKE.Recipient(
                privateKey: key, ciphersuite: ciphersuite, info: info, encapsulatedKey: Data(enc))
            return try recipient.open(Data(ciphertext), authenticating: Data(installHost.utf8))
        } catch {
            return nil
        }
    }

    /// The inner data map, or nil.
    static func open(_ sealed: String, installHost: String, key: Curve25519.KeyAgreement.PrivateKey) -> [String: String]? {
        guard let data = openData(sealed, installHost: installHost, key: key),
            let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return map.compactMapValues { $0 as? String }
    }
}
