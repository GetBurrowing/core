package com.koboai.burrow.push

import com.google.crypto.tink.hybrid.internal.HpkeContext
import com.google.crypto.tink.hybrid.internal.HpkeKemPrivateKey
import com.google.crypto.tink.hybrid.internal.HpkePrimitiveFactory
import com.google.crypto.tink.hybrid.internal.HpkeUtil
import com.google.crypto.tink.subtle.X25519
import com.google.crypto.tink.util.Bytes
import org.json.JSONObject
import java.util.Base64

/**
 * Opens a sealed push preview (task 01a1261e; `Platform.Push.Seal` on the
 * server, `PushSeal.swift` on iOS): HPKE RFC 9180 base mode,
 * DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / AES-128-GCM, info [INFO], aad
 * = the payload's `install_host`. The blob is base64url (no padding) of
 * `enc(32) || ciphertext || tag(16)`, Tink's NO_PREFIX layout.
 *
 * Tink's public `HybridDecrypt` fixes the HPKE aad to empty (its context
 * info is the HPKE info), so this uses Tink's HPKE context directly to bind
 * the ciphertext to its install. The shared fixture test
 * (`push_seal_v1.json`) pins the exact behaviour, so a Tink upgrade that
 * moved it fails a named test.
 *
 * Returns null on ANY failure; it never throws and never logs.
 */
object PushSeal {
    const val INFO = "burrow push v1"
    private const val ENC_LENGTH = 32
    private const val TAG_LENGTH = 16

    /** The server's cap on a sealed value (base64url characters). */
    const val MAX_SEALED_LENGTH = 3_072

    fun openBytes(
        sealed: String,
        installHost: String,
        privateKey: ByteArray,
    ): ByteArray? {
        if (sealed.length > MAX_SEALED_LENGTH) return null
        return try {
            val blob = Base64.getUrlDecoder().decode(sealed)
            if (blob.size <= ENC_LENGTH + TAG_LENGTH) return null
            val enc = blob.copyOfRange(0, ENC_LENGTH)
            val ciphertext = blob.copyOfRange(ENC_LENGTH, blob.size)
            val recipient = HpkeKemPrivateKey(Bytes.copyFrom(privateKey), Bytes.copyFrom(X25519.publicFromPrivate(privateKey)))
            HpkeContext
                .createRecipientContext(
                    enc,
                    recipient,
                    HpkePrimitiveFactory.createKem(HpkeUtil.X25519_HKDF_SHA256_KEM_ID),
                    HpkePrimitiveFactory.createKdf(HpkeUtil.HKDF_SHA256_KDF_ID),
                    HpkePrimitiveFactory.createAead(HpkeUtil.AES_128_GCM_AEAD_ID),
                    INFO.toByteArray(Charsets.UTF_8),
                ).open(ciphertext, installHost.toByteArray(Charsets.UTF_8))
        } catch (_: Exception) {
            null
        }
    }

    /** The inner FCM data map (string values), or null. */
    fun open(
        sealed: String,
        installHost: String,
        privateKey: ByteArray,
    ): Map<String, String>? {
        val bytes = openBytes(sealed, installHost, privateKey) ?: return null
        return try {
            val json = JSONObject(String(bytes, Charsets.UTF_8))
            json
                .keys()
                .asSequence()
                .filterNot { json.isNull(it) }
                .associateWith { key -> json.get(key).toString() }
        } catch (_: Exception) {
            null
        }
    }
}
