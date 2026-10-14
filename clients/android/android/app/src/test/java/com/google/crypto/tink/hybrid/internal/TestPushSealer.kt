package com.google.crypto.tink.hybrid.internal

import java.util.Base64

/**
 * Test-only: seals an inner push map the way the server does
 * (`Platform.Push.Seal`), so a test can relay a payload the shared fixture
 * does not contain (task 01a12773: an `author_avatar_url`). Lives in Tink's
 * package because `HpkeContext.createSenderContext` is package-private; the
 * app never seals.
 */
object TestPushSealer {
    fun seal(
        plaintext: String,
        recipientPublicKey: ByteArray,
        installHost: String,
        info: String,
    ): String {
        val context =
            HpkeContext.createSenderContext(
                recipientPublicKey,
                HpkePrimitiveFactory.createKem(HpkeUtil.X25519_HKDF_SHA256_KEM_ID),
                HpkePrimitiveFactory.createKdf(HpkeUtil.HKDF_SHA256_KDF_ID),
                HpkePrimitiveFactory.createAead(HpkeUtil.AES_128_GCM_AEAD_ID),
                info.toByteArray(Charsets.UTF_8),
            )
        val ciphertext = context.seal(plaintext.toByteArray(Charsets.UTF_8), installHost.toByteArray(Charsets.UTF_8))
        return Base64.getUrlEncoder().withoutPadding().encodeToString(context.encapsulatedKey + ciphertext)
    }
}
