import Foundation

/// One ring's VoIP payload (server: `Platform.Meetings.Ringing`, stage 2):
/// ids and display strings only, never a token.
struct RingPayload: Equatable {
    let ringID: String
    let meetingID: String
    let spaceID: String?
    let trigger: String?
    let callerName: String
    let installHost: String

    /// The CallKit call's UUID: the ring id (UUIDv7) itself.
    var callUUID: UUID? { UUID(uuidString: ringID) }

    /// What CallKit shows when the payload cannot be read.
    static let fallbackCallerName = "Burrow"

    /// Nil when a required key is missing or the wrong shape.
    init?(_ payload: [AnyHashable: Any]) {
        guard let ringID = payload["ring_id"] as? String, UUID(uuidString: ringID) != nil,
            let meetingID = payload["meeting_id"] as? String, !meetingID.isEmpty,
            let rawHost = payload["install_host"] as? String, let host = InstallStore.normalizeHost(rawHost)
        else { return nil }
        self.ringID = ringID
        self.meetingID = meetingID
        self.spaceID = payload["space_id"] as? String
        self.trigger = payload["trigger"] as? String
        let name = (payload["caller_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.callerName = name.isEmpty ? Self.fallbackCallerName : name
        self.installHost = host
    }

    init(ringID: String, meetingID: String, spaceID: String?, trigger: String?, callerName: String, installHost: String) {
        self.ringID = ringID
        self.meetingID = meetingID
        self.spaceID = spaceID
        self.trigger = trigger
        self.callerName = callerName
        self.installHost = installHost
    }
}

/// What the person sees when a ring arrives during a call: the in-call
/// invite banner (canvas "Invites you to join").
struct RingInvite: Equatable, Identifiable {
    let ringID: String
    let meetingID: String
    let installHost: String
    /// "{Inviter} in {Meeting}", or "{Meeting} meeting".
    let title: String

    var id: String { ringID }
    /// The avatar letter: the caller's first letter.
    var initial: String { title.first.map { String($0).uppercased() } ?? "?" }

    init(ringID: String, meetingID: String, installHost: String, title: String) {
        self.ringID = ringID
        self.meetingID = meetingID
        self.installHost = installHost
        self.title = title
    }

    init(_ payload: RingPayload) {
        self.init(ringID: payload.ringID, meetingID: payload.meetingID, installHost: payload.installHost, title: payload.callerName)
    }

    /// From the `meeting_ring_waiting` alert push (category
    /// `SUITE_RING_WAITING` or `BURROW_RING_WAITING`): the title is the
    /// alert's title.
    init?(userInfo: [AnyHashable: Any]) {
        guard let ringID = userInfo["ring_id"] as? String, let meetingID = userInfo["meeting_id"] as? String,
            let rawHost = userInfo["install_host"] as? String, let host = InstallStore.normalizeHost(rawHost)
        else { return nil }
        let alert = (userInfo["aps"] as? [String: Any])?["alert"] as? [String: Any]
        let title = (alert?["title"] as? String) ?? RingPayload.fallbackCallerName
        self.init(ringID: ringID, meetingID: meetingID, installHost: host, title: title)
    }
}
