package com.koboai.burrow.push

import android.content.Context
import androidx.core.app.NotificationManagerCompat
import com.koboai.burrow.AndroidKeyStoreCipher
import com.koboai.burrow.AppApiClient
import com.koboai.burrow.HttpTransport
import com.koboai.burrow.InstallStore
import com.koboai.burrow.KeystoreTokenStore
import com.koboai.burrow.SharedPreferencesStore
import com.koboai.burrow.TokenCipher
import com.koboai.burrow.TokenStore
import com.koboai.burrow.UrlConnectionTransport

/**
 * The push side's view of the app's stores, built from a Context so the
 * messaging service, the reply receiver and the plugin see the same
 * installs and bearers as the shell. [transportOverride] lets a test put a
 * recording transport (or a MockWebServer) behind every call.
 */
object BurrowPush {
    @Volatile
    internal var transportOverride: HttpTransport? = null

    @Volatile
    internal var tokenSourceOverride: PushTokenSource? = null

    /** Bearers for [client] (the debug reply stub); null means the Keystore store. */
    @Volatile
    internal var tokenStoreOverride: TokenStore? = null

    /** The JVM has no AndroidKeyStore; tests put a software cipher here. */
    @Volatile
    internal var cipherOverride: TokenCipher? = null

    fun installs(context: Context): InstallStore =
        InstallStore(
            SharedPreferencesStore(context, InstallStore.PREFS_FILE),
            SharedPreferencesStore(context, InstallStore.DEVICE_FILE),
        )

    fun tokens(context: Context): KeystoreTokenStore =
        KeystoreTokenStore(SharedPreferencesStore(context, KeystoreTokenStore.PREFS_FILE), cipherOverride ?: AndroidKeyStoreCipher())

    fun prefs(context: Context): PushPrefs = PushPrefs(SharedPreferencesStore(context, PushPrefs.FILE))

    /** A client on [context]'s bearers. [timeoutMillis] bounds each connect and read. */
    fun client(
        context: Context,
        timeoutMillis: Int = 20_000,
    ): AppApiClient = AppApiClient(tokenStoreOverride ?: tokens(context), transportOverride ?: UrlConnectionTransport(timeoutMillis))

    fun tokenSource(context: Context): PushTokenSource = tokenSourceOverride ?: PushTokenSources.forContext(context)

    fun registrar(
        context: Context,
        tokens: PushTokenSource = tokenSource(context),
    ): PushRegistrar = PushRegistrar(client(context), tokens, context.packageName, installs(context).appInstallId)

    /** Installs with a stored bearer: the ones this phone receives push for. */
    fun signedInHosts(context: Context): List<String> {
        val tokens = tokens(context)
        return installs(context).installs.map { it.host }.filter { tokens.token(it) != null }
    }

    /**
     * Both channels for every signed-in install, plus [extraHost]'s. With
     * none, nothing is created: a channel pair for an install nobody uses
     * would sit in Android settings for good.
     */
    fun ensureChannels(
        context: Context,
        extraHost: String? = null,
    ) {
        val installs = installs(context).installs
        val hosts = (signedInHosts(context) + listOfNotNull(extraHost)).distinct()
        val names = installs.associate { it.host to it.displayName }
        NotificationChannels.ensure(context, hosts, names)
    }

    fun notificationsEnabled(context: Context): Boolean = NotificationManagerCompat.from(context).areNotificationsEnabled()
}
