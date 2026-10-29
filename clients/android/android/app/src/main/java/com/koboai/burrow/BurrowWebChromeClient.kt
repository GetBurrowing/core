package com.koboai.burrow

import android.os.Message
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import com.getcapacitor.Bridge
import com.getcapacitor.BridgeWebChromeClient

/** Keep Capacitor's chrome features while routing popup URLs through the shell policy. */
class BurrowWebChromeClient(
    bridge: Bridge,
    private val shell: MainActivity,
) : BridgeWebChromeClient(bridge) {
    override fun onCreateWindow(
        view: WebView,
        isDialog: Boolean,
        isUserGesture: Boolean,
        resultMsg: Message,
    ): Boolean {
        val transport = resultMsg.obj as? WebView.WebViewTransport ?: return false
        // Android supplies the popup URL only after a child WebView is returned.
        // This unattached view has no JS or native bridge and never renders it.
        val popup = WebView(view.context)
        var handled = false

        fun route(url: String): Boolean {
            if (handled) return true
            handled = true
            shell.handleNavigation(url, isMainFrame = true, isNewWindow = true)
            popup.post { popup.destroy() }
            return true
        }
        popup.webViewClient =
            object : WebViewClient() {
                override fun shouldOverrideUrlLoading(
                    view: WebView,
                    request: WebResourceRequest,
                ): Boolean = route(request.url.toString())

                @Suppress("OVERRIDE_DEPRECATION")
                override fun shouldOverrideUrlLoading(
                    view: WebView,
                    url: String,
                ): Boolean = route(url)
            }
        transport.webView = popup
        resultMsg.sendToTarget()
        return true
    }
}
