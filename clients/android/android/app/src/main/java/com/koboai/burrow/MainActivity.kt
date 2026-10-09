package com.koboai.burrow

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.View
import android.view.ViewGroup
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.activity.enableEdgeToEdge
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.core.view.WindowCompat
import com.getcapacitor.BridgeActivity
import com.koboai.burrow.push.BurrowPush
import com.koboai.burrow.push.NotificationPresenter
import com.koboai.burrow.push.PushPayload
import com.koboai.burrow.shortcuts.ConversationShortcuts
import com.koboai.burrow.widgets.CountsRepository
import com.koboai.burrow.widgets.WidgetRefresh
import kotlinx.coroutines.runBlocking
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The shell: Capacitor's bridge around the selected install's web UI.
 * Mirrors iOS `SuiteBridgeViewController`.
 *
 * - edge to edge: the WebView draws under transparent system bars and the
 *   web UI pads itself with `env(safe-area-inset-*)` (`viewport-fit=cover`
 *   in root.html.heex). Capacitor 8's SystemBars plugin passes the insets
 *   through to the page on WebView 140+, and on older WebViews pads the
 *   WebView natively instead (README, "System bars");
 * - the status bar icons follow the web UI's `data-theme`;
 * - the install host stays in the view, every other host opens in the
 *   browser ([NavigationPolicy] through [BurrowWebViewClient]);
 * - back walks the WebView's history, then falls through to the system's
 *   predictive back-to-home.
 */
class MainActivity :
    BridgeActivity(),
    LaunchRouter.Shell {
    private lateinit var store: InstallStore
    private lateinit var pickerReturn: PickerReturn
    private lateinit var tokens: KeystoreTokenStore
    private lateinit var client: AppApiClient
    private lateinit var exposure: NativeBridgeExposure

    private val io: ExecutorService = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private var currentInstall: Install? = null

    /** The install in the WebView, for the plugin (push registers there). */
    val currentHost: String? get() = currentInstall?.host
    private var policy: NavigationPolicy? = null
    private var auth: AuthSession? = null
    private var authTabShown = false
    private var lastHandoffAt = 0L
    private var signingOutHost: String? = null
    private var clearHistoryOnFinish = false
    private var started = false
    private var pendingIntent: Intent? = null
    private val router = LaunchRouter(this)

    private var picker: InstallPickerView? = null
    private lateinit var cover: View
    private lateinit var back: OnBackPressedCallback

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        store = InstallStore(SharedPreferencesStore(this, InstallStore.PREFS_FILE), SharedPreferencesStore(this, InstallStore.DEVICE_FILE))
        pickerReturn = PickerReturn(store)
        tokens = KeystoreTokenStore(SharedPreferencesStore(this, KeystoreTokenStore.PREFS_FILE), AndroidKeyStoreCipher())
        client = AppApiClient(tokens)
        registerPlugin(SuiteNativePlugin::class.java)
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)

        exposure = NativeBridgeExposure(bridge)
        bridge.setWebViewClient(BurrowWebViewClient(bridge, this))
        val surface = ContextCompat.getColor(this, R.color.burrow_surface)
        bridge.webView.setBackgroundColor(surface)

        // Hides the WebView while it is between installs, so one install's
        // page never shows under another's sign-in.
        cover = View(this).apply { setBackgroundColor(surface) }
        (bridge.webView.parent as ViewGroup).addView(cover, ViewGroup.LayoutParams(MATCH, MATCH))
        cover.visibility = View.GONE

        back =
            object : OnBackPressedCallback(false) {
                override fun handleOnBackPressed() {
                    goBack()
                }
            }
        onBackPressedDispatcher.addCallback(this, back)

        started = true
        ensureNotificationChannels()
        WidgetRefresh.schedule(this)
        val launchIntent = pendingIntent ?: intent
        pendingIntent = null
        router.onLaunch(launchIntent, restored = savedInstanceState != null)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (!started) {
            // BridgeActivity.load() replays the launch intent from inside
            // onCreate, before this activity is set up.
            pendingIntent = intent
            return
        }
        router.onNewIntent(intent)
    }

    /** The login callback's code, for the sign-in this activity started. */
    override fun completeSignIn(code: String) {
        val session = auth
        auth = null
        authTabShown = false
        if (session == null || session.install.host != currentInstall?.host) {
            presentPicker()
            return
        }
        val deviceName = deviceName()
        val installId = store.appInstallId
        io.execute {
            val handoff =
                try {
                    session.complete(code, client, tokens, installId, deviceName)
                } catch (_: ApiException) {
                    null
                }
            main.post {
                if (currentInstall?.host != session.install.host) return@post
                if (handoff != null) {
                    bridge.webView.loadUrl(handoff)
                    // Signed in: the widgets can go live.
                    WidgetRefresh.now(this)
                } else {
                    signInFailed()
                }
            }
        }
    }

    override fun onPause() {
        super.onPause()
        if (auth != null) authTabShown = true
    }

    override fun onResume() {
        super.onResume()
        // Foreground: refresh the widget counts.
        WidgetRefresh.now(this)
        // Back from the Custom Tab without a callback: the person closed it.
        if (auth != null && authTabShown) {
            auth = null
            authTabShown = false
            abandonInstall()
        }
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }

    // Notifications

    /**
     * A notification's Open (or tap): switch to its install if that is not
     * the one showing, then load `https://<install_host><url>` after the
     * handoff. The path was guarded when the notification was built
     * ([com.koboai.burrow.push.PushPayload.safePath]) and is guarded again
     * here, since an intent is input. An install that is no longer on this
     * phone just brings the app forward.
     */
    override fun openFromNotification(intent: Intent): Boolean {
        if (intent.action != NotificationPresenter.ACTION_OPEN) return false
        val path = PushPayload.safePath(intent.getStringExtra(NotificationPresenter.EXTRA_PATH))
        val host = intent.getStringExtra(NotificationPresenter.EXTRA_HOST)?.let { InstallStore.normalizeHost(it) }
        intent.getStringExtra(NotificationPresenter.EXTRA_TAG)?.let { tag ->
            NotificationManagerCompat.from(this).cancel(tag, NotificationPresenter.NOTIFICATION_ID)
        }
        // Consumed: a recreated activity must not replay it.
        intent.action = null
        openInstallAt(host, path)
        return true
    }

    /** A conversation shortcut: the same switch-and-load as a notification's Open. */
    override fun openConversation(
        host: String?,
        path: String,
    ) {
        openInstallAt(host, PushPayload.safePath(path))
    }

    /**
     * Shows [path] on [host]'s install, switching to it first when another
     * is showing. An install that is no longer on this phone just brings the
     * app forward.
     */
    private fun openInstallAt(
        host: String?,
        path: String,
    ) {
        val install = host?.let { h -> store.installs.firstOrNull { it.host == h } }
        when {
            install == null -> if (currentInstall == null) startWithSelection()
            install.host == currentInstall?.host && picker == null -> bridge.webView.loadUrl("https://${install.host}$path")
            else -> open(install, "https://${install.host}$path")
        }
    }

    override fun startWithSelection() {
        if (store.hasConfirmedSelection && store.selectedInstall != null) open(store.selectedInstall!!, null) else presentPicker()
    }

    /** Mentions and Approvals for every signed-in install (first launch, and each launch after). */
    private fun ensureNotificationChannels() {
        val app = applicationContext
        io.execute { BurrowPush.ensureChannels(app) }
    }

    // Install lifecycle

    /**
     * Loads an install. With a bearer the WebView is signed in through
     * `POST /api/app/handoff` ([InstallLauncher]); without one, or on a 401,
     * the native sign-in runs.
     */
    fun open(
        install: Install,
        destination: String?,
    ) {
        dismissPicker()
        if (currentInstall?.host != install.host) {
            cover.visibility = View.VISIBLE
            bridge.webView.stopLoading()
            clearHistoryOnFinish = true
        }
        currentInstall = install
        signingOutHost = null
        pickerReturn.clear()
        policy = NavigationPolicy(install.host)
        exposure.expose(install.host)
        store.select(install.host)
        store.confirmSelection()
        launch(install, destination)
    }

    private fun launch(
        install: Install,
        destination: String?,
    ) {
        lastHandoffAt = SystemClock.elapsedRealtime()
        val launcher = InstallLauncher(client, tokens, ::removeShortcuts)
        io.execute {
            val step = launcher.start(install, destination)
            main.post {
                if (currentInstall?.host != install.host) return@post
                when (step) {
                    is LaunchStep.Load -> bridge.webView.loadUrl(step.url)
                    LaunchStep.SignIn -> signIn(install)
                }
            }
        }
    }

    private fun signIn(install: Install) {
        val session = AuthSession(install)
        auth = session
        authTabShown = false
        try {
            session.launch(this)
        } catch (_: ActivityNotFoundException) {
            auth = null
            signInFailed()
        }
    }

    private fun signInFailed() {
        Toast.makeText(this, R.string.sign_in_failed, Toast.LENGTH_LONG).show()
        abandonInstall()
    }

    /**
     * A sign-in that did not finish: nothing of the install is in the
     * WebView, so the picker is the only screen (back does not dismiss it
     * onto an empty page).
     */
    private fun abandonInstall() {
        currentInstall = null
        policy = null
        presentPicker()
    }

    /**
     * The web "Log out": revoke the device and the session, forget the
     * bearer, then run the web `/auth/logout` in the view so the web cookie
     * goes too. Its redirect to the identity provider is not opened in the
     * browser; the sign-out ends on the install picker.
     */
    private fun signOut(install: Install) {
        signingOutHost = install.host
        cover.visibility = View.VISIBLE
        val signOut = NativeSignOut(client, tokens, store.appInstallId, ::removeShortcuts)
        io.execute {
            signOut.run(install.host)
            // The old account's counts must not show under the next sign-in.
            runBlocking { CountsRepository.forContext(applicationContext).forget(install.host) }
            WidgetRefresh.now(applicationContext)
            main.post {
                if (signingOutHost != install.host) return@post
                bridge.webView.loadUrl("https://${install.host}/auth/logout")
            }
        }
    }

    private fun finishSignOut() {
        signingOutHost = null
        currentInstall = null
        policy = null
        presentPicker()
    }

    /**
     * The launcher's "Switch install": the picker, remembering the current
     * install so back returns to it with its selection intact.
     */
    override fun presentSwitchPicker() {
        pickerReturn.onPresent(switching = true)
        presentPicker()
    }

    override fun presentPicker() {
        pickerReturn.onPresent(switching = false)
        picker?.let {
            it.reload()
            return
        }
        val view =
            InstallPickerView(this, store, ::removeShortcuts) { install ->
                open(install, null)
            }
        (bridge.webView.parent as ViewGroup).addView(view, ViewGroup.LayoutParams(MATCH, MATCH))
        picker = view
        view.reload()
        updateBackState()
    }

    private fun dismissPicker() {
        val view = picker ?: return
        (view.parent as? ViewGroup)?.removeView(view)
        picker = null
        pickerReturn.clear()
        updateBackState()
    }

    // Navigation policy

    /**
     * True when the navigation was taken over (cancelled), false to let it
     * load, null to leave it to Capacitor (no install open: the bundled page).
     */
    fun handleNavigation(
        url: String,
        isMainFrame: Boolean,
    ): Boolean? {
        val policy = policy ?: return null
        val install = currentInstall ?: return null
        val decision = policy.decide(url, isMainFrame)
        if (signingOutHost == install.host) {
            return when (decision) {
                // The shell's own load of /auth/logout, after NativeSignOut.
                NavigationDecision.SIGN_OUT, NavigationDecision.ALLOW -> false
                // The end-session redirect, or the signed-out install asking
                // for a login: the sign-out is done.
                else -> {
                    main.post { finishSignOut() }
                    true
                }
            }
        }
        return when (decision) {
            NavigationDecision.ALLOW -> false
            NavigationDecision.BLOCK -> true
            NavigationDecision.OPEN_EXTERNALLY -> {
                openExternally(url)
                true
            }
            NavigationDecision.START_NATIVE_LOGIN -> {
                main.post {
                    // A handoff that did not take lands here; do not loop on it.
                    if (SystemClock.elapsedRealtime() - lastHandoffAt < HANDOFF_GRACE_MS) {
                        signIn(install)
                    } else {
                        launch(install, null)
                    }
                }
                true
            }
            NavigationDecision.SIGN_OUT -> {
                main.post { signOut(install) }
                true
            }
        }
    }

    private fun openExternally(url: String) {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, url.toUri()).addCategory(Intent.CATEGORY_BROWSABLE))
        } catch (_: ActivityNotFoundException) {
            // Nothing handles it; stay put.
        }
    }

    fun pageFinished(url: String?) {
        val host = url?.toUri()?.host?.lowercase()
        if (host != null && host == currentInstall?.host?.lowercase()) {
            cover.visibility = View.GONE
            if (clearHistoryOnFinish) {
                // Back must not walk into the bundled page or another install.
                clearHistoryOnFinish = false
                bridge.webView.clearHistory()
            }
            syncStatusBarWithWebTheme()
        }
        updateBackState()
    }

    // Back

    fun updateBackState() {
        if (!::back.isInitialized) return
        val picker = picker
        back.isEnabled =
            if (picker != null) {
                pickerReturn.decide(picker.hasSubScreen, currentInstall?.host) != PickerBack.SYSTEM
            } else {
                bridge.webView.canGoBack()
            }
    }

    private fun goBack() {
        val picker = picker
        if (picker != null) {
            when (pickerReturn.decide(picker.hasSubScreen, currentInstall?.host)) {
                PickerBack.CLOSE_SUB_SCREEN -> picker.handleBack()
                PickerBack.DISMISS_TO_CURRENT -> {
                    // A row tap selected another install; it was not picked.
                    pickerReturn.restoreSelection()
                    dismissPicker()
                }
                PickerBack.OPEN_RESTORED -> pickerReturn.restoreSelection()?.let { open(it, null) }
                PickerBack.SYSTEM -> Unit
            }
        } else if (bridge.webView.canGoBack()) {
            bridge.webView.goBack()
        }
        updateBackState()
    }

    // Status bar

    /**
     * The status bar sits over the web UI's top bar, so its icons follow
     * the web theme (a person can pick a theme that differs from Android's).
     * Without a readable theme they follow the system.
     */
    private fun syncStatusBarWithWebTheme() {
        bridge.webView.evaluateJavascript("document.documentElement.getAttribute('data-theme')") { value ->
            val dark =
                when (value?.trim('"')) {
                    "dark" -> true
                    "light" -> false
                    else -> (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
                }
            WindowCompat.getInsetsController(window, window.decorView).isAppearanceLightStatusBars = !dark
        }
    }

    /** One install's conversation shortcuts, after its sign-out, revocation or removal. */
    private fun removeShortcuts(host: String) {
        ConversationShortcuts.forContext(applicationContext).removeForHost(host)
    }

    private fun deviceName(): String = Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME) ?: Build.MODEL

    companion object {
        private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        private const val HANDOFF_GRACE_MS = 15_000L
    }
}
