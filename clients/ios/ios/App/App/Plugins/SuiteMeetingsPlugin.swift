import Capacitor
import Foundation

/// `SuiteMeetings` (task 01a10db7 stage 3): the web UI hands a meeting join
/// to the native call. Registered beside `SuiteNative` in
/// `SuiteBridgeViewController.capacitorDidLoad`.
///
/// `meeting_client.js` calls `join({meetingId})` INSTEAD of building its own
/// LiveKit `Room`: both would join as the same `user:<id>` identity, kick
/// each other out, and play the call twice. `callEnded` tells the page the
/// native call is over so it can push the same `meeting_left` its own
/// Disconnected handler pushes.
public class SuiteMeetingsPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SuiteMeetingsPlugin"
    public let jsName = "SuiteMeetings"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "join", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "state", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "leave", returnType: CAPPluginReturnPromise),
    ]

    weak var shell: SuiteBridgeViewController?

    override public func load() {
        Task { @MainActor in
            CallController.shared.onCallEnded = { [weak self] meetingID in
                self?.notifyListeners("callEnded", data: ["meetingId": meetingID])
            }
        }
    }

    /// `{meetingId}` -> `{status: "starting" | "already_in_call" | "busy"}`.
    /// A call already up for the same meeting ("Open full meeting") is a
    /// no-op that still resolves, so the page treats it as joined.
    @objc func join(_ call: CAPPluginCall) {
        guard let meetingID = call.getString("meetingId"), !meetingID.isEmpty else {
            call.reject("meetingId is required")
            return
        }
        Task { @MainActor in
            guard let host = self.shell?.currentInstall?.host else {
                call.reject("no install is open")
                return
            }
            let outcome = CallController.shared.start(host: host, meetingID: meetingID)
            call.resolve(["status": Self.status(outcome)])
        }
    }

    /// `{meetingId: string | null, phase: string}`.
    @objc func state(_ call: CAPPluginCall) {
        Task { @MainActor in
            let controller = CallController.shared
            var data: [String: Any] = ["phase": String(describing: controller.state.phase)]
            data["meetingId"] = controller.meetingID ?? NSNull()
            call.resolve(data)
        }
    }

    @objc func leave(_ call: CAPPluginCall) {
        Task { @MainActor in
            CallController.shared.leave()
            call.resolve()
        }
    }

    static func status(_ outcome: CallController.StartOutcome) -> String {
        switch outcome {
        case .starting: return "starting"
        case .alreadyInCall: return "already_in_call"
        case .busy: return "busy"
        }
    }
}
