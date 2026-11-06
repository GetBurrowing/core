import Foundation
import WebKit

/// Task 01a1ad86 stage 2: when the Voice tab's microphone press does nothing on
/// a device, webload.log must say whether WebKit asked the shell for capture
/// and what the shell answered.
///
/// Sits in front of Capacitor's UI delegate (`WebViewDelegationHandler`) the
/// way WebLoadTracingDelegate sits in front of its navigation delegate. Only
/// the media-capture permission request is implemented here; every other
/// WKUIDelegate call reaches Capacitor's handler through the Objective-C
/// forwarding path, so its behaviour is untouched.
///
/// The origin is logged as its relation to the shell (`install`, `localhost`
/// or `other`) plus its scheme, never as a host, matching WebLoadLog's rule.
final class WebMediaCaptureTrace: NSObject, WKUIDelegate {
    enum Origin: String {
        case install
        case localhost
        case other
    }

    /// Capacitor's handler. `WKWebView.uiDelegate` is weak and so is this, so
    /// the shell controller retains the proxy and Capacitor retains its own.
    private(set) weak var target: WKUIDelegate?
    private let installHost: () -> String?
    private let log: (String) -> Void

    init(target: WKUIDelegate?, installHost: @escaping () -> String?, log: @escaping (String) -> Void = WebLoadLog.event) {
        self.target = target
        self.installHost = installHost
        self.log = log
        super.init()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (target?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let target, target.responds(to: aSelector) { return target }
        return super.forwardingTarget(for: aSelector)
    }

    /// Where a capture request came from, relative to the shell.
    func classify(host: String) -> Origin {
        let host = host.lowercased()
        if let install = installHost()?.lowercased(), !install.isEmpty, host == install { return .install }
        if host == "localhost" { return .localhost }
        return .other
    }

    static func describe(_ type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .cameraAndMicrophone: return "cameraAndMicrophone"
        @unknown default: return "unknown(\(type.rawValue))"
        }
    }

    static func describe(_ decision: WKPermissionDecision) -> String {
        switch decision {
        case .prompt: return "prompt"
        case .grant: return "grant"
        case .deny: return "deny"
        @unknown default: return "unknown(\(decision.rawValue))"
        }
    }

    /// One log line per request, written when the decision is made.
    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let ask: (@escaping (WKPermissionDecision) -> Void) -> Void = { [weak self] forward in
            let selector = #selector(WKUIDelegate.webView(_:requestMediaCapturePermissionFor:initiatedByFrame:type:decisionHandler:))
            if let target = self?.target, target.responds(to: selector) {
                target.webView?(webView, requestMediaCapturePermissionFor: origin, initiatedByFrame: frame, type: type, decisionHandler: forward)
            } else {
                // No handler behind the proxy: WebKit's own default.
                forward(.prompt)
            }
        }
        decide(scheme: origin.protocol, host: origin.host, type: type, mainFrame: frame.isMainFrame, ask: ask, decisionHandler: decisionHandler)
    }

    /// The decision, separated from WebKit's objects (which tests cannot
    /// construct). `ask` hands the request to the target and reports back.
    func decide(
        scheme: String, host: String, type: WKMediaCaptureType, mainFrame: Bool,
        ask: (@escaping (WKPermissionDecision) -> Void) -> Void,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let origin = classify(host: host)
        let summary = "media-capture origin=\(origin.rawValue) scheme=\(scheme) type=\(Self.describe(type)) mainFrame=\(mainFrame)"
        switch origin {
        case .install, .localhost:
            log("\(summary) decision=grant by=shell")
            decisionHandler(.grant)
        case .other:
            ask { [log] decision in
                log("\(summary) decision=\(Self.describe(decision)) by=target")
                decisionHandler(decision)
            }
        }
    }
}
