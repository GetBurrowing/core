import AVFoundation
import Foundation
import LiveKit
import UIKit
import os

/// One LiveKit room for one native call: connect with the join response,
/// publish the mic, subscribe to AUDIO only (no video track is ever
/// subscribed, so a phone call costs no video bandwidth).
///
/// Audio session: CallKit owns activation. The SDK's automatic
/// `AVAudioSession` management is off (`CallController` turns it off once),
/// and the audio engine is unavailable until CallKit calls
/// `provider(_:didActivate:)`, which calls `audioActivated()`.
///
/// Reports what happens as `CallEvent`s through `onEvent`, on the main queue.
/// Logs room name, participant counts and byte counters only: never the
/// token or the join response.
final class MeetingSession: NSObject, RoomDelegate, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.kobo-ai.burrow", category: "meetings")

    let room = Room()
    /// Remote track statistics feed the DEBUG inbound-byte counter only.
    #if DEBUG
        private static let reportsStatistics = true
    #else
        private static let reportsStatistics = false
    #endif
    private let join: MeetingJoin
    private let onEvent: (CallEvent) -> Void
    /// Set when WE muted or unmuted, so the next mute update on our own
    /// mic track is not mistaken for a host mute.
    private var expectingLocalMuteChange = false
    private var leaving = false
    #if DEBUG
        private var statsTimer: Timer?
    #endif

    init(join: MeetingJoin, onEvent: @escaping (CallEvent) -> Void) {
        self.join = join
        self.onEvent = onEvent
        super.init()
        room.add(delegate: self)
    }

    /// Connects and publishes the mic. The engine stays off until CallKit
    /// activates the audio session.
    func connect(defaultURL: String?) async throws {
        guard let url = join.url ?? defaultURL else { throw LiveKitError(.failedToParseUrl) }
        try AudioManager.shared.setEngineAvailability(.none)
        try await room.connect(
            url: url, token: join.token,
            connectOptions: ConnectOptions(autoSubscribe: false),
            roomOptions: RoomOptions(adaptiveStream: false, dynacast: false, reportRemoteTrackStatistics: Self.reportsStatistics))
        Self.log.info("meeting connected room=\(self.join.roomName, privacy: .public) remote=\(self.room.remoteParticipants.count)")
        for participant in room.remoteParticipants.values {
            subscribeAudio(of: participant)
        }
        try await room.localParticipant.setMicrophone(enabled: true)
        publishParticipants()
        #if DEBUG
            startStats()
        #endif
    }

    /// CallKit activated the audio session: let the engine run.
    func audioActivated() {
        try? AudioManager.shared.setEngineAvailability(.default)
    }

    /// CallKit deactivated it (the call ended, or another call took over).
    func audioDeactivated() {
        try? AudioManager.shared.setEngineAvailability(.none)
    }

    func setMicrophone(enabled: Bool) async {
        expectingLocalMuteChange = true
        _ = try? await room.localParticipant.setMicrophone(enabled: enabled)
    }

    func disconnect() async {
        leaving = true
        #if DEBUG
            await MainActor.run { statsTimer?.invalidate() }
        #endif
        await room.disconnect()
    }

    // MARK: Audio only

    private func subscribeAudio(of participant: RemoteParticipant) {
        for publication in participant.trackPublications.values {
            guard let remote = publication as? RemoteTrackPublication, remote.kind == .audio else { continue }
            Task { try? await remote.set(subscribed: true) }
        }
    }

    func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        guard publication.kind == .audio else { return }
        Task { try? await publication.set(subscribed: true) }
    }

    // MARK: Connection

    func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        switch connectionState {
        case .reconnecting: emit(.reconnecting(at: Date()))
        case .connected where oldConnectionState == .reconnecting: emit(.connected)
        default: break
        }
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        guard !leaving else { return }
        Self.log.info("meeting disconnected room=\(self.join.roomName, privacy: .public)")
        // The room ended, we were removed, or the connection is gone for good:
        // all of them end the call from the far side. Removal is its own
        // ending: the ended screen offers no rejoin.
        emit(.ended(error?.type == .participantRemoved ? .removed : .remoteEnded))
    }

    func room(_ room: Room, participant: Participant, didUpdateConnectionQuality quality: ConnectionQuality) {
        guard participant is LocalParticipant else { return }
        emit(.connectionQuality(poor: quality == .poor || quality == .lost))
    }

    // MARK: People

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        subscribeAudio(of: participant)
        publishParticipants()
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) { publishParticipants() }
    func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) { publishParticipants() }
    func room(_ room: Room, participant: Participant, didUpdateName name: String) { publishParticipants() }
    func room(_ room: Room, participant: Participant, didUpdateMetadata metadata: String?) { publishParticipants() }

    private func publishParticipants() {
        let people = room.remoteParticipants.values
            .map { p in
                CallParticipant(
                    id: p.identity?.stringValue ?? UUID().uuidString,
                    name: p.name,
                    isAgent: CallParticipant.isAgent(kindIsAgent: p.kind == .agent, metadata: p.metadata),
                    isSpeaking: p.isSpeaking)
            }
            .sorted { $0.id < $1.id }
        emit(.participantsChanged(people))
    }

    // MARK: Mute

    func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        guard participant is LocalParticipant, trackPublication.source == .microphone else { return }
        if expectingLocalMuteChange {
            expectingLocalMuteChange = false
            return
        }
        // Nobody here asked: the host or the SFU muted our track.
        emit(.hostMuted(isMuted))
    }

    private func emit(_ event: CallEvent) {
        DispatchQueue.main.async { self.onEvent(event) }
    }

    // MARK: DEBUG counters (byte counts and participant counts only)

    #if DEBUG
        /// Total inbound RTP bytes across every subscribed remote audio track.
        var inboundAudioBytes: UInt64 {
            room.remoteParticipants.values
                .flatMap { $0.audioTracks }
                .compactMap { $0.track?.statistics?.inboundRtpStream }
                .flatMap { $0 }
                .compactMap(\.bytesReceived)
                .reduce(0, +)
        }

        private func startStats() {
            DispatchQueue.main.async {
                self.statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    let state = UIApplication.shared.applicationState == .active ? "active" : "background"
                    Self.log.info(
                        "meeting-stats room=\(self.join.roomName, privacy: .public) remote=\(self.room.remoteParticipants.count) inbound_bytes=\(self.inboundAudioBytes) app=\(state, privacy: .public)"
                    )
                }
            }
        }
    #endif
}
