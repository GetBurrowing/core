package com.koboai.burrow

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import org.json.JSONObject
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.URL
import java.net.UnknownHostException

/**
 * What a check of a typed address found (task 01a12787). Offline is kept
 * apart from not found, because they ask the person to do different things.
 */
sealed interface InstallCheck {
    data class Found(
        val name: String?,
    ) : InstallCheck

    data object NotFound : InstallCheck

    data object Offline : InstallCheck
}

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
     * DEBUG/TEST SEAM: answers [probe], [check] and [reachable] in-process (the debug
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

    /**
     * [probe], but telling an offline device apart from a host that is not
     * Burrow: a host that does not resolve or refuses the connection while
     * the device has no validated network is [InstallCheck.Offline].
     */
    fun check(
        host: String,
        networkValidated: () -> Boolean,
    ): InstallCheck {
        probeOverride?.let { override -> return override(host)?.let { InstallCheck.Found(it.name) } ?: InstallCheck.NotFound }
        return try {
            val install = Install(host)
            val health = fetchJsonOrThrow(install.healthUrl)
            val manifest = if (health?.optString("status") == "ok") fetchJsonOrThrow(install.manifestUrl) else null
            if (manifest == null || (!manifest.has("name") && !manifest.has("short_name"))) {
                InstallCheck.NotFound
            } else {
                InstallCheck.Found(manifest.optString("name").ifEmpty { manifest.optString("short_name") }.ifEmpty { null })
            }
        } catch (e: Exception) {
            classify(e, networkValidated())
        }
    }

    /** A failed check: offline only when the error is a connection one AND no network is validated. */
    fun classify(
        error: Exception,
        networkValidated: Boolean,
    ): InstallCheck =
        if ((error is UnknownHostException || error is ConnectException) && !networkValidated) {
            InstallCheck.Offline
        } else {
            InstallCheck.NotFound
        }

    /** True when the active network has been validated (it reaches the internet). */
    fun networkValidated(context: Context): Boolean {
        val connectivity = context.getSystemService(ConnectivityManager::class.java) ?: return false
        val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
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

    /** [fetchJson] that lets a connection error through, for [check] to classify. Null when the host answered but not 200. */
    private fun fetchJsonOrThrow(url: String): JSONObject? =
        open(url)?.let { connection ->
            try {
                JSONObject(connection.inputStream.bufferedReader().use { it.readText() })
            } finally {
                connection.disconnect()
            }
        }

    // No `Accept: application/json`: /health answers that with 406
    // (measured on a production install for iOS, 2026-10-04).
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
