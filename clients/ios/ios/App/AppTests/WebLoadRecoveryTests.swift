import XCTest

@testable import App

/// Task 01a17d1f stage 2: WebLoadRecovery against a fake loader and a manual
/// clock.
final class WebLoadRecoveryTests: XCTestCase {
    private var loads: [URLRequest] = []
    private var timers: [(delay: TimeInterval, block: () -> Void)] = []
    private var lines: [String] = []

    private let fixture = URLRequest(url: URL(string: "capacitor://localhost/tabbar-fixture.html")!)
    private let other = URLRequest(url: URL(string: "capacitor://localhost/other.html")!)

    private func makeRecovery() -> WebLoadRecovery {
        loads = []
        timers = []
        lines = []
        return WebLoadRecovery(
            load: { self.loads.append($0) },
            schedule: { delay, block in self.timers.append((delay, block)) },
            log: { self.lines.append($0) })
    }

    /// Runs every timer scheduled so far, once, in order.
    private func fire() {
        let due = timers
        timers = []
        for timer in due { timer.block() }
    }

    func testProvisionalFailureReissuesTheLoad() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        recovery.failed(url: fixture.url, domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertTrue(loads.isEmpty, "the re-issue waits out the backoff")
        fire()
        XCTAssertEqual(loads.map(\.url), [fixture.url])
        XCTAssertEqual(recovery.attempts, 1)
    }

    func testFailureAfterTheProvisionalPhaseReissuesToo() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        recovery.failed(url: nil, domain: "WebKitErrorDomain", code: 102)
        fire()
        XCTAssertEqual(loads.map(\.url), [fixture.url])
    }

    func testTerminationReissuesALoadNotAReload() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        recovery.didCommit(url: fixture.url)
        recovery.didFinish()
        recovery.terminated()
        fire()
        XCTAssertEqual(loads.map(\.url), [fixture.url])
        XCTAssertFalse(recovery.committed)
    }

    func testTerminationRestoresWhatWasOnScreenNotTheFirstLoad() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        recovery.didCommit(url: fixture.url)
        recovery.didCommit(url: other.url)
        recovery.terminated()
        fire()
        XCTAssertEqual(loads.map(\.url), [other.url])
    }

    func testTerminationBeforeAnyCommitReissuesTheShellsLoad() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        recovery.terminated()
        fire()
        XCTAssertEqual(loads.map(\.url), [fixture.url])
    }

    func testCancellationBySupersedingLoadIsNotRetried() {
        let recovery = makeRecovery()
        recovery.shellLoad(other)
        recovery.shellLoad(fixture)
        // The first load's cancellation arrives after the second was issued.
        recovery.failed(url: other.url, domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        recovery.failed(url: nil, domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        // Nothing was scheduled for either cancellation: the only timers are
        // the two loads' watchdogs.
        XCTAssertTrue(loads.isEmpty)
        XCTAssertEqual(timers.count, 2)
        XCTAssertFalse(lines.contains { $0.contains("scheduled") })
        XCTAssertEqual(lines.filter { $0.contains("ignored") }.count, 2)
    }

    func testCancellationOfTheCurrentLoadIsRetried() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        recovery.failed(url: fixture.url, domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        fire()
        XCTAssertEqual(loads.map(\.url), [fixture.url])
    }

    func testFailureAfterCommitIsNotRetried() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        recovery.didCommit(url: fixture.url)
        recovery.failed(url: fixture.url, domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        fire()
        XCTAssertTrue(loads.isEmpty)
    }

    func testWatchdogReissuesAfterNoCommit() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        XCTAssertEqual(timers.map(\.delay), [WebLoadRecovery.Config().watchdog])
        fire()  // the watchdog: schedules the backoff
        XCTAssertTrue(loads.isEmpty)
        fire()  // the backoff
        XCTAssertEqual(loads.map(\.url), [fixture.url])
    }

    func testCommitWithoutFinishReissuesTheLoad() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        recovery.didCommit(url: fixture.url)
        XCTAssertEqual(timers.map(\.delay), [WebLoadRecovery.Config().watchdog, WebLoadRecovery.Config().finishBounds[0]])
        fire()  // the finish bound: schedules the backoff (the stale no-commit watchdog does nothing)
        XCTAssertTrue(loads.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("did not finish") })
        fire()  // the backoff
        XCTAssertEqual(loads.map(\.url), [fixture.url])
        XCTAssertEqual(recovery.attempts, 1)
    }

    /// A slow but healthy device: the first load needs 15 s, so the 10 s bound
    /// re-issues it once; the re-issue gets 20 s, finishes inside it, and the
    /// budget is not exhausted.
    func testASlowLoadLandsOnTheSecondAttemptAndDoesNotExhaust() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        recovery.didCommit(url: fixture.url)
        XCTAssertEqual(timers.last?.delay, 10)
        fire()  // 10 s: not finished, no progress
        fire()  // backoff: the re-issue
        XCTAssertEqual(loads.count, 1)
        recovery.didCommit(url: fixture.url)
        XCTAssertEqual(timers.last?.delay, 20, "the re-issue gets a longer bound")
        recovery.didFinish(url: fixture.url)  // lands at 15 s
        fire()
        fire()
        XCTAssertEqual(loads.count, 1)
        XCTAssertEqual(recovery.attempts, 1)
        XCTAssertFalse(lines.contains { $0.contains("exhausted") })
    }

    func testTheBoundKeepsGrowingToTheLastEntry() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        var armed: [TimeInterval] = []
        for _ in 0..<3 {
            recovery.didCommit(url: fixture.url)
            armed.append(timers.last?.delay ?? 0)
            fire()
            fire()
        }
        XCTAssertEqual(armed, [10, 20, 40])
    }

    func testALoadStillProgressingIsNotReissued() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        recovery.didCommit(url: fixture.url)
        recovery.progress(0.3)
        fire()  // the bound passes, but the load moved
        XCTAssertFalse(lines.contains { $0.contains("did not finish") })
        XCTAssertTrue(lines.contains { $0.contains("still progressing") })
        XCTAssertEqual(timers.last?.delay, 10, "it is checked again")
        fire()  // no further progress
        fire()
        XCTAssertEqual(loads.map(\.url), [fixture.url])
    }

    func testFinishDisarmsTheFinishBound() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        recovery.didCommit(url: fixture.url)
        recovery.didFinish()
        fire()
        fire()
        XCTAssertTrue(loads.isEmpty)
        XCTAssertFalse(lines.contains { $0.contains("did not finish") })
    }

    func testCommitWithoutFinishIsBoundedLikeAnyOtherFailure() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        recovery.didCommit(url: fixture.url)
        for _ in 0..<4 {
            fire()  // the finish bound
            fire()  // the backoff, then the re-issue
            recovery.didCommit(url: fixture.url)  // it commits again, and again never finishes
        }
        XCTAssertEqual(loads.count, 3)
        XCTAssertTrue(lines.contains { $0.contains("exhausted") })
    }

    func testTheBootstrapPageDoesNotStandInForTheIntendedLoad() {
        let recovery = makeRecovery()
        let bootstrap = URL(string: "capacitor://localhost/")!
        recovery.shellLoad(fixture)
        recovery.didCommit(url: bootstrap)
        recovery.didFinish(url: bootstrap)
        XCTAssertFalse(recovery.committed)
        // The intended load then fails: it is still retried.
        recovery.failed(url: fixture.url, domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        fire()
        fire()
        XCTAssertEqual(loads.map(\.url), [fixture.url])
    }

    func testCommitDisarmsTheWatchdog() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        recovery.didCommit(url: fixture.url)
        fire()
        fire()
        XCTAssertTrue(loads.isEmpty)
    }

    func testAttemptsAreBoundedAndBackedOff() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        var delays: [TimeInterval] = []
        for _ in 0..<6 {
            recovery.failed(url: fixture.url, domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            if let last = timers.last, lines.last?.contains("scheduled") == true { delays.append(last.delay) }
            fire()
        }
        XCTAssertEqual(loads.count, 3)
        XCTAssertEqual(recovery.attempts, 3)
        XCTAssertEqual(delays, [0.5, 1, 2])
        XCTAssertTrue(lines.contains { $0.contains("exhausted") })
    }

    func testANewShellLoadStartsAFreshBudget() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        for _ in 0..<3 {
            recovery.failed(url: fixture.url, domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            fire()
        }
        recovery.shellLoad(other)
        XCTAssertEqual(recovery.attempts, 0)
        recovery.failed(url: other.url, domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        fire()
        XCTAssertEqual(loads.last?.url, other.url)
    }

    func testARecoveredPageIsCountedAndReported() {
        let recovery = makeRecovery()
        var reported: [Int] = []
        recovery.onRecoveredPage = { reported.append($0) }
        recovery.shellLoad(fixture)
        recovery.failed(url: fixture.url, domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        fire()
        recovery.didCommit(url: fixture.url)
        recovery.didFinish()
        XCTAssertEqual(reported, [1])
        // A page that needed no recovery reports nothing.
        recovery.shellLoad(other)
        recovery.didCommit(url: other.url)
        recovery.didFinish()
        XCTAssertEqual(reported, [1])
    }
}
