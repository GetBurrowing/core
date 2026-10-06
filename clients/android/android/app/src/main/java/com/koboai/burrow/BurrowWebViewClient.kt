package com.koboai.burrow

import android.webkit.WebResourceRequest
import android.webkit.WebView
import com.getcapacitor.Bridge
import com.getcapacitor.BridgeWebViewClient

/**
 * Capacitor's WebViewClient with the shell's NavigationPolicy in front of
 * Capacitor's own rule. Capacitor's plugin hook (`shouldOverrideLoad`) only
 * sees the URL; this sees whether the navigation is the main frame, which
 * the policy needs.
 */
class BurrowWebViewClient(
    bridge: Bridge,
    private val shell: MainActivity,
) : BridgeWebViewClient(bridge) {
    override fun shouldOverrideUrlLoading(
        view: WebView,
        request: WebResourceRequest,
    ): Boolean = shell.handleNavigation(request.url.toString(), request.isForMainFrame) ?: super.shouldOverrideUrlLoading(view, request)

    override fun onPageFinished(
        view: WebView,
        url: String?,
    ) {
        super.onPageFinished(view, url)
        shell.pageFinished(url)
    }

    override fun doUpdateVisitedHistory(
        view: WebView,
        url: String?,
        isReload: Boolean,
    ) {
        super.doUpdateVisitedHistory(view, url, isReload)
        shell.updateBackState()
    }
}
