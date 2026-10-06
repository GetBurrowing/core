import CallKit
import Foundation
import UIKit
import os

/// The CallKit half the ring path needs, so tests drive it with a fake.
protocol IncomingCallReporting: AnyObject {
    /// `CXProvider.reportNewIncomingCall`. `completion` gets CallKit's
    /// refusal, if any (a duplicate UUID, Do Not Disturb, ...).
    func reportIncoming(uuid: UUID, callerName: String, completion: @escaping (Error?) -> Void)
    /// `CXProvider.reportCall(with:endedAt:reason:)`.
    func reportEnded(uuid: UUID, reason: CXCallEndedReason)
}

/// The server half: `/api/app/rings/:id` and its transitions.
protocol RingServing {
    func ring(host: String, ringID: String) async throws -> RingStatus
    func transition(host: String, ringID: String, to action: RingAction) async throws
}

extension MeetingAPI: RingServing {}

/// Every VoIP push lands here, from the PushKit delegate and (DEBUG) the
/// injection seam alike, through `VoIPEntry`.
@MainActor
protocol IncomingVoIPHandling: AnyObject {
    func handleIncomingVoIP(payload: [AnyHashable: Any], completion: @escaping () -> Void)
}

/// Incoming rings (task 01a10db7 stage 5).
///
/// Apple's rule, and the order here: EVERY push reports a CallKit incoming
/// call first and only then calls PushKit's completion, whatever the
/// payload says: malformed, unknown install, duplicate, busy or stale.
/// Only after that does anything ask the server. The server decides who
/// is rung (stage 2); this never filters a ring on its own judgement, it
/// only ends calls the server says are over.
@MainActor
final class RingCenter: IncomingVoIPHandling {
    static let shared = RingCenter()

    /// Rings go unanswered after this long (the server's window is 45 s).
    static let ringTimeout: TimeInterval = 30

    private static let log = Logger(subsystem: "com.kobo-ai.burrow", category: "rings")

    enum Phase: Equatable {
        case ringing
        case answering
        case answered
        case declined
        case missed
        case ended
    }

    private struct Ring {
        let payload: RingPayload?
        var phase: Phase
        var cancelTimeout: (() -> Void)?
        /// CallKit dropped the call (simulator) and the ring carries on in
        /// the app's own prompt.
        var inApp = false
    }

    /// MEASURED on the iOS 26.3 simulator (stage 5): `reportNewIncomingCall`
    /// succeeds and the call reaches Ringing, then callservicesd fails to
    /// open `facetime://?launchForIncomingCall=1` (LSApplicationWorkspace
    /// error 115: no in-call UI app) and commits an unrequested
    /// CXEndCallAction about 70 ms later. That end is indistinguishable from
    /// a person's Decline, so on the simulator the ring degrades the way
    /// stage 3's outgoing call does: it carries on in the app (Answer joins
    /// without CallKit) instead of posting a decline nobody made. On a device
    /// an end action on a ringing call IS the person declining.
    #if targetEnvironment(simulator)
        var systemEndsIncomingCalls = true
    #else
        var systemEndsIncomingCalls = false
    #endif

    weak var reporter: IncomingCallReporting?
    var server: RingServing = MeetingAPI()
    /// Whether this install holds a bearer for `host`.
    var knowsInstall: (String) -> Bool = { host in
        InstallStore.shared.installs.contains { $0.host == host } && SuiteAPIClient.shared.isSignedIn(host: host)
    }
    /// Whether a native call is already up.
    var isBusy: () -> Bool = { CallController.shared.meetingID != nil }
    /// Joins the meeting natively; `uuid` is the CallKit call (nil: the
    /// in-app ring, no CallKit). The Bool is "media connected".
    var join: (_ host: String, _ meetingID: String, _ uuid: UUID?, _ done: @escaping (Bool) -> Void) -> Void = { host, meetingID, uuid, done in
        CallController.shared.answerRing(host: host, meetingID: meetingID, callUUID: uuid, completion: done)
    }
    /// Shows the in-call invite banner.
    var showInvite: (RingInvite) -> Void = { RingWaiting.shared.show($0) }
    /// Shows / clears the in-app incoming prompt (simulator degrade).
    var showIncoming: (RingInvite, UUID) -> Void = { RingWaiting.shared.showIncoming($0, uuid: $1) }
    var clearIncoming: (String) -> Void = { RingWaiting.shared.clearIncoming(ringID: $0) }
    /// Runs `after` seconds later; returns a cancel.
    var schedule: (_ after: TimeInterval, _ work: @escaping () -> Void) -> (() -> Void) = { after, work in
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: item)
        return { item.cancel() }
    }
    /// Keeps a POST alive while the phone locks: begin, then end.
    var backgroundTask: (_ name: String) -> (() -> Void) = { name in
        let id = UIApplication.shared.beginBackgroundTask(withName: name)
        return { UIApplication.shared.endBackgroundTask(id) }
    }

    private var rings: [UUID: Ring] = [:]
    private var tasks: [Task<Void, Never>] = []

    // MARK: The one entry point

    func handleIncomingVoIP(payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        let parsed = RingPayload(payload)
        let uuid = parsed?.callUUID ?? UUID()
        let previous = rings[uuid]
        let duplicate = previous.map { Self.holdsLiveRing($0.phase) } ?? false
        let name = parsed?.callerName ?? RingPayload.fallbackCallerName
        Self.log.info("ring push received parsed=\(parsed != nil) duplicate=\(duplicate) redelivery=\(previous != nil && !duplicate)")
        guard let reporter else {
            // No provider yet (cannot happen once the app is up): nothing
            // can be reported, so at least do not hold PushKit.
            Self.log.error("ring push with no CallKit reporter")
            completion()
            return
        }
        // A ring already settled (declined, missed, answered, ended) is
        // replaced: CallKit no longer has a call for its UUID and accepts
        // the new report, so the new call needs the whole normal path
        // (timeout, server check), never the duplicate no-op.
        if !duplicate { rings[uuid] = Ring(payload: parsed, phase: .ringing) }
        // FIRST: report. Completion only once CallKit has the call.
        reporter.reportIncoming(uuid: uuid, callerName: name) { [weak self] error in
            completion()
            MainActor.assumeIsolated {
                self?.reported(uuid: uuid, payload: parsed, duplicate: duplicate, previous: previous, error: error)
            }
        }
    }

    /// Whether a ring in `phase` still has a live CallKit call that refuses
    /// a second report for its UUID: ringing, or mid-answer. Every later
    /// phase is settled and a re-delivered push is a new call.
    private static func holdsLiveRing(_ phase: Phase) -> Bool {
        phase == .ringing || phase == .answering
    }

    /// After CallKit has the call: decide, from the payload and then the
    /// server, whether it keeps ringing.
    private func reported(uuid: UUID, payload: RingPayload?, duplicate: Bool, previous: Ring?, error: Error?) {
        if duplicate {
            // CallKit refuses a second report for a ringing UUID; the first
            // ring carries on untouched.
            Self.log.info("ring push duplicate; leaving the ringing call alone")
            return
        }
        if let error {
            let code = (error as NSError).code
            Self.log.error("ring report refused by callkit code=\(code)")
            // CallKit has no NEW call for this UUID: nothing to end. A busy
            // race still deserves the banner, unless this push re-delivered
            // a ring already settled here: that one goes back as it was (an
            // answered call CallKit still holds stays ours, no banner for it).
            if previous == nil, let payload, isBusy() { showInvite(RingInvite(payload)) }
            rings[uuid] = previous
            return
        }
        guard let payload else {
            end(uuid, reason: .failed)
            return
        }
        guard knowsInstall(payload.installHost) else {
            Self.log.error("ring push for an install this app is not signed in to")
            end(uuid, reason: .failed)
            return
        }
        RecentCalls.record(handle: payload.callerName, host: payload.installHost, meetingID: payload.meetingID, spaceID: payload.spaceID)
        if isBusy() {
            // The server's busy check raced a call starting here: never put
            // the current call on hold. End it, offer the banner.
            end(uuid, reason: .unanswered)
            showInvite(RingInvite(payload))
            return
        }
        rings[uuid]?.cancelTimeout = schedule(Self.ringTimeout) { [weak self] in
            MainActor.assumeIsolated { self?.timedOut(uuid) }
        }
        track {
            let status = try? await self.server.ring(host: payload.installHost, ringID: payload.ringID)
            guard let status, self.rings[uuid]?.phase == .ringing else { return }
            if !status.isRinging {
                Self.log.info("ring is over on the server state=\(status.state, privacy: .public)")
                self.end(uuid, reason: .remoteEnded)
            }
        }
    }

    // MARK: CallKit actions on a ringing call

    /// Whether `uuid` is a ring not yet answered (its CXEndCallAction is a
    /// decline, not a hang-up).
    func isRinging(_ uuid: UUID) -> Bool { rings[uuid]?.phase == .ringing }

    func owns(_ uuid: UUID) -> Bool { rings[uuid] != nil }

    /// `CXAnswerCallAction`: `/answer`, then the native join; `done(true)`
    /// once media connects (fulfil), `done(false)` to fail the action.
    func answer(_ uuid: UUID, done: @escaping (Bool) -> Void) {
        guard var ring = rings[uuid], ring.phase == .ringing, let payload = ring.payload else { return done(false) }
        let viaCallKit = !ring.inApp
        if ring.inApp { clearIncoming(payload.ringID) }
        ring.phase = .answering
        ring.cancelTimeout?()
        ring.cancelTimeout = nil
        rings[uuid] = ring
        track {
            do {
                try await self.server.transition(host: payload.installHost, ringID: payload.ringID, to: .answer)
            } catch {
                Self.log.error("ring answer refused")
                self.rings[uuid]?.phase = .ended
                done(false)
                return
            }
            self.join(payload.installHost, payload.meetingID, viaCallKit ? uuid : nil) { connected in
                MainActor.assumeIsolated {
                    self.rings[uuid]?.phase = connected ? .answered : .ended
                    done(connected)
                }
            }
        }
    }

    /// A `CXEndCallAction` on a ringing call. On a device that is the
    /// person declining; on the simulator it is the system (see
    /// `systemEndsIncomingCalls`) and the ring moves into the app.
    func endedByCallKit(_ uuid: UUID) {
        guard var ring = rings[uuid], ring.phase == .ringing else { return }
        guard systemEndsIncomingCalls else { return decline(uuid) }
        guard !ring.inApp, let payload = ring.payload else { return }
        Self.log.info("callkit ended a ringing call on the simulator; ringing in-app")
        ring.inApp = true
        rings[uuid] = ring
        showIncoming(RingInvite(payload), uuid)
    }

    /// `CXEndCallAction` while ringing: the person declined. `/decline`
    /// exactly once, inside a background task so it lands when locked.
    func decline(_ uuid: UUID) {
        guard var ring = rings[uuid], ring.phase == .ringing else { return }
        ring.phase = .declined
        ring.cancelTimeout?()
        ring.cancelTimeout = nil
        rings[uuid] = ring
        guard let payload = ring.payload else { return }
        if ring.inApp { clearIncoming(payload.ringID) }
        let endTask = backgroundTask("suite.ring.decline")
        track {
            try? await self.server.transition(host: payload.installHost, ringID: payload.ringID, to: .decline)
            endTask()
        }
    }

    private func timedOut(_ uuid: UUID) {
        guard var ring = rings[uuid], ring.phase == .ringing else { return }
        ring.phase = .missed
        ring.cancelTimeout = nil
        rings[uuid] = ring
        reporter?.reportEnded(uuid: uuid, reason: .unanswered)
        guard let payload = ring.payload else { return }
        if ring.inApp { clearIncoming(payload.ringID) }
        let endTask = backgroundTask("suite.ring.missed")
        track {
            try? await self.server.transition(host: payload.installHost, ringID: payload.ringID, to: .missed)
            endTask()
        }
    }

    private func end(_ uuid: UUID, reason: CXCallEndedReason) {
        if rings[uuid]?.inApp == true, let ringID = rings[uuid]?.payload?.ringID { clearIncoming(ringID) }
        rings[uuid]?.cancelTimeout?()
        rings[uuid]?.cancelTimeout = nil
        rings[uuid]?.phase = .ended
        reporter?.reportEnded(uuid: uuid, reason: reason)
    }

    // MARK: The in-call banner's choices

    /// "Not now": the inviter hears it as a decline.
    func declineWaiting(_ invite: RingInvite) {
        let endTask = backgroundTask("suite.ring.decline")
        track {
            try? await self.server.transition(host: invite.installHost, ringID: invite.ringID, to: .decline)
            endTask()
        }
    }

    /// Nobody chose within the banner's 30 s: a missed invite.
    func missWaiting(_ invite: RingInvite) {
        track { try? await self.server.transition(host: invite.installHost, ringID: invite.ringID, to: .missed) }
    }

    /// "Switch": `/answer`, then leave the current call and join this one.
    func switchTo(_ invite: RingInvite) {
        track {
            do {
                try await self.server.transition(host: invite.installHost, ringID: invite.ringID, to: .answer)
            } catch {
                Self.log.error("ring switch refused")
                return
            }
            CallController.shared.switchCall(host: invite.installHost, meetingID: invite.meetingID)
        }
    }

    // MARK: Test support

    func phase(of uuid: UUID) -> Phase? { rings[uuid]?.phase }

    /// Awaits every server call started so far (tests).
    func settle() async {
        while !tasks.isEmpty {
            let pending = tasks
            tasks.removeAll()
            for task in pending { await task.value }
        }
    }

    private func track(_ work: @escaping @MainActor () async -> Void) {
        tasks.append(Task { @MainActor in await work() })
    }
}

/// The ONE door into ring handling. The PushKit delegate and the DEBUG
/// injection seam both call `receive`, which calls
/// `handler.handleIncomingVoIP(payload:completion:)`; a test holds both
/// to it.
@MainActor
enum VoIPEntry {
    static var handler: IncomingVoIPHandling = RingCenter.shared

    static func receive(payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        handler.handleIncomingVoIP(payload: payload, completion: completion)
    }
}
