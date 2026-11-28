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
    /// Another app is playing audio (a podcast, music).
    var isOtherAudioPlaying: Bool { get }
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

/// Who holds the Voice audio session (task 01a21e75 stage 5): the Voice
/// tab's plugin, or the native turn a Voice control, Action button or
/// widget starts (`VoiceTurnRunner`).
enum VoiceSessionHolder: String, Hashable {
    case plugin, runner
}

/// The Voice tab's audio session (task 01a20dc5 stage 1): active only for a
/// turn (the mic is open) or an utterance (a reply is playing), never for a
/// meeting. Meetings own their own session through `CallController`.
///
/// ONE owner of the session for both Voice paths (task 01a21e75 stage 5):
/// each path holds it through its own `handle(_:)`, the session is activated
/// by the first holder and deactivated only when the LAST one lets go. So the
/// plugin's background stop (which fires on `didEnterBackground`, exactly
/// when a native turn runs) releases only the plugin's hold and never the
/// runner's.
@MainActor
final class VoiceAudioSession: VoiceAudioSessionControl {
    /// The session both Voice paths share.
    static let shared = VoiceAudioSession()

    private let backend: VoiceAudioSessionBackend
    private(set) var isActive = false
    private(set) var holders: Set<VoiceSessionHolder> = []

    /// `holder`'s view of the shared session.
    func handle(_ holder: VoiceSessionHolder) -> VoiceAudioSessionHandle { VoiceAudioSessionHandle(session: self, holder: holder) }

    func activate(holder: VoiceSessionHolder) throws {
        if !isActive { try activate() }
        holders.insert(holder)
    }

    func deactivate(holder: VoiceSessionHolder) {
        holders.remove(holder)
        if holders.isEmpty { deactivateBackend() }
    }

    func isHeld(by holder: VoiceSessionHolder) -> Bool { holders.contains(holder) }
    /// The category before `activate()`, restored on `deactivate()`.
    private var previous: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

    init(backend: VoiceAudioSessionBackend = AVAudioSession.sharedInstance()) {
        self.backend = backend
    }

    /// `.defaultToSpeaker`: a reply plays from the loudspeaker, not the
    /// earpiece, when nothing is connected. `.allowBluetoothHFP`: a headset's
    /// mic can open (A2DP has no mic).
    ///
    /// `.interruptSpokenAudioAndMixWithOthers` + `.duckOthers` (task 01a20fdd
    /// stage 4): with another app's audio playing, a podcast or audiobook is
    /// PAUSED and music is DUCKED while the mic is open or a reply plays, and
    /// `deactivate()`'s `.notifyOthersOnDeactivation` lets it resume after.
    /// Without them the session is non-mixable: opening it interrupts the
    /// other app, and when that app took its audio back iOS interrupted
    /// THIS session, which `stopReason` reads as `interrupted`, so a toggled
    /// turn dropped right after the tap and a reply never played over or
    /// after a podcast.
    static let options: AVAudioSession.CategoryOptions = [
        .allowBluetoothHFP, .defaultToSpeaker, .duckOthers, .interruptSpokenAudioAndMixWithOthers,
    ]

    func activate() throws {
        if isActive { return }
        let before = (backend.category, backend.mode, backend.categoryOptions)
        // Read BEFORE activating: activating pauses a podcast
        // (`.interruptSpokenAudioAndMixWithOthers`), so afterwards it reads false.
        let otherBefore = backend.isOtherAudioPlaying
        do {
            try backend.setCategory(.playAndRecord, mode: .default, options: Self.options)
            try backend.setActive(true, options: [])
        } catch {
            try? backend.setCategory(before.0, mode: before.1, options: before.2)
            VoiceTrace.log("session activate failed other_audio=\(backend.isOtherAudioPlaying) error=\((error as NSError).code)")
            throw error
        }
        VoiceTrace.log(
            "session activated other_audio_before=\(otherBefore) other_audio=\(backend.isOtherAudioPlaying) route=\(Self.routeLabel(backend.routePortTypes) ?? "builtin")"
        )
        previous = before
        isActive = true
    }

    /// Deactivates whatever holds it (the single-owner form, kept for the
    /// plugin's own tests and callers without a holder).
    func deactivate() {
        holders.removeAll()
        deactivateBackend()
    }

    private func deactivateBackend() {
        guard isActive else { return }
        isActive = false
        try? backend.setActive(false, options: .notifyOthersOnDeactivation)
        VoiceTrace.log("session deactivated notify_others=true")
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
            // A began delivered because the APP was suspended earlier is
            // stale: nothing is interrupting the session now.
            if let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt,
                AVAudioSession.InterruptionReason(rawValue: reason) == .appWasSuspended
            {
                return nil
            }
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

/// One holder's view of the shared `VoiceAudioSession`: `activate` adds its
/// hold, `deactivate` drops only its hold, `isActive` is its own hold.
@MainActor
final class VoiceAudioSessionHandle: VoiceAudioSessionControl {
    let session: VoiceAudioSession
    let holder: VoiceSessionHolder

    init(session: VoiceAudioSession, holder: VoiceSessionHolder) {
        self.session = session
        self.holder = holder
    }

    var isActive: Bool { session.isHeld(by: holder) }
    func activate() throws { try session.activate(holder: holder) }
    func deactivate() { session.deactivate(holder: holder) }
    var routeLabel: String? { session.routeLabel }
    var hasOutputRoute: Bool { session.hasOutputRoute }
}

/// The two Voice paths stop each other (task 01a21e75 stage 5): a turn
/// started in the Voice tab stops a native turn, and a native turn stops
/// the tab's reply. Set by each side; nil when that side is not running.
@MainActor
enum VoiceCoordinator {
    static var stopRunner: (() -> Void)?
    static var stopPluginSpeakers: (() -> Void)?
}
