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
