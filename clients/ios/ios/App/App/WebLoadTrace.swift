import Foundation
import OSLog
import WebKit

/// Task 01a17d1f: the first cold launch can show a blank web view. This traces
/// every web load the shell issues and every navigation event WebKit reports,
/// under one subsystem and category, so CI can read what happened
/// (`log show --predicate 'subsystem == "burrow.webload"'`).
///
/// Only the URL scheme and path are logged, never a host or query.
enum WebLoadLog {
    static let subsystem = "burrow.webload"
    static let category = "navigation"
    static let logger = Logger(subsystem: subsystem, category: category)

    /// `scheme:path`, nothing else.
    static func describe(_ url: URL?) -> String {
        guard let url else { return "none" }
        let path = url.path.isEmpty ? "/" : url.path
        return "\(url.scheme ?? "?"):\(path)"
    }

    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "domain=\(nsError.domain) code=\(nsError.code)"
    }
}

/// Sits in front of Capacitor's navigation delegate. Logs the navigation
/// lifecycle and forwards every call, unchanged, to Capacitor's handler.
final class WebLoadTracingDelegate: NSObject, WKNavigationDelegate {
    private weak var target: WKNavigationDelegate?
    /// Navigations started (provisional) and not yet finished or failed.
    private(set) var inFlight = 0

    init(target: WKNavigationDelegate?) {
        self.target = target
        super.init()
    }

    // Everything not implemented below reaches Capacitor's handler through
    // the Objective-C forwarding path, so its behaviour is untouched.
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (target?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let target, target.responds(to: aSelector) { return target }
        return super.forwardingTarget(for: aSelector)
    }

    /// The shell is about to call `load`/`reload`.
    func noteShellLoad(_ reason: String, url: URL?, webView: WKWebView?) {
        WebLoadLog.logger.notice(
            "shell-load reason=\(reason, privacy: .public) url=\(WebLoadLog.describe(url), privacy: .public) inFlight=\(self.inFlight) isLoading=\(webView?.isLoading ?? false) current=\(WebLoadLog.describe(webView?.url), privacy: .public)"
        )
    }

    private func finishOne() { inFlight = max(0, inFlight - 1) }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        inFlight += 1
        WebLoadLog.logger.notice("didStartProvisional url=\(WebLoadLog.describe(webView.url), privacy: .public) inFlight=\(self.inFlight)")
        target?.webView?(webView, didStartProvisionalNavigation: navigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        WebLoadLog.logger.notice("didCommit url=\(WebLoadLog.describe(webView.url), privacy: .public) inFlight=\(self.inFlight)")
        target?.webView?(webView, didCommit: navigation)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishOne()
        WebLoadLog.logger.notice("didFinish url=\(WebLoadLog.describe(webView.url), privacy: .public) inFlight=\(self.inFlight)")
        target?.webView?(webView, didFinish: navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishOne()
        WebLoadLog.logger.notice(
            "didFail url=\(WebLoadLog.describe(webView.url), privacy: .public) \(WebLoadLog.describe(error), privacy: .public) inFlight=\(self.inFlight)")
        target?.webView?(webView, didFail: navigation, withError: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishOne()
        WebLoadLog.logger.notice(
            "didFailProvisional url=\(WebLoadLog.describe(webView.url), privacy: .public) \(WebLoadLog.describe(error), privacy: .public) inFlight=\(self.inFlight)")
        target?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        WebLoadLog.logger.notice(
            "webContentProcessDidTerminate url=\(WebLoadLog.describe(webView.url), privacy: .public) inFlight=\(self.inFlight) committed=\(webView.url != nil)")
        target?.webViewWebContentProcessDidTerminate?(webView)
    }
}
