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
    /// The last local `isSpeaking` traced, so the trace logs changes only.
    private var tracedLocalSpeaking: Bool?
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
        MeetingTrace.append("connect ok remote=\(room.remoteParticipants.count)")
        for participant in room.remoteParticipants.values {
            subscribeAudio(of: participant)
        }
        do {
            try await room.localParticipant.setMicrophone(enabled: true)
        } catch {
            MeetingTrace.append("mic enable failed")
            throw error
        }
        traceMicPublication("after-connect")
        emit(.micConfirmed(room.localParticipant.isMicrophoneEnabled()))
        publishParticipants()
        #if DEBUG
            startStats()
        #endif
    }

    /// CallKit activated the audio session: let the engine run.
    func audioActivated() {
        do {
            try AudioManager.shared.setEngineAvailability(.default)
            MeetingTrace.append("engine availability=default")
        } catch {
            MeetingTrace.append("engine availability=default failed")
        }
        traceMicPublication("after-activate")
    }

    /// CallKit deactivated it (the call ended, or another call took over).
    func audioDeactivated() {
        do {
            try AudioManager.shared.setEngineAvailability(.none)
            MeetingTrace.append("engine availability=none")
        } catch {
            MeetingTrace.append("engine availability=none failed")
        }
    }

    /// Asks the SDK for `enabled`, then reads the CONFIRMED state back from
    /// our microphone publication. Emits `.micConfirmed` with it, or
    /// `.micFailed` when the SDK threw or the publication did not follow;
    /// returns the confirmed state, or nil on failure.
    @discardableResult
    func setMicrophone(enabled: Bool) async -> Bool? {
        expectingLocalMuteChange = true
        do {
            _ = try await room.localParticipant.setMicrophone(enabled: enabled)
        } catch {
            expectingLocalMuteChange = false
            MeetingTrace.append("mic set enabled=\(enabled) failed")
            emit(.micFailed)
            return nil
        }
        traceMicPublication("after-set enabled=\(enabled)")
        let confirmed = room.localParticipant.isMicrophoneEnabled()
        guard confirmed == enabled else {
            MeetingTrace.append("mic set enabled=\(enabled) not confirmed")
            emit(.micFailed)
            return nil
        }
        emit(.micConfirmed(confirmed))
        return confirmed
    }

    /// Whether our mic publication exists, and its mute flag. No identity.
    private func traceMicPublication(_ when: String) {
        if let publication = room.localParticipant.firstAudioPublication {
            MeetingTrace.append("mic publication=present muted=\(publication.isMuted) \(when)")
        } else {
            MeetingTrace.append("mic publication=absent \(when)")
        }
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
        MeetingTrace.append("remote joined remote=\(room.remoteParticipants.count)")
        publishParticipants()
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        MeetingTrace.append("remote left remote=\(room.remoteParticipants.count)")
        publishParticipants()
    }
    func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) { publishParticipants() }
    func room(_ room: Room, participant: Participant, didUpdateName name: String) { publishParticipants() }
    func room(_ room: Room, participant: Participant, didUpdateMetadata metadata: String?) { publishParticipants() }

    private func publishParticipants() {
        let local = room.localParticipant
        let localSpeaking = local.isSpeaking
        if tracedLocalSpeaking != localSpeaking {
            tracedLocalSpeaking = localSpeaking
            MeetingTrace.append("local speaking=\(localSpeaking) remote=\(room.remoteParticipants.count)")
        }
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
        emit(.localParticipantChanged(identity: local.identity?.stringValue, isSpeaking: localSpeaking))
    }

    // MARK: Mute

    func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        guard participant is LocalParticipant, trackPublication.source == .microphone else { return }
        MeetingTrace.append("mic publication muted=\(isMuted) expected=\(expectingLocalMuteChange)")
        // Every confirmed change, whatever caused it: our call, CallKit
        // (Control Centre, AirPods, the lock screen) or a host mute.
        emit(.micConfirmed(!isMuted))
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

/// Debug builds only (task 01a13c62 stage 1): what the native call did with
/// the mic and the audio session, appended to `Library/Caches/meeting-trace.log`
/// so a device run can be read afterwards over Wi-Fi, where console capture
/// does not work:
/// `xcrun devicectl device copy from --domain-type appDataContainer
/// --domain-identifier com.kobo-ai.burrow --source Library/Caches/meeting-trace.log`.
/// Constants, booleans and counts ONLY: never the token, the join response,
/// a name, an identity or a room name (`MeetingSourceScanTests` checks).
/// Release builds compile this to nothing.
enum MeetingTrace {
    #if DEBUG
        private static let lock = NSLock()
        private static let url: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("meeting-trace.log")
        private static let stamp: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
    #endif

    static func append(_ line: String) {
        #if DEBUG
            guard let url else { return }
            lock.lock()
            defer { lock.unlock() }
            guard let data = "\(stamp.string(from: Date())) \(line)\n".data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        #endif
    }
}
