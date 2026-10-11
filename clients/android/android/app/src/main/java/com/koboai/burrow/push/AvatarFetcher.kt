package com.koboai.burrow.push

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.SystemClock
import android.util.Log
import android.util.LruCache
import androidx.core.graphics.scale
import com.koboai.burrow.AppApiClient
import com.koboai.burrow.TokenStore
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLSocketFactory

/**
 * The sender's picture for a notification (task 01a12773 stage 3), from the
 * push's `author_avatar_url`. Every failure returns null and the caller
 * draws the letter disc ([com.koboai.burrow.shortcuts.Monogram]); a push is
 * never late or missing because of its avatar.
 *
 * The rules, each pinned by a test (AvatarFetcherTest):
 * - https only.
 * - The install's bearer goes ONLY to a URL on the install's own host
 *   ([AppApiClient.sameHost]); an OIDC picture on another host is fetched
 *   with no Authorization header at all.
 * - No redirect is followed, and a 3xx is a failure, so a bearer can never
 *   ride a redirect to another host.
 * - Bounded: connect and read timeouts of at most [TIMEOUT_MS] each, AND a
 *   total wall-clock deadline of [DEADLINE_MS] (the read timeout is per
 *   read, so a host that drips one byte a second would pass it), enforced
 *   by waiting on a Future and disconnecting when it lapses.
 * - At most [MAX_BYTES] of body, accepting any media type, decoded down to
 *   at most [MAX_PX] on a side.
 * - Cached by the FULL url (the server's `?v=` token changes the url when
 *   the bytes change): in memory, and on disk under `cacheDir/avatars/`
 *   because FCM often wakes a cold process. A failure is remembered for
 *   [NEGATIVE_MS], so a dead host costs one bounded attempt, not one per
 *   message.
 *
 * Logs a status or a failure kind only: never a url, a host or a header.
 */
class AvatarFetcher(
    private val tokens: TokenStore,
    private val cacheDir: File?,
    private val sslSocketFactory: SSLSocketFactory? = null,
    private val connectTimeoutMs: Int = TIMEOUT_MS,
    private val readTimeoutMs: Int = TIMEOUT_MS,
    private val deadlineMs: Long = DEADLINE_MS,
    private val clock: () -> Long = SystemClock::elapsedRealtime,
) {
    private val memory = LruCache<String, Bitmap>(MEMORY_ENTRIES)
    private val failedUntil = ConcurrentHashMap<String, Long>()

    /**
     * The avatar for [url], from cache or the network, or null. Blocks for at
     * most about [deadlineMs]: call it off the main thread (the FCM worker).
     */
    fun fetch(
        url: String?,
        installHost: String?,
    ): Bitmap? {
        val target = usable(url) ?: return null
        cached(target)?.let { return it }
        val until = failedUntil[target]
        if (until != null && clock() < until) return null
        val bitmap = download(target, installHost)
        if (bitmap == null) {
            failedUntil[target] = clock() + NEGATIVE_MS
        } else {
            failedUntil.remove(target)
            memory.put(target, bitmap)
            writeDisk(target, bitmap)
        }
        return bitmap
    }

    /** Memory, then disk; never the network. The reply and restore paths use only this. */
    fun cached(url: String?): Bitmap? {
        val target = usable(url) ?: return null
        memory.get(target)?.let { return it }
        val file = diskFile(target) ?: return null
        if (!file.isFile) return null
        val bitmap = BitmapFactory.decodeFile(file.path) ?: return null
        memory.put(target, bitmap)
        return bitmap
    }

    private fun usable(url: String?): String? {
        val text = url?.trim()?.ifEmpty { null } ?: return null
        return text.takeIf { it.startsWith("https://", ignoreCase = true) }
    }

    private fun download(
        url: String,
        installHost: String?,
    ): Bitmap? {
        val connection = AtomicReference<HttpURLConnection?>()
        val future = EXECUTOR.submit<Bitmap?> { request(url, installHost, connection) }
        return try {
            future.get(deadlineMs, TimeUnit.MILLISECONDS)
        } catch (_: TimeoutException) {
            Log.w(TAG, "avatar fetch: deadline")
            null
        } catch (_: Exception) {
            null
        } finally {
            // A lapsed deadline leaves the worker inside a read. Interrupt it
            // (readCapped stops between reads) and close its connection on
            // another thread: HttpURLConnection.disconnect() can wait behind
            // a read in progress, and the caller must not wait with it
            // (measured: a 1 KB/s body held a same-thread disconnect for 16 s).
            future.cancel(true)
            connection.get()?.let { open -> EXECUTOR.execute { open.disconnect() } }
        }
    }

    private fun request(
        url: String,
        installHost: String?,
        holder: AtomicReference<HttpURLConnection?>,
    ): Bitmap? {
        val connection = URL(url).openConnection() as? HttpURLConnection ?: return null
        holder.set(connection)
        try {
            if (connection !is HttpsURLConnection) return null
            sslSocketFactory?.let { connection.sslSocketFactory = it }
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.connectTimeout = connectTimeoutMs
            connection.readTimeout = readTimeoutMs
            connection.setRequestProperty("Accept", "*/*")
            if (installHost != null && AppApiClient.sameHost(url, installHost)) {
                tokens.token(installHost)?.let { connection.setRequestProperty("Authorization", "Bearer $it") }
            }
            val status = connection.responseCode
            if (status != HttpURLConnection.HTTP_OK) {
                Log.w(TAG, "avatar fetch: status $status")
                return null
            }
            if (connection.contentLengthLong > MAX_BYTES) {
                Log.w(TAG, "avatar fetch: dropped, content-length over cap")
                return null
            }
            val bytes = connection.inputStream.use { readCapped(it) } ?: return null
            return decode(bytes)
        } catch (_: IOException) {
            Log.w(TAG, "avatar fetch: network")
            return null
        } finally {
            connection.disconnect()
        }
    }

    private fun readCapped(stream: InputStream): ByteArray? {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(8_192)
        while (true) {
            // Cancelled at the deadline: stop between reads.
            if (Thread.currentThread().isInterrupted) return null
            val read = stream.read(buffer)
            if (read < 0) break
            if (out.size() + read > MAX_BYTES) {
                Log.w(TAG, "avatar fetch: dropped, body over cap")
                return null
            }
            out.write(buffer, 0, read)
        }
        return out.toByteArray()
    }

    private fun writeDisk(
        url: String,
        bitmap: Bitmap,
    ) {
        val file = diskFile(url) ?: return
        try {
            file.parentFile?.mkdirs()
            val temp = File(file.path + ".part")
            temp.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            if (!temp.renameTo(file)) temp.delete()
        } catch (_: IOException) {
            // A cache that cannot be written is only a cache.
        }
    }

    private fun diskFile(url: String): File? {
        val dir = cacheDir ?: return null
        return File(File(dir, DISK_DIR), sha256(url) + ".png")
    }

    companion object {
        const val TIMEOUT_MS = 1_500
        const val DEADLINE_MS = 2_500L
        const val MAX_BYTES = 256 * 1024
        const val MAX_PX = 192
        const val NEGATIVE_MS = 10 * 60 * 1_000L
        const val DISK_DIR = "avatars"
        private const val MEMORY_ENTRIES = 64
        private const val TAG = "BurrowAvatar"

        // Daemon threads: a fetch abandoned at its deadline must never keep
        // the process alive.
        private val EXECUTOR: ExecutorService =
            Executors.newCachedThreadPool { runnable ->
                Thread(runnable, "burrow-avatar").apply { isDaemon = true }
            }

        fun sha256(text: String): String =
            MessageDigest
                .getInstance("SHA-256")
                .digest(text.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }

        /** Decodes [bytes], sampled and scaled so neither side exceeds [MAX_PX]; null if not an image. */
        fun decode(bytes: ByteArray): Bitmap? {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_PX) sample *= 2
            val options = BitmapFactory.Options().apply { inSampleSize = sample }
            val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
            val side = maxOf(decoded.width, decoded.height)
            if (side <= MAX_PX) return decoded
            val scale = MAX_PX.toFloat() / side
            return decoded.scale(maxOf(1, (decoded.width * scale).toInt()), maxOf(1, (decoded.height * scale).toInt()))
        }
    }
}
