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
    let recovery: WebLoadRecovery

    #if DEBUG
        /// `-BurrowInjectNavigationFailure provisional|terminate`: one injected
        /// failure of the first fixture load, for the recovery UI tests.
        private let injection = UserDefaults.standard.string(forKey: "BurrowInjectNavigationFailure")
        private var injected = false
        /// Sticky per controller: reissuing on this poisoned view must not
        /// satisfy the recreate proof. A fresh Capacitor controller opts out.
        private let injectCommittedHang: Bool
        private var committedHangInjected = false

        private func isFixture(_ url: URL?) -> Bool { url?.path.hasSuffix("/tabbar-fixture.html") ?? false }
    #endif

    init(target: WKNavigationDelegate?, recovery: WebLoadRecovery) {
        self.target = target
        self.recovery = recovery
        #if DEBUG
            injectCommittedHang = UserDefaults.standard.string(forKey: "BurrowInjectNavigationFailure") == "double-commit" && !recovery.hasRecreated
        #endif
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

    private static func failingURL(_ error: Error, _ webView: WKWebView) -> URL? {
        (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url
    }

    private func finishOne() { inFlight = max(0, inFlight - 1) }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        inFlight += 1
        WebLoadLog.logger.notice("didStartProvisional url=\(WebLoadLog.describe(webView.url), privacy: .public) inFlight=\(self.inFlight)")
        #if DEBUG
            if injection == "provisional", !injected, isFixture(webView.url) {
                injected = true
                // WebKit reports a real didFailProvisionalNavigation (-999) for
                // a stopped provisional load. Cancelling in decidePolicyFor does
                // not: it delivers no failure callback at all (run 40515959708).
                WebLoadLog.logger.notice("injected provisional failure (stopLoading) url=\(WebLoadLog.describe(webView.url), privacy: .public)")
                DispatchQueue.main.async { webView.stopLoading() }
            }
        #endif
        target?.webView?(webView, didStartProvisionalNavigation: navigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        WebLoadLog.logger.notice("didCommit url=\(WebLoadLog.describe(webView.url), privacy: .public) inFlight=\(self.inFlight)")
        recovery.didCommit(url: webView.url)
        #if DEBUG
            if injectCommittedHang, isFixture(webView.url) {
                committedHangInjected = true
                WebLoadLog.logger.notice("injected commit-without-finish on original Capacitor view")
                webView.isHidden = true
                DispatchQueue.main.async { webView.stopLoading() }
            }
            if injection == "terminate", !injected, isFixture(webView.url) {
                injected = true
                // SIMULATED: a real WebContent termination cannot be provoked
                // from here. This drives the same recovery path the real
                // callback does, without Capacitor's own reload().
                DispatchQueue.main.async { [weak self] in
                    WebLoadLog.logger.notice("webContentProcessDidTerminate (simulated, injected)")
                    self?.recovery.terminated()
                }
            }
        #endif
        target?.webView?(webView, didCommit: navigation)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        #if DEBUG
            if committedHangInjected, isFixture(webView.url) {
                WebLoadLog.logger.notice("injected finish suppressed on original Capacitor view")
                return
            }
        #endif
        finishOne()
        WebLoadLog.logger.notice("didFinish url=\(WebLoadLog.describe(webView.url), privacy: .public) inFlight=\(self.inFlight)")
        recovery.didFinish(url: webView.url)
        target?.webView?(webView, didFinish: navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishOne()
        WebLoadLog.logger.notice(
            "didFail url=\(WebLoadLog.describe(webView.url), privacy: .public) \(WebLoadLog.describe(error), privacy: .public) inFlight=\(self.inFlight)")
        recovery.failed(url: Self.failingURL(error, webView), domain: (error as NSError).domain, code: (error as NSError).code)
        target?.webView?(webView, didFail: navigation, withError: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishOne()
        WebLoadLog.logger.notice(
            "didFailProvisional url=\(WebLoadLog.describe(webView.url), privacy: .public) \(WebLoadLog.describe(error), privacy: .public) inFlight=\(self.inFlight)"
        )
        recovery.failed(url: Self.failingURL(error, webView), domain: (error as NSError).domain, code: (error as NSError).code)
        target?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        WebLoadLog.logger.notice(
            "webContentProcessDidTerminate url=\(WebLoadLog.describe(webView.url), privacy: .public) inFlight=\(self.inFlight) committed=\(webView.url != nil)")
        recovery.terminated()
        target?.webViewWebContentProcessDidTerminate?(webView)
    }
}

/// Observe Capacitor without changing its serving queue or response bytes.
/// `stop` is cancellation, not the normal success callback: terminal events
/// include finish/error so every start can be accounted for in webload.log.
final class WebLoadSchemeTrace: NSObject, WKURLSchemeHandler {
    private let target: WKURLSchemeHandler
    private var tasks: [ObjectIdentifier: TaskTrace] = [:]
    private var sequence = 0

    init(target: WKURLSchemeHandler) { self.target = target }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        sequence += 1
        let key = ObjectIdentifier(urlSchemeTask)
        let task = TaskTrace(target: urlSchemeTask, id: sequence) { [weak self] in
            self?.tasks.removeValue(forKey: key)
        }
        tasks[key] = task
        task.log("start")
        target.webView(webView, start: task)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        guard let task = tasks[ObjectIdentifier(urlSchemeTask)] else { return }
        target.webView(webView, stop: task)
        task.end("cancel")
    }

    private final class TaskTrace: NSObject, WKURLSchemeTask {
        let target: WKURLSchemeTask
        let id: Int
        let began = ProcessInfo.processInfo.systemUptime
        let completed: () -> Void
        var ended = false
        var request: URLRequest { target.request }

        init(target: WKURLSchemeTask, id: Int, completed: @escaping () -> Void) {
            self.target = target
            self.id = id
            self.completed = completed
        }

        func log(_ event: String) {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
            WebLoadLog.logger.notice("scheme-\(event, privacy: .public) handler=\(String(describing: ObjectIdentifier(self)), privacy: .public) request=\(self.id) url=\(WebLoadLog.describe(self.request.url), privacy: .public) elapsedMs=\(elapsed) main=\(Thread.isMainThread)")
        }

        func end(_ event: String) {
            guard !ended else { return }
            ended = true
            log("stop reason=\(event)")
            completed()
        }

        func didReceive(_ response: URLResponse) { target.didReceive(response) }
        func didReceive(_ data: Data) { target.didReceive(data) }
        func didFinish() {
            target.didFinish()
            end("finish")
        }
        func didFailWithError(_ error: Error) {
            target.didFailWithError(error)
            end("error \(WebLoadLog.describe(error))")
        }
    }
}

/// Monotonic main-queue sampling starts before Capacitor's bootstrap load.
/// Periodic summaries prove the sampler stayed alive even when no drift was
/// above the threshold. Keep sampling through the entire launch/retry window.
final class WebLoadHeartbeat {
    static let shared = WebLoadHeartbeat()
    private var timer: DispatchSourceTimer?
    private var previous = 0.0
    private var began = 0.0
    private var samples = 0
    private var maxDrift = 0.0

    func start() {
        guard timer == nil else { return }
        began = ProcessInfo.processInfo.systemUptime
        previous = began
        WebLoadLog.logger.notice("heartbeat-start intervalMs=100 thresholdMs=250 durationSeconds=120")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        self.timer = timer
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let drift = max(0, now - previous - 0.1)
        previous = now
        samples += 1
        maxDrift = max(maxDrift, drift)
        if drift > 0.25 {
            WebLoadLog.logger.notice("heartbeat-stall driftMs=\(Int(drift * 1000)) elapsedMs=\(Int((now - self.began) * 1000))")
        }
        if samples % 10 == 0 {
            WebLoadLog.logger.notice("heartbeat samples=\(self.samples) maxDriftMs=\(Int(self.maxDrift * 1000)) elapsedMs=\(Int((now - self.began) * 1000))")
        }
        if now - began >= 120 {
            timer?.cancel()
            timer = nil
            WebLoadLog.logger.notice("heartbeat-stop samples=\(self.samples) maxDriftMs=\(Int(self.maxDrift * 1000))")
        }
    }
}
