import SwiftUI
import XCTest

@testable import App

/// The in-call screen's model and style (task 01a10db7 stage 4): the ring,
/// the row order, the copy and states of design canvas 01a11166.
final class InCallModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_791_000_000)
    private let saru = CallParticipant(id: "agent:saru", name: "Saru", isAgent: true)
    private let ada = CallParticipant(id: "user:ada", name: "Ada", isAgent: false)
    private let bo = CallParticipant(id: "user:bo", name: "Bo", isAgent: false)

    private func state(_ people: [CallParticipant], _ phase: CallPhase = .connected) -> CallState {
        var s = CallState()
        s.phase = phase
        s.meetingName = "Design review"
        s.participants = people
        s.hasConnected = true
        return s
    }

    private func speaking(_ p: CallParticipant, _ on: Bool = true) -> CallParticipant {
        var p = p
        p.isSpeaking = on
        return p
    }

    // MARK: The ring

    func testTheRingIsOnExactlyTheActiveSpeaker() {
        let m = InCallModel.make(state: state([saru, speaking(ada), bo]), elapsed: 12)
        XCTAssertEqual(m.ringed, ["user:ada"])
        XCTAssertEqual(m.people.filter(\.isSpeaking).map(\.name), ["Ada"])
    }

    func testNobodyIsRingedWhenTheRoomIsSilent() {
        XCTAssertEqual(InCallModel.make(state: state([saru, ada, bo]), elapsed: 12).ringed, [])
    }

    func testASpeakingAgentIsRingedAndAnswering() {
        let m = InCallModel.make(state: state([speaking(saru), ada]), elapsed: 12)
        XCTAssertEqual(m.ringed, ["agent:saru"])
        XCTAssertEqual(m.agents.first?.answering, "Saru is answering")
        XCTAssertNil(m.people.first { $0.name == "Ada" }?.answering, "people never read 'answering'")
    }

    // MARK: The "you" row (task 01a13c62 stage 1)

    /// The SFU's speaker update says WE speak: the "you" row rings, exactly
    /// as a remote speaker's does. It used to be hard-coded off.
    func testLocalSpeakingRingsYou() {
        var s = state([saru, ada])
        s.localSpeaking = true
        let m = InCallModel.make(state: s, elapsed: 12)
        XCTAssertEqual(m.ringed, ["you"])
        XCTAssertEqual(m.people.first?.isYou, true)
        XCTAssertEqual(m.people.first?.isSpeaking, true)
    }

    /// Reduced from the session's event, not set by hand: the same path the
    /// device takes.
    func testTheLocalSpeakingEventRingsYouAlongsideARemoteSpeaker() {
        var s = state([saru, speaking(ada)])
        s = CallState.reduce(s, .localParticipantChanged(identity: "user:me", isSpeaking: true))
        let m = InCallModel.make(state: s, elapsed: 12)
        XCTAssertEqual(Set(m.ringed), ["you", "user:ada"])
        // The ring moves; the list stays still.
        XCTAssertEqual(m.people.map(\.id), ["you", "user:ada"])
    }

    func testAMutedYouIsNotRinged() {
        var s = state([ada])
        s.localSpeaking = true
        s.isMuted = true
        let m = InCallModel.make(state: s, elapsed: 12)
        XCTAssertEqual(m.ringed, [])
        XCTAssertEqual(m.people.first?.isMuted, true)
    }

    func testASilentYouIsNotRinged() {
        let s = CallState.reduce(state([ada]), .localParticipantChanged(identity: "user:me", isSpeaking: false))
        XCTAssertEqual(InCallModel.make(state: s, elapsed: 12).ringed, [])
    }

    func testTheRingIsTheInfoSlotAtTwoPoints() {
        XCTAssertEqual(InCallStyle.ring, .info, "cyan marks live state; iOS primary is orange")
        XCTAssertNotEqual(InCallStyle.ring, .primary)
        XCTAssertEqual(InCallStyle.ringWidth, 2)
    }

    // MARK: Order

    /// The ring moves; the list stays still. Whoever speaks, the rows keep
    /// the participants' order: agents first, then You, then people.
    func testRowOrderIsStableAcrossSpeakerChanges() {
        let base = [saru, ada, bo]
        let silent = InCallModel.make(state: state(base), elapsed: 1)
        let expectedPeople = ["you", "user:ada", "user:bo"]
        XCTAssertEqual(silent.agents.map(\.id), ["agent:saru"])
        XCTAssertEqual(silent.people.map(\.id), expectedPeople)
        for speaker in base.indices {
            var people = base
            people[speaker].isSpeaking = true
            let m = InCallModel.make(state: state(people), elapsed: 1)
            XCTAssertEqual(m.agents.map(\.id), ["agent:saru"], "speaker \(speaker)")
            XCTAssertEqual(m.people.map(\.id), expectedPeople, "speaker \(speaker)")
        }
        // Bo speaking alone must not lift Bo above Ada.
        let m = InCallModel.make(state: state([saru, ada, speaking(bo)]), elapsed: 1)
        XCTAssertEqual(m.people.map(\.name), ["You", "Ada", "Bo"])
    }

    // MARK: States and copy

    func testConnectingShowsYouOnly() {
        var s = state([saru, ada], .connecting)
        s.hasConnected = false
        let m = InCallModel.make(state: s, elapsed: nil)
        XCTAssertEqual(m.status, "Connecting")
        XCTAssertEqual(m.statusKind, .connecting)
        XCTAssertEqual(m.agents, [])
        XCTAssertEqual(m.people.map(\.name), ["You"])
    }

    func testConnectedStatusIsTheClockAndTheHeadCount() {
        let m = InCallModel.make(state: state([saru, ada]), elapsed: 75)
        XCTAssertEqual(m.status, "1:15  ·  3 in meeting")
        XCTAssertEqual(m.title, "Design review")
        XCTAssertNil(m.aloneText)
        XCTAssertNil(m.recovery)
        XCTAssertFalse(m.dimsList)
    }

    func testAlone() {
        let m = InCallModel.make(state: state([], .alone), elapsed: 5)
        XCTAssertEqual(m.aloneText, "You're the only one here")
        XCTAssertEqual(m.status, "0:05  ·  1 in meeting")
    }

    func testReconnectingDimsTheList() {
        let m = InCallModel.make(state: state([ada], .reconnecting), elapsed: 30)
        XCTAssertEqual(m.status, "Reconnecting")
        XCTAssertTrue(m.dimsList)
        XCTAssertFalse(m.lostConnection)
        XCTAssertNil(m.recovery)
    }

    func testCouldNotReconnectOffersTryAgain() {
        let m = InCallModel.make(state: state([ada], .couldNotReconnect), elapsed: 30)
        XCTAssertTrue(m.lostConnection)
        XCTAssertEqual(m.recovery, .tryAgain)
        XCTAssertEqual(InCallCopy.lostConnection, "Lost connection to the meeting.")
        XCTAssertEqual(InCallCopy.tryAgain, "Try again")
    }

    func testOnHoldOffersResume() {
        var s = state([ada], .onHold)
        s.isMuted = true
        let m = InCallModel.make(state: s, elapsed: 30)
        XCTAssertEqual(m.status, "On hold")
        XCTAssertEqual(m.recovery, .resume)
        XCTAssertTrue(m.isMuted)
        XCTAssertTrue(m.people[0].isMuted, "the You row shows the slashed mic")
    }

    func testPoorConnectionKeepsTheClock() {
        let m = InCallModel.make(state: state([ada], .poorConnection), elapsed: 61)
        XCTAssertEqual(m.status, "1:01  ·  Poor connection")
    }

    func testMutedByHostNote() {
        var s = state([ada])
        s = CallState.reduce(s, .hostMuted(true))
        let m = InCallModel.make(state: s, elapsed: 3)
        XCTAssertTrue(m.isMuted)
        XCTAssertEqual(m.mutedByHostNote, "The host muted you. Tap Mute to talk.")
        XCTAssertNil(InCallModel.make(state: CallState.reduce(s, .setMuted(false)), elapsed: 3).mutedByHostNote)
    }

    func testEnded() {
        XCTAssertEqual(
            EndedModel.make(reason: .remoteEnded, elapsed: 1_234),
            EndedModel(title: "Meeting ended", duration: "20:34", showsOpenSpace: true))
        XCTAssertEqual(
            EndedModel.make(reason: .removed, elapsed: 60),
            EndedModel(title: "You were removed from the meeting", duration: "1:00", showsOpenSpace: false))
    }

    func testClock() {
        XCTAssertEqual(InCallCopy.clock(0), "0:00")
        XCTAssertEqual(InCallCopy.clock(59.9), "0:59")
        XCTAssertEqual(InCallCopy.clock(3_725), "1:02:05")
        XCTAssertEqual(InCallCopy.routeMoved("AirPods Pro"), "Audio moved to AirPods Pro")
    }

    // MARK: The call clock (CallState)

    func testTheClockRunsWhileConnectedAndPausesWhileReconnecting() {
        var s = CallState.reduce(CallState(), .startConnecting(meetingName: "x"))
        XCTAssertNil(s.elapsed(at: t0))
        s = CallState.reduce(s, .connected)
        s = CallState.reduce(s, .tick(t0))
        XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(10)), 10)
        s = CallState.reduce(s, .reconnecting(at: t0.addingTimeInterval(10)))
        s = CallState.reduce(s, .tick(t0.addingTimeInterval(10)))
        XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(25)), 10, "paused while reconnecting")
        s = CallState.reduce(s, .connected)
        s = CallState.reduce(s, .tick(t0.addingTimeInterval(25)))
        XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(30)), 15)
    }

    // MARK: Forced dark

    func testTheInCallScreenIsForcedDark() {
        let host = InCallHostingController(rootView: Text("x"))
        XCTAssertEqual(host.overrideUserInterfaceStyle, .dark)
        host.loadViewIfNeeded()
        XCTAssertEqual(host.traitCollection.userInterfaceStyle, .dark)
    }

    /// The shell presents the screen through the forced-dark host.
    func testTheShellPresentsTheScreenInTheDarkHost() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("App/SuiteBridgeViewController.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("InCallHostingController(rootView: InCallScreen("))
        XCTAssertFalse(source.contains("UIHostingController(rootView: InCallScreen("))
    }
}
