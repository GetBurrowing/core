import Capacitor
import Combine
import Foundation
import UIKit

/// What the plugin needs from the native call. `CallController` is the real
/// one; tests inject a fake.
@MainActor
protocol MeetingMediaControl: AnyObject {
    var state: CallState { get }
    var meetingID: String? { get }
    /// Resolves with the CONFIRMED mic state; throws when the change failed.
    func requestMuted(_ muted: Bool, timeout: TimeInterval) async throws -> Bool
    /// The page's CONFIRMED companion camera, reported to CallKit as
    /// `hasVideo` (task 01a13ca2 stage 4).
    func setVideoActive(_ active: Bool)
}

/// The media state the page draws, derived from `CallState`. Only confirmed
/// values: `mic` is `micEnabled`, never the request-time `isMuted`.
struct MeetingMediaSnapshot: Equatable {
    let mic: Bool
    let camera: Bool
    /// LiveKit identities (`user:<uuid>`, `agent:...`), ours included, sorted.
    let speaking: [String]

    init(_ state: CallState) {
        mic = state.micEnabled
        // Always false: the native call is audio only. The camera lives on
        // the page's companion connection (`video:user:`), and the page owns
        // its state; it reports it back through `setVideoActive`.
        camera = false
        speaking = state.speakingIdentities.sorted()
    }

    var media: [String: Any] { ["mic": mic, "camera": camera] }

    /// The listener events to send moving from `old` to `new`. No baseline
    /// (the first observation) sends nothing.
    static func events(from old: MeetingMediaSnapshot?, to new: MeetingMediaSnapshot) -> [(name: String, data: [String: Any])] {
        guard let old else { return [] }
        var events: [(name: String, data: [String: Any])] = []
        if old.mic != new.mic || old.camera != new.camera { events.append(("mediaChanged", new.media)) }
        if old.speaking != new.speaking { events.append(("activeSpeakers", ["identities": new.speaking])) }
        return events
    }
}

/// `SuiteMeetings` (task 01a10db7 stage 3): the web UI hands a meeting join
/// to the native call. Registered beside `SuiteNative` in
/// `BurrowBridgeViewController.capacitorDidLoad`.
///
/// `meeting_client.js` calls `join({meetingId})` INSTEAD of building its own
/// LiveKit `Room`: both would join as the same `user:<id>` identity, kick
/// each other out, and play the call twice. `callEnded` tells the page the
/// native call is over so it can push the same `meeting_left` its own
/// Disconnected handler pushes.
public class BurrowMeetingsPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "BurrowMeetingsPlugin"
    // The JS-facing wire name stays `SuiteMeetings`, as `SuiteNative` does
    // (docs/runbooks/burrow-rename-deferred.md).
    public let jsName = "SuiteMeetings"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "join", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "state", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "leave", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "capabilities", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setMuted", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setVideoActive", returnType: CAPPluginReturnPromise),
    ]

    /// What this build can do. Prod web is served to every installed build
    /// and Capacitor rejects an unknown method, so the page feature-detects
    /// with this. `camera` (task 01a13ca2 stage 4): the page may open its
    /// video-only companion connection, and this build has `setVideoActive`
    /// and the `appStateChanged` event.
    static let capabilities: [String: Any] = ["mic": true, "camera": true, "activeSpeakers": true]

    /// How long the app keeps running after it resigns active, so the page
    /// can turn the companion camera off before the web view is suspended.
    static let resignGrace: TimeInterval = 3

    /// How long `setMuted` waits for the SDK's confirmation.
    static let muteTimeout: TimeInterval = 5

    weak var shell: BurrowBridgeViewController?
    /// The native call. Injected by tests.
    var media: @MainActor () -> any MeetingMediaControl = { CallController.shared }
    private var stateObserver: AnyCancellable?
    private var lastSnapshot: MeetingMediaSnapshot?
    private var appStateObservers: [NSObjectProtocol] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    override public func load() {
        Task { @MainActor in
            CallController.shared.onCallEnded = { [weak self] meetingID in
                self?.notifyListeners("callEnded", data: ["meetingId": meetingID])
            }
            // `mediaChanged` and `activeSpeakers` on every CONFIRMED change,
            // whatever caused it: the page, the native screen, Control
            // Centre, AirPods, the lock screen or the host.
            self.stateObserver = CallController.shared.$state
                .map(MeetingMediaSnapshot.init)
                .removeDuplicates()
                .sink { [weak self] snapshot in
                    guard let self else { return }
                    let events = MeetingMediaSnapshot.events(from: self.lastSnapshot, to: snapshot)
                    self.lastSnapshot = snapshot
                    for event in events { self.notifyListeners(event.name, data: event.data) }
                }
        }
        observeAppState()
    }

    /// The `appStateChanged` payload for an application notification, or nil
    /// for any other notification.
    static func appStateEvent(_ name: Notification.Name) -> [String: Any]? {
        switch name {
        case UIApplication.willResignActiveNotification: return ["active": false]
        case UIApplication.didBecomeActiveNotification: return ["active": true]
        default: return nil
        }
    }

    /// `appStateChanged {active}`. willResignActive arrives before the web
    /// view is suspended: the page turns the companion camera off on
    /// `active: false`, under a background task of at most `resignGrace`.
    private func observeAppState() {
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification] {
            appStateObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    guard let self, let data = BurrowMeetingsPlugin.appStateEvent(note.name) else { return }
                    MainActor.assumeIsolated {
                        if data["active"] as? Bool == false { self.holdBackgroundTask() }
                        self.notifyListeners("appStateChanged", data: data)
                    }
                })
        }
    }

    @MainActor
    private func holdBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "meeting-camera-off") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resignGrace) { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
    }

    @MainActor
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// `{mic: true, camera: true, activeSpeakers: true}`.
    @objc func capabilities(_ call: CAPPluginCall) {
        call.resolve(Self.capabilities)
    }

    /// `{muted}` -> `{mic}` once the native call CONFIRMED the change, through
    /// the same CallKit mute as the native screen. Rejects on failure.
    @objc func setMuted(_ call: CAPPluginCall) {
        guard let muted = call.getBool("muted") else {
            call.reject("muted is required")
            return
        }
        Task { @MainActor in
            do {
                let mic = try await self.media().requestMuted(muted, timeout: Self.muteTimeout)
                call.resolve(["mic": mic])
            } catch {
                call.reject("Couldn't change the mic", "MIC_FAILED")
            }
        }
    }

    /// `{camera}` -> `{camera}`: the page's CONFIRMED companion camera,
    /// reported to CallKit as the call's `hasVideo`. Rejects without
    /// `camera`. Nothing here publishes or renders video.
    @objc func setVideoActive(_ call: CAPPluginCall) {
        guard let camera = call.getBool("camera") else {
            call.reject("camera is required")
            return
        }
        Task { @MainActor in
            self.media().setVideoActive(camera)
            call.resolve(["camera": camera])
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

    /// `{meetingId: string | null, phase: string, mic: bool, camera: bool,
    /// speaking: [identity]}`. `mic` is the CONFIRMED state; `camera` is
    /// the native call's, always false (the page owns the camera).
    @objc func state(_ call: CAPPluginCall) {
        Task { @MainActor in
            call.resolve(Self.statePayload(self.media()))
        }
    }

    @MainActor
    static func statePayload(_ media: any MeetingMediaControl) -> [String: Any] {
        let snapshot = MeetingMediaSnapshot(media.state)
        var data: [String: Any] = ["phase": String(describing: media.state.phase)]
        data["meetingId"] = media.meetingID ?? NSNull()
        data["mic"] = snapshot.mic
        data["camera"] = snapshot.camera
        data["speaking"] = snapshot.speaking
        return data
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
