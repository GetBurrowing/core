package com.koboai.burrow.share

import com.koboai.burrow.ApiException
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.math.BigDecimal
import java.math.RoundingMode
import java.net.HttpURLConnection
import java.net.URL

/**
 * `GET /api/app/upload_config` (task 01a120be): the install's limits. The
 * share sheet never holds the per-file limit as a constant; it reads it here.
 */
data class UploadConfig(
    /** The largest file one upload may carry on this install. */
    val maxUploadBytes: Long,
    /** [maxUploadBytes] as the server words it ("1 GB"). */
    val maxUploadLabel: String,
    /** The largest body one chunked PATCH may carry. */
    val chunkBytes: Long,
    /**
     * The largest multipart REQUEST body the server's parser takes
     * (Plug.Parsers' 8_000_000). At or under it a file keeps the multipart
     * `POST /api/app/spaces/:id/messages`.
     */
    val multipartMaxBytes: Long,
) {
    companion object {
        const val PATH = "/api/app/upload_config"

        fun parse(body: String): UploadConfig =
            try {
                val o = JSONObject(body)
                UploadConfig(
                    o.getLong("max_upload_bytes"),
                    o.getString("max_upload_label"),
                    o.getLong("chunk_bytes"),
                    o.getLong("multipart_max_bytes"),
                )
            } catch (_: JSONException) {
                throw ApiException(ApiException.Kind.BAD_RESPONSE, route = PATH)
            }
    }
}

/** `POST /api/app/spaces/:space_id/uploads`: a reserved chunked upload. */
data class UploadReservation(
    val id: String,
    /** A path on the install; the token in it is the only auth. */
    val uploadUrl: String,
    val chunkBytes: Long,
    val offset: Long,
) {
    /** The absolute `https://<host>/chat/attachments/upload/<token>`. */
    fun absoluteUrl(host: String): String = if (uploadUrl.startsWith("https://")) uploadUrl else "https://$host$uploadUrl"

    companion object {
        fun uploadsPath(spaceId: String) = "/api/app/spaces/$spaceId/uploads"

        fun parse(body: String): UploadReservation =
            try {
                val o = JSONObject(body)
                UploadReservation(o.getString("id"), o.getString("upload_url"), o.getLong("chunk_bytes"), o.optLong("offset", 0))
            } catch (_: JSONException) {
                throw ApiException(ApiException.Kind.BAD_RESPONSE, route = "uploads")
            }
    }
}

/**
 * The one size-label rule every Burrow surface uses (server, web, Android,
 * iOS; task 01a120be): decimal units, one decimal rounded half-up, no
 * trailing ".0", rolling over to the next unit at 1000 ("999.96 MB" reads
 * "1 GB"). Under 1000 bytes it reads "<n> bytes".
 */
object ByteLabel {
    private val units = listOf("bytes", "KB", "MB", "GB", "TB")

    fun format(bytes: Long): String {
        val k = unitFor(bytes)
        return if (k == 0) "$bytes bytes" else "${render(scaled(bytes, k))} ${units[k]}"
    }

    /** "412 of 900 MB": [sent] (clamped to [total]) in the unit [total] reads in. */
    fun progress(
        sent: Long,
        total: Long,
    ): String {
        val k = unitFor(total)
        val s = sent.coerceIn(0, maxOf(total, 0))
        return if (k == 0) {
            "$s of $total bytes"
        } else {
            "${render(scaled(s, k))} of ${render(scaled(total, k))} ${units[k]}"
        }
    }

    /** The unit index: 0 bytes, 1 KB, 2 MB, 3 GB, 4 TB. */
    private fun unitFor(bytes: Long): Int {
        if (bytes < 1000) return 0
        var k = 1
        while (k < 4 && bytes >= BigDecimal.TEN.pow(3 * (k + 1)).toLong()) k++
        if (k < 4 && scaled(bytes, k) >= THOUSAND) k++
        return k
    }

    private val THOUSAND = BigDecimal(1000)

    private fun scaled(
        bytes: Long,
        k: Int,
    ): BigDecimal = BigDecimal.valueOf(bytes).divide(BigDecimal.TEN.pow(3 * k)).setScale(1, RoundingMode.HALF_UP)

    private fun render(v: BigDecimal): String = v.stripTrailingZeros().toPlainString()
}

/** What one chunk request came back with. */
data class ChunkResponse(
    val status: Int,
    /** The server's `Upload-Offset`, when it sent one. */
    val uploadOffset: Long?,
    val body: String,
)

/** One HTTP exchange for [ChunkUploadClient]. Throws [IOException] on a network failure. */
fun interface ChunkTransport {
    @Throws(IOException::class)
    fun execute(
        method: String,
        url: String,
        headers: Map<String, String>,
        body: ByteArray?,
    ): ChunkResponse

    /**
     * Aborts the exchange in flight, from any thread, so [execute] throws
     * [IOException] now instead of when a socket timeout fires (the network
     * was lost: task 01a120be).
     */
    fun cancel() {}
}

/**
 * HttpURLConnection. Android's implementation accepts PATCH (the JVM's does
 * not, which is why tests inject an OkHttp transport instead).
 */
class UrlConnectionChunkTransport(
    private val connectTimeoutMillis: Int = 15_000,
    private val readTimeoutMillis: Int = 30_000,
) : ChunkTransport {
    @Volatile
    private var current: HttpURLConnection? = null

    /** Disconnecting from another thread makes the blocked read or write throw. */
    override fun cancel() {
        current?.disconnect()
    }

    override fun execute(
        method: String,
        url: String,
        headers: Map<String, String>,
        body: ByteArray?,
    ): ChunkResponse {
        val connection = URL(url).openConnection() as HttpURLConnection
        current = connection
        try {
            connection.requestMethod = method
            connection.connectTimeout = connectTimeoutMillis
            connection.readTimeout = readTimeoutMillis
            connection.instanceFollowRedirects = false
            headers.forEach { (k, v) -> connection.setRequestProperty(k, v) }
            if (body != null) {
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(body.size)
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            val text = if (method == "HEAD") "" else stream?.bufferedReader()?.use { it.readText() } ?: ""
            return ChunkResponse(status, connection.getHeaderField("Upload-Offset")?.toLongOrNull(), text)
        } finally {
            current = null
            connection.disconnect()
        }
    }
}

/**
 * HEAD and PATCH on a presigned upload URL (`ChatAttachmentUploadController`).
 * The token in the URL is the only auth: no bearer rides these. HTTPS only.
 */
class ChunkUploadClient(
    private val transport: ChunkTransport = UrlConnectionChunkTransport(),
) {
    @Volatile
    var aborted = false
        private set

    /**
     * Aborts the request in flight and refuses every later one with
     * [IOException], so the upload loop ends with a retry. Any thread.
     */
    fun abort() {
        aborted = true
        transport.cancel()
    }

    /** The bytes the server holds, in the response's [ChunkResponse.uploadOffset]. */
    @Throws(IOException::class)
    fun headOffset(url: String): ChunkResponse = send("HEAD", url, mapOf("Accept" to "application/json"), null)

    /** PATCH [bytes] at [offset]. */
    @Throws(IOException::class)
    fun patchChunk(
        url: String,
        offset: Long,
        bytes: ByteArray,
    ): ChunkResponse =
        send(
            "PATCH",
            url,
            mapOf(
                "Accept" to "application/json",
                "Upload-Offset" to offset.toString(),
                "Content-Type" to "application/offset+octet-stream",
            ),
            bytes,
        )

    private fun send(
        method: String,
        url: String,
        headers: Map<String, String>,
        body: ByteArray?,
    ): ChunkResponse {
        if (aborted) throw IOException("aborted: the network was lost")
        // A response that arrived despite a racing abort is still used: a
        // final 200 must never be turned into a retry.
        return transport.execute(method, https(url), headers, body)
    }

    private fun https(url: String): String {
        if (!url.startsWith("https://")) throw IOException("refusing a non-HTTPS request")
        return url
    }
}

/** What the share sheet hands a large file to. */
fun interface LargeUploadEnqueuer {
    /** Copies [file] into app storage and schedules its upload. Throws [IOException]. */
    @Throws(IOException::class)
    fun enqueue(
        host: String,
        reservation: UploadReservation,
        file: SharedFile,
        spaceName: String,
    )
}
