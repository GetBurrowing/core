package com.koboai.burrow.push

import com.google.crypto.tink.subtle.X25519
import com.koboai.burrow.AndroidKeyStoreCipher
import com.koboai.burrow.KeyValueStore
import com.koboai.burrow.Sealed
import com.koboai.burrow.TokenCipher
import java.util.Base64

/**
 * This phone's push keys (task 01a1261e stage 5): one X25519 keypair PER
 * INSTALL HOST, so signing out of one install deletes only its key and two
 * installs cannot correlate the phone by key. Mirrors iOS `PushKeyStore`.
 *
 * - The install gets the PUBLIC key at registration ([publicKey], sent as
 *   `push_public_key`, base64url without padding) and seals each push
 *   preview to it; the relay in between only ever sees ciphertext.
 * - The PRIVATE key never leaves the phone. At rest it is AES-256-GCM
 *   ciphertext under a non-exportable AndroidKeyStore key of its own
 *   ([KEY_ALIAS], not the bearer key), with the host as the GCM associated
 *   data, in the private prefs file [PREFS_FILE] (the [KeystoreTokenStore]
 *   pattern). A copy moved under another host's entry does not decrypt.
 * - [PREFS_FILE] is excluded from backup: without its keystore key a
 *   restored ciphertext is useless.
 * - Never logged; [toString] names a count only.
 */
class PushKeyStore(
    private val prefs: KeyValueStore,
    private val cipher: TokenCipher,
    private val generate: () -> ByteArray = { X25519.generatePrivateKey() },
) {
    companion object {
        const val PREFS_FILE = "burrow_push_keys"
        const val KEY_ALIAS = "burrow_push_key_v1"
        private const val PREFIX = "pushkey.v1."

        private fun entry(host: String) = PREFIX + host.lowercase()

        private fun aad(host: String) = host.lowercase().toByteArray(Charsets.UTF_8)

        fun base64Url(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

        /** The production store, on its own AndroidKeyStore key. */
        fun cipher(): TokenCipher = AndroidKeyStoreCipher(KEY_ALIAS)
    }

    /** [host]'s stored private key, or null (none yet, or it no longer decrypts). */
    fun privateKey(host: String): ByteArray? {
        val stored = prefs.getString(entry(host)) ?: return null
        val parts = stored.split(':')
        if (parts.size != 2) return null
        return try {
            val decoder = Base64.getDecoder()
            cipher.decrypt(Sealed(decoder.decode(parts[0]), decoder.decode(parts[1])), aad(host)).takeIf { it.size == 32 }
        } catch (_: Exception) {
            // Keystore reset or a tampered entry: it can never open a push
            // again. Forget it; the next registration makes a new pair.
            prefs.remove(entry(host))
            null
        }
    }

    /**
     * [host]'s public key, base64url without padding, creating the pair on
     * first use. Null when the keystore refused: the registration then goes
     * out without a key and that install's pushes read "New message in ...".
     */
    fun publicKey(host: String): String? =
        try {
            val key = privateKey(host) ?: generate().also { if (!put(host, it)) return null }
            base64Url(X25519.publicFromPrivate(key))
        } catch (_: Exception) {
            null
        }

    /** Stores [privateKey] for [host] (also how a test installs a fixture key). */
    internal fun put(
        host: String,
        privateKey: ByteArray,
    ): Boolean =
        try {
            val sealed = cipher.encrypt(privateKey, aad(host))
            val encoder = Base64.getEncoder()
            prefs.putString(entry(host), encoder.encodeToString(sealed.iv) + ":" + encoder.encodeToString(sealed.ciphertext))
            true
        } catch (_: Exception) {
            false
        }

    /** Sign-out: the install's key goes with its bearer. */
    fun remove(host: String) {
        prefs.remove(entry(host))
    }

    override fun toString(): String = "PushKeyStore(${prefs.keys().count { it.startsWith(PREFIX) }} hosts)"
}
