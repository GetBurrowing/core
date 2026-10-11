package com.koboai.burrow.push

import android.content.Context
import androidx.core.app.NotificationManagerCompat
import com.koboai.burrow.AndroidKeyStoreCipher
import com.koboai.burrow.AppApiClient
import com.koboai.burrow.HttpTransport
import com.koboai.burrow.InstallStore
import com.koboai.burrow.KeystoreTokenStore
import com.koboai.burrow.R
import com.koboai.burrow.SharedPreferencesStore
import com.koboai.burrow.TokenCipher
import com.koboai.burrow.TokenStore
import com.koboai.burrow.UrlConnectionTransport
import com.koboai.burrow.widgets.DataStoreCountsStore

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

    /** The push-key cipher; tests put a software cipher here (the JVM has no AndroidKeyStore). */
    @Volatile
    internal var pushKeyCipherOverride: TokenCipher? = null

    /**
     * Called on the main thread after a push changed a stored unread count,
     * while the shell is in the foreground (MainActivity sets it in
     * onResume, clears it in onPause): the shell re-fires
     * `burrowInstallBadges` and refreshes an open picker.
     */
    @Volatile
    var unreadChanged: (() -> Unit)? = null

    fun installs(context: Context): InstallStore =
        InstallStore(
            SharedPreferencesStore(context, InstallStore.PREFS_FILE),
            SharedPreferencesStore(context, InstallStore.DEVICE_FILE),
            SharedPreferencesStore(context, UnreadStore.FILE),
        )

    fun pushKeys(context: Context): PushKeyStore =
        PushKeyStore(SharedPreferencesStore(context, PushKeyStore.PREFS_FILE), pushKeyCipherOverride ?: PushKeyStore.cipher())

    /** Per-install unread counts, over the signed-in installs. */
    fun unread(context: Context): UnreadStore = UnreadStore(SharedPreferencesStore(context, UnreadStore.FILE)) { signedInHosts(context) }

    fun preparer(context: Context): PushContentPreparer {
        val keys = pushKeys(context)
        return PushContentPreparer(
            privateKey = { keys.privateKey(it) },
            unread = unread(context),
            installs = { installs(context).installs },
            signedInHosts = { signedInHosts(context) },
            fallbackBody = { context.getString(R.string.push_fallback_body, it) },
        )
    }

    fun reconciler(context: Context): UnreadReconciler = UnreadReconciler(UnreadReconciler.fetcher(client(context)), unread(context))

    /** The app open's one counts request per install: unread badges plus the widgets' cache. */
    fun resumeRefresh(context: Context): ResumeRefresh = ResumeRefresh(reconciler(context), DataStoreCountsStore(context))

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
    ): PushRegistrar {
        val keys = pushKeys(context)
        return PushRegistrar(
            client(context),
            tokens,
            context.packageName,
            installs(context).appInstallId,
            publicKey = { keys.publicKey(it) },
        )
    }

    /**
     * [host]'s display name when two or more installs are signed in, else
     * null: the one rule for naming the install on a notification (subtext,
     * conversation title, conversation shortcut label).
     */
    fun installLabel(
        context: Context,
        host: String,
    ): String? {
        if (signedInHosts(context).size < 2) return null
        return installs(context).installs.firstOrNull { it.host == host }?.displayName ?: host
    }

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
