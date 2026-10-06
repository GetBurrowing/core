import CallKit
import XCTest

@testable import App

/// Incoming rings (task 01a10db7 stage 5). Apple's rule first: every VoIP
/// push reports a CallKit incoming call BEFORE PushKit's completion runs,
/// whatever the payload; only then does anything ask the server.
@MainActor
final class VoIPHandlingTests: XCTestCase {
    /// One shared log, so order across CallKit, PushKit and the server is
    /// asserted, not inferred.
    final class Log {
        var events: [String] = []
    }

    final class FakeReporter: IncomingCallReporting {
        let log: Log
        var active: Set<UUID> = []
        var reported: [(UUID, String)] = []
        var ended: [(UUID, CXCallEndedReason)] = []
        /// When set, CallKit decides at report time but answers later
        /// (`release()`), as the real provider does.
        var hold = false
        var held: [() -> Void] = []

        init(log: Log) { self.log = log }

        func reportIncoming(uuid: UUID, callerName: String, completion: @escaping (Error?) -> Void) {
            reported.append((uuid, callerName))
            log.events.append("report")
            let error: Error?
            if active.contains(uuid) {
                error = NSError(domain: CXErrorDomainIncomingCall, code: CXErrorCodeIncomingCallError.callUUIDAlreadyExists.rawValue)
            } else {
                active.insert(uuid)
                error = nil
            }
            if hold { held.append { completion(error) } } else { completion(error) }
        }

        func release() {
            hold = false
            let pending = held
            held = []
            for work in pending { work() }
        }

        func reportEnded(uuid: UUID, reason: CXCallEndedReason) {
            ended.append((uuid, reason))
            active.remove(uuid)
            log.events.append("ended:\(reason.rawValue)")
        }
    }

    final class FakeServer: RingServing {
        let log: Log
        var status = RingStatus(id: "", state: "ringing", meetingID: "m1", meetingStatus: "live", spaceID: "s1")
        var refuse: Set<RingAction> = []
        var transitions: [RingAction] = []
        var statusCalls = 0

        init(log: Log) { self.log = log }

        func ring(host: String, ringID: String) async throws -> RingStatus {
            statusCalls += 1
            log.events.append("status")
            return status
        }

        func transition(host: String, ringID: String, to action: RingAction) async throws {
            transitions.append(action)
            log.events.append("post:\(action.rawValue)")
            if refuse.contains(action) { throw MeetingAPI.Failure.notRinging }
        }
    }

    private let ringID = "01a111f0-0000-7000-8000-000000000001"
    private var log: Log!
    private var reporter: FakeReporter!
    private var server: FakeServer!
    private var center: RingCenter!
    private var scheduled: [(TimeInterval, () -> Void)] = []
    private var invites: [RingInvite] = []
    private var busy = false
    private var joins: [(String, String, UUID?)] = []
    private var prompts: [String] = []
    private var joinResult = true
    private var backgroundBegun = 0
    private var backgroundEnded = 0

    override func setUp() async throws {
        RecentCalls.defaults = UserDefaults(suiteName: "VoIPHandlingTests.\(UUID().uuidString)")!
        log = Log()
        reporter = FakeReporter(log: log)
        server = FakeServer(log: log)
        center = RingCenter()
        center.reporter = reporter
        center.server = server
        center.knowsInstall = { $0 == "suite.example.com" }
        center.isBusy = { [unowned self] in self.busy }
        center.showInvite = { [unowned self] in self.invites.append($0) }
        center.schedule = { [unowned self] after, work in
            self.scheduled.append((after, work))
            return {}
        }
        center.systemEndsIncomingCalls = false
        center.showIncoming = { [unowned self] invite, _ in self.prompts.append("show:\(invite.ringID)") }
        center.clearIncoming = { [unowned self] ringID in self.prompts.append("clear:\(ringID)") }
        center.join = { [unowned self] host, meetingID, uuid, done in
            self.joins.append((host, meetingID, uuid))
            self.log.events.append("join")
            done(self.joinResult)
        }
        center.backgroundTask = { [unowned self] _ in
            self.backgroundBegun += 1
            return { self.backgroundEnded += 1 }
        }
    }

    private func payload(_ overrides: [String: Any?] = [:]) -> [AnyHashable: Any] {
        var p: [String: Any] = [
            "ring_id": ringID, "meeting_id": "m1", "space_id": "s1", "trigger": "live_invite",
            "caller_name": "Harper in Design review", "install_host": "suite.example.com",
            "sent_at": "2026-10-06T16:00:00Z",
        ]
        for (k, v) in overrides { p[k] = v }
        return p
    }

    /// Pushes and asserts, synchronously, that CallKit had the call before
    /// PushKit's completion ran.
    private func push(_ p: [AnyHashable: Any]) {
        let before = reporter.reported.count
        var completed = false
        center.handleIncomingVoIP(payload: p) {
            completed = true
            self.log.events.append("completion")
        }
        XCTAssertEqual(reporter.reported.count, before + 1, "exactly one report per push, made synchronously")
        XCTAssertTrue(completed, "PushKit's completion ran")
        guard let lastReport = log.events.lastIndex(of: "report"),
            let lastCompletion = log.events.lastIndex(of: "completion")
        else { return XCTFail("no report or no completion: \(log.events)") }
        XCTAssertLessThan(lastReport, lastCompletion, "report before completion: \(log.events)")
    }

    private var uuid: UUID { UUID(uuidString: ringID)! }

    // MARK: Every payload shape reports first

    func testAValidRingReportsThenChecksTheServer() async {
        push(payload())
        await center.settle()
        XCTAssertEqual(log.events, ["report", "completion", "status"])
        XCTAssertEqual(reporter.reported.first?.0, uuid, "the CallKit UUID is the ring id")
        XCTAssertEqual(reporter.reported.first?.1, "Harper in Design review")
        XCTAssertTrue(reporter.ended.isEmpty)
        XCTAssertEqual(center.phase(of: uuid), .ringing)
        XCTAssertEqual(scheduled.map(\.0), [30])
    }

    func testAMalformedPayloadStillReportsThenEndsFailed() async {
        for bad: [AnyHashable: Any] in [
            [:],
            payload(["ring_id": nil]),
            payload(["ring_id": "not-a-uuid"]),
            payload(["meeting_id": ""]),
            payload(["install_host": nil]),
        ] {
            reporter.ended = []
            push(bad)
            await center.settle()
            XCTAssertEqual(reporter.ended.map(\.1), [.failed], "\(bad)")
        }
        XCTAssertEqual(server.statusCalls, 0, "nothing to ask the server about")
        XCTAssertEqual(reporter.reported.first?.1, RingPayload.fallbackCallerName)
    }

    func testAnUnknownInstallStillReportsThenEndsFailed() async {
        push(payload(["install_host": "other.example.com"]))
        await center.settle()
        XCTAssertEqual(reporter.ended.map(\.1), [.failed])
        XCTAssertEqual(server.statusCalls, 0)
    }

    func testADuplicateWhileStillRingingStaysANoOp() async {
        push(payload())
        await center.settle()
        push(payload())
        await center.settle()
        XCTAssertEqual(reporter.reported.count, 2, "the duplicate is reported too (CallKit refuses it)")
        XCTAssertTrue(reporter.ended.isEmpty, "the first ring keeps ringing")
        XCTAssertEqual(center.phase(of: uuid), .ringing)
        XCTAssertEqual(server.statusCalls, 1, "no second server check")
        XCTAssertEqual(scheduled.count, 1, "no second timeout")
        XCTAssertEqual(log.events, ["report", "completion", "status", "report", "completion"])

        // CallKit answers the duplicate's report later; the first ring times
        // out meanwhile. Its end must stick: the refused duplicate does not
        // put a ringing entry back.
        reporter.hold = true
        center.handleIncomingVoIP(payload: payload()) {}
        scheduled[0].1()
        await center.settle()
        reporter.release()
        await center.settle()
        XCTAssertEqual(center.phase(of: uuid), .missed)
        XCTAssertFalse(center.isRinging(uuid))
        XCTAssertEqual(reporter.ended.map(\.1), [.unanswered])
        XCTAssertEqual(server.statusCalls, 1)
        XCTAssertEqual(scheduled.count, 1)
    }

    func testADuplicateWhileAnsweringStaysANoOp() async {
        push(payload())
        await center.settle()
        var fulfilled: Bool?
        center.answer(uuid) { fulfilled = $0 }
        XCTAssertEqual(center.phase(of: uuid), .answering)
        // CallKit refuses the duplicate after the answer has connected.
        reporter.hold = true
        center.handleIncomingVoIP(payload: payload()) {}
        await center.settle()
        reporter.release()
        await center.settle()
        XCTAssertEqual(reporter.reported.count, 2)
        XCTAssertEqual(fulfilled, true)
        XCTAssertEqual(joins.count, 1)
        XCTAssertEqual(center.phase(of: uuid), .answered)
        XCTAssertEqual(server.statusCalls, 1)
        XCTAssertTrue(reporter.ended.isEmpty)
    }

    // MARK: A push re-delivered after the ring settled (stage 6, finding 3)

    /// The ring is over on the server by the time the same payload comes
    /// back; CallKit no longer has a call for the UUID and accepts it.
    private func redeliverOverRing() async {
        server.status = RingStatus(id: ringID, state: "over", meetingID: "m1", meetingStatus: "ended", spaceID: "s1")
        let reports = reporter.reported.count
        let checks = server.statusCalls
        let timeouts = scheduled.count
        let endings = reporter.ended.count
        push(payload())
        await center.settle()
        XCTAssertEqual(reporter.reported.count, reports + 1, "exactly one new report")
        XCTAssertEqual(server.statusCalls, checks + 1, "the server was asked")
        XCTAssertEqual(scheduled.count, timeouts + 1, "the new call's 30 s timeout was armed")
        XCTAssertEqual(scheduled.last?.0, 30)
        XCTAssertEqual(reporter.ended.dropFirst(endings).map(\.1), [.remoteEnded], "ended because the server says over")
        XCTAssertEqual(Array(log.events.suffix(4)), ["report", "completion", "status", "ended:\(CXCallEndedReason.remoteEnded.rawValue)"])
        XCTAssertFalse(reporter.active.contains(uuid), "the app owns no ringing CallKit call")
        XCTAssertFalse(center.isRinging(uuid))
        var fulfilled: Bool?
        center.answer(uuid) { fulfilled = $0 }
        await center.settle()
        XCTAssertEqual(fulfilled, false, "answer is not possible")
    }

    func testARedeliveredPushAfterDeclineIsReportedCheckedAndEnded() async {
        push(payload())
        await center.settle()
        center.endedByCallKit(uuid)
        reporter.active.remove(uuid)  // CallKit ended the declined call.
        await center.settle()
        XCTAssertEqual(center.phase(of: uuid), .declined)
        await redeliverOverRing()
        XCTAssertEqual(server.transitions, [.decline], "no second decline, no answer")
        XCTAssertTrue(joins.isEmpty)
    }

    func testARedeliveredPushAfterMissedIsReportedCheckedAndEnded() async {
        push(payload())
        await center.settle()
        scheduled[0].1()
        await center.settle()
        XCTAssertEqual(center.phase(of: uuid), .missed)
        await redeliverOverRing()
        XCTAssertEqual(reporter.ended.map(\.1), [.unanswered, .remoteEnded])
        XCTAssertEqual(server.transitions, [.missed])
    }

    func testARedeliveredPushAfterAnsweredAndEndedIsReportedCheckedAndEnded() async {
        push(payload())
        await center.settle()
        center.answer(uuid) { _ in }
        await center.settle()
        XCTAssertEqual(center.phase(of: uuid), .answered)
        reporter.active.remove(uuid)  // The person hung up; CallKit has no call.
        await redeliverOverRing()
        XCTAssertEqual(server.transitions, [.answer])
        XCTAssertEqual(joins.count, 1, "no second join")
    }

    func testARedeliveredPushTheServerStillRingsTimesOutOnItsOwnTimer() async {
        push(payload())
        await center.settle()
        center.decline(uuid)
        reporter.active.remove(uuid)
        await center.settle()
        push(payload())
        await center.settle()
        XCTAssertEqual(server.statusCalls, 2)
        XCTAssertTrue(center.isRinging(uuid), "the server says ringing: it rings")
        XCTAssertEqual(scheduled.count, 2)
        scheduled[1].1()
        await center.settle()
        XCTAssertEqual(reporter.ended.map(\.1), [.unanswered], "the new call's own 30 s timeout ended it")
        XCTAssertEqual(server.transitions, [.decline, .missed])
    }

    func testARedeliveryCallKitRefusesLeavesTheAnsweredCallOurs() async {
        push(payload())
        await center.settle()
        center.answer(uuid) { _ in }
        await center.settle()
        busy = true  // the answered call is up; CallKit still holds the UUID
        push(payload())
        await center.settle()
        XCTAssertEqual(center.phase(of: uuid), .answered)
        XCTAssertTrue(center.owns(uuid))
        XCTAssertTrue(invites.isEmpty, "no banner inviting us to our own call")
        XCTAssertTrue(reporter.ended.isEmpty)
        XCTAssertEqual(server.statusCalls, 1)
    }

    func testABusyCalleeIsReportedThenEndedUnansweredWithTheBanner() async {
        busy = true
        push(payload())
        await center.settle()
        XCTAssertEqual(reporter.ended.map(\.1), [.unanswered])
        XCTAssertEqual(invites, [RingInvite(ringID: ringID, meetingID: "m1", installHost: "suite.example.com", title: "Harper in Design review")])
        XCTAssertEqual(server.statusCalls, 0)
    }

    // MARK: Over on the server

    func testARingTheServerCallsOverEndsRemoteEnded() async {
        server.status = RingStatus(id: ringID, state: "over", meetingID: "m1", meetingStatus: "ended", spaceID: "s1")
        push(payload())
        await center.settle()
        XCTAssertEqual(log.events, ["report", "completion", "status", "ended:\(CXCallEndedReason.remoteEnded.rawValue)"])
    }

    func testARingWhoseMeetingEndedEndsRemoteEnded() async {
        server.status = RingStatus(id: ringID, state: "ringing", meetingID: "m1", meetingStatus: "ended", spaceID: "s1")
        push(payload())
        await center.settle()
        XCTAssertEqual(reporter.ended.map(\.1), [.remoteEnded])
    }

    // MARK: Decline, timeout, answer

    func testDeclinePostsDeclineOnceInABackgroundTask() async {
        push(payload())
        await center.settle()
        center.decline(uuid)
        center.decline(uuid)
        await center.settle()
        XCTAssertEqual(server.transitions, [.decline])
        XCTAssertEqual(backgroundBegun, 1)
        XCTAssertEqual(backgroundEnded, 1, "the background task ends after the POST")
        XCTAssertFalse(center.isRinging(uuid))
    }

    func testThirtySecondsUnansweredEndsTheCallAndPostsMissed() async {
        push(payload())
        await center.settle()
        XCTAssertEqual(scheduled.count, 1)
        scheduled[0].1()
        await center.settle()
        XCTAssertEqual(reporter.ended.map(\.1), [.unanswered])
        XCTAssertEqual(server.transitions, [.missed])
        XCTAssertEqual(center.phase(of: uuid), .missed)
    }

    func testAnswerPostsAnswerThenJoins() async {
        push(payload())
        await center.settle()
        var fulfilled: Bool?
        center.answer(uuid) { fulfilled = $0 }
        await center.settle()
        XCTAssertEqual(Array(log.events.suffix(2)), ["post:answer", "join"])
        XCTAssertEqual(joins.first?.0, "suite.example.com")
        XCTAssertEqual(joins.first?.1, "m1")
        XCTAssertEqual(joins.first?.2, uuid)
        XCTAssertEqual(fulfilled, true)
        XCTAssertEqual(center.phase(of: uuid), .answered)
        // The answered call's later hang-up is not a decline.
        center.decline(uuid)
        await center.settle()
        XCTAssertEqual(server.transitions, [.answer])
    }

    func testAnAnswerTheServerRefusesFailsTheActionAndDoesNotJoin() async {
        server.refuse = [.answer]
        push(payload())
        await center.settle()
        var fulfilled: Bool?
        center.answer(uuid) { fulfilled = $0 }
        await center.settle()
        XCTAssertEqual(fulfilled, false)
        XCTAssertTrue(joins.isEmpty)
    }

    func testAnAnswerWhoseMediaNeverConnectsFails() async {
        joinResult = false
        push(payload())
        await center.settle()
        var fulfilled: Bool?
        center.answer(uuid) { fulfilled = $0 }
        await center.settle()
        XCTAssertEqual(fulfilled, false)
    }

    // MARK: CallKit ending a ringing call

    func testOnADeviceCallKitEndingARingingCallIsADecline() async {
        push(payload())
        await center.settle()
        center.endedByCallKit(uuid)
        center.endedByCallKit(uuid)
        await center.settle()
        XCTAssertEqual(server.transitions, [.decline])
        XCTAssertTrue(prompts.isEmpty)
    }

    /// The measured simulator behaviour: the system ends the incoming call
    /// itself. No decline is invented; the ring carries on in the app and
    /// Answer joins with no CallKit call.
    func testOnTheSimulatorTheSystemEndMovesTheRingInApp() async {
        center.systemEndsIncomingCalls = true
        push(payload())
        await center.settle()
        center.endedByCallKit(uuid)
        center.endedByCallKit(uuid)
        await center.settle()
        XCTAssertTrue(server.transitions.isEmpty, "nobody declined")
        XCTAssertEqual(prompts, ["show:\(ringID)"])
        XCTAssertTrue(center.isRinging(uuid))
        var fulfilled: Bool?
        center.answer(uuid) { fulfilled = $0 }
        await center.settle()
        XCTAssertEqual(server.transitions, [.answer])
        XCTAssertEqual(joins.count, 1)
        XCTAssertNil(joins[0].2, "joined without CallKit")
        XCTAssertEqual(fulfilled, true)
        XCTAssertEqual(prompts, ["show:\(ringID)", "clear:\(ringID)"])
    }

    func testOnTheSimulatorTheInAppDeclinePostsDeclineOnce() async {
        center.systemEndsIncomingCalls = true
        push(payload())
        await center.settle()
        center.endedByCallKit(uuid)
        center.decline(uuid)
        center.decline(uuid)
        await center.settle()
        XCTAssertEqual(server.transitions, [.decline])
        XCTAssertEqual(prompts.last, "clear:\(ringID)")
    }

    // MARK: Payload decoding

    func testThePayloadCarriesNoToken() {
        let p = RingPayload(payload())
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.callUUID, uuid)
        XCTAssertEqual(p?.installHost, "suite.example.com")
        XCTAssertEqual(RingPayload(payload(["caller_name": "  "]))?.callerName, "Burrow")
    }
}

/// The PushKit delegate and the DEBUG seam share ONE entry point:
/// `VoIPEntry.receive` -> `handleIncomingVoIP(payload:completion:)`.
@MainActor
final class VoIPEntryPointTests: XCTestCase {
    final class Recorder: IncomingVoIPHandling {
        var payloads: [[AnyHashable: Any]] = []
        func handleIncomingVoIP(payload: [AnyHashable: Any], completion: @escaping () -> Void) {
            payloads.append(payload)
            completion()
        }
    }

    private var saved: IncomingVoIPHandling!

    override func setUp() async throws {
        saved = VoIPEntry.handler
    }

    override func tearDown() async throws {
        VoIPEntry.handler = saved
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testTheSeamGoesThroughTheSameHandlerAsPushKit() throws {
        let recorder = Recorder()
        VoIPEntry.handler = recorder
        let json = try JSONSerialization.data(withJSONObject: ["ring_id": "r1", "meeting_id": "m1"])
        let encoded = json.base64EncodedString()

        DebugVoIPSeam.inject(base64: encoded)
        XCTAssertTrue(DebugVoIPSeam.handle(url: URL(string: "burrow://debug/voip?payload=\(encoded)")!))
        XCTAssertFalse(DebugVoIPSeam.handle(url: URL(string: "burrow://open?host=a.example&path=/")!))
        // A payload that is not base64 JSON still reaches the handler, empty.
        DebugVoIPSeam.inject(base64: "%%%")

        guard recorder.payloads.count == 3 else {
            return XCTFail("the seam reached the entry point \(recorder.payloads.count) of 3 times")
        }
        XCTAssertEqual(recorder.payloads[0]["ring_id"] as? String, "r1")
        XCTAssertEqual(recorder.payloads[1]["meeting_id"] as? String, "m1")
        XCTAssertTrue(recorder.payloads[2].isEmpty)
    }

    func testThePushKitDelegateCallsTheEntryPoint() {
        let recorder = Recorder()
        VoIPEntry.handler = recorder
        var completed = false
        VoIPEntry.receive(payload: ["ring_id": "r2"]) { completed = true }
        XCTAssertEqual(recorder.payloads.first?["ring_id"] as? String, "r2")
        XCTAssertTrue(completed)
    }

    /// The delegate method's body is the one `VoIPEntry.receive` call, and
    /// the seam's inject goes through it too: read from the source, since
    /// a `PKPushPayload` cannot be built in a test.
    func testBothDoorsCallVoIPEntryReceiveInTheSource() throws {
        let source = try String(contentsOf: appRoot.appendingPathComponent("App/Meetings/VoIPRegistrar.swift"), encoding: .utf8)
        let delegate = try XCTUnwrap(source.range(of: "didReceiveIncomingPushWith payload: PKPushPayload"))
        let delegateBody = source[delegate.upperBound...].prefix(400)
        XCTAssertTrue(delegateBody.contains("VoIPEntry.receive(payload: dictionary, completion: completion)"), String(delegateBody))
        let seam = try XCTUnwrap(source.range(of: "static func inject(base64: String"))
        XCTAssertTrue(source[seam.upperBound...].prefix(300).contains("VoIPEntry.receive(payload:"))
        XCTAssertEqual(source.components(separatedBy: "handleIncomingVoIP(").count - 1, 0, "nothing here calls a handler directly")
    }
}
