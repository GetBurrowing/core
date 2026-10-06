package com.koboai.burrow

import android.app.Activity
import androidx.browser.customtabs.CustomTabColorSchemeParams
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.content.ContextCompat
import androidx.core.net.toUri

/**
 * Native sign-in for one install. Mirrors `clients/ios/ios/App/App/AuthSession.swift`.
 *
 * 1. A Chrome Custom Tab opens `https://<host>/auth/login?app_challenge=<S256>`.
 *    The Custom Tab is the browser itself, so passkeys work there; they do
 *    not in a third-party WebView (README, "Login").
 * 2. The server's OIDC callback lands on `burrow://auth/callback?code=…`,
 *    which MainActivity's intent filter receives ([AuthCallback]).
 * 3. `POST /api/app/session` swaps the code plus the verifier for a bearer
 *    and a `handoff_url` ([complete]).
 * 4. The bearer goes to the Keystore store and the WebView loads the
 *    handoff URL, which signs the WebView in.
 *
 * The verifier exists only in this object, in memory. Neither it, the code
 * nor the bearer is ever logged.
 */
class AuthSession(
    val install: Install,
    private val verifier: String = Pkce.makeVerifier(),
) {
    companion object {
        fun loginUrl(
            host: String,
            challenge: String,
        ): String = "https://$host/auth/login?app_challenge=$challenge"
    }

    val loginUrl: String get() = loginUrl(install.host, Pkce.challenge(verifier))

    fun launch(activity: Activity) {
        val colours =
            CustomTabColorSchemeParams
                .Builder()
                .setToolbarColor(ContextCompat.getColor(activity, R.color.burrow_surface))
                .build()
        CustomTabsIntent
            .Builder()
            .setDefaultColorSchemeParams(colours)
            .setShowTitle(true)
            .setShareState(CustomTabsIntent.SHARE_STATE_OFF)
            .build()
            .launchUrl(activity, loginUrl.toUri())
    }

    /** Steps 3 and 4. Blocks: run off the main thread. Returns the handoff URL. */
    fun complete(
        code: String,
        client: AppApiClient,
        tokens: MutableTokenStore,
        appInstallId: String,
        deviceName: String,
    ): String {
        val grant = client.exchangeSession(install.host, code, verifier, appInstallId, deviceName)
        if (!tokens.store(install.host, grant.token)) {
            throw ApiException(ApiException.Kind.BAD_RESPONSE, route = AppApiClient.SESSION_PATH)
        }
        return grant.handoffUrl
    }

    override fun toString(): String = "AuthSession(${install.host})"
}
