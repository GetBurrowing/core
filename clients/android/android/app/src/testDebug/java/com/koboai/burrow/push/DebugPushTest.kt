package com.koboai.burrow.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class DebugPushTest {
    private fun b64(json: String) = Base64.getEncoder().encodeToString(json.toByteArray())

    @Test
    fun `the debug token is stable, per install, and shaped like an FCM token`() {
        val token = DebugTokenSource("install-1").token()
        assertEquals(token, DebugTokenSource("install-1").token())
        assertNotEquals(token, DebugTokenSource("install-2").token())
        // fcm_devices' format (Platform.Mobile.FcmDevice @token_format) and the FCM shape.
        assertTrue(Regex("^[A-Za-z0-9_:\\-]{20,4096}$").matches(token))
        assertTrue(Regex("^[A-Za-z0-9_\\-]{22}:APA91b[A-Za-z0-9_\\-]{134}$").matches(token))
        assertTrue(!DebugTokenSource("install-1").toString().contains(token))
    }

    @Test
    fun `replay accepts the recorded FCM v1 body, a data object, or bare data`() {
        val data = """{"kind":"chat_mention","space_id":"s1","message_id":"m1"}"""
        val expected = mapOf("kind" to "chat_mention", "space_id" to "s1", "message_id" to "m1")
        assertEquals(expected, DebugPushReceiver.parse(b64("""{"message":{"token":"t","data":$data,"android":{"priority":"high"}}}""")))
        assertEquals(expected, DebugPushReceiver.parse(b64("""{"data":$data}""")))
        assertEquals(expected, DebugPushReceiver.parse(b64(data)))
        assertNull(DebugPushReceiver.parse("not base64 json"))
    }
}
