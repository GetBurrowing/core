package com.koboai.burrow.voice.pocket

import com.getcapacitor.JSObject
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executor

/**
 * Fetches one file over HTTP into a staging file. [HttpRangeFetcher] is the
 * real one; tests inject a fake.
 */
interface PocketFetcher {
    /**
     * Appends the bytes of [url] from [offset] on to [staging], creating it
     * when absent. A server that ignores the range sends the whole file, and
     * the staging file is rewritten from zero. [progress] gets the staging
     * file's size each time it grows. Throws [IOException] on failure.
     */
    fun fetch(
        url: String,
        staging: File,
        offset: Long,
        progress: (Long) -> Unit,
    )
}

/** Loads the engine once the files are in place (the `compiling` state). */
fun interface PocketLoader {
    fun load()
}

/** The model's state, exactly the JS `MODEL_STATES` (`voice_tab_native_runtime.js`). */
sealed class PocketModelState(
    val name: String,
) {
    data object Absent : PocketModelState("absent")

    data class Downloading(
        val received: Long,
        val total: Long,
    ) : PocketModelState("downloading")

    data object Compiling : PocketModelState("compiling")

    data object Ready : PocketModelState("ready")

    data class Failed(
        val reason: String,
    ) : PocketModelState("failed")

    companion object {
        val NAMES = listOf("absent", "downloading", "compiling", "ready", "failed")
    }
}

/**
 * Pocket TTS files on this phone (task 01a21e4a stage 3): absent until first
 * use, then downloaded from the pinned revision ([PocketManifest]), checked,
 * and loaded. Mirrors iOS `PocketModelStore.swift`.
 *
 * - Never bundled in the APK or AAB; fetched on FIRST USE only.
 * - Under `noBackupFilesDir/pocket-tts/<revision>/`: excluded from backup,
 *   and not the cache dir, which the system can evict mid-use.
 * - Each file lands as `<path>.part` and is moved into place only once its
 *   size and SHA-256 match the manifest. A mismatch deletes the part and
 *   fails with `checksum`; nothing unverified is ever in place.
 * - An interrupted download resumes from the part's size (HTTP Range).
 * - No auth token: the repository is ungated.
 *
 * One owner: [prepare] runs the work on [worker] (a single thread), and every
 * state change is delivered through [post] (the main thread).
 */
class PocketModelStore(
    val directory: File,
    val files: List<PocketFile>,
    private val fetcher: PocketFetcher,
    private val loader: PocketLoader?,
    private val worker: Executor,
    private val post: (() -> Unit) -> Unit,
    private val urlFor: (PocketFile) -> String = PocketManifest::url,
) {
    val total: Long = files.sumOf { it.size }

    /** Every state change, including each progress step (never backwards). Main thread. */
    var onChange: ((PocketModelState) -> Unit)? = null

    var state: PocketModelState = if (allPresent() && loader == null) PocketModelState.Ready else PocketModelState.Absent
        private set

    private var running = false

    /** The last `downloading` figure sent: progress never goes backwards. */
    private var reported = -1L

    fun local(file: PocketFile): File = File(directory, file.path)

    /** `{state, received, total, reason}`. */
    fun data(): JSObject {
        val (received, reason) =
            when (val s = state) {
                is PocketModelState.Downloading -> s.received to null
                PocketModelState.Compiling, PocketModelState.Ready -> total to null
                is PocketModelState.Failed -> 0L to s.reason
                PocketModelState.Absent -> 0L to null
            }
        return JSObject()
            .put("state", state.name)
            .put("received", received)
            .put("total", total)
            .put("reason", reason ?: JSONObject.NULL)
    }

    /** Starts the download (or only the load, if the files are there). Idempotent while running or ready. */
    fun prepare() {
        if (running || state == PocketModelState.Ready) return
        running = true
        worker.execute { run() }
    }

    /** Deletes every file (debug `pocket_reset`). */
    fun reset() {
        directory.deleteRecursively()
        reported = -1
        set(PocketModelState.Absent)
    }

    private fun set(next: PocketModelState) {
        post {
            if (next !is PocketModelState.Downloading) running = next == PocketModelState.Compiling
            if (state == next) return@post
            state = next
            onChange?.invoke(next)
        }
    }

    private fun report(received: Long) {
        if (received <= reported) return
        // A step per 0.1% at most (the bridge carries every one), and always the last byte.
        if (received - reported < total / 1000 && received < total && reported >= 0) return
        reported = received
        set(PocketModelState.Downloading(received, total))
    }

    private fun allPresent(): Boolean = files.all { local(it).length() == it.size }

    private fun run() {
        var done = 0L
        for (file in files) {
            val target = local(file)
            if (target.length() == file.size) {
                done += file.size
                continue
            }
            target.parentFile?.mkdirs()
            val part = File(target.path + ".part")
            val before = done
            try {
                report(before + part.length())
                fetcher.fetch(urlFor(file), part, part.length()) { size -> report(before + size) }
            } catch (_: IOException) {
                // The part stays: the next prepare() resumes from it.
                set(PocketModelState.Failed("network"))
                return
            }
            if (part.length() != file.size || sha256(part) != file.sha256) {
                part.delete()
                set(PocketModelState.Failed("checksum"))
                return
            }
            if (!part.renameTo(target)) {
                part.delete()
                set(PocketModelState.Failed("storage"))
                return
            }
            done += file.size
            report(done)
        }
        if (loader == null) {
            set(PocketModelState.Ready)
            return
        }
        set(PocketModelState.Compiling)
        try {
            loader.load()
            set(PocketModelState.Ready)
        } catch (_: Exception) {
            set(PocketModelState.Failed("load"))
        }
    }

    companion object {
        fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(1 shl 16)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    digest.update(buffer, 0, n)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
    }
}

/** `HttpURLConnection` with a `Range` header (the app's transports are URLConnection-based; no new library). */
class HttpRangeFetcher : PocketFetcher {
    override fun fetch(
        url: String,
        staging: File,
        offset: Long,
        progress: (Long) -> Unit,
    ) {
        var next: String = url
        var connection: HttpURLConnection
        // Hugging Face answers a resolve URL with a redirect to its CDN host.
        var hops = 0
        while (true) {
            connection = URL(next).openConnection() as HttpURLConnection
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            if (offset > 0) connection.setRequestProperty("Range", "bytes=$offset-")
            val code = connection.responseCode
            if (code in 300..399 && hops < 5) {
                val location = connection.getHeaderField("Location") ?: throw IOException("redirect without Location")
                next = URL(URL(next), location).toString()
                connection.disconnect()
                hops++
                continue
            }
            break
        }
        try {
            val append =
                when (connection.responseCode) {
                    HttpURLConnection.HTTP_PARTIAL -> true
                    HttpURLConnection.HTTP_OK -> false
                    416 -> return // already complete: the checksum decides
                    else -> throw IOException("HTTP ${connection.responseCode}")
                }
            var size = if (append) staging.length() else 0L
            FileOutputStream(staging, append).use { out ->
                connection.inputStream.use { input ->
                    val buffer = ByteArray(1 shl 16)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        out.write(buffer, 0, n)
                        size += n
                        progress(size)
                    }
                }
            }
        } finally {
            connection.disconnect()
        }
    }
}
