package com.koboai.burrow

import android.annotation.SuppressLint
import androidx.webkit.ScriptHandler
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.getcapacitor.Bridge
import com.getcapacitor.JSExport
import com.getcapacitor.MessageHandler

/**
 * Gives the selected install's pages `window.Capacitor` and the `SuiteNative` plugin.
 *
 * Capacitor Android injects its bridge only into its own origin
 * (`https://localhost`) and accepts plugin messages only from its allowed
 * origins, so a remote install would never see `SuiteNative`. Capacitor's
 * `server.allowNavigation` is not the answer: it routes those hosts through
 * Capacitor's local proxy, which re-issues every request. Instead, for
 * exactly ONE origin at a time, the current install:
 *
 * 1. the same bridge script Capacitor builds is added as a document-start
 *    script for that origin only;
 * 2. that origin is added to the bridge's allowed origins and the
 *    `androidBridge` message listener is re-registered with them, so plugin
 *    calls from main-frame pages of that origin reach the bridge. Iframes
 *    are still refused (Capacitor's MessageHandler checks isMainFrame).
 *
 * A switch to another install removes the previous origin first.
 */
class NativeBridgeExposure(
    private val bridge: Bridge,
) {
    private var script: ScriptHandler? = null
    private var origin: String? = null

    companion object {
        private const val LISTENER = "androidBridge"
        private val PLUGIN_IDS = listOf("SuiteNative", "CapacitorCookies", "CapacitorHttp", "WebView", "SystemBars")

        val supported: Boolean
            get() =
                WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT) &&
                    WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)
    }

    @SuppressLint("RequiresFeature") // checked by [supported]
    fun expose(host: String) {
        if (!supported) return
        val next = "https://${host.lowercase()}"
        if (next == origin) return
        val webView = bridge.webView

        script?.remove()
        script = WebViewCompat.addDocumentStartJavaScript(webView, bridgeScript(), setOf(next))

        val rules = bridge.allowedOriginRules
        origin?.let { rules.remove(it) }
        rules.add(next)
        origin = next
        WebViewCompat.removeWebMessageListener(webView, LISTENER)
        // Registers `androidBridge` again, now with the install's origin.
        MessageHandler(bridge, webView, null)
    }

    private fun bridgeScript(): String {
        val context = bridge.context
        val handles = PLUGIN_IDS.mapNotNull { bridge.getPlugin(it) }
        return listOf(
            JSExport.getGlobalJS(context, false, bridge.isDevMode),
            "window.WEBVIEW_SERVER_URL = '${bridge.localUrl}';",
            JSExport.getBridgeJS(context),
            JSExport.getPluginJS(handles),
        ).joinToString("\n\n")
    }
}
