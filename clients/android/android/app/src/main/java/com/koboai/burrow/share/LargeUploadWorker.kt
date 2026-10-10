package com.koboai.burrow.share

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.koboai.burrow.R
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.concurrent.TimeUnit
import kotlin.coroutines.cancellation.CancellationException

/**
 * Uploads one large shared file in chunks (task 01a120be stage 5), after the
 * share activity is gone.
 *
 * The file was copied into app storage before the activity finished (the
 * share grant on a content URI does not outlive the activity). Each run
 * first HEADs the server's offset and resumes from it, never from zero; it
 * then PATCHes `chunk_bytes` slices with `Upload-Offset`, adopting the
 * server's offset on a 409.
 *
 * Losing the network (a default-network callback, or WorkManager stopping
 * the run because its [NetworkType.CONNECTED] constraint went unmet) aborts
 * the chunk in flight at once instead of waiting out a socket timeout, and
 * the run ends with [Result.retry]. WorkManager tears the foreground
 * notification down with the run, so a separate ongoing "Waiting for
 * connection · 377 of 899.1 MB" notification ([waitingNotificationId])
 * stays posted until the next run starts and clears it.
 *
 * Progress goes to [setProgress] and an ongoing foreground notification
 * ("412 of 900 MB"), refreshed about once a second. The server posts the
 * message when the last chunk lands; the worker only says "Sent to
 * #<space>". A reservation the server no longer has (HEAD or PATCH 404/410)
 * posts "Couldn't send <file> to #<space>: the upload expired ..."; any
 * other failure posts its own "Couldn't send" line.
 */
class LargeUploadWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    private val notifications get() = NotificationManagerCompat.from(applicationContext)

    /** Bytes the server held at the last report; persisted next to the local copy across runs. */
    @Volatile
    private var lastSent = 0L

    /** Wall clock of the last progress notification, for the ~1/s throttle. */
    private var lastNotifiedAt = 0L

    /** Deletes the local copy, and its job directory when it is one of ours. */
    private fun cleanUp(file: File) {
        file.delete()
        sentFile(file).delete()
        file.parentFile?.takeIf { it.parentFile?.name == JOBS_DIR }?.deleteRecursively()
    }

    private fun sentFile(file: File) = File(file.parentFile, "sent")

    private fun readLastSent(file: File): Long =
        try {
            val f = sentFile(file)
            if (f.exists()) f.readText().trim().toLongOrNull() ?: 0L else 0L
        } catch (_: IOException) {
            0L
        }

    private fun writeLastSent(
        file: File,
        sent: Long,
    ) {
        try {
            sentFile(file).writeText(sent.toString())
        } catch (_: IOException) {
            // Only the waiting notification's number depends on it.
        }
    }

    /** Expedited work on API < 31 runs as a foreground service with this notification. */
    override suspend fun getForegroundInfo(): ForegroundInfo =
        foregroundInfo(inputData.getString(KEY_ID).orEmpty(), 0, inputData.getLong(KEY_SIZE, 0))

    override suspend fun doWork(): Result {
        val id = inputData.getString(KEY_ID) ?: return Result.failure()
        val url = inputData.getString(KEY_URL) ?: return Result.failure()
        val path = inputData.getString(KEY_PATH) ?: return Result.failure()
        val size = inputData.getLong(KEY_SIZE, -1)
        val chunkBytes = inputData.getLong(KEY_CHUNK, 0)
        val spaceName = inputData.getString(KEY_SPACE).orEmpty()
        val file = File(path)
        val fileName = inputData.getString(KEY_NAME) ?: file.name
        if (size < 0 || chunkBytes <= 0 || !file.exists()) return Result.failure()

        // This run is the resume: the waiting state from the last one goes.
        notifications.cancel(waitingNotificationId(id))
        lastSent = readLastSent(file)
        showProgress(id, lastSent, size, force = true)

        val client = clientFactory()
        val unwatch =
            watchNetwork {
                // The default network is gone: abort the chunk in flight now.
                client.abort()
                post(notificationId(id), waitingNotification(applicationContext, lastSent, size))
            }
        val outcome =
            try {
                coroutineScope {
                    // WorkManager stopping the run (its network constraint
                    // went unmet) cancels this coroutine; a blocked socket
                    // does not notice, so abort the request too.
                    val stopWatch = launch { awaitStop(client) }
                    try {
                        withContext(Dispatchers.IO) {
                            ChunkedUpload.run(
                                file = file,
                                url = url,
                                size = size,
                                chunkBytes = chunkBytes,
                                client = client,
                            ) { sent ->
                                lastSent = sent
                                setProgress(workDataOf(KEY_SENT to sent, KEY_SIZE to size))
                                showProgress(id, sent, size, force = false, file = file)
                            }
                        }
                    } finally {
                        stopWatch.cancel()
                    }
                }
            } catch (e: CancellationException) {
                // Stopped by WorkManager: it runs the work again later, so say we are waiting.
                withContext(NonCancellable) { postWaiting(id, file, size) }
                throw e
            } finally {
                unwatch()
            }
        return when (outcome) {
            ChunkedUpload.Outcome.Done -> {
                cleanUp(file)
                notifySent(id, spaceName)
                Result.success()
            }
            ChunkedUpload.Outcome.Retry -> {
                postWaiting(id, file, size)
                Result.retry()
            }
            is ChunkedUpload.Outcome.Failed -> {
                cleanUp(file)
                notifications.cancel(notificationId(id))
                post(resultNotificationId(id), resultNotification(applicationContext, failureText(fileName, spaceName, outcome.status)))
                Result.failure(workDataOf(KEY_STATUS to outcome.status))
            }
        }
    }

    /**
     * Suspends until cancelled, then aborts [client]'s request: on a stop
     * that ends the blocked chunk; at the end of a finished run it is a no-op.
     */
    private suspend fun awaitStop(client: ChunkUploadClient) {
        try {
            awaitCancellation()
        } finally {
            client.abort()
        }
    }

    /**
     * The separate ongoing "Waiting for connection · 377 of 899.1 MB": it
     * outlives the run (the foreground notification goes with it).
     */
    private fun postWaiting(
        id: String,
        file: File,
        size: Long,
    ) {
        writeLastSent(file, lastSent)
        post(waitingNotificationId(id), waitingNotification(applicationContext, lastSent, size))
        notifications.cancel(notificationId(id))
    }

    /** Registers a default-network callback; returns its unregister. */
    private fun watchNetwork(lost: () -> Unit): () -> Unit {
        val manager = applicationContext.getSystemService(ConnectivityManager::class.java) ?: return {}
        val callback =
            object : ConnectivityManager.NetworkCallback() {
                override fun onLost(network: Network) = lost()
            }
        try {
            manager.registerDefaultNetworkCallback(callback)
        } catch (_: RuntimeException) {
            // No ACCESS_NETWORK_STATE, or too many callbacks: WorkManager's stop still aborts.
            return {}
        }
        val unregister: () -> Unit = {
            try {
                manager.unregisterNetworkCallback(callback)
            } catch (_: IllegalArgumentException) {
                // Already unregistered.
            }
        }
        return unregister
    }

    private fun foregroundInfo(
        id: String,
        sent: Long,
        size: Long,
    ): ForegroundInfo {
        val notification = progressNotification(applicationContext, sent, size)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(notificationId(id), notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(notificationId(id), notification)
        }
    }

    /**
     * The ongoing progress notification, at most about once a second (and
     * always at the start and at 100%). setForeground keeps the run a
     * foreground service; the same notification is also posted directly, so
     * it is visible even when the foreground start is refused.
     */
    private suspend fun showProgress(
        id: String,
        sent: Long,
        size: Long,
        force: Boolean,
        file: File? = null,
    ) {
        val now = System.currentTimeMillis()
        if (!force && sent < size && now - lastNotifiedAt < PROGRESS_INTERVAL_MS) return
        lastNotifiedAt = now
        file?.let { writeLastSent(it, sent) }
        try {
            setForeground(foregroundInfo(id, sent, size))
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // Not allowed to start a foreground service right now: the post below still shows it.
        }
        post(notificationId(id), progressNotification(applicationContext, sent, size))
    }

    private fun notifySent(
        id: String,
        spaceName: String,
    ) {
        notifications.cancel(notificationId(id))
        post(resultNotificationId(id), resultNotification(applicationContext, sentText(spaceName)))
    }

    private fun post(
        id: Int,
        notification: Notification,
    ) {
        try {
            notifications.notify(id, notification)
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS not granted: the upload still finishes.
        }
    }

    companion object {
        const val KEY_ID = "id"
        const val KEY_URL = "url"
        const val KEY_PATH = "path"
        const val KEY_SIZE = "size"
        const val KEY_CHUNK = "chunk_bytes"
        const val KEY_SPACE = "space"
        const val KEY_NAME = "name"
        const val KEY_SENT = "sent"
        const val KEY_STATUS = "status"
        const val CHANNEL = "burrow_uploads"
        const val JOBS_DIR = "large-uploads"
        const val PROGRESS_INTERVAL_MS = 1_000L
        const val WAITING_TITLE = "Waiting for connection"

        /** Tests swap the HTTP layer; the app uses HttpURLConnection. */
        @Volatile
        var clientFactory: () -> ChunkUploadClient = { ChunkUploadClient() }

        /** One unique work per reservation, so a duplicate enqueue collapses. */
        fun workName(reservationId: String) = "burrow-large-upload-$reservationId"

        /** The progress (foreground) notification; [resultNotificationId] and [waitingNotificationId] follow it. */
        fun notificationId(reservationId: String) = 0x5E00 + (reservationId.hashCode() and 0x0FFF) * 4

        /** "Sent to #space" or "Couldn't send ...": outlives the run. */
        fun resultNotificationId(reservationId: String) = notificationId(reservationId) + 1

        /** "Waiting for connection · ...": posted when a run ends without the network, cleared by the next run. */
        fun waitingNotificationId(reservationId: String) = notificationId(reservationId) + 2

        /** "412 of 900 MB". */
        fun progressText(
            sent: Long,
            size: Long,
        ) = ByteLabel.progress(sent, size)

        /** "Waiting for connection · 377 of 899.1 MB". */
        fun waitingText(
            sent: Long,
            size: Long,
        ) = "$WAITING_TITLE · ${progressText(sent, size)}"

        fun sentText(spaceName: String) = "Sent to #$spaceName"

        /** HEAD or PATCH 404/410: the server reaped the reservation. */
        fun isExpired(status: Int) = status == 404 || status == 410

        fun failureText(
            fileName: String,
            spaceName: String,
            status: Int,
        ): String =
            when {
                isExpired(status) ->
                    "Couldn't send $fileName to #$spaceName: the upload expired after the connection was lost too long. Share it again."
                status == 0 -> "Couldn't send $fileName to #$spaceName: the copied file could not be read. Share it again."
                else -> "Couldn't send $fileName to #$spaceName: the server refused the upload (HTTP $status). Share it again."
            }

        fun ensureChannel(context: Context): String {
            // minSdk is 26, so channels always exist.
            val manager = context.getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL, context.getString(R.string.upload_channel), NotificationManager.IMPORTANCE_LOW),
                )
            }
            return CHANNEL
        }

        fun progressNotification(
            context: Context,
            sent: Long,
            size: Long,
        ): Notification {
            val percent = if (size > 0) (sent * 100 / size).toInt() else 0
            return NotificationCompat
                .Builder(context, ensureChannel(context))
                .setSmallIcon(R.drawable.ic_stat_burrow)
                .setContentTitle(context.getString(R.string.upload_in_progress))
                .setContentText(progressText(sent, size))
                .setProgress(100, percent, false)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                // Android 12+ otherwise defers a foreground service's
                // notification by up to 10 s: show progress at once.
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .build()
        }

        /** Paused: the last progress, the bar held indeterminate until the network returns. */
        fun waitingNotification(
            context: Context,
            sent: Long,
            size: Long,
        ): Notification =
            NotificationCompat
                .Builder(context, ensureChannel(context))
                .setSmallIcon(R.drawable.ic_stat_burrow)
                .setContentTitle(WAITING_TITLE)
                .setContentText(waitingText(sent, size))
                .setProgress(0, 0, true)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .build()

        fun resultNotification(
            context: Context,
            text: String,
        ): Notification =
            NotificationCompat
                .Builder(context, ensureChannel(context))
                .setSmallIcon(R.drawable.ic_stat_burrow)
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setAutoCancel(true)
                .build()
    }
}

/** The resume loop, with the HTTP layer injected. */
object ChunkedUpload {
    sealed class Outcome {
        object Done : Outcome()

        object Retry : Outcome()

        data class Failed(
            val status: Int,
        ) : Outcome()
    }

    /** 408 (the request timed out on the server's side) and 429 are worth a retry, not a failure. */
    private fun transient(status: Int) = status == 408 || status == 429

    /** Server errors in a row before a run gives up and asks for a retry. */
    private const val MAX_SERVER_ERRORS = 3

    suspend fun run(
        file: File,
        url: String,
        size: Long,
        chunkBytes: Long,
        client: ChunkUploadClient,
        onProgress: suspend (Long) -> Unit,
    ): Outcome {
        // Every run starts from the server's offset, never from zero.
        var offset =
            try {
                val head = client.headOffset(url)
                when {
                    head.status in 200..299 && head.uploadOffset != null -> head.uploadOffset
                    head.status >= 500 || transient(head.status) -> return Outcome.Retry
                    else -> return Outcome.Failed(head.status)
                }
            } catch (_: IOException) {
                return Outcome.Retry
            }
        onProgress(offset)
        var serverErrors = 0
        RandomAccessFile(file, "r").use { input ->
            while (true) {
                val length = minOf(chunkBytes, size - offset).coerceAtLeast(0).toInt()
                val bytes = ByteArray(length)
                try {
                    input.seek(offset)
                    input.readFully(bytes)
                } catch (_: IOException) {
                    // The local copy is shorter than the reservation: nothing will fix that.
                    return Outcome.Failed(0)
                }
                val response =
                    try {
                        client.patchChunk(url, offset, bytes)
                    } catch (_: IOException) {
                        return Outcome.Retry
                    }
                when {
                    response.status == 200 -> {
                        onProgress(size)
                        return Outcome.Done
                    }
                    response.status == 204 -> {
                        offset = response.uploadOffset ?: (offset + length)
                        serverErrors = 0
                        onProgress(offset)
                    }
                    response.status == 409 && response.uploadOffset != null -> offset = response.uploadOffset
                    response.status >= 500 || transient(response.status) ->
                        if (++serverErrors > MAX_SERVER_ERRORS) return Outcome.Retry
                    else -> return Outcome.Failed(response.status)
                }
            }
        }
    }
}

/**
 * The app's [LargeUploadEnqueuer]: copies the shared file into app storage
 * (while the share grant is still live) and enqueues a unique, expedited
 * [LargeUploadWorker] for the reservation.
 */
class WorkManagerLargeUploadEnqueuer(
    private val context: Context,
) : LargeUploadEnqueuer {
    override fun enqueue(
        host: String,
        reservation: UploadReservation,
        file: SharedFile,
        spaceName: String,
    ) {
        val dir = File(File(context.filesDir, LargeUploadWorker.JOBS_DIR), reservation.id).apply { mkdirs() }
        val target = File(dir, "source")
        try {
            file.open().use { input -> target.outputStream().use { input.copyTo(it, 1 shl 20) } }
        } catch (e: IOException) {
            dir.deleteRecursively()
            throw e
        }
        schedule(
            context,
            reservation.id,
            reservation.absoluteUrl(host),
            target,
            file.size,
            reservation.chunkBytes,
            spaceName,
            file.name,
        )
    }

    companion object {
        /** Enqueues the unique, expedited, network-constrained upload of [target]. */
        fun schedule(
            context: Context,
            reservationId: String,
            url: String,
            target: File,
            size: Long,
            chunkBytes: Long,
            spaceName: String,
            fileName: String,
        ) {
            val request =
                OneTimeWorkRequestBuilder<LargeUploadWorker>()
                    .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.SECONDS)
                    .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                    .setInputData(
                        workDataOf(
                            LargeUploadWorker.KEY_ID to reservationId,
                            LargeUploadWorker.KEY_URL to url,
                            LargeUploadWorker.KEY_PATH to target.absolutePath,
                            LargeUploadWorker.KEY_SIZE to size,
                            LargeUploadWorker.KEY_CHUNK to chunkBytes,
                            LargeUploadWorker.KEY_SPACE to spaceName,
                            LargeUploadWorker.KEY_NAME to fileName,
                        ),
                    ).build()
            WorkManager
                .getInstance(context)
                .enqueueUniqueWork(LargeUploadWorker.workName(reservationId), ExistingWorkPolicy.KEEP, request)
        }
    }
}
