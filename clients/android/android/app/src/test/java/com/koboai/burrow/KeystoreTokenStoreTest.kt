package com.koboai.burrow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class KeystoreTokenStoreTest {
    private val prefs = InMemoryKeyValueStore()
    private val cipher = FakeTokenCipher()
    private val store = KeystoreTokenStore(prefs, cipher)

    private val bearerA = "bearer-AAAA-1111-secret"
    private val bearerB = "bearer-BBBB-2222-secret"

    @Test
    fun `install B never sees install A's bearer, after A was used`() {
        // The iOS lesson (e03cc922): exercise A FIRST, through the same path
        // a request takes, then assert B does not get it.
        assertTrue(store.store("a.example.com", bearerA))
        val client = AppApiClient(store, RecordingTransport())
        assertEquals(bearerA, store.token("a.example.com"))
        assertEquals("Bearer $bearerA", client.authorized("a.example.com", "GET", "/api/app/counts", null).headers["Authorization"])

        assertNull(store.token("b.example.com"))
        try {
            client.authorized("b.example.com", "GET", "/api/app/counts", null)
            fail("install B must not be signed in")
        } catch (e: ApiException) {
            assertEquals(ApiException.Kind.NOT_SIGNED_IN, e.kind)
        }

        assertTrue(store.store("b.example.com", bearerB))
        assertEquals(bearerA, store.token("a.example.com"))
        assertEquals(bearerB, store.token("b.example.com"))
        assertEquals("Bearer $bearerB", client.authorized("b.example.com", "GET", "/x", null).headers["Authorization"])

        store.remove("a.example.com")
        assertNull(store.token("a.example.com"))
        assertEquals(bearerB, store.token("b.example.com"))
    }

    @Test
    fun `only ciphertext is stored, never the bearer`() {
        store.store("a.example.com", bearerA)
        val raw = prefs.rawValues().joinToString()
        assertFalse(raw.contains(bearerA))
        assertFalse(raw.contains("AAAA"))
        assertTrue(prefs.keys().all { it.startsWith("bearer.v1.") })
    }

    @Test
    fun `A's ciphertext copied under B's entry does not decrypt (host is the GCM associated data)`() {
        store.store("a.example.com", bearerA)
        val stolen = prefs.getString("bearer.v1.a.example.com")!!
        prefs.putString("bearer.v1.b.example.com", stolen)
        assertNull(store.token("b.example.com"))
        // The undecryptable entry is forgotten; A is untouched.
        assertNull(prefs.getString("bearer.v1.b.example.com"))
        assertEquals(bearerA, store.token("a.example.com"))
    }

    @Test
    fun `a lost keystore key reads as signed out and clears the entry`() {
        store.store("a.example.com", bearerA)
        cipher.forget()
        assertNull(store.token("a.example.com"))
        assertTrue(prefs.keys().isEmpty())
    }

    @Test
    fun `hosts are case-insensitive`() {
        store.store("A.Example.com", bearerA)
        assertEquals(bearerA, store.token("a.example.com"))
    }

    @Test
    fun `toString names a count, never a token`() {
        store.store("a.example.com", bearerA)
        store.store("b.example.com", bearerB)
        val text = store.toString()
        assertEquals("KeystoreTokenStore(2 hosts)", text)
        assertFalse(text.contains(bearerA) || text.contains(bearerB))
        assertFalse(Sealed(ByteArray(12), bearerA.toByteArray()).toString().contains(bearerA))
    }

    @Test
    fun `hostsIn returns entry names and never touches the cipher`() {
        assertTrue(store.store("a.example.com", bearerA))
        assertTrue(store.store("B.Example.com", bearerB))
        prefs.putString("unrelated.key", "x")
        // A cipher that throws on any use: hostsIn must not decrypt.
        val throwing =
            object : TokenCipher {
                override fun encrypt(
                    plaintext: ByteArray,
                    aad: ByteArray,
                ): Sealed = throw AssertionError("hostsIn encrypted")

                override fun decrypt(
                    sealed: Sealed,
                    aad: ByteArray,
                ): ByteArray = throw AssertionError("hostsIn decrypted")
            }
        val untouchable = KeystoreTokenStore(prefs, throwing)
        assertEquals(setOf("a.example.com", "b.example.com"), KeystoreTokenStore.hostsIn(prefs))
        assertEquals("KeystoreTokenStore(2 hosts)", untouchable.toString())
        // A bearer that no longer decrypts still counts as a sign-in.
        cipher.forget()
        assertEquals(setOf("a.example.com", "b.example.com"), KeystoreTokenStore.hostsIn(prefs))
        assertEquals(emptySet<String>(), KeystoreTokenStore.hostsIn(InMemoryKeyValueStore()))
    }
}
