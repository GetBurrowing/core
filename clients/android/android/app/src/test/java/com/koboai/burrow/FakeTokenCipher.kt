package com.koboai.burrow

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The same AES-256-GCM as [AndroidKeyStoreCipher], with a software key in
 * place of the AndroidKeyStore one (which the JVM does not have). [forget]
 * simulates a lost keystore key.
 */
class FakeTokenCipher : TokenCipher {
    private var key: SecretKey = newKey()

    private fun newKey(): SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

    fun forget() {
        key = newKey()
    }

    override fun encrypt(
        plaintext: ByteArray,
        aad: ByteArray,
    ): Sealed {
        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, iv))
        cipher.updateAAD(aad)
        return Sealed(iv, cipher.doFinal(plaintext))
    }

    override fun decrypt(
        sealed: Sealed,
        aad: ByteArray,
    ): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, sealed.iv))
        cipher.updateAAD(aad)
        return cipher.doFinal(sealed.ciphertext)
    }
}
