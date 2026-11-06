import WebKit
import XCTest

@testable import App

/// Task 01a1ad86 stage 2: the media-capture proxy in front of Capacitor's UI
/// delegate, against a fake target.
@MainActor
final class WebMediaCaptureTraceTests: XCTestCase {
    private final class FakeTarget: NSObject, WKUIDelegate {
        func webView(
            _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.grant)
        }

        func webView(
            _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            completionHandler()
        }
    }

    private static let mediaCapture = #selector(
        WKUIDelegate.webView(_:requestMediaCapturePermissionFor:initiatedByFrame:type:decisionHandler:))
    private static let alertPanel = #selector(WKUIDelegate.webView(_:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:))
    private static let confirmPanel = #selector(
        WKUIDelegate.webView(_:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:))

    private var lines: [String] = []
    private var target = FakeTarget()

    private func makeTrace(installHost: String? = "suite.example.test") -> WebMediaCaptureTrace {
        lines = []
        target = FakeTarget()
        return WebMediaCaptureTrace(target: target, installHost: { installHost }, log: { self.lines.append($0) })
    }

    /// Runs one request through the proxy; returns the decision and how often
    /// the target was asked.
    private func request(
        _ trace: WebMediaCaptureTrace, host: String, scheme: String = "https", type: WKMediaCaptureType = .microphone,
        targetAnswers answer: WKPermissionDecision = .prompt
    ) -> (decision: WKPermissionDecision?, asked: Int) {
        var decision: WKPermissionDecision?
        var asked = 0
        trace.decide(
            scheme: scheme, host: host, type: type, mainFrame: true,
            ask: { forward in
                asked += 1
                forward(answer)
            },
            decisionHandler: { decision = $0 })
        return (decision, asked)
    }

    func testGrantsForTheInstallHostWithoutAskingTheTarget() {
        let trace = makeTrace()
        let result = request(trace, host: "Suite.Example.Test")
        XCTAssertEqual(result.decision, .grant)
        XCTAssertEqual(result.asked, 0)
        XCTAssertEqual(lines, ["media-capture origin=install scheme=https type=microphone mainFrame=true decision=grant by=shell"])
    }

    func testGrantsForTheBundledLocalhost() {
        let trace = makeTrace(installHost: nil)
        let result = request(trace, host: "localhost", scheme: "capacitor", type: .cameraAndMicrophone)
        XCTAssertEqual(result.decision, .grant)
        XCTAssertEqual(result.asked, 0)
        XCTAssertEqual(lines, ["media-capture origin=localhost scheme=capacitor type=cameraAndMicrophone mainFrame=true decision=grant by=shell"])
    }

    func testAnotherHostIsDecidedByTheTargetAndLogged() {
        let trace = makeTrace()
        let result = request(trace, host: "elsewhere.example.test", targetAnswers: .deny)
        XCTAssertEqual(result.decision, .deny)
        XCTAssertEqual(result.asked, 1)
        XCTAssertEqual(lines, ["media-capture origin=other scheme=https type=microphone mainFrame=true decision=deny by=target"])
    }

    func testOneLogLinePerRequestAndNoHostInTheLog() {
        let trace = makeTrace()
        _ = request(trace, host: "suite.example.test")
        _ = request(trace, host: "localhost", scheme: "capacitor")
        _ = request(trace, host: "elsewhere.example.test", type: .camera)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("media-capture ") })
        XCTAssertFalse(lines.contains { $0.contains("example.test") }, "\(lines)")
    }

    func testForwardsOtherSelectorsToTheTarget() {
        let trace = makeTrace()
        XCTAssertTrue(trace.responds(to: Self.alertPanel))
        XCTAssertTrue((trace.forwardingTarget(for: Self.alertPanel) as? FakeTarget) === target)
        // Nothing behind the proxy implements it, so WebKit must not see it.
        XCTAssertFalse(trace.responds(to: Self.confirmPanel))
        // The capture method is the proxy's own.
        XCTAssertTrue(trace.responds(to: Self.mediaCapture))
        XCTAssertNil(trace.forwardingTarget(for: Self.mediaCapture))
    }

    func testDoesNotRetainItsTarget() {
        var owned: FakeTarget? = FakeTarget()
        let trace = WebMediaCaptureTrace(target: owned, installHost: { nil }, log: { _ in })
        XCTAssertNotNil(trace.target)
        owned = nil
        XCTAssertNil(trace.target)
    }

    // MARK: Installed by the shell

    /// recreateShell builds a fresh BurrowBridgeViewController; its viewDidLoad
    /// must install the proxy in front of that controller's own Capacitor
    /// handler, as the first controller did.
    func testTheShellInstallsTheProxyOnAFirstAndARecreatedController() throws {
        var traces: [WebMediaCaptureTrace] = []
        for _ in 0..<2 {
            let shell = BurrowBridgeViewController()
            shell.loadViewIfNeeded()
            let webView = try XCTUnwrap(shell.webView, "the bridge loaded a web view")
            let trace = try XCTUnwrap(webView.uiDelegate as? WebMediaCaptureTrace, "uiDelegate is \(String(describing: webView.uiDelegate))")
            XCTAssertTrue(shell.mediaCaptureTrace === trace, "the controller retains the proxy")
            let capacitor = try XCTUnwrap(trace.target, "Capacitor's handler is behind the proxy")
            XCTAssertFalse(capacitor is WebMediaCaptureTrace)
            XCTAssertTrue(capacitor.responds(to: Self.mediaCapture))
            traces.append(trace)
        }
        XCTAssertFalse(traces[0] === traces[1])
    }
}
