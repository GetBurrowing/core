package com.koboai.burrow.share

import android.app.Notification
import android.app.NotificationManager
import android.net.ConnectivityManager
import androidx.work.ListenableWorker
import androidx.work.testing.TestListenableWorkerBuilder
import androidx.work.workDataOf
import kotlinx.coroutines.runBlocking
import okhttp3.Call
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.ShadowNetwork
import java.io.File
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Task 01a120be stage 5: [LargeUploadWorker] against a tus-style
 * MockWebServer. Every run HEADs the server's offset first and resumes from
 * it, never from zero; a 409 adopts the server's offset.
 */
@RunWith(RobolectricTestRunner::class)
class LargeUploadWorkerTest {
    private lateinit var server: MockWebServer
    private lateinit var clientCerts: HandshakeCertificates
    private lateinit var source: File
    private val size = 300L

    /** A server that stores up to 100 bytes per PATCH at its offset. */
    private inner class TusServer(
        var stored: Long,
        /** What HEAD reports (a stale value tests 409 adoption); null = the truth. */
        var headReports: Long? = null,
        /** PATCH numbers (1-based) whose connection drops after half the chunk arrived. */
        val dropOn: Set<Int> = emptySet(),
        /** PATCH numbers (1-based) the server holds, unanswered, until [release] (a dead link). */
        val holdOn: Set<Int> = emptySet(),
        /** A status HEAD answers instead of 200 (404/410: the reservation was reaped). */
        var headStatus: Int = 200,
        /** PATCH number (1-based) to status: answered instead of storing the chunk. */
        val patchStatus: Map<Int, Int> = emptyMap(),
    ) : Dispatcher() {
        @Volatile
        var patches = 0
        val log = Collections.synchronizedList(mutableListOf<String>())
        val held = CountDownLatch(1)
        val release = CountDownLatch(1)
        var onHead: () -> Unit = {}

        override fun dispatch(request: RecordedRequest): MockResponse {
            if (request.method == "HEAD") {
                onHead()
                val reported = headReports ?: stored
                headReports = null
                log.add("HEAD")
                if (headStatus != 200) return MockResponse().setResponseCode(headStatus)
                return MockResponse().setResponseCode(200).addHeader("Upload-Offset", reported)
            }
            patches++
            val offset = request.getHeader("Upload-Offset")!!.toLong()
            log.add("PATCH $offset")
            patchStatus[patches]?.let { return MockResponse().setResponseCode(it) }
            if (patches in holdOn) {
                held.countDown()
                release.await(20, TimeUnit.SECONDS)
                return MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START)
            }
            if (patches in dropOn) {
                stored += request.bodySize / 2
                return MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST)
            }
            if (offset != stored) return MockResponse().setResponseCode(409).addHeader("Upload-Offset", stored)
            stored += request.bodySize
            return if (stored == size) {
                MockResponse().setResponseCode(200).setBody("""{"id":"att","message_id":"m1"}""")
            } else {
                MockResponse().setResponseCode(204).addHeader("Upload-Offset", stored)
            }
        }
    }

    @Before
    fun setUp() {
        val localhost = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverCerts = HandshakeCertificates.Builder().heldCertificate(localhost).build()
        clientCerts = HandshakeCertificates.Builder().addTrustedCertificate(localhost.certificate).build()
        server = MockWebServer()
        server.useHttps(serverCerts.sslSocketFactory(), false)
        server.start()
        val http =
            OkHttpClient
                .Builder()
                .sslSocketFactory(clientCerts.sslSocketFactory(), clientCerts.trustManager)
                .retryOnConnectionFailure(false)
                .readTimeout(30, TimeUnit.SECONDS)
                .build()
        // The JVM's HttpURLConnection refuses PATCH (Android's accepts it), so
        // the tests drive the worker through OkHttp; cancel() cancels the call
        // in flight, as the app's transport disconnects its connection.
        LargeUploadWorker.clientFactory = {
            ChunkUploadClient(
                object : ChunkTransport {
                    @Volatile
                    private var call: Call? = null

                    override fun cancel() {
                        call?.cancel()
                    }

                    override fun execute(
                        method: String,
                        url: String,
                        headers: Map<String, String>,
                        body: ByteArray?,
                    ): ChunkResponse {
                        val builder = Request.Builder().url(url)
                        headers.forEach { (k, v) -> builder.header(k, v) }
                        builder.method(method, body?.toRequestBody("application/offset+octet-stream".toMediaType()))
                        val c = http.newCall(builder.build())
                        call = c
                        return c.execute().use { response ->
                            ChunkResponse(
                                response.code,
                                response.header("Upload-Offset")?.toLongOrNull(),
                                response.body?.string().orEmpty(),
                            )
                        }
                    }
                },
            )
        }
        setUpSource()
    }

    /** Laid out as the enqueuer lays it out: <files>/large-uploads/<id>/source. */
    private fun setUpSource() {
        val job =
            File(
                File(
                    java.nio.file.Files
                        .createTempDirectory("lu")
                        .toFile(),
                    LargeUploadWorker.JOBS_DIR,
                ),
                "r1",
            ).apply { mkdirs() }
        source = File(job, "source").apply { writeBytes(ByteArray(size.toInt()) { (it % 251).toByte() }) }
    }

    @After
    fun tearDown() {
        server.shutdown()
        LargeUploadWorker.clientFactory = { ChunkUploadClient() }
    }

    private fun worker(name: String? = "launch-walkthrough.mov"): LargeUploadWorker =
        TestListenableWorkerBuilder
            .from(RuntimeEnvironment.getApplication(), LargeUploadWorker::class.java)
            .setInputData(
                workDataOf(
                    LargeUploadWorker.KEY_ID to "r1",
                    LargeUploadWorker.KEY_URL to server.url("/chat/attachments/upload/tok").toString(),
                    LargeUploadWorker.KEY_PATH to source.absolutePath,
                    LargeUploadWorker.KEY_SIZE to size,
                    LargeUploadWorker.KEY_CHUNK to 100L,
                    LargeUploadWorker.KEY_SPACE to "design-review",
                    LargeUploadWorker.KEY_NAME to name,
                ),
            ).build()

    private fun run(): ListenableWorker.Result = runBlocking { worker().doWork() }

    private val context get() = RuntimeEnvironment.getApplication()
    private val shadowNotifications get() =
        shadowOf(context.getSystemService(NotificationManager::class.java))

    /** The text of the posted notification with [id], or null when none is posted. */
    private fun posted(id: Int): String? =
        shadowNotifications
            .getNotification(id)
            ?.extras
            ?.getCharSequence(Notification.EXTRA_TEXT)
            ?.toString()

    private fun title(id: Int): String? =
        shadowNotifications
            .getNotification(id)
            ?.extras
            ?.getCharSequence(Notification.EXTRA_TITLE)
            ?.toString()

    private val waitingId = LargeUploadWorker.waitingNotificationId("r1")
    private val progressId = LargeUploadWorker.notificationId("r1")
    private val resultId = LargeUploadWorker.resultNotificationId("r1")

    @Test
    fun `a mid-chunk failure retries, and the next run resumes from the HEAD offset, never zero`() {
        val tus = TusServer(stored = 0, dropOn = setOf(2))
        server.dispatcher = tus

        // Run 1: HEAD 0, PATCH 0 ok, PATCH 100 drops after 50 bytes reached the server.
        assertEquals(ListenableWorker.Result.retry(), run())
        assertEquals(listOf("HEAD", "PATCH 0", "PATCH 100"), tus.log)

        // Run 2 (WorkManager's retry): HEAD reads 150 and the upload carries on from there.
        tus.log.clear()
        val result = run()
        assertTrue(result is ListenableWorker.Result.Success)
        assertEquals(listOf("HEAD", "PATCH 150", "PATCH 250"), tus.log)
        assertFalse(tus.log.contains("PATCH 0"))
        assertEquals(size, tus.stored)
        assertFalse("the local copy is cleaned up", source.exists())
        assertFalse("and its job directory", source.parentFile!!.exists())
    }

    @Test
    fun `a 409 adopts the server offset`() {
        // HEAD answers a stale 0 (another run raced it); the server really holds 120.
        val tus = TusServer(stored = 120, headReports = 0)
        server.dispatcher = tus

        assertTrue(run() is ListenableWorker.Result.Success)
        assertEquals(listOf("HEAD", "PATCH 0", "PATCH 120", "PATCH 220"), tus.log)
    }

    @Test
    fun `a retry leaves a Waiting for connection notification posted`() {
        server.dispatcher = TusServer(stored = 0, dropOn = setOf(2))

        assertEquals(ListenableWorker.Result.retry(), run())

        // The run is over (WorkManager tears its foreground notification down);
        // the waiting state outlives it under its own id, with the last progress.
        assertEquals("Waiting for connection · 100 of 300 bytes", posted(waitingId))
        assertEquals("Waiting for connection", title(waitingId))
        val waiting = shadowNotifications.getNotification(waitingId)!!
        assertTrue("ongoing", waiting.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertTrue("bar held indeterminate", waiting.extras.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE))
        assertNull("the progress notification went with the run", posted(progressId))
    }

    @Test
    fun `a lost network aborts the chunk in flight and yields retry`() {
        // PATCH 2 reaches the server, which never answers: the link is dead.
        val tus = TusServer(stored = 0, holdOn = setOf(2))
        server.dispatcher = tus
        try {
            val result = AtomicReference<ListenableWorker.Result>()
            val thread = Thread { result.set(run()) }.apply { start() }
            assertTrue("PATCH 2 in flight", tus.held.await(10, TimeUnit.SECONDS))
            val connectivity = context.getSystemService(ConnectivityManager::class.java)
            val callbacks = shadowOf(connectivity).networkCallbacks
            assertEquals("the worker watches the default network", 1, callbacks.size)

            val lostAt = System.nanoTime()
            callbacks.forEach { it.onLost(connectivity.activeNetwork ?: ShadowNetwork.newInstance(1)) }
            thread.join(10_000)

            // Well under the 30 s read timeout: the abort ended it, not a timeout.
            val waitedMs = (System.nanoTime() - lostAt) / 1_000_000
            assertTrue("ended ${waitedMs}ms after the loss", waitedMs < 5_000)
            assertEquals(ListenableWorker.Result.retry(), result.get())
            assertEquals(listOf("HEAD", "PATCH 0", "PATCH 100"), tus.log.toList())
            assertEquals("Waiting for connection · 100 of 300 bytes", posted(waitingId))
            assertTrue("the callback is unregistered", shadowOf(connectivity).networkCallbacks.isEmpty())
        } finally {
            tus.release.countDown()
        }
    }

    @Test
    fun `WorkManager stopping the run aborts the chunk and leaves the waiting notification`() {
        // What the reviewer hit: the CONNECTED constraint goes unmet and
        // WorkManager stops the worker (its foreground notification goes too).
        val tus = TusServer(stored = 0, holdOn = setOf(2))
        server.dispatcher = tus
        try {
            val worker = worker()
            val future = worker.startWork()
            assertTrue("PATCH 2 in flight", tus.held.await(10, TimeUnit.SECONDS))
            val stoppedAt = System.nanoTime()
            // WorkManager's WorkerWrapper stops a worker by cancelling its future.
            future.cancel(true)
            val deadline = System.currentTimeMillis() + 5_000
            while (posted(waitingId) == null && System.currentTimeMillis() < deadline) Thread.sleep(20)
            assertEquals("Waiting for connection · 100 of 300 bytes", posted(waitingId))
            assertTrue("aborted promptly", (System.nanoTime() - stoppedAt) / 1_000_000 < 5_000)
            assertTrue(future.isCancelled)
        } finally {
            tus.release.countDown()
        }
    }

    @Test
    fun `the next run clears the waiting notification when it starts, then resumes`() {
        val tus = TusServer(stored = 0, dropOn = setOf(2))
        server.dispatcher = tus
        assertEquals(ListenableWorker.Result.retry(), run())
        assertTrue(posted(waitingId) != null)

        var waitingAtHead: String? = "unset"
        var progressAtHead: String? = null
        tus.onHead = {
            waitingAtHead = posted(waitingId)
            progressAtHead = posted(progressId)
        }
        tus.log.clear()
        assertTrue(run() is ListenableWorker.Result.Success)

        assertNull("cleared before the run's first request", waitingAtHead)
        // The resumed run shows progress again, starting from the last known bytes.
        assertEquals("100 of 300 bytes", progressAtHead)
        assertNull(posted(waitingId))
        assertEquals(listOf("HEAD", "PATCH 150", "PATCH 250"), tus.log.toList())
        assertEquals("Sent to #design-review", posted(resultId))
    }

    @Test
    fun `an expired reservation on HEAD says so`() {
        for (status in listOf(404, 410)) {
            setUpSource()
            server.dispatcher = TusServer(stored = 0, headStatus = status)
            val result = run()
            assertTrue(result is ListenableWorker.Result.Failure)
            assertEquals(
                "Couldn't send launch-walkthrough.mov to #design-review: " +
                    "the upload expired after the connection was lost too long. Share it again.",
                posted(resultId),
            )
            assertNull(posted(progressId))
            assertNull(posted(waitingId))
            assertFalse("the local copy is cleaned up", source.exists())
        }
    }

    @Test
    fun `an expired reservation on PATCH says so`() {
        server.dispatcher = TusServer(stored = 0, patchStatus = mapOf(2 to 410))
        assertTrue(run() is ListenableWorker.Result.Failure)
        assertEquals(
            "Couldn't send launch-walkthrough.mov to #design-review: " +
                "the upload expired after the connection was lost too long. Share it again.",
            posted(resultId),
        )
    }

    @Test
    fun `any other failure posts a clear failure notification`() {
        server.dispatcher = TusServer(stored = 0, patchStatus = mapOf(1 to 403))
        assertTrue(run() is ListenableWorker.Result.Failure)
        assertEquals(
            "Couldn't send launch-walkthrough.mov to #design-review: the server refused the upload (HTTP 403). Share it again.",
            posted(resultId),
        )
        assertNull(posted(progressId))
    }

    @Test
    fun `a normal run keeps a progress notification posted`() {
        val tus = TusServer(stored = 0)
        var progressAtSecondPatch: String? = null
        server.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    if (request.method == "PATCH" && tus.patches == 1) progressAtSecondPatch = posted(progressId)
                    return tus.dispatch(request)
                }
            }
        assertTrue(run() is ListenableWorker.Result.Success)
        // Visible mid-run (throttled to ~1/s, so still the first tick here).
        assertEquals("0 of 300 bytes", progressAtSecondPatch)
        // Never deferred the 10 s Android 12+ applies to foreground-service notifications.
        // (The getter is hidden in the SDK stubs; read the field it returns.)
        val behavior = Notification::class.java.getDeclaredField("mFgsDeferBehavior").apply { isAccessible = true }
        assertEquals(Notification.FOREGROUND_SERVICE_IMMEDIATE, behavior.getInt(LargeUploadWorker.progressNotification(context, 1, 300)))
        assertEquals(Notification.FOREGROUND_SERVICE_IMMEDIATE, behavior.getInt(LargeUploadWorker.waitingNotification(context, 1, 300)))
        // Done: the progress notification is replaced by the result.
        assertNull(posted(progressId))
        assertEquals("Sent to #design-review", posted(resultId))
    }

    @Test
    fun `progress copy and the unique work name`() {
        assertEquals("412 of 900 MB", LargeUploadWorker.progressText(412_000_000, 900_000_000))
        assertEquals("Waiting for connection · 377.4 of 899.1 MB", LargeUploadWorker.waitingText(377_356_288, 899_109_076))
        assertEquals("Sent to #design-review", LargeUploadWorker.sentText("design-review"))
        assertEquals("burrow-large-upload-r1", LargeUploadWorker.workName("r1"))
    }
}
