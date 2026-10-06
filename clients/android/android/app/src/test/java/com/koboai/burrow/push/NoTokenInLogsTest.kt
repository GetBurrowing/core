package com.koboai.burrow.push

import android.app.Application
import com.koboai.burrow.HttpResponse
import com.koboai.burrow.RecordingTransport
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.shadows.ShadowLog

/**
 * Runtime half of the logging guard (NoSecretLoggingTest is the source
 * half): the real onNewToken path, with the token reaching the server and
 * the server failing, writes neither the FCM token nor the bearer to the
 * log, in a message or in an exception.
 */
@RunWith(RobolectricTestRunner::class)
class NoTokenInLogsTest {
    private val fcm = "fcmInstanceId012345678:APA91bSecretTokenBodyThatMustNeverBeLogged0123456789"
    private lateinit var app: Application

    @Before
    fun setUp() {
        app = PushTestSupport.app()
        PushTestSupport.signIn(app)
        ShadowLog.clear()
    }

    @After
    fun tearDown() = PushTestSupport.reset()

    @Test
    fun `onNewToken re-registers silently and logs no token`() {
        for (status in listOf(201, 500)) {
            val transport = RecordingTransport(mapOf("POST /api/app/devices" to HttpResponse(status, "{}")))
            PushTestSupport.withTransport(transport)
            val service = Robolectric.setupService(BurrowMessagingService::class.java)
            service.onNewToken(fcm)

            // Positive control: the token did reach the request, so a leak was possible.
            assertEquals(1, transport.requests.size)
            assertTrue(
                transport.requests
                    .single()
                    .body!!
                    .contains(fcm),
            )
            assertFalse(transport.requests.toString().contains(fcm))
        }
        for (log in ShadowLog.getLogs()) {
            val line = "${log.msg} ${log.throwable?.toString().orEmpty()} ${log.throwable?.stackTraceToString().orEmpty()}"
            assertFalse("log line carries the FCM token: ${log.tag}", line.contains(fcm))
            assertFalse("log line carries the bearer: ${log.tag}", line.contains(PushTestSupport.BEARER))
        }
    }

    @Test
    fun `onNewToken does nothing when notifications are off`() {
        val transport = RecordingTransport()
        PushTestSupport.withTransport(transport)
        org.robolectric.Shadows
            .shadowOf(app.getSystemService(android.app.NotificationManager::class.java))
            .setNotificationsEnabled(false)
        Robolectric.setupService(BurrowMessagingService::class.java).onNewToken(fcm)
        assertTrue(transport.requests.isEmpty())
    }
}
