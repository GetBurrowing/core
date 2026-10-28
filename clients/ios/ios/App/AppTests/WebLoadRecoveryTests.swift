import WebKit
import XCTest

@testable import App

/// Task 01a17d1f stage 2: WebLoadRecovery against a fake loader and a manual
/// clock.
final class WebLoadRecoveryTests: XCTestCase {
    private var loads: [URLRequest] = []
    private var timers: [(delay: TimeInterval, due: TimeInterval, block: () -> Void)] = []
    private var lines: [String] = []
    private var recreates: [URLRequest] = []
    private var clock: TimeInterval = 0
    private var errors = 0

    private let fixture = URLRequest(url: URL(string: "capacitor://localhost/tabbar-fixture.html")!)
    private let other = URLRequest(url: URL(string: "capacitor://localhost/other.html")!)

    private func makeRecovery() -> WebLoadRecovery {
        loads = []
        timers = []
        lines = []
        recreates = []
        clock = 0
        errors = 0
        let recovery = WebLoadRecovery(
            load: { self.loads.append($0) },
            recreate: { self.recreates.append($0) },
            schedule: { delay, block in self.timers.append((delay, self.clock + delay, block)) },
            log: { self.lines.append($0) })
        recovery.onExhausted = { self.errors += 1 }
        return recovery
    }

    /// Advance past cancelled timers to the next observable recovery event.
    private func fire() {
        let before = lines.count
        while let next = timers.indices.min(by: { timers[$0].due < timers[$1].due }) {
            let timer = timers.remove(at: next)
            clock = timer.due
            timer.block()
            if lines.count != before { return }
        }
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
        XCTAssertEqual(
            timers.map(\.delay), [WebLoadRecovery.Config().watchdog, WebLoadRecovery.Config().finishBounds[0], WebLoadRecovery.Config().finishHardCaps[0]])
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
        XCTAssertTrue(timers.contains { $0.delay == 10 })
        fire()  // 10 s: not finished, no progress
        fire()  // backoff: the re-issue
        XCTAssertEqual(loads.count, 1)
        recovery.didCommit(url: fixture.url)
        XCTAssertTrue(timers.contains { $0.delay == 6 }, "attempt two has a shorter finish bound")
        recovery.didFinish(url: fixture.url)  // lands at 15 s
        fire()
        fire()
        XCTAssertEqual(loads.count, 1)
        XCTAssertEqual(recovery.attempts, 1)
        XCTAssertFalse(lines.contains { $0.contains("exhausted") })
    }

    func testSecondHangRecreatesEvenWhenProgressContinues() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        recovery.didCommit(url: fixture.url)
        fire()  // first stalled commit
        fire()  // first reissue
        recovery.didCommit(url: fixture.url)
        recovery.progress(0.3)
        fire()  // six-second soft bound leaves progress alone
        XCTAssertTrue(recreates.isEmpty)
        recovery.progress(0.6)
        fire()  // eight-second hard cap cannot be extended
        fire()  // recreate backoff
        XCTAssertEqual(loads.map(\.url), [fixture.url])
        XCTAssertEqual(recreates.map(\.url), [fixture.url])
        XCTAssertTrue(recovery.hasRecreated)
        XCTAssertEqual(recovery.attempts, 2)
        XCTAssertLessThanOrEqual(clock, 20)
        XCTAssertTrue(lines.contains { $0.contains("hard cap") })
    }

    func testALoadStillProgressingIsNotReissued() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        recovery.didCommit(url: fixture.url)
        recovery.progress(0.3)
        fire()  // the bound passes, but the load moved
        XCTAssertFalse(lines.contains { $0.contains("did not finish") })
        XCTAssertTrue(lines.contains { $0.contains("still progressing") })
        XCTAssertEqual(timers.last?.delay, 10, "the soft bound checks again; the independent hard cap stays armed")
        fire()  // no further progress
        fire()
        XCTAssertEqual(loads.map(\.url), [fixture.url])
    }

    func testATerminationReportedAfterTheFinishStillReissues() {
        let recovery = makeRecovery()
        recovery.shellLoad(fixture)
        recovery.didCommit(url: fixture.url)
        recovery.terminated()
        recovery.didFinish(url: fixture.url)  // the finish lands after the termination was scheduled
        fire()
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
        XCTAssertEqual(loads.count, 1)
        XCTAssertEqual(recreates.count, 1)
        XCTAssertEqual(errors, 1)
        XCTAssertTrue(recovery.exhausted)
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
        recovery.didFinish(url: fixture.url)
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

#if DEBUG
    final class LaunchHeartbeatStateTests: XCTestCase {
        func testBlockedMainHasOnePendingPulseAndReportsBeforeItResumes() {
            var state = LaunchHeartbeatState(now: 0)
            guard let pulse = state.tick(now: 0.1).pulse else {
                XCTFail("missing pulse")
                return
            }
            XCTAssertNil(state.tick(now: 0.2).pulse)
            let stalled = state.tick(now: 0.4)
            XCTAssertNil(stalled.pulse)
            XCTAssertEqual(stalled.mainDrift ?? -1, 0.3, accuracy: 0.0001)
            XCTAssertNil(state.tick(now: 0.5).mainDrift, "do not log the same stall at 10 Hz")
            XCTAssertEqual(state.acknowledge(pulse.id, now: 0.6) ?? -1, 0.5, accuracy: 0.0001)
            XCTAssertNotNil(state.tick(now: 0.7).pulse)
        }

        func testDelayedSamplerDoesNotGetLabelledAsMainStarvation() {
            var state = LaunchHeartbeatState(now: 0)
            guard let pulse = state.tick(now: 0.1).pulse else {
                XCTFail("missing pulse")
                return
            }
            XCTAssertNil(state.acknowledge(pulse.id, now: 0.101))
            let late = state.tick(now: 0.6)
            XCTAssertEqual(late.samplerDrift ?? -1, 0.4, accuracy: 0.0001)
            XCTAssertNil(late.mainDrift)
            XCTAssertNotNil(late.pulse)
        }

        func testThresholdIsStrictlyOver250Milliseconds() {
            var state = LaunchHeartbeatState(now: 0)
            guard let pulse = state.tick(now: 0).pulse else {
                XCTFail("missing pulse")
                return
            }
            XCTAssertNil(state.acknowledge(pulse.id, now: 0.25))
            guard let next = state.tick(now: 1).pulse else {
                XCTFail("missing next pulse")
                return
            }
            XCTAssertNotNil(state.acknowledge(next.id, now: 1.251))
        }
    }

    final class SchemeTaskTraceTests: XCTestCase {
        @MainActor
        private final class FakeTask: NSObject, WKURLSchemeTask {
            let request: URLRequest
            var events: [String] = []
            init(_ request: URLRequest) { self.request = request }
            func didReceive(_ response: URLResponse) { events.append("response") }
            func didReceive(_ data: Data) { events.append("data:\(data.count)") }
            func didFinish() { events.append("finish") }
            func didFailWithError(_ error: Error) { events.append("fail") }
        }

        @MainActor
        func testProxyForwardsRequestAndCallbacksAndLogsTerminalAfterForwarding() {
            var request = URLRequest(url: URL(string: "capacitor://localhost/fixture.html?secret=hidden")!)
            request.httpMethod = "POST"
            request.httpBody = Data([1, 2])
            let original = FakeTask(request)
            var lines: [String] = []
            var ended = 0
            let proxy = TracedSchemeTask(
                task: original, id: "test", now: { 1 }, log: { lines.append($0) },
                onEnd: {
                    XCTAssertEqual(original.events.last, "finish")
                    ended += 1
                })
            XCTAssertEqual(proxy.request, request)
            proxy.didReceive(URLResponse(url: request.url!, mimeType: "text/html", expectedContentLength: 2, textEncodingName: nil))
            proxy.didReceive(Data([1, 2]))
            proxy.didFinish()
            XCTAssertEqual(original.events, ["response", "data:2", "finish"])
            XCTAssertEqual(ended, 1)
            XCTAssertTrue(lines.last?.contains("end outcome=finished") == true)
            XCTAssertTrue(lines.allSatisfy { !$0.contains("secret") && !$0.contains("localhost") })
        }

        @MainActor
        func testFailureStillReachesWebKitAndEndsTheTrace() {
            let original = FakeTask(URLRequest(url: URL(string: "capacitor://localhost/missing")!))
            var lines: [String] = []
            var ended = 0
            let proxy = TracedSchemeTask(
                task: original, id: "test", log: { lines.append($0) },
                onEnd: {
                    XCTAssertEqual(original.events.last, "fail")
                    ended += 1
                })
            proxy.didFailWithError(URLError(.fileDoesNotExist))
            XCTAssertEqual(original.events, ["fail"])
            XCTAssertEqual(ended, 1)
            XCTAssertTrue(lines.last?.contains("end outcome=failed") == true)
        }
    }
#endif
