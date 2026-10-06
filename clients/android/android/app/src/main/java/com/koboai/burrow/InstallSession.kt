package com.koboai.burrow

import java.net.URI

/** What the shell does next to put a signed-in install in the WebView. */
sealed class LaunchStep {
    /** Load this URL (a one-time handoff URL, or the page itself). */
    data class Load(
        val url: String,
    ) : LaunchStep() {
        // A handoff URL carries a one-time code in its query.
        override fun toString(): String = "Load(<url>)"
    }

    /** No usable bearer: run the native Custom Tab sign-in. */
    object SignIn : LaunchStep() {
        override fun toString(): String = "SignIn"
    }
}

/**
 * Opens an install on its stored bearer instead of a new sign-in. Mirrors
 * iOS `InstallLauncher`.
 *
 * The install's `_platform_session` cookie has no max_age, so it dies with
 * the app process: on a cold start or an install switch the WebView is
 * signed out even though the Keystore holds a bearer. With a bearer,
 * `POST /api/app/handoff` returns a one-time URL that signs the WebView back
 * in, so there is no passkey ceremony per cold start. A 401 means the bearer
 * was revoked: it is removed and the native sign-in runs. Any other failure
 * (offline, a 5xx) loads the page itself.
 *
 * Blocks: run off the main thread.
 */
class InstallLauncher(
    private val client: AppApiClient,
    private val tokens: MutableTokenStore,
) {
    fun start(
        install: Install,
        destination: String?,
    ): LaunchStep {
        if (!client.isSignedIn(install.host)) return LaunchStep.SignIn
        return try {
            LaunchStep.Load(client.handoff(install.host, localPath(destination, install.host)))
        } catch (e: ApiException) {
            if (e.kind == ApiException.Kind.STATUS && e.status == 401) {
                tokens.remove(install.host)
                LaunchStep.SignIn
            } else {
                LaunchStep.Load(destination ?: install.baseUrl)
            }
        }
    }

    companion object {
        /** The path (and query) of [url] when it is on [host]; null for the root or anything else. */
        fun localPath(
            url: String?,
            host: String,
        ): String? {
            if (url == null) return null
            val uri =
                try {
                    URI(url)
                } catch (_: Exception) {
                    return null
                }
            if (!host.equals(uri.host, ignoreCase = true)) return null
            val path = uri.rawPath.orEmpty().ifEmpty { "/" }
            val local = uri.rawQuery?.let { "$path?$it" } ?: path
            return if (local == "/") null else local
        }
    }
}

/**
 * Native sign-out for one install, run when the web UI navigates to
 * `/auth/logout`:
 *
 * 1. `DELETE /api/app/devices/:app_install_id`, so pushes stop;
 * 2. `DELETE /api/app/session`, so the bearer is revoked server-side (the
 *    server also drops this session's fcm_devices row);
 * 3. the bearer leaves the Keystore store.
 *
 * The bearer is removed whatever the server answered: a person who signed
 * out offline is signed out on this phone.
 *
 * Blocks: run off the main thread.
 */
class NativeSignOut(
    private val client: AppApiClient,
    private val tokens: MutableTokenStore,
    private val appInstallId: String,
) {
    fun run(host: String) {
        try {
            client.delete(host, AppApiClient.devicePath(appInstallId))
        } catch (_: ApiException) {
            // A device that was never registered answers 404; carry on.
        }
        try {
            client.delete(host, AppApiClient.SESSION_PATH)
        } catch (_: ApiException) {
            // Offline or already revoked: the local bearer goes regardless.
        }
        tokens.remove(host)
    }
}
