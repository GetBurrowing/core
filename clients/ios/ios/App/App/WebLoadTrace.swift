import Foundation
import OSLog
import WebKit

#if DEBUG
    import Capacitor
    import ObjectiveC
#endif

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

    static func event(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

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

#if DEBUG
    /// Diagnostic state only. The watchdog runs off-main and keeps at most
    /// one main-queue pulse pending, so a stall cannot build a ping backlog.
    struct LaunchHeartbeatState {
        struct Pulse {
            let id: Int
            let queuedAt: TimeInterval
        }
        struct Tick {
            var pulse: Pulse?
            var mainDrift: TimeInterval?
            var samplerDrift: TimeInterval?
            var sample = false
            var ackAge: TimeInterval = 0
        }
        private var previousTick: TimeInterval
        private var lastSample: TimeInterval
        private var lastStallReport: TimeInterval?
        private var sequence = 0
        private(set) var pending: Pulse?
        private(set) var lastAck: TimeInterval

        init(now: TimeInterval) {
            previousTick = now
            lastSample = now
            lastAck = now
        }

        mutating func tick(now: TimeInterval) -> Tick {
            var result = Tick()
            let samplerDrift = now - previousTick - 0.1
            previousTick = now
            if samplerDrift > 0.25 { result.samplerDrift = samplerDrift }
            if let pending {
                let drift = now - pending.queuedAt
                if drift > 0.25, lastStallReport == nil || now - lastStallReport! >= 1 {
                    result.mainDrift = drift
                    lastStallReport = now
                }
            } else {
                sequence += 1
                let pulse = Pulse(id: sequence, queuedAt: now)
                pending = pulse
                result.pulse = pulse
            }
            if now - lastSample >= 1 {
                result.sample = true
                result.ackAge = now - lastAck
                lastSample = now
            }
            return result
        }

        mutating func acknowledge(_ id: Int, now: TimeInterval) -> TimeInterval? {
            guard let pulse = pending, pulse.id == id else { return nil }
            pending = nil
            lastAck = now
            lastStallReport = nil
            let drift = now - pulse.queuedAt
            return drift > 0.25 ? drift : nil
        }
    }

    /// Covers startup, the first navigation and AppTests' startup window.
    /// Off-main liveness logs distinguish no measured drift from no sampler.
    final class LaunchHeartbeat: @unchecked Sendable {
        static let shared = LaunchHeartbeat()
        private let queue = DispatchQueue(label: "burrow.launch-heartbeat", qos: .utility)
        private let lock = NSLock()
        private var timer: DispatchSourceTimer?
        private var state: LaunchHeartbeatState?
        private var until: TimeInterval = 0

        func start() {
            lock.lock()
            guard timer == nil else {
                lock.unlock()
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            state = LaunchHeartbeatState(now: now)
            until = now + 120
            let source = DispatchSource.makeTimerSource(queue: queue)
            timer = source
            source.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(10))
            source.setEventHandler { [weak self] in self?.tick() }
            lock.unlock()
            WebLoadLog.event("heartbeat start interval_ms=100 threshold_ms=250 window_s=120")
            source.resume()
        }

        private func tick() {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            guard state != nil else {
                lock.unlock()
                return
            }
            if now >= until {
                let source = timer
                timer = nil
                state = nil
                lock.unlock()
                source?.cancel()
                WebLoadLog.event("heartbeat stop window-ended")
                return
            }
            let result = state!.tick(now: now)
            let pending = state!.pending != nil
            lock.unlock()
            if let drift = result.samplerDrift {
                WebLoadLog.event("heartbeat sampler-drift drift_ms=\(Int(drift * 1000))")
            }
            if let drift = result.mainDrift {
                WebLoadLog.event("heartbeat main-pending drift_ms=\(Int(drift * 1000))")
            }
            if result.sample {
                WebLoadLog.event("heartbeat alive last_ack_age_ms=\(Int(result.ackAge * 1000)) pending=\(pending)")
            }
            if let pulse = result.pulse {
                DispatchQueue.main.async { [weak self] in self?.acknowledge(pulse.id) }
            }
        }

        private func acknowledge(_ id: Int) {
            lock.lock()
            let drift = state?.acknowledge(id, now: ProcessInfo.processInfo.systemUptime)
            lock.unlock()
            if let drift { WebLoadLog.event("heartbeat main-resumed drift_ms=\(Int(drift * 1000))") }
        }
    }

    /// Wraps the task, not the asset-serving algorithm or its queue. Captures
    /// terminal callbacks as well as cancellation (WK's stop callback).
    @MainActor
    final class TracedSchemeTask: NSObject, WKURLSchemeTask {
        let id: String
        private let task: WKURLSchemeTask
        private let started: TimeInterval
        private let now: () -> TimeInterval
        private let log: (String) -> Void
        private let onEnd: () -> Void
        var request: URLRequest { task.request }

        init(
            task: WKURLSchemeTask, id: String,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            log: @escaping (String) -> Void = WebLoadLog.event,
            onEnd: @escaping () -> Void
        ) {
            self.task = task
            self.id = id
            self.now = now
            self.log = log
            self.onEnd = onEnd
            started = now()
        }

        func event(_ name: String) {
            let elapsed = Int((now() - started) * 1000)
            log("scheme \(name) id=\(id) url=\(WebLoadLog.describe(request.url)) elapsed_ms=\(elapsed) main=\(Thread.isMainThread)")
        }

        func didReceive(_ response: URLResponse) {
            event("response")
            task.didReceive(response)
        }

        func didReceive(_ data: Data) {
            event("data bytes=\(data.count)")
            task.didReceive(data)
        }

        func didFinish() {
            event("finish-enter")
            task.didFinish()
            end("finished")
        }

        func didFailWithError(_ error: Error) {
            event("fail-enter \(WebLoadLog.describe(error))")
            task.didFailWithError(error)
            end("failed")
        }

        func end(_ outcome: String) {
            event("end outcome=\(outcome)")
            onEnd()
        }
    }

    @MainActor
    private final class SchemeTaskTrace {
        private let lock = NSLock()
        private let instance = UUID().uuidString
        private var sequence = 0
        private var tasks: [ObjectIdentifier: TracedSchemeTask] = [:]

        func begin(_ task: WKURLSchemeTask) -> TracedSchemeTask {
            let key = ObjectIdentifier(task)
            lock.lock()
            sequence += 1
            let id = "\(instance)/\(sequence)"
            let traced = TracedSchemeTask(task: task, id: id) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if self.tasks[key]?.id == id { self.tasks.removeValue(forKey: key) }
                self.lock.unlock()
            }
            tasks[key] = traced
            lock.unlock()
            traced.event("start")
            return traced
        }

        func lookup(_ task: WKURLSchemeTask) -> TracedSchemeTask? {
            lock.lock()
            defer { lock.unlock() }
            return tasks[ObjectIdentifier(task)]
        }
    }

    /// Capacitor 8.5.2 constructs its asset handler privately. Instrument its
    /// public callbacks once in DEBUG; do not replace WK configuration or
    /// duplicate Capacitor's asset-serving code.
    @MainActor
    enum SchemeTraceHooks {
        private static let lock = NSLock()
        private static var key: UInt8 = 0
        private static let installed: Void = {
            guard
                let start = class_getInstanceMethod(WebViewAssetHandler.self, #selector(WKURLSchemeHandler.webView(_:start:))),
                let tracedStart = class_getInstanceMethod(WebViewAssetHandler.self, #selector(WebViewAssetHandler.burrowTraceWebView(_:start:))),
                let stop = class_getInstanceMethod(WebViewAssetHandler.self, #selector(WKURLSchemeHandler.webView(_:stop:))),
                let tracedStop = class_getInstanceMethod(WebViewAssetHandler.self, #selector(WebViewAssetHandler.burrowTraceWebView(_:stop:)))
            else {
                WebLoadLog.event("scheme instrumentation unavailable")
                return
            }
            method_exchangeImplementations(start, tracedStart)
            method_exchangeImplementations(stop, tracedStop)
            WebLoadLog.event("scheme instrumentation installed")
        }()

        static func install() { _ = installed }

        fileprivate static func trace(_ handler: WebViewAssetHandler) -> SchemeTaskTrace {
            lock.lock()
            defer { lock.unlock() }
            if let value = objc_getAssociatedObject(handler, &key) as? SchemeTaskTrace { return value }
            let value = SchemeTaskTrace()
            objc_setAssociatedObject(handler, &key, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return value
        }
    }

    @MainActor
    extension WebViewAssetHandler {
        @objc fileprivate dynamic func burrowTraceWebView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            let traced = SchemeTraceHooks.trace(self).begin(task)
            // After exchange this dispatches to Capacitor's original method.
            burrowTraceWebView(webView, start: traced)
            traced.event("handler-return")
        }

        @objc fileprivate dynamic func burrowTraceWebView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
            if let traced = SchemeTraceHooks.trace(self).lookup(task) {
                traced.event("stop")
                burrowTraceWebView(webView, stop: traced)
                traced.end("cancelled")
            } else {
                WebLoadLog.event("scheme stop untracked url=\(WebLoadLog.describe(task.request.url)) main=\(Thread.isMainThread)")
                burrowTraceWebView(webView, stop: task)
            }
        }
    }
#endif
