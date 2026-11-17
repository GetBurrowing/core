import AVFoundation
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

    // MARK: Local speaking (task 01a13c62 stage 1)

    func testLocalSpeakingIsReducedFromTheSessionEvent() {
        var s = run([.localParticipantChanged(identity: "user:me", isSpeaking: true)], from: connectedAlone())
        XCTAssertTrue(s.localSpeaking)
        XCTAssertEqual(s.localIdentity, "user:me")
        s = CallState.reduce(s, .localParticipantChanged(identity: "user:me", isSpeaking: false))
        XCTAssertFalse(s.localSpeaking)
    }

    /// The set stage 2 bridges to the page: remote speakers plus us.
    func testSpeakingIdentitiesIncludeTheLocalParticipant() {
        let bo = CallParticipant(id: "user:b", name: "Bo", isAgent: false, isSpeaking: true)
        var s = run([.participantsChanged([ada, bo]), .localParticipantChanged(identity: "user:me", isSpeaking: true)], from: connectedAlone())
        XCTAssertEqual(s.speakingIdentities, ["user:b", "user:me"])
        s = CallState.reduce(s, .localParticipantChanged(identity: "user:me", isSpeaking: false))
        XCTAssertEqual(s.speakingIdentities, ["user:b"])
    }

    func testNoLocalIdentityMeansNoLocalEntryInTheSpeakingSet() {
        let s = run([.localParticipantChanged(identity: nil, isSpeaking: true)], from: connectedAlone())
        XCTAssertEqual(s.speakingIdentities, [])
    }

    func testLocalSpeakingDoesNotChangeThePhase() {
        let s = run([.localParticipantChanged(identity: "user:me", isSpeaking: true)], from: connectedAlone())
        XCTAssertEqual(s.phase, .alone, "speaking alone is still alone")
    }

    func testEndingClearsLocalSpeaking() {
        let s = run([.localParticipantChanged(identity: "user:me", isSpeaking: true), .ended(.local)], from: connectedAlone())
        XCTAssertFalse(s.localSpeaking)
        XCTAssertEqual(s.speakingIdentities, [])
    }

    // MARK: Confirmed mic (task 01a13c62 stage 2)

    func testMicConfirmedSetsTheConfirmedState() {
        var s = run([.micConfirmed(true)], from: connectedAlone())
        XCTAssertTrue(s.micEnabled)
        s = CallState.reduce(s, .micConfirmed(false))
        XCTAssertFalse(s.micEnabled)
    }

    func testAMuteRequestAloneDoesNotChangeTheConfirmedState() {
        let s = run([.micConfirmed(true), .setMuted(true)], from: connectedAlone())
        XCTAssertTrue(s.isMuted, "the native screen keeps its request-time value")
        XCTAssertTrue(s.micEnabled, "nothing confirmed the mute yet")
    }

    func testAFailedSDKCallLeavesMicEnabledUnchanged() {
        let s = run([.micConfirmed(true), .setMuted(true), .micFailed], from: connectedAlone())
        XCTAssertTrue(s.micEnabled)
    }

    func testACallKitMuteConfirmedByTheSDKTurnsTheMicOff() {
        // CXSetMutedCallAction reduces `.setMuted`, then the session reads
        // the publication back and emits `.micConfirmed`.
        let s = run([.micConfirmed(true), .setMuted(true), .micConfirmed(false)], from: connectedAlone())
        XCTAssertTrue(s.isMuted)
        XCTAssertFalse(s.micEnabled)
    }

    /// Task 01a13ca2 stage 4: companion connections (`video:user:`) are not
    /// people. A room of only companions is alone.
    func testCompanionsNeverCountAsParticipants() {
        let bo = CallParticipant(id: "user:b", name: "Bo", isAgent: false)
        let bosCompanion = CallParticipant(id: "video:user:b", name: "Bo", isAgent: false, isSpeaking: true)
        let mine = CallParticipant(id: "video:user:me", name: "Me", isAgent: false)
        var s = run([.participantsChanged([bo, bosCompanion, mine])], from: connectedAlone())
        XCTAssertEqual(s.participants.map(\.id), ["user:b"])
        XCTAssertEqual(s.phase, .connected)
        XCTAssertEqual(s.activeSpeakers, [], "a speaking companion is not a speaker")
        s = CallState.reduce(s, .participantsChanged([mine]))
        XCTAssertEqual(s.participants, [])
        XCTAssertEqual(s.phase, .alone)
    }

    func testEndingClearsTheConfirmedMic() {
        let s = run([.micConfirmed(true), .ended(.local)], from: connectedAlone())
        XCTAssertFalse(s.micEnabled)
    }

    // MARK: Speaker

    func testSpeakerChangedSetsSpeakerOnWithoutTouchingMute() {
        var s = run([.setMuted(true), .speakerChanged(true)], from: connectedAlone())
        XCTAssertTrue(s.speakerOn)
        XCTAssertTrue(s.isMuted)
        s = run([.speakerChanged(false)], from: s)
        XCTAssertFalse(s.speakerOn)
    }
}

/// The speakerphone decision (2026-11-17 report: "the speaker can't be
/// turned on; audio stays on the earpiece").
final class CallAudioRouteTests: XCTestCase {
    func testTheCallCategoryDefaultsToTheSpeaker() {
        XCTAssertTrue(CallController.categoryOptions(speaker: true).contains(.defaultToSpeaker))
        XCTAssertTrue(CallController.categoryOptions(speaker: true).contains(.allowBluetoothA2DP))
        XCTAssertFalse(CallController.categoryOptions(speaker: false).contains(.defaultToSpeaker))
    }

    func testPortsMapToReceiverSpeakerOrExternal() {
        XCTAssertEqual(CallController.output(.builtInReceiver), .receiver)
        XCTAssertEqual(CallController.output(.builtInSpeaker), .speaker)
        for port: AVAudioSession.Port in [.headphones, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .carAudio, .airPlay, .usbAudio] {
            XCTAssertEqual(CallController.output(port), .external, port.rawValue)
        }
    }

    func testTheSpeakerOverridesTheEarpieceButNeverAHeadset() {
        XCTAssertTrue(CallAudioRoute.overridesToSpeaker(preferSpeaker: true, outputs: [.receiver]))
        XCTAssertFalse(CallAudioRoute.overridesToSpeaker(preferSpeaker: true, outputs: [.external]))
        XCTAssertFalse(CallAudioRoute.overridesToSpeaker(preferSpeaker: false, outputs: [.receiver]))
    }

    func testARouteChangeTheAppDidNotAskForIsUndone() {
        // The web view's media (or anything else) reset the category and the
        // audio fell back to the earpiece while the speaker is preferred.
        XCTAssertEqual(CallAudioRoute.onRouteChange(reason: .other, preferSpeaker: true, outputs: [.receiver]), .reassert)
        XCTAssertEqual(CallAudioRoute.onRouteChange(reason: .other, preferSpeaker: false, outputs: [.speaker]), .reassert)
        XCTAssertEqual(CallAudioRoute.onRouteChange(reason: .other, preferSpeaker: true, outputs: [.speaker]), .none)
    }

    func testPickingAnOutputInTheRoutePickerBecomesThePreference() {
        XCTAssertEqual(CallAudioRoute.onRouteChange(reason: .override, preferSpeaker: true, outputs: [.receiver]), .adopt(speaker: false))
        XCTAssertEqual(CallAudioRoute.onRouteChange(reason: .override, preferSpeaker: false, outputs: [.speaker]), .adopt(speaker: true))
        XCTAssertEqual(CallAudioRoute.onRouteChange(reason: .override, preferSpeaker: true, outputs: [.speaker]), .none)
    }

    func testAHeadsetIsLeftAlone() {
        XCTAssertEqual(CallAudioRoute.onRouteChange(reason: .other, preferSpeaker: true, outputs: [.external]), .none)
        XCTAssertEqual(CallAudioRoute.onRouteChange(reason: .override, preferSpeaker: true, outputs: [.external]), .none)
    }
}
