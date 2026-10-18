package com.koboai.burrow.push

import com.google.crypto.tink.subtle.X25519
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PushSealTest {
    @Test
    fun `the shared fixture opens to its plaintext byte for byte`() {
        val opened = PushSeal.openBytes(SealFixture.sealed, SealFixture.host, SealFixture.privateKey)
        assertArrayEquals(SealFixture.plaintext.toByteArray(Charsets.UTF_8), opened)
        assertEquals(SealFixture.info, PushSeal.INFO)
    }

    @Test
    fun `the fixture's private key derives its published public key`() {
        assertEquals(SealFixture.recipientPublicKey, PushKeyStore.base64Url(X25519.publicFromPrivate(SealFixture.privateKey)))
    }

    @Test
    fun `the opened map is the server's FCM data map`() {
        val map = PushSeal.open(SealFixture.sealed, SealFixture.host, SealFixture.privateKey)!!
        assertEquals("chat_mention", map["kind"])
        assertEquals("Dana in launch", map["title"])
        assertEquals("@Robin can you check the deck before 3?", map["body"])
        assertEquals(SealFixture.innerData, map)
    }

    @Test
    fun `another install_host as aad does not open`() {
        assertNull(PushSeal.openBytes(SealFixture.sealed, "burrow-a.localhost", SealFixture.privateKey))
    }

    @Test
    fun `another key does not open`() {
        assertNull(PushSeal.openBytes(SealFixture.sealed, SealFixture.host, X25519.generatePrivateKey()))
    }

    @Test
    fun `a flipped byte, a truncated blob, junk and an oversized value do not open`() {
        val bytes = SealFixture.blob()
        bytes[bytes.size - 1] = (bytes[bytes.size - 1].toInt() xor 1).toByte()
        val flipped = PushKeyStore.base64Url(bytes)
        assertNull(PushSeal.openBytes(flipped, SealFixture.host, SealFixture.privateKey))
        assertNull(PushSeal.openBytes(SealFixture.sealed.take(60), SealFixture.host, SealFixture.privateKey))
        assertNull(PushSeal.openBytes("not base64url!!", SealFixture.host, SealFixture.privateKey))
        assertNull(PushSeal.openBytes("A".repeat(PushSeal.MAX_SEALED_LENGTH + 1), SealFixture.host, SealFixture.privateKey))
    }
}
