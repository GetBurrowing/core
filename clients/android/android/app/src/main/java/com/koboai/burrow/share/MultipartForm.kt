package com.koboai.burrow.share

import com.koboai.burrow.HttpResponse
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.UUID

/**
 * One shared file. [open] streams its bytes; the file is never read into
 * memory whole. [toString] names no content.
 */
class SharedFile(
    val name: String,
    val mimeType: String,
    val size: Long,
    val open: () -> InputStream,
) {
    override fun toString(): String = "SharedFile($mimeType, $size bytes)"
}

/**
 * A `multipart/form-data` body: text fields plus at most one `file` part
 * (the controller takes one file per request). Mirrors iOS `MultipartForm`.
 */
class MultipartForm(
    val fields: List<Pair<String, String>>,
    val file: SharedFile?,
    val boundary: String = "burrow-${UUID.randomUUID()}",
) {
    val contentType: String get() = "multipart/form-data; boundary=$boundary"

    fun field(name: String): String? = fields.firstOrNull { it.first == name }?.second

    /** The exact body length, so the upload can stream with a fixed length. */
    fun contentLength(): Long = head().size.toLong() + (file?.size ?: 0L) + tail().size.toLong()

    fun writeTo(out: OutputStream) {
        out.write(head())
        file?.let { f -> f.open().use { it.copyTo(out, 64 * 1024) } }
        out.write(tail())
    }

    private fun head(): ByteArray {
        val sb = StringBuilder()
        for ((name, value) in fields) {
            sb.append("--").append(boundary).append(CRLF)
            sb
                .append("Content-Disposition: form-data; name=\"")
                .append(name)
                .append('"')
                .append(CRLF)
                .append(CRLF)
            sb.append(value).append(CRLF)
        }
        file?.let {
            sb.append("--").append(boundary).append(CRLF)
            sb
                .append("Content-Disposition: form-data; name=\"file\"; filename=\"")
                .append(quote(it.name))
                .append('"')
                .append(CRLF)
            sb
                .append("Content-Type: ")
                .append(it.mimeType)
                .append(CRLF)
                .append(CRLF)
        }
        return sb.toString().toByteArray(Charsets.UTF_8)
    }

    private fun tail(): ByteArray {
        val prefix = if (file != null) CRLF else ""
        return "$prefix--$boundary--$CRLF".toByteArray(Charsets.UTF_8)
    }

    override fun toString(): String = "MultipartForm(fields=${fields.map { it.first }}, file=$file)"

    companion object {
        private const val CRLF = "\r\n"

        private fun quote(name: String): String = name.replace("\"", "'").replace("\r", " ").replace("\n", " ")
    }
}

/** Sends a multipart body. Behind an interface so tests record requests. */
fun interface MultipartTransport {
    @Throws(IOException::class)
    fun post(
        url: String,
        headers: Map<String, String>,
        form: MultipartForm,
    ): HttpResponse
}

/**
 * HttpURLConnection, HTTPS only, streaming the body with a fixed length.
 * Nothing here logs: not the headers (the bearer), not the body.
 */
class UrlConnectionMultipartTransport(
    private val timeoutMillis: Int = 60_000,
) : MultipartTransport {
    override fun post(
        url: String,
        headers: Map<String, String>,
        form: MultipartForm,
    ): HttpResponse {
        val target = URL(url)
        if (target.protocol != "https") throw IOException("refusing a non-HTTPS request to ${URI(url).host}")
        val connection = target.openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = timeoutMillis
            connection.readTimeout = timeoutMillis
            connection.instanceFollowRedirects = false
            connection.doOutput = true
            headers.forEach { (k, v) -> connection.setRequestProperty(k, v) }
            connection.setRequestProperty("Content-Type", form.contentType)
            connection.setFixedLengthStreamingMode(form.contentLength())
            connection.outputStream.use { form.writeTo(it) }
            val status = connection.responseCode
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            return HttpResponse(status, stream?.bufferedReader()?.use { it.readText() } ?: "")
        } finally {
            connection.disconnect()
        }
    }
}
