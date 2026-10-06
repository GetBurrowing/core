package com.koboai.burrow

import java.net.URI
import java.net.URLDecoder

/**
 * The login callback the server redirects to: `burrow://auth/callback?code=…`.
 *
 * Any app can declare the `burrow` scheme, so another app may receive a
 * code meant for Burrow. That code is useless without the PKCE verifier,
 * which never leaves this process (README, "Login").
 */
object AuthCallback {
    const val SCHEME = "burrow"
    const val HOST = "auth"
    const val PATH = "/callback"

    /** The `code` from an exact `burrow://auth/callback` URI; null for anything else. */
    fun code(uri: String?): String? {
        if (uri == null) return null
        val parsed =
            try {
                URI(uri)
            } catch (_: Exception) {
                return null
            }
        if (!SCHEME.equals(parsed.scheme, ignoreCase = true)) return null
        if (!HOST.equals(parsed.host, ignoreCase = true)) return null
        if (parsed.path != PATH) return null
        if (parsed.userInfo != null || parsed.port != -1) return null
        val query = parsed.rawQuery ?: return null
        return query
            .split('&')
            .firstOrNull { it.substringBefore('=') == "code" }
            ?.substringAfter('=', "")
            ?.let { URLDecoder.decode(it, "UTF-8") }
            ?.takeIf { it.isNotEmpty() }
    }
}
