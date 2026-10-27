import Foundation

/// Task 01a17d1f stage 2: the shell's own recovery for a web load that never
/// lands. The first cold launch can show a blank web view; nothing in
/// Capacitor re-issues a load that failed provisionally or lost its WebContent
/// process before it committed (its `reload()` does nothing with no committed
/// URL), and the UI test used to hide that by relaunching the app.
///
/// `WebLoadTracingDelegate` drives this type. It remembers the request the
/// shell last issued and re-issues it (a fresh `load`, never `reload()`) on:
/// - a failed or provisionally failed navigation of that load, except a
///   cancellation (-999) that a newer shell load caused;
/// - a WebContent process termination;
/// - a watchdog that fires when nothing commits soon enough after a load;
/// - the same for a page that commits but does not finish loading (the
///   mechanism behind the blank first launch, task 01a17d1f).
///
/// Attempts are bounded per shell load and spaced by a short backoff. Pure
/// (the clock and the web view are injected) so it can be unit tested.
final class WebLoadRecovery {
    struct Config {
        var maxAttempts = 3
        /// Delay before re-issue attempt 1, 2, 3...; the last entry repeats.
        var backoff: [TimeInterval] = [0.5, 1, 2]
        /// Longest a load may go without committing. A cold runner took 13 s.
        var watchdog: TimeInterval = 25
        /// Longest a committed page may go without finishing, for the first
        /// load, then after the first and the second re-issue (the last
        /// repeats). In run 40538916731 (cold runner) two launches committed
        /// and never finished while the test waited; the slowest cold
        /// commit-to-finish that did land took 8.4 s, a warm one 0.1 s. The
        /// bound grows because a re-issue restarts the load: a slow but
        /// healthy device must eventually be left to finish.
        var finishBounds: [TimeInterval] = [10, 20, 40]
    }

    private let config: Config
    private let load: (URLRequest) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let log: (String) -> Void

    /// Called on didFinish of a page that a re-issue brought up.
    var onRecoveredPage: ((Int) -> Void)?

    private(set) var intended: URLRequest?
    private(set) var attempts = 0
    private(set) var committed = false
    private(set) var finished = false
    private var lastProgress = 0.0
    private var progressTicks = 0
    /// Pages that finished loading after a re-issue.
    private(set) var recoveredPages = 0
    private var awaitingRecoveredCommit = false
    private var recoveredCommitSeen = false
    /// Invalidates every scheduled backoff and watchdog it was captured before.
    private var epoch = 0

    init(
        config: Config = Config(),
        load: @escaping (URLRequest) -> Void,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
        },
        log: @escaping (String) -> Void = { message in WebLoadLog.logger.notice("\(message, privacy: .public)") }
    ) {
        self.config = config
        self.load = load
        self.schedule = schedule
        self.log = log
    }

    // MARK: Events

    /// The shell is issuing a load (the caller issues it; this only records it).
    func shellLoad(_ request: URLRequest) {
        epoch += 1
        intended = request
        attempts = 0
        committed = false
        finished = false
        lastProgress = 0
        awaitingRecoveredCommit = false
        recoveredCommitSeen = false
        armWatchdog()
    }

    /// Capacitor's own bootstrap page (`capacitor://…/`), not a load the shell
    /// asked for: its commit or finish must not stand in for the intended one.
    private func isBootstrapOfAnotherLoad(_ url: URL?) -> Bool {
        guard let url, let intended, url.scheme == "capacitor", ["", "/", "/index.html"].contains(url.path) else { return false }
        return url.absoluteString != intended.url?.absoluteString
    }

    func didCommit(url: URL?) {
        if isBootstrapOfAnotherLoad(url) {
            log("recovery ignored commit of the bootstrap page")
            return
        }
        epoch += 1
        committed = true
        finished = false
        armFinishWatchdog()
        // Whatever is on screen now is what a later termination restores.
        if let url { intended = URLRequest(url: url) }
        if awaitingRecoveredCommit {
            awaitingRecoveredCommit = false
            recoveredCommitSeen = true
        }
    }

    func didFinish(url: URL? = nil) {
        if isBootstrapOfAnotherLoad(url) {
            log("recovery ignored finish of the bootstrap page")
            return
        }
        // No epoch bump: a retry already scheduled (a termination reported
        // just after the finish) must still run. The finish bound checks
        // `finished` itself.
        finished = true
        guard recoveredCommitSeen else { return }
        recoveredCommitSeen = false
        recoveredPages += 1
        log("recovery recovered pages=\(recoveredPages)")
        onRecoveredPage?(recoveredPages)
    }

    /// `didFail` or `didFailProvisionalNavigation`. `url` is the failing URL
    /// when the error or the web view names one.
    func failed(url: URL?, domain: String, code: Int) {
        guard let intended else { return }
        guard !committed else {
            log("recovery ignored failure after commit \(domain) \(code)")
            return
        }
        if let url, url.absoluteString != intended.url?.absoluteString {
            log("recovery ignored failure of a different load \(domain) \(code)")
            return
        }
        if url == nil, domain == NSURLErrorDomain, code == NSURLErrorCancelled {
            log("recovery ignored cancellation (superseded) \(domain) \(code)")
            return
        }
        scheduleRetry("failed \(domain) \(code)")
    }

    func terminated() {
        guard intended != nil else { return }
        scheduleRetry("terminated")
    }

    // MARK: Retry

    private func scheduleRetry(_ reason: String) {
        guard attempts < config.maxAttempts else {
            epoch += 1
            log("recovery exhausted attempts=\(attempts) reason=\(reason)")
            return
        }
        epoch += 1
        let captured = epoch
        let delay = config.backoff.isEmpty ? 0 : config.backoff[min(attempts, config.backoff.count - 1)]
        log("recovery scheduled attempt=\(attempts + 1) delay=\(delay) reason=\(reason)")
        schedule(delay) { [weak self] in
            guard let self, self.epoch == captured else { return }
            self.reissue(reason)
        }
    }

    private func reissue(_ reason: String) {
        guard let intended, attempts < config.maxAttempts else { return }
        attempts += 1
        epoch += 1
        committed = false
        finished = false
        lastProgress = 0
        awaitingRecoveredCommit = true
        log("recovery reissue attempt=\(attempts) reason=\(reason)")
        // MUTATION (reverted next commit): re-issue is a no-op.
        _ = intended
        armWatchdog()
    }

    /// `WKWebView.estimatedProgress`. A load that is still moving is left alone.
    func progress(_ value: Double) {
        guard value > lastProgress else { return }
        lastProgress = value
        progressTicks += 1
    }

    private func armFinishWatchdog() {
        let bounds = config.finishBounds
        let bound = bounds.isEmpty ? 10 : bounds[min(attempts, bounds.count - 1)]
        armFinishWatchdog(epoch: epoch, ticks: progressTicks, bound: bound)
    }

    private func armFinishWatchdog(epoch captured: Int, ticks: Int, bound: TimeInterval) {
        schedule(bound) { [weak self] in
            guard let self, self.epoch == captured, self.committed, !self.finished else { return }
            if self.progressTicks != ticks {
                self.log("recovery finish bound passed but the load is still progressing")
                self.armFinishWatchdog(epoch: captured, ticks: self.progressTicks, bound: bound)
                return
            }
            self.log("recovery committed but did not finish")
            self.scheduleRetry("commit without finish")
        }
    }

    private func armWatchdog() {
        let captured = epoch
        schedule(config.watchdog) { [weak self] in
            guard let self, self.epoch == captured, !self.committed else { return }
            self.log("recovery watchdog fired")
            self.scheduleRetry("watchdog")
        }
    }
}
