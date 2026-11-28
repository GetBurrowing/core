import Foundation

/// The native Voice turn's server half (task 01a21e75 stage 2), from the
/// app (task 01a21e75 stage 5): the last partner, sending a turn, and
/// long-polling its reply. Every request goes through
/// `authorizedRequest(host:path:)` for its OWN host. The turn text and the
/// reply are message text: they are never logged and never cached.

/// `GET /api/app/voice/partner`.
struct VoicePartner: Codable, Equatable {
    let agentID: String
    let name: String
    let lastUsedAt: String

    var lastUsed: Date? { InstallUnreadStore.parseDate(lastUsedAt) }

    enum CodingKeys: String, CodingKey {
        case agentID = "agent_id"
        case name
        case lastUsedAt = "last_used_at"
    }
}

/// The partner the mic talks to, with the install it lives on.
struct VoicePartnerChoice: Codable, Equatable {
    let host: String
    let agentID: String
    let name: String
    let lastUsedAt: Date?
}

/// `POST /api/app/voice/turns`.
struct VoiceTurnPosted: Codable, Equatable {
    let spaceID: String
    let pathSegment: String

    enum CodingKeys: String, CodingKey {
        case spaceID = "space_id"
        case pathSegment = "path_segment"
    }
}

/// `GET /api/app/voice/turns/:client_turn_id`.
struct VoiceReplyPoll: Codable, Equatable {
    /// `thinking`, `speaking` or `done`.
    let state: String
    let sentences: [String]
    let spoken: Int
    let final: Bool
}

extension BurrowAPIClient {
    func voicePartner(host: String) async throws -> VoicePartner? {
        struct Body: Decodable { let partner: VoicePartner? }
        return try await fetch(Body.self, host: host, path: "/api/app/voice/partner").partner
    }

    func sendVoiceTurn(host: String, agentID: String, text: String, clientTurnID: String) async throws -> VoiceTurnPosted {
        try await fetch(
            VoiceTurnPosted.self, host: host, path: "/api/app/voice/turns", method: "POST",
            json: ["agent_id": agentID, "text": text, "client_turn_id": clientTurnID])
    }

    func voiceReply(host: String, clientTurnID: String, spoken: Int, waitMs: Int) async throws -> VoiceReplyPoll {
        let id = clientTurnID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? clientTurnID
        return try await fetch(VoiceReplyPoll.self, host: host, path: "/api/app/voice/turns/\(id)?spoken=\(spoken)&wait_ms=\(waitMs)")
    }
}

/// The most recently used Voice partner across EVERY signed-in install
/// (newest `last_used_at` wins), each install asked with its own bearer
/// through `InstallFanout`, and cached in the App Group so the control and
/// the widget can name the partner without a fetch.
enum VoicePartnerResolver {
    static func newest(installs: [Install], client: BurrowAPIClient, cache: VoicePartnerCache = VoicePartnerCache()) async -> VoicePartnerChoice? {
        let results = await InstallFanout.fetch(installs: installs, client: client) { host -> VoicePartnerChoice? in
            guard let partner = try await client.voicePartner(host: host) else { return nil }
            return VoicePartnerChoice(host: host, agentID: partner.agentID, name: partner.name, lastUsedAt: partner.lastUsed)
        }
        let answered = results.compactMap { $0.result.value ?? nil }
        let anyAnswered = results.contains { if case .ok = $0.result { return true } else { return false } }
        guard anyAnswered else { return cache.partner }
        let newest = answered.max { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }
        cache.partner = newest
        return newest
    }
}

/// The last resolved partner, in the App Group. A name and ids, never text.
struct VoicePartnerCache {
    private static let key = "suite.voice.partner.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: InstallStore.appGroup)) {
        self.defaults = defaults ?? .standard
    }

    var partner: VoicePartnerChoice? {
        get { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(VoicePartnerChoice.self, from: $0) } }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }
}

/// The one-shot "open Voice already listening" flag (task 01a21e75 stage 5),
/// in the App Group: set by a Voice surface that has to open the app, read
/// and cleared by `BurrowVoicePlugin.capabilities`, so the Voice tab starts
/// a turn with no second tap. Expires, so a flag left by an open that never
/// reached the Voice tab does not start the mic hours later.
struct VoiceAutoStart {
    private static let key = "suite.voice.autostart.v1"
    static let validFor: TimeInterval = 60
    let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: InstallStore.appGroup)) {
        self.defaults = defaults ?? .standard
    }

    func arm(now: Date = Date()) { defaults.set(now.timeIntervalSince1970, forKey: Self.key) }

    /// True once per arm, within `validFor`.
    func take(now: Date = Date()) -> Bool {
        let at = defaults.double(forKey: Self.key)
        defaults.removeObject(forKey: Self.key)
        return at > 0 && now.timeIntervalSince1970 - at <= Self.validFor && now.timeIntervalSince1970 >= at
    }
}
