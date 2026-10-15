import Capacitor
import XCTest

@testable import App

/// A native call whose mute the test confirms or fails by hand.
@MainActor
private final class FakeMedia: MeetingMediaControl {
    var state = CallState()
    var meetingID: String? = "m1"
    var requests: [Bool] = []
    var failure: Error?
    private var pending: CheckedContinuation<Bool, Error>?

    func requestMuted(_ muted: Bool, timeout: TimeInterval) async throws -> Bool {
        requests.append(muted)
        if let failure { throw failure }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    func confirm(_ mic: Bool) {
        state = CallState.reduce(state, .micConfirmed(mic))
        pending?.resume(returning: mic)
        pending = nil
    }

    var isWaiting: Bool { pending != nil }
}

private struct SDKRefused: Error {}

/// `SuiteMeetings` (task 01a13c62 stage 2): capabilities, confirmed mute,
/// media state and active speakers for the in-app meeting page.
@MainActor
final class SuiteMeetingsPluginTests: XCTestCase {
    private var resolved: [String: Any]?
    private var rejected: String?

    private func makeCall(_ method: String, _ options: [String: Any] = [:], done: XCTestExpectation? = nil) -> CAPPluginCall {
        CAPPluginCall(
            callbackId: "1", methodName: method, options: options,
            success: { [weak self] result, _ in
                self?.resolved = result?.data
                done?.fulfill()
            },
            error: { [weak self] error in
                self?.rejected = error?.message
                done?.fulfill()
            })
    }

    private func makePlugin(_ media: FakeMedia) -> SuiteMeetingsPlugin {
        let plugin = SuiteMeetingsPlugin()
        plugin.media = { media }
        return plugin
    }

    func testTheNewMethodsAreRegistered() {
        let names = SuiteMeetingsPlugin().pluginMethods.map(\.name)
        for name in ["join", "state", "leave", "capabilities", "setMuted"] {
            XCTAssertTrue(names.contains(name), name)
        }
    }

    func testCapabilitiesShape() {
        let done = expectation(description: "resolved")
        SuiteMeetingsPlugin().capabilities(makeCall("capabilities", done: done))
        wait(for: [done], timeout: 1)
        XCTAssertEqual(resolved?["mic"] as? Bool, true)
        XCTAssertEqual(resolved?["camera"] as? Bool, false, "stage 4 flips camera")
        XCTAssertEqual(resolved?["activeSpeakers"] as? Bool, true)
        XCTAssertEqual(resolved?.count, 3)
    }

    func testStateShapeCarriesTheConfirmedMicAndEverySpeaker() {
        let media = FakeMedia()
        let events: [CallEvent] = [
            .startConnecting(meetingName: "Standup"), .connected,
            .participantsChanged([CallParticipant(id: "agent:x", name: "Higgins", isAgent: true, isSpeaking: true)]),
            .localParticipantChanged(identity: "user:me", isSpeaking: true),
            .micConfirmed(true), .setMuted(true),
        ]
        media.state = events.reduce(CallState(), CallState.reduce)
        let done = expectation(description: "resolved")
        makePlugin(media).state(makeCall("state", done: done))
        wait(for: [done], timeout: 1)
        XCTAssertEqual(resolved?["meetingId"] as? String, "m1")
        XCTAssertEqual(resolved?["phase"] as? String, "connected")
        XCTAssertEqual(resolved?["mic"] as? Bool, true, "the confirmed state, not the request")
        XCTAssertEqual(resolved?["camera"] as? Bool, false)
        XCTAssertEqual(resolved?["speaking"] as? [String], ["agent:x", "user:me"])
    }

    func testSetMutedResolvesOnlyAfterTheConfirmation() async {
        let media = FakeMedia()
        media.state = CallState.reduce(media.state, .micConfirmed(true))
        let done = expectation(description: "settled")
        makePlugin(media).setMuted(makeCall("setMuted", ["muted": true], done: done))
        for _ in 0..<50 where !media.isWaiting { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(media.requests, [true])
        XCTAssertTrue(media.isWaiting)
        XCTAssertNil(resolved, "nothing resolves before the SDK confirms")
        XCTAssertNil(rejected)
        media.confirm(false)
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(resolved?["mic"] as? Bool, false)
        XCTAssertNil(rejected)
    }

    func testSetMutedRejectsWhenTheChangeFails() async {
        let media = FakeMedia()
        media.failure = SDKRefused()
        let done = expectation(description: "settled")
        makePlugin(media).setMuted(makeCall("setMuted", ["muted": false], done: done))
        await fulfillment(of: [done], timeout: 1)
        XCTAssertNil(resolved)
        XCTAssertEqual(rejected, "Couldn't change the mic")
    }

    func testSetMutedWithoutMutedRejects() {
        let media = FakeMedia()
        let done = expectation(description: "settled")
        makePlugin(media).setMuted(makeCall("setMuted", done: done))
        wait(for: [done], timeout: 1)
        XCTAssertEqual(rejected, "muted is required")
        XCTAssertEqual(media.requests, [])
    }

    // MARK: Listeners

    private func connected() -> CallState {
        let events: [CallEvent] = [
            .startConnecting(meetingName: "Standup"), .connected, .localParticipantChanged(identity: "user:me", isSpeaking: false), .micConfirmed(true),
        ]
        return events.reduce(CallState(), CallState.reduce)
    }

    func testACallKitMuteEmitsMediaChanged() {
        let before = connected()
        // Control Centre: CXSetMutedCallAction, then the SDK's confirmation.
        let requested = CallState.reduce(before, .setMuted(true))
        XCTAssertTrue(
            MeetingMediaSnapshot.events(from: MeetingMediaSnapshot(before), to: MeetingMediaSnapshot(requested)).isEmpty,
            "a request alone is not a confirmed change")
        let confirmed = CallState.reduce(requested, .micConfirmed(false))
        let events = MeetingMediaSnapshot.events(from: MeetingMediaSnapshot(requested), to: MeetingMediaSnapshot(confirmed))
        XCTAssertEqual(events.map(\.name), ["mediaChanged"])
        XCTAssertEqual(events.first?.data["mic"] as? Bool, false)
        XCTAssertEqual(events.first?.data["camera"] as? Bool, false)
    }

    func testAFailedChangeEmitsNothing() {
        let before = CallState.reduce(connected(), .setMuted(true))
        let after = CallState.reduce(before, .micFailed)
        XCTAssertTrue(MeetingMediaSnapshot.events(from: MeetingMediaSnapshot(before), to: MeetingMediaSnapshot(after)).isEmpty)
    }

    func testSpeakingChangesEmitActiveSpeakersWithTheLocalIdentity() {
        let before = connected()
        let after = CallState.reduce(before, .localParticipantChanged(identity: "user:me", isSpeaking: true))
        let events = MeetingMediaSnapshot.events(from: MeetingMediaSnapshot(before), to: MeetingMediaSnapshot(after))
        XCTAssertEqual(events.map(\.name), ["activeSpeakers"])
        XCTAssertEqual(events.first?.data["identities"] as? [String], ["user:me"])
    }

    func testTheFirstObservationIsABaselineAndEmitsNothing() {
        XCTAssertTrue(MeetingMediaSnapshot.events(from: nil, to: MeetingMediaSnapshot(connected())).isEmpty)
    }
}
