import AVFoundation
import CallKit
import Combine
import Foundation
import LiveKit
import os

/// The app's one native call (task 01a10db7 stage 3): one `CXProvider`, one
/// `CXCallController`, at most one `MeetingSession`.
///
/// Every state change the person can cause from outside the app (Lock
/// Screen, AirPods, Control Center, a cellular call) arrives as a CallKit
/// action, and the app's own controls REQUEST the same actions rather than
/// acting directly, so CallKit and our surface never disagree:
///
///   * start  -> `CXStartCallAction` (handle = the meeting's NAME, never an id)
///   * mute   -> `CXSetMutedCallAction`
///   * hold   -> `CXSetHeldCallAction` (mic off, `onHold`, no auto-resume)
///   * leave  -> `CXEndCallAction` -> disconnect + `POST .../leave`
///
/// What the surface draws is `state`, produced only by `CallState.reduce`.
@MainActor
final class CallController: NSObject, ObservableObject {
    static let shared = CallController()

    private static let log = Logger(subsystem: "com.kobo-ai.burrow", category: "meetings")

    @Published private(set) var state = CallState()
    /// The meeting the current call is for; nil when there is no call.
    @Published private(set) var meetingID: String?
    /// Whether the system accepted our CallKit transaction for this call.
    /// Nil before the first call; false means the call runs without CallKit
    /// (measured on the simulator, see the stage 3 notes).
    @Published private(set) var callKitAccepted: Bool?
    /// The last CallKit refusal, for the DEBUG measurement. No secrets.
    private(set) var lastCallKitError: String?

    /// Whether the in-call screen should be on screen. It stays up through
    /// the ended screen until Done; "Open full meeting" hides it while the
    /// call keeps the audio.
    @Published private(set) var presented = false
    /// The call's duration when it ended, for the ended screen.
    @Published private(set) var endedElapsed: TimeInterval?

    /// The plugin's `callEnded` event and the web hand-off listen here.
    var onCallEnded: ((String) -> Void)?
    /// Opens `path` on `host` in the shell's web view (set by the shell).
    var openWeb: ((_ host: String, _ path: String) -> Void)?

    /// The last call's install, meeting slug and space, kept past its end
    /// for "Open the space" and "Open full meeting".
    private(set) var lastHost: String?
    private(set) var meetingSlug: String?
    private(set) var spaceID: String?

    var api = MeetingAPI()

    private let provider: CXProvider
    /// Rings report through this (RingCenter holds it weakly).
    private let ringReporter: ProviderCallReporter
    private let callKit = CXCallController()
    /// CallKit has activated the audio session (an answered ring can
    /// activate it before the join returns).
    private var audioActive = false
    /// "Switch" from the invite banner: join this once the current call ends.
    private var pendingSwitch: (host: String, meetingID: String)?
    private var callUUID: UUID?
    private var host: String?
    private var session: MeetingSession?
    private var ticker: Timer?
    private var observers: [NSObjectProtocol] = []
    #if DEBUG
        /// DEBUG measurement: run the probe call without CallKit.
        private var probeSkipsCallKit = false
    #endif

    enum StartOutcome: Equatable {
        case starting
        /// A call for this same meeting is already up ("Open full meeting").
        case alreadyInCall
        /// A call for ANOTHER meeting is up; one call at a time.
        case busy
    }

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.includesCallsInRecents = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        // No ringtone file and no icon template until the arch mark merges
        // (design canvas): the system defaults stand.
        provider = CXProvider(configuration: config)
        ringReporter = ProviderCallReporter(provider: provider)
        super.init()
        provider.setDelegate(self, queue: nil)
        RingCenter.shared.reporter = ringReporter
        // CallKit owns the audio session; the SDK must not configure or
        // activate it on its own.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
    }

    // MARK: Requests (our surface, the plugin, the intents)

    /// `donates`: a call the person started in Burrow's UI is donated as a
    /// recipients-only meeting value (DonationPolicy); an intent run passes
    /// false, as the system already knows about it.
    @discardableResult
    func start(host: String, meetingID: String, donates: Bool = true, ifOver: (() -> Void)? = nil) -> StartOutcome {
        if let current = self.meetingID { return current == meetingID ? .alreadyInCall : .busy }
        self.meetingID = meetingID
        self.host = host
        lastHost = host
        endedElapsed = nil
        presented = true
        state = CallState.reduce(CallState(), .startConnecting(meetingName: nil))
        Task {
            do {
                let join = try await api.join(host: host, meetingID: meetingID)
                guard self.meetingID == meetingID else { return }
                begin(join)
                if donates { Self.donateJoin(join, host: host) }
            } catch MeetingAPI.Failure.meetingOver {
                finish(.meetingOver, callLeave: false)
                if let ifOver {
                    dismissEnded()
                    ifOver()
                }
            } catch {
                Self.log.error("meeting join refused meeting=\(meetingID, privacy: .public)")
                finish(.failed, callLeave: false)
            }
        }
        return .starting
    }

    func leave() {
        Self.log.info("meeting leave requested by the app")
        guard let uuid = callUUID else {
            finish(.local, callLeave: true)
            return
        }
        request(CXEndCallAction(call: uuid))
    }

    func setMuted(_ muted: Bool) {
        guard let uuid = callUUID else {
            // A call running without CallKit (refused on the simulator):
            // apply the mute directly.
            guard meetingID != nil else { return }
            state = CallState.reduce(state, .setMuted(muted))
            let session = self.session
            Task { await session?.setMicrophone(enabled: !muted) }
            return
        }
        request(CXSetMutedCallAction(call: uuid, muted: muted))
    }

    // MARK: The in-call screen's actions (stage 4)

    /// "Open full meeting": hide this screen, open the meeting's web page.
    /// The native call keeps the audio; the page's own join is a no-op.
    func openFullMeeting() {
        presented = false
        if let host = lastHost, let slug = meetingSlug { openWeb?(host, "/meetings/\(slug)") }
    }

    /// The Lock Screen Burrow button or a Recents tap brings the app back:
    /// show the screen again while a call exists.
    func reopen() {
        if meetingID != nil { presented = true }
    }

    /// Done on the ended screen.
    func dismissEnded() {
        presented = false
        if meetingID == nil {
            state = CallState()
            endedElapsed = nil
        }
    }

    /// "Open the space" on the ended screen.
    func openSpace() {
        let host = lastHost
        let space = spaceID
        dismissEnded()
        if let host, let space { openWeb?(host, "/chat/\(space)") }
    }

    /// "Try again" after the reconnect window: a fresh join of the same meeting.
    func tryAgain() {
        guard let meetingID, let host else { return }
        finish(.failed, callLeave: false)
        start(host: host, meetingID: meetingID)
    }

    // MARK: Rings (stage 5)

    /// An answered ring: join natively on the ring's CallKit UUID. No
    /// CXStartCallAction: CallKit already has this call. `completion(true)`
    /// once media connects (the answer action is fulfilled then).
    /// `uuid` nil: the simulator's in-app ring, with no CallKit call (the
    /// audio session is activated here, as stage 3's fallback does).
    func answerRing(host: String, meetingID: String, callUUID uuid: UUID?, completion: @escaping (Bool) -> Void) {
        guard self.meetingID == nil else { return completion(false) }
        self.meetingID = meetingID
        self.host = host
        lastHost = host
        endedElapsed = nil
        presented = true
        callUUID = uuid
        state = CallState.reduce(CallState(), .startConnecting(meetingName: nil))
        Task {
            do {
                let join = try await api.join(host: host, meetingID: meetingID)
                guard self.meetingID == meetingID else { return completion(false) }
                RecentCalls.record(handle: join.meeting.name, host: host, meetingID: meetingID, spaceID: join.meeting.spaceID)
                Self.donateJoin(join, host: host)
                prepare(join)
                Self.configureAudioSession()
                guard let session else { return completion(false) }
                if uuid == nil { try? AVAudioSession.sharedInstance().setActive(true) }
                try await session.connect(defaultURL: nil)
                if audioActive || uuid == nil { session.audioActivated() }
                state = CallState.reduce(state, .connected)
                publishRoute()
                completion(true)
            } catch MeetingAPI.Failure.meetingOver {
                Self.log.error("answered ring for a meeting that is over meeting=\(meetingID, privacy: .public)")
                completion(false)
                finish(.meetingOver, callLeave: false)
            } catch {
                Self.log.error("answered ring failed to join meeting=\(meetingID, privacy: .public)")
                completion(false)
                finish(.failed, callLeave: true)
            }
        }
    }

    /// The meeting alone (its id, name and slug), never who else is in it.
    private static func donateJoin(_ join: MeetingJoin, host: String) {
        Donations.shared.donate(.meetingJoined(host: host, meetingID: join.meeting.id, name: join.meeting.name, slug: join.meeting.slug))
    }

    /// "Switch" on the invite banner: leave this call, then join `meetingID`.
    func switchCall(host: String, meetingID: String) {
        guard self.meetingID != nil else {
            start(host: host, meetingID: meetingID)
            return
        }
        pendingSwitch = (host, meetingID)
        leave()
    }

    /// A tap on the call in Recents: rejoin if the meeting is live, else
    /// open its space.
    func rejoinFromRecents(handle: String) {
        guard let recent = RecentCalls.lookup(handle: handle) else { return }
        if let current = meetingID {
            if current == recent.meetingID { presented = true }
            return
        }
        start(host: recent.host, meetingID: recent.meetingID) { [weak self] in
            if let space = recent.spaceID { self?.openWeb?(recent.host, "/chat/\(space)") }
        }
    }

    /// The person resumes a held call. The mic stays off.
    func resume() {
        guard let uuid = callUUID else { return }
        request(CXSetHeldCallAction(call: uuid, onHold: false))
    }

    #if DEBUG
        /// DEBUG measurement only: connect to a LiveKit room directly, skipping
        /// the install's join route. Arguments come from the launch environment
        /// and are never logged.
        func startProbe(url: String, token: String, roomName: String, meetingName: String, useCallKit: Bool = true) {
            guard meetingID == nil else { return }
            probeSkipsCallKit = !useCallKit
            meetingID = "probe"
            presented = true
            state = CallState.reduce(CallState(), .startConnecting(meetingName: nil))
            let join = MeetingJoin(
                token: token, url: url, roomName: roomName, identity: "probe",
                meeting: .init(id: "probe", slug: "probe", name: meetingName, spaceID: "probe", status: "live"))
            begin(join)
        }
    #endif

    // MARK: Lifecycle

    /// The session, observers and clock for a join, before connecting.
    private func prepare(_ join: MeetingJoin) {
        state = CallState.reduce(state, .startConnecting(meetingName: join.meeting.name))
        meetingSlug = join.meeting.slug
        spaceID = join.meeting.spaceID
        let session = MeetingSession(join: join) { [weak self] event in
            self?.sessionEvent(event)
        }
        self.session = session
        observeAudioSession()
        startTicker()
    }

    private func begin(_ join: MeetingJoin) {
        prepare(join)
        if join.meeting.id != "probe" {
            RecentCalls.record(handle: join.meeting.name, host: host ?? "", meetingID: join.meeting.id, spaceID: join.meeting.spaceID)
        }

        #if DEBUG
            if probeSkipsCallKit {
                Self.log.info("meeting probe without callkit")
                connectWithoutCallKit()
                return
            }
        #endif
        let uuid = UUID()
        callUUID = uuid
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: join.meeting.name))
        action.isVideo = false
        callKit.request(CXTransaction(action: action)) { [weak self] error in
            Task { @MainActor in
                guard let self, self.callUUID == uuid else { return }
                if let error {
                    // Measured, not assumed: record why, then run the call
                    // without CallKit so the meeting still works.
                    self.callKitAccepted = false
                    self.lastCallKitError = "\((error as NSError).domain) \((error as NSError).code)"
                    Self.log.error("callkit start refused: \(self.lastCallKitError ?? "", privacy: .public)")
                    self.connectWithoutCallKit()
                } else {
                    self.callKitAccepted = true
                }
            }
        }
    }

    private func connect(reportingTo uuid: UUID?) {
        guard let session else { return }
        Task {
            do {
                try await session.connect(defaultURL: nil)
                if let uuid { provider.reportOutgoingCall(with: uuid, connectedAt: Date()) }
                state = CallState.reduce(state, .connected)
                publishRoute()
            } catch {
                Self.log.error("meeting connect failed kind=\(String(describing: type(of: error)), privacy: .public) code=\((error as NSError).code)")
                if let uuid { provider.reportCall(with: uuid, endedAt: Date(), reason: .failed) }
                finish(.failed, callLeave: true)
            }
        }
    }

    private func connectWithoutCallKit() {
        callUUID = nil
        Self.configureAudioSession()
        try? AVAudioSession.sharedInstance().setActive(true)
        connect(reportingTo: nil)
        session?.audioActivated()
    }

    private func sessionEvent(_ event: CallEvent) {
        switch event {
        case .ended(let reason):
            if let uuid = callUUID { provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded) }
            finish(reason, callLeave: true)
        case .hostMuted(true):
            state = CallState.reduce(state, event)
            // Keep CallKit's mute in step with the host's.
            if let uuid = callUUID { request(CXSetMutedCallAction(call: uuid, muted: true)) }
        default:
            state = CallState.reduce(state, event)
        }
    }

    private func finish(_ reason: CallEndReason, callLeave: Bool) {
        guard let meetingID else { return }
        let now = Date()
        state = CallState.reduce(state, .tick(now))
        endedElapsed = state.elapsed(at: now)
        state = CallState.reduce(state, .ended(reason))
        let session = self.session
        let host = self.host
        let api = self.api
        Task {
            await session?.disconnect()
            if callLeave, let host, meetingID != "probe" { try? await api.leave(host: host, meetingID: meetingID) }
        }
        ticker?.invalidate()
        ticker = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        self.session = nil
        self.callUUID = nil
        self.host = nil
        self.meetingID = nil
        onCallEnded?(meetingID)
        if let next = pendingSwitch {
            pendingSwitch = nil
            start(host: next.host, meetingID: next.meetingID)
        }
    }

    private func request(_ action: CXCallAction) {
        callKit.request(CXTransaction(action: action)) { error in
            if let error { Self.log.error("callkit action refused code=\((error as NSError).code)") }
        }
    }

    // MARK: Audio session, route, interruptions

    static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.publishRoute() }
            })
        observers.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                Task { @MainActor in
                    guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                    // Siri and other short interruptions: the mic pauses and
                    // comes back by itself. A cellular call holds the call
                    // through CXSetHeldCallAction instead.
                    self.state = CallState.reduce(
                        self.state, type == .began ? .interruptionBegan(at: Date()) : .interruptionEnded(at: Date()))
                }
            })
    }

    private func publishRoute() {
        let name = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName
        state = CallState.reduce(state, .routeChanged(name))
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.state = CallState.reduce(self.state, .tick(Date()))
            }
        }
    }
}

// MARK: - CXProviderDelegate

extension CallController: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.finish(.failed, callLeave: true) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            Self.configureAudioSession()
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
            action.fulfill()
            self.connect(reportingTo: action.callUUID)
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            Self.log.info("callkit answer action")
            Self.configureAudioSession()
            RingCenter.shared.answer(action.callUUID) { connected in
                connected ? action.fulfill() : action.fail()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            // Ending a call that is still ringing is a decline.
            if RingCenter.shared.isRinging(action.callUUID) {
                Self.log.info("callkit end action on a ringing call")
                RingCenter.shared.endedByCallKit(action.callUUID)
                action.fulfill()
                return
            }
            // A ring already settled (ended, answered elsewhere) or any call
            // that is not the current one: nothing of ours to hang up.
            let isCurrent = action.callUUID == self.callUUID
            let isUnknownWithoutCallKit = self.callUUID == nil && !RingCenter.shared.owns(action.callUUID)
            guard isCurrent || isUnknownWithoutCallKit else {
                action.fulfill()
                return
            }
            Self.log.info("callkit end action phase=\(String(describing: self.state.phase), privacy: .public)")
            self.finish(.local, callLeave: true)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            self.state = CallState.reduce(self.state, .setMuted(action.isMuted))
            let session = self.session
            Task { await session?.setMicrophone(enabled: !action.isMuted) }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        Task { @MainActor in
            if action.isOnHold {
                self.state = CallState.reduce(self.state, .held)
                let session = self.session
                Task { await session?.setMicrophone(enabled: false) }
            } else {
                self.state = CallState.reduce(self.state, .resumed)
            }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in
            Self.log.info("callkit audio session activated")
            self.audioActive = true
            self.session?.audioActivated()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in
            self.audioActive = false
            self.session?.audioDeactivated()
        }
    }
}
