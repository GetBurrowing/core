import AVFoundation
import UIKit

/// The slice of `AVAudioSession` the Voice tab uses. `AVAudioSession` is the
/// real one; tests inject a fake that records every call.
protocol VoiceAudioSessionBackend: AnyObject {
    var category: AVAudioSession.Category { get }
    var mode: AVAudioSession.Mode { get }
    var categoryOptions: AVAudioSession.CategoryOptions { get }
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
    /// The port TYPES of the current route, inputs then outputs.
    var routePortTypes: [AVAudioSession.Port] { get }
    var hasOutputRoute: Bool { get }
}

extension AVAudioSession: VoiceAudioSessionBackend {
    var routePortTypes: [AVAudioSession.Port] { (currentRoute.inputs + currentRoute.outputs).map(\.portType) }
    var hasOutputRoute: Bool { !currentRoute.outputs.isEmpty }
}

/// What the plugin needs from the audio session.
@MainActor
protocol VoiceAudioSessionControl: AnyObject {
    /// True only while THIS object holds the session active.
    var isActive: Bool { get }
    /// `.playAndRecord` and `setActive(true)`. Throws when another app
    /// (or a call) holds the microphone.
    func activate() throws
    /// `setActive(false, .notifyOthersOnDeactivation)`, and the category the
    /// app had before. A no-op unless `activate()` succeeded: the plugin never
    /// deactivates a session it did not activate.
    func deactivate()
    /// "Bluetooth", "Headphones", "Car", or nil for the built-in mic and
    /// speaker (`VoiceAudioSession.routeLabel`).
    var routeLabel: String? { get }
    var hasOutputRoute: Bool { get }
}

/// The Voice tab's audio session (task 01a20dc5 stage 1): active only for a
/// turn (the mic is open) or an utterance (a reply is playing), never for a
/// meeting. Meetings own their own session through `CallController`.
@MainActor
final class VoiceAudioSession: VoiceAudioSessionControl {
    private let backend: VoiceAudioSessionBackend
    private(set) var isActive = false
    /// The category before `activate()`, restored on `deactivate()`.
    private var previous: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

    init(backend: VoiceAudioSessionBackend = AVAudioSession.sharedInstance()) {
        self.backend = backend
    }

    /// `.defaultToSpeaker`: a reply plays from the loudspeaker, not the
    /// earpiece, when nothing is connected. `.allowBluetoothHFP`: a headset's
    /// mic can open (A2DP has no mic).
    static let options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]

    func activate() throws {
        if isActive { return }
        let before = (backend.category, backend.mode, backend.categoryOptions)
        do {
            try backend.setCategory(.playAndRecord, mode: .default, options: Self.options)
            try backend.setActive(true, options: [])
        } catch {
            try? backend.setCategory(before.0, mode: before.1, options: before.2)
            throw error
        }
        previous = before
        isActive = true
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        try? backend.setActive(false, options: .notifyOthersOnDeactivation)
        if let previous {
            try? backend.setCategory(previous.0, mode: previous.1, options: previous.2)
        }
        previous = nil
    }

    var routeLabel: String? { Self.routeLabel(backend.routePortTypes) }
    var hasOutputRoute: Bool { backend.hasOutputRoute }

    /// The test caption's route, from the port TYPE only. Never `portName`:
    /// that is the name the person gave their device, often their own name.
    static func routeLabel(_ ports: [AVAudioSession.Port]) -> String? {
        if ports.contains(where: { [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE].contains($0) }) { return "Bluetooth" }
        if ports.contains(.carAudio) { return "Car" }
        if ports.contains(where: { [.headphones, .headsetMic, .usbAudio].contains($0) }) { return "Headphones" }
        return nil
    }

    /// Why a system notification stops the Voice turn and any reply, or nil
    /// when it does not (canvas states 10 and 16).
    /// - an interruption that BEGAN (a phone call, Siri): `interrupted`;
    /// - the route lost its device (AirPods out): `route_lost`, so the reply
    ///   stops instead of moving to the loudspeaker;
    /// - the app went to the background (another app, the lock screen):
    ///   `background`. The page's JS may already be suspended, so the native
    ///   side stops everything itself.
    nonisolated static func stopReason(for note: Notification) -> String? {
        switch note.name {
        case UIApplication.didEnterBackgroundNotification:
            return "background"
        case AVAudioSession.interruptionNotification:
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: raw) == .began
            else { return nil }
            return "interrupted"
        case AVAudioSession.routeChangeNotification:
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
            else { return nil }
            return "route_lost"
        default:
            return nil
        }
    }
}
