package com.koboai.burrow.share

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.IntentCompat
import java.io.IOException
import java.io.InputStream

/**
 * What an ACTION_SEND / ACTION_SEND_MULTIPLE intent carries: the streams as
 * [SharedFile]s (name, type and size read from the provider, never the
 * bytes) and any shared text or link.
 */
object ShareIntents {
    data class Shared(
        val files: List<SharedFile>,
        val text: String?,
    )

    /** Queries the provider: run off the main thread. */
    fun parse(
        resolver: ContentResolver,
        intent: Intent,
    ): Shared {
        val uris =
            when (intent.action) {
                Intent.ACTION_SEND ->
                    listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
                Intent.ACTION_SEND_MULTIPLE ->
                    IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
                else -> emptyList()
            }
        val text =
            listOfNotNull(intent.getStringExtra(Intent.EXTRA_SUBJECT), intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString())
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .distinct()
                .joinToString("\n")
                .ifEmpty { null }
        val files = uris.filter { it.scheme == ContentResolver.SCHEME_CONTENT }.map { file(resolver, it, intent.type) }
        return Shared(files, text)
    }

    private fun file(
        resolver: ContentResolver,
        uri: Uri,
        intentType: String?,
    ): SharedFile {
        var name: String? = null
        var size: Long? = null
        try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val s = c.getColumnIndex(OpenableColumns.SIZE)
                    if (n >= 0 && !c.isNull(n)) name = c.getString(n)
                    if (s >= 0 && !c.isNull(s)) size = c.getLong(s)
                }
            }
        } catch (_: SecurityException) {
            // No read grant: the size is measured below, which fails the same way.
        }
        val type = resolver.getType(uri) ?: intentType?.takeIf { !it.contains('*') } ?: "application/octet-stream"
        val open: () -> InputStream = { resolver.openInputStream(uri) ?: throw IOException("unreadable share") }
        val measured = size ?: measure(open)
        return SharedFile(name ?: uri.lastPathSegment ?: "file", type, measured, open)
    }

    /** A provider that reports no size: count the bytes (never holding them). */
    private fun measure(open: () -> InputStream): Long =
        try {
            open().use { input ->
                val buffer = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                }
                total
            }
        } catch (_: Exception) {
            Long.MAX_VALUE
        }
}
