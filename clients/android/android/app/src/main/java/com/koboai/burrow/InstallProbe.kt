package com.koboai.burrow

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Probes an install: `/health` must answer `{"status":"ok"}` and
 * `/manifest.json` must be a web app manifest. Both, or it is not Burrow.
 * Mirrors iOS `InstallProbe`. Every call blocks: run it off the main thread.
 */
object InstallProbe {
    class Result(
        val name: String?,
    )

    /**
     * DEBUG/TEST SEAM: answers [probe] and [reachable] in-process (the debug
     * unread receiver's emulator evidence uses it for hosts that do not
     * exist). Null in the app.
     */
    @Volatile
    internal var probeOverride: ((String) -> Result?)? = null

    fun probe(host: String): Result? {
        probeOverride?.let { return it(host) }
        val install = Install(host)
        val health = fetchJson(install.healthUrl) ?: return null
        if (health.optString("status") != "ok") return null
        val manifest = fetchJson(install.manifestUrl) ?: return null
        val name = manifest.optString("name").ifEmpty { manifest.optString("short_name") }.ifEmpty { null }
        if (!manifest.has("name") && !manifest.has("short_name")) return null
        return Result(name)
    }

    fun reachable(host: String): Boolean {
        probeOverride?.let { return it(host) != null }
        return fetchJson(Install(host).healthUrl)?.optString("status") == "ok"
    }

    fun icon(install: Install): Bitmap? =
        try {
            open(install.iconUrl)?.let { connection ->
                try {
                    connection.inputStream.use { BitmapFactory.decodeStream(it) }
                } finally {
                    connection.disconnect()
                }
            }
        } catch (_: Exception) {
            null
        }

    private fun fetchJson(url: String): JSONObject? =
        try {
            open(url)?.let { connection ->
                try {
                    JSONObject(connection.inputStream.bufferedReader().use { it.readText() })
                } finally {
                    connection.disconnect()
                }
            }
        } catch (_: Exception) {
            null
        }

    // No `Accept: application/json`: /health answers that with 406
    // (measured on suite.example.com for iOS, 2026-10-04).
    private fun open(url: String): HttpURLConnection? {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 10_000
        connection.readTimeout = 10_000
        connection.useCaches = false
        if (connection.responseCode != 200) {
            connection.disconnect()
            return null
        }
        return connection
    }
}
