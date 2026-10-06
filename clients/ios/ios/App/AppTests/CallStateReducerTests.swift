import XCTest

@testable import App

/// `CallState.reduce`: every transition the call surface draws.
final class CallStateReducerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_791_000_000)
    private let ada = CallParticipant(id: "user:a", name: "Ada", isAgent: false)

    private func run(_ events: [CallEvent], from state: CallState = CallState()) -> CallState {
        events.reduce(state, CallState.reduce)
    }

    private func connectedAlone() -> CallState {
        run([.startConnecting(meetingName: "Design review"), .connected])
    }

    func testConnectingThenConnectedAloneThenWithOthers() {
        var s = run([.startConnecting(meetingName: "Design review")])
        XCTAssertEqual(s.phase, .connecting)
        XCTAssertEqual(s.meetingName, "Design review")
        s = CallState.reduce(s, .connected)
        XCTAssertEqual(s.phase, .alone, "nobody else is in the call")
        s = CallState.reduce(s, .participantsChanged([ada]))
        XCTAssertEqual(s.phase, .connected)
        s = CallState.reduce(s, .participantsChanged([]))
        XCTAssertEqual(s.phase, .alone)
    }

    func testReconnectingRecoversWithinTheWindow() {
        var s = run([.participantsChanged([ada]), .reconnecting(at: t0), .tick(t0.addingTimeInterval(29))], from: connectedAlone())
        XCTAssertEqual(s.phase, .reconnecting)
        s = CallState.reduce(s, .connected)
        XCTAssertEqual(s.phase, .connected)
        XCTAssertNil(s.reconnectingSince)
    }

    func testThirtySecondsOfReconnectingIsCouldNotReconnect() {
        let s = run(
            [
                .reconnecting(at: t0), .tick(t0.addingTimeInterval(15)), .reconnecting(at: t0.addingTimeInterval(20)),
                .tick(t0.addingTimeInterval(30)),
            ], from: connectedAlone())
        XCTAssertEqual(s.phase, .couldNotReconnect, "the window counts from the FIRST reconnecting event")
    }

    func testPoorConnectionComesAndGoes() {
        var s = CallState.reduce(connectedAlone(), .connectionQuality(poor: true))
        XCTAssertEqual(s.phase, .poorConnection)
        s = CallState.reduce(s, .connectionQuality(poor: false))
        XCTAssertEqual(s.phase, .alone)
        // Quality reports while not connected change nothing.
        let connecting = run([.startConnecting(meetingName: nil), .connectionQuality(poor: true)])
        XCTAssertEqual(connecting.phase, .connecting)
    }

    func testMuteSurvivesARouteChange() {
        var s = run([.setMuted(true), .routeChanged("AirPods Pro")], from: connectedAlone())
        XCTAssertTrue(s.isMuted)
        XCTAssertEqual(s.route, "AirPods Pro")
        s = run([.setMuted(false), .routeChanged("iPhone")], from: s)
        XCTAssertFalse(s.isMuted, "unmuted stays unmuted when AirPods come out")
        XCTAssertEqual(s.route, "iPhone")
    }

    func testHoldTurnsTheMicOffAndNeverResumesOnItsOwn() {
        var s = CallState.reduce(connectedAlone(), .held)
        XCTAssertEqual(s.phase, .onHold)
        XCTAssertTrue(s.isMuted)
        // Nothing that is not the person's own resume leaves hold.
        s = run(
            [
                .connected, .interruptionEnded(at: t0), .tick(t0.addingTimeInterval(120)),
                .participantsChanged([ada]), .routeChanged("iPhone"),
            ], from: s)
        XCTAssertEqual(s.phase, .onHold)
        s = CallState.reduce(s, .resumed)
        XCTAssertEqual(s.phase, .connected)
        XCTAssertTrue(s.isMuted, "resuming does not open the mic")
    }

    func testShortInterruptionResumesAndIsNotFlagged() {
        let s = run(
            [.interruptionBegan(at: t0), .tick(t0.addingTimeInterval(3)), .interruptionEnded(at: t0.addingTimeInterval(4))],
            from: connectedAlone())
        XCTAssertEqual(s.phase, .alone)
        XCTAssertFalse(s.isMuted)
        XCTAssertNil(s.micPausedSince)
        XCTAssertFalse(s.hadLongMicPause)
    }

    func testAMicPauseOverFiveSecondsIsFlagged() {
        let viaTick = run([.interruptionBegan(at: t0), .tick(t0.addingTimeInterval(6))], from: connectedAlone())
        XCTAssertTrue(viaTick.hadLongMicPause)
        let viaEnd = run([.interruptionBegan(at: t0), .interruptionEnded(at: t0.addingTimeInterval(7))], from: connectedAlone())
        XCTAssertTrue(viaEnd.hadLongMicPause)
    }

    func testHostMuteMutesAndIsCleared() {
        var s = CallState.reduce(connectedAlone(), .hostMuted(true))
        XCTAssertTrue(s.isMuted)
        XCTAssertTrue(s.mutedByHost)
        s = CallState.reduce(s, .setMuted(false))
        XCTAssertFalse(s.isMuted)
        XCTAssertFalse(s.mutedByHost)
    }

    func testEndedIsTerminal() {
        var s = CallState.reduce(connectedAlone(), .ended(.remoteEnded))
        XCTAssertEqual(s.phase, .ended(.remoteEnded))
        s = run([.connected, .reconnecting(at: t0), .held, .participantsChanged([ada])], from: s)
        XCTAssertEqual(s.phase, .ended(.remoteEnded))
    }

    func testAgentsAndUnresolvedNames() {
        XCTAssertTrue(CallParticipant.isAgent(kindIsAgent: true, metadata: nil))
        XCTAssertTrue(CallParticipant.isAgent(kindIsAgent: false, metadata: #"{"agent": true}"#))
        XCTAssertFalse(CallParticipant.isAgent(kindIsAgent: false, metadata: #"{"agent": false}"#))
        XCTAssertFalse(CallParticipant.isAgent(kindIsAgent: false, metadata: "not json"))
        XCTAssertEqual(CallParticipant(id: "x", name: nil, isAgent: false).name, "Joining")
        XCTAssertEqual(CallParticipant(id: "x", name: "  ", isAgent: false).name, "Joining")
    }

    func testActiveSpeakers() {
        let speaking = CallParticipant(id: "user:b", name: "Bo", isAgent: false, isSpeaking: true)
        let s = CallState.reduce(connectedAlone(), .participantsChanged([ada, speaking]))
        XCTAssertEqual(s.activeSpeakers.map(\.id), ["user:b"])
    }
}
