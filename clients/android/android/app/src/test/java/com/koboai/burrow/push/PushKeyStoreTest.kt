package com.koboai.burrow.push

import com.google.crypto.tink.subtle.X25519
import com.koboai.burrow.FakeTokenCipher
import com.koboai.burrow.InMemoryKeyValueStore
import com.koboai.burrow.Sealed
import com.koboai.burrow.TokenCipher
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class PushKeyStoreTest {
    private val prefs = InMemoryKeyValueStore()
    private val cipher = FakeTokenCipher()
    private val store = PushKeyStore(prefs, cipher)

    @Test
    fun `a host's public key is made once, stable, and base64url without padding of 32 bytes`() {
        val first = store.publicKey("suite-b.localhost")!!
        assertEquals(first, store.publicKey("suite-b.localhost"))
        assertEquals(43, first.length)
        assertFalse(first.contains('=') || first.contains('+') || first.contains('/'))
        assertEquals(32, Base64.getUrlDecoder().decode(first).size)
        assertEquals(first, PushKeyStore.base64Url(X25519.publicFromPrivate(store.privateKey("suite-b.localhost")!!)))
    }

    @Test
    fun `each install gets its own key`() {
        assertNotEquals(store.publicKey("suite-a.localhost"), store.publicKey("suite-b.localhost"))
    }

    @Test
    fun `the private key is stored encrypted, never as its own bytes`() {
        store.publicKey("suite-b.localhost")
        val key = store.privateKey("suite-b.localhost")!!
        val raw = PushKeyStore.base64Url(key)
        val rawStd = Base64.getEncoder().encodeToString(key)
        prefs.keys().forEach { k ->
            val value = prefs.getString(k).orEmpty()
            assertFalse(value.contains(raw) || value.contains(rawStd))
        }
    }

    @Test
    fun `the host is the associated data, so a key moved to another host's entry does not open`() {
        store.publicKey("suite-a.localhost")
        val stolen = prefs.getString("pushkey.v1.suite-a.localhost")!!
        prefs.putString("pushkey.v1.suite-b.localhost", stolen)
        assertNull(store.privateKey("suite-b.localhost"))
        // ...and the undecryptable entry is forgotten.
        assertNull(prefs.getString("pushkey.v1.suite-b.localhost"))
        assertNotNull(store.privateKey("suite-a.localhost"))
    }

    @Test
    fun `sign-out removes only that host's key`() {
        store.publicKey("suite-a.localhost")
        store.publicKey("suite-b.localhost")
        store.remove("suite-a.localhost")
        assertNull(store.privateKey("suite-a.localhost"))
        assertNotNull(store.privateKey("suite-b.localhost"))
    }

    @Test
    fun `a keystore that refuses gives no public key, so the device registers without one`() {
        val refusing =
            object : TokenCipher {
                override fun encrypt(
                    plaintext: ByteArray,
                    aad: ByteArray,
                ): Sealed = throw java.security.KeyStoreException("no keystore")

                override fun decrypt(
                    sealed: Sealed,
                    aad: ByteArray,
                ): ByteArray = throw java.security.KeyStoreException("no keystore")
            }
        assertNull(PushKeyStore(InMemoryKeyValueStore(), refusing).publicKey("suite-b.localhost"))
    }

    @Test
    fun `a stored fixture key round-trips`() {
        assertTrue(store.put(SealFixture.host, SealFixture.privateKey))
        assertArrayEquals(SealFixture.privateKey, store.privateKey(SealFixture.host))
        assertEquals(SealFixture.recipientPublicKey, store.publicKey(SealFixture.host))
    }

    @Test
    fun `toString names a count, never a key`() {
        store.publicKey("suite-b.localhost")
        assertEquals("PushKeyStore(1 hosts)", store.toString())
    }
}
