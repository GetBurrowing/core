package com.koboai.burrow

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Where a caller reads an install's bearer from. */
interface TokenStore {
    fun token(host: String): String?
}

/** A token store the app can also write and forget a host's bearer in. */
interface MutableTokenStore : TokenStore {
    fun store(
        host: String,
        token: String,
    ): Boolean

    fun remove(host: String)
}

/** AES-GCM output: the IV and the ciphertext with its tag. */
class Sealed(
    val iv: ByteArray,
    val ciphertext: ByteArray,
) {
    override fun toString(): String = "Sealed(${ciphertext.size} bytes)"
}

/** Encrypts the bearer. Production: [AndroidKeyStoreCipher]. */
interface TokenCipher {
    fun encrypt(
        plaintext: ByteArray,
        aad: ByteArray,
    ): Sealed

    /** Throws when the key is gone or the ciphertext or [aad] do not match. */
    fun decrypt(
        sealed: Sealed,
        aad: ByteArray,
    ): ByteArray
}

/**
 * An AES-256-GCM key in AndroidKeyStore. The key never leaves the keystore
 * (non-exportable); the keystore picks the IV for every encryption.
 */
class AndroidKeyStoreCipher(
    private val alias: String = ALIAS,
) : TokenCipher {
    companion object {
        const val ALIAS = "burrow_bearer_key_v1"
        private const val PROVIDER = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val TAG_BITS = 128
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (keyStore.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        generator.init(
            KeyGenParameterSpec
                .Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    override fun encrypt(
        plaintext: ByteArray,
        aad: ByteArray,
    ): Sealed {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(aad)
        val ciphertext = cipher.doFinal(plaintext)
        return Sealed(cipher.iv, ciphertext)
    }

    override fun decrypt(
        sealed: Sealed,
        aad: ByteArray,
    ): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, sealed.iv))
        cipher.updateAAD(aad)
        return cipher.doFinal(sealed.ciphertext)
    }
}

/**
 * The app's bearer tokens, one per install host. Mirrors iOS
 * `KeychainTokenStore`:
 *
 * - entry = the install host, so each install keeps its own session;
 * - the bearer is AES-256-GCM ciphertext under a non-exportable
 *   AndroidKeyStore key, stored with its IV in the private prefs file
 *   [PREFS_FILE]; the host is the GCM associated data, so install A's
 *   ciphertext copied under install B's entry does not decrypt;
 * - [PREFS_FILE] is excluded from backup (data_extraction_rules.xml,
 *   backup_rules.xml): a restored ciphertext without its keystore key is
 *   undecryptable, so it would only turn a fresh sign-in into a failure;
 * - not androidx.security-crypto's EncryptedSharedPreferences, which is
 *   deprecated;
 * - never logged. Nothing here prints a token, and [toString] names only a
 *   count.
 */
class KeystoreTokenStore(
    private val prefs: KeyValueStore,
    private val cipher: TokenCipher,
) : MutableTokenStore {
    companion object {
        const val PREFS_FILE = "burrow_bearer_tokens"
        private const val PREFIX = "bearer.v1."

        private fun entry(host: String) = PREFIX + host.lowercase()

        private fun aad(host: String) = host.lowercase().toByteArray(Charsets.UTF_8)
    }

    override fun token(host: String): String? {
        val stored = prefs.getString(entry(host)) ?: return null
        val parts = stored.split(':')
        if (parts.size != 2) return null
        return try {
            val decoder = Base64.getDecoder()
            val sealed = Sealed(decoder.decode(parts[0]), decoder.decode(parts[1]))
            String(cipher.decrypt(sealed, aad(host)), Charsets.UTF_8)
        } catch (_: Exception) {
            // The key is gone (an app data restore, a keystore reset) or the
            // entry was tampered with: it can never decrypt, so forget it and
            // let the native sign-in run.
            prefs.remove(entry(host))
            null
        }
    }

    override fun store(
        host: String,
        token: String,
    ): Boolean =
        try {
            val sealed = cipher.encrypt(token.toByteArray(Charsets.UTF_8), aad(host))
            val encoder = Base64.getEncoder()
            prefs.putString(entry(host), encoder.encodeToString(sealed.iv) + ":" + encoder.encodeToString(sealed.ciphertext))
            true
        } catch (_: Exception) {
            false
        }

    override fun remove(host: String) {
        prefs.remove(entry(host))
    }

    override fun toString(): String = "KeystoreTokenStore(${prefs.keys().count { it.startsWith(PREFIX) }} hosts)"
}
