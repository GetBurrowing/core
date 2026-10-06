package com.koboai.burrow

import java.net.URI

/** What the shell does with one WebView navigation. */
enum class NavigationDecision {
    /** Stay in the WebView. */
    ALLOW,

    /** Cancel and hand the URL to Android (the browser, mail, phone...). */
    OPEN_EXTERNALLY,

    /** Cancel and sign in natively in a Custom Tab. */
    START_NATIVE_LOGIN,

    /** Cancel, sign out natively (session, device, Keystore), then return to the picker. */
    SIGN_OUT,

    /** Cancel and do nothing: a scheme the web must never hand to Android. */
    BLOCK,
}

/**
 * The shell's navigation rule: the selected install's host stays in the
 * view; every other host opens in the external browser. Pure, so it is unit
 * tested. Mirrors `clients/ios/ios/App/App/NavigationPolicy.swift`.
 *
 * - Sub-frame loads stay whatever their host: an embed is part of the
 *   install's page, not a navigation away.
 * - The install's own `/auth/login` in the main frame is the web app asking
 *   for a sign-in. Passkeys do not complete inside a third-party WebView, so
 *   the shell runs the native Custom Tab flow instead. A URL already
 *   carrying `app_challenge` is that native flow's own URL and stays.
 * - The install's own `/auth/logout` in the main frame is the web "Log out".
 *   The app's bearer and device row outlive the web cookie, so the shell
 *   signs out natively.
 * - `burrow:` (the app's own callback scheme), `intent:`, `file:` and
 *   `content:` are blocked: a page must not be able to drive the app's own
 *   callback or another app's private components.
 */
class NavigationPolicy(
    installHost: String,
) {
    private val installHost = installHost.lowercase()

    companion object {
        val IN_VIEW_SCHEMES = setOf("about", "data", "blob")
        val BLOCKED_SCHEMES = setOf(AuthCallback.SCHEME, "intent", "file", "content", "javascript")
    }

    fun decide(
        url: String?,
        isMainFrame: Boolean,
    ): NavigationDecision {
        if (url == null) return NavigationDecision.ALLOW
        val uri =
            try {
                URI(url)
            } catch (_: Exception) {
                return if (isMainFrame) NavigationDecision.BLOCK else NavigationDecision.ALLOW
            }
        val scheme = uri.scheme?.lowercase() ?: return NavigationDecision.ALLOW
        if (scheme in IN_VIEW_SCHEMES) return NavigationDecision.ALLOW
        if (scheme in BLOCKED_SCHEMES) return NavigationDecision.BLOCK
        if (scheme != "https" && scheme != "http") return NavigationDecision.OPEN_EXTERNALLY

        val host = uri.host?.lowercase() ?: ""
        if (host != installHost) {
            return if (isMainFrame) NavigationDecision.OPEN_EXTERNALLY else NavigationDecision.ALLOW
        }
        if (isMainFrame && uri.path == "/auth/logout") return NavigationDecision.SIGN_OUT
        if (isMainFrame && uri.path == "/auth/login" && !hasQueryItem(uri, "app_challenge")) {
            return NavigationDecision.START_NATIVE_LOGIN
        }
        return NavigationDecision.ALLOW
    }

    private fun hasQueryItem(
        uri: URI,
        name: String,
    ): Boolean = (uri.rawQuery ?: "").split('&').any { it.substringBefore('=') == name }
}
