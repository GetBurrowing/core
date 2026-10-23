package com.koboai.burrow.push

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.koboai.burrow.HttpResponse
import com.koboai.burrow.HttpTransport
import com.koboai.burrow.TokenStore
import com.koboai.burrow.share.ChunkResponse
import com.koboai.burrow.share.ChunkTransport
import com.koboai.burrow.share.ChunkUploadClient
import com.koboai.burrow.share.LargeUploadWorker
import com.koboai.burrow.share.WorkManagerLargeUploadEnqueuer
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.Base64

/**
 * DEBUG BUILDS ONLY (`src/debug`, registered in the debug manifest). Takes
 * a base64 JSON extra, [EXTRA_PAYLOAD], and hands its FCM `message.data` to
 * [PushDispatch.handle], the same entry point [BurrowMessagingService] calls
 * for a real push (the notification, and the briefing widget's refresh on
 * an `insight_briefing`). Accepts what `fcm_stub.py` records (`{"message": {"data":
 * {...}}}`), a bare `{"data": {...}}`, or the data object itself.
 * [EXTRA_REPLY_STUB] stands in for the server on Reply.
 */
class DebugPushReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        if (intent.action != ACTION) return
        intent.getStringExtra(EXTRA_REPLY_STUB)?.toIntOrNull()?.let { stubReplies(it) }
        intent.getStringExtra(EXTRA_UPLOAD_PROGRESS)?.let { showUploadProgress(context, it) }
        intent.getStringExtra(EXTRA_UPLOAD_STUB)?.let { startStubUpload(context, it) }
        val encoded = intent.getStringExtra(EXTRA_PAYLOAD) ?: return
        val data = parse(encoded) ?: return
        PushDispatch.handle(context, data)
    }

    companion object {
        const val ACTION = "com.koboai.burrow.debug.PUSH"
        const val EXTRA_PAYLOAD = "payload"

        /**
         * `--es reply_stub 201` (or 500): until the process dies, every
         * `/api/app` call made through [BurrowPush.client] is answered
         * in-process with that status and a stand-in bearer, so Reply's sent
         * and failed states can be shown on an emulator that cannot sign in
         * (the IdP is passkey-only). Nothing is persisted and no request
         * leaves the device.
         */
        const val EXTRA_REPLY_STUB = "reply_stub"

        /**
         * GET /api/app/spaces answers [STUB_SPACES] (the share sheet's space
         * list); every other call answers [status].
         */
        private fun stubReplies(status: Int) {
            BurrowPush.tokenStoreOverride =
                object : TokenStore {
                    override fun token(host: String): String = "debug-reply-stub"
                }
            BurrowPush.transportOverride =
                HttpTransport { request ->
                    if (request.method == "GET" && request.url.endsWith("/api/app/spaces")) {
                        HttpResponse(200, STUB_SPACES)
                    } else if (request.method == "GET" && request.url.endsWith("/api/app/upload_config")) {
                        // Task 01a120be: the server's limits, as a default install sends them.
                        HttpResponse(200, STUB_UPLOAD_CONFIG)
                    } else if (request.method == "POST" && request.url.endsWith("/uploads")) {
                        HttpResponse(201, STUB_RESERVATION)
                    } else {
                        HttpResponse(status, "{}")
                    }
                }
        }

        /**
         * `--es upload_progress 412000000/900000000`: posts the large-upload
         * worker's own ongoing progress notification with those numbers, so
         * the notification can be shown without a reachable server.
         */
        const val EXTRA_UPLOAD_PROGRESS = "upload_progress"

        private fun showUploadProgress(
            context: Context,
            value: String,
        ) {
            val (sent, total) = value.split("/").mapNotNull { it.trim().toLongOrNull() }.takeIf { it.size == 2 } ?: return
            val notification =
                LargeUploadWorker
                    .progressNotification(context, sent, total)
            try {
                androidx.core.app.NotificationManagerCompat
                    .from(context)
                    .notify(0x5EFF, notification)
            } catch (_: SecurityException) {
            }
        }

        /**
         * `--es upload_stub 899109076/1000`: a DEBUG STUB upload. Writes a
         * sparse local copy of that many bytes and enqueues the REAL
         * [LargeUploadWorker] (same WorkManager
         * request, network constraint, network callback and notifications)
         * against an IN-PROCESS stand-in for the upload endpoint: HEAD answers
         * the bytes it holds, each 33,554,432-byte PATCH takes the given
         * milliseconds and is aborted by the worker's cancel like a socket.
         * No request leaves the device, so cutting wifi and data
         * (`svc wifi disable`, `svc data disable`) shows the worker's own
         * offline path: the chunk aborts, "Waiting for connection" posts, and
         * the next run resumes from the stub's HEAD offset.
         */
        const val EXTRA_UPLOAD_STUB = "upload_stub"

        private fun startStubUpload(
            context: Context,
            value: String,
        ) {
            val parts = value.split("/").mapNotNull { it.trim().toLongOrNull() }
            val size = parts.getOrNull(0) ?: return
            val delayMs = parts.getOrNull(1) ?: 1_000L
            val id = "debug-stub-upload"
            val dir =
                File(File(context.filesDir, LargeUploadWorker.JOBS_DIR), id).apply {
                    deleteRecursively()
                    mkdirs()
                }
            val target = File(dir, "source")
            RandomAccessFile(target, "rw").use { it.setLength(size) }
            val server = StubChunkServer(size, delayMs)
            LargeUploadWorker.clientFactory = {
                ChunkUploadClient(server.transport())
            }
            WorkManagerLargeUploadEnqueuer.schedule(
                context,
                id,
                "https://debug-stub.invalid/chat/attachments/upload/debug",
                target,
                size,
                STUB_CHUNK_BYTES,
                "launch-room",
                "launch-walkthrough.mov",
            )
        }

        private const val STUB_CHUNK_BYTES = 33_554_432L

        /** The in-process stand-in for `ChatAttachmentUploadController` (debug stub only). */
        private class StubChunkServer(
            val total: Long,
            val delayMs: Long,
        ) {
            @Volatile
            var stored = 0L

            fun transport(): ChunkTransport =
                object : ChunkTransport {
                    private val lock = Object()
                    private var cancelled = false

                    override fun cancel() {
                        synchronized(lock) {
                            cancelled = true
                            lock.notifyAll()
                        }
                    }

                    override fun execute(
                        method: String,
                        url: String,
                        headers: Map<String, String>,
                        body: ByteArray?,
                    ): ChunkResponse {
                        if (method == "HEAD") return ChunkResponse(200, stored, "")
                        val offset = headers["Upload-Offset"]?.toLongOrNull() ?: -1
                        val deadline = System.currentTimeMillis() + delayMs
                        synchronized(lock) {
                            while (!cancelled) {
                                val left = deadline - System.currentTimeMillis()
                                if (left <= 0) break
                                lock.wait(left)
                            }
                            if (cancelled) throw IOException("stub: aborted")
                        }
                        if (offset != stored) return ChunkResponse(409, stored, "")
                        stored += body?.size ?: 0
                        return if (stored >= total) {
                            ChunkResponse(200, stored, """{"id":"debug","message_id":"debug"}""")
                        } else {
                            ChunkResponse(204, stored, "")
                        }
                    }
                }
        }

        private const val STUB_UPLOAD_CONFIG =
            """{"max_upload_bytes":1000000000,"max_upload_label":"1 GB","chunk_bytes":33554432,"multipart_max_bytes":8000000}"""

        private const val STUB_RESERVATION =
            """{"id":"debug-reservation","upload_url":"/chat/attachments/upload/debug","chunk_bytes":33554432,"offset":0}"""

        private const val STUB_SPACES =
            """{"spaces":[
            {"id":"0192f0a1-s1","name":"Internal Acme Globex","path_segment":"internal-acme-globex","agents":[{"id":"a1","name":"Higgins"}]},
            {"id":"0192f0a1-s2","name":"Launch room","path_segment":"launch-room","agents":[]}]}"""

        /** The FCM data map from a base64 JSON payload, or null when it is not one. */
        fun parse(encoded: String): Map<String, String>? {
            val json =
                try {
                    JSONObject(String(Base64.getDecoder().decode(encoded.trim()), Charsets.UTF_8))
                } catch (_: Exception) {
                    return null
                }
            val data =
                json.optJSONObject("message")?.optJSONObject("data")
                    ?: json.optJSONObject("data")
                    ?: json
            return data.keys().asSequence().associateWith { data.get(it).toString() }
        }
    }
}
