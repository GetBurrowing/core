import Foundation

/// `POST /api/app/meetings/:id/join` (task 01a10db7 stage 1).
///
/// Carries the LiveKit token: a bearer credential for the room. Its
/// descriptions redact it, so an accidental `print(join)` or string
/// interpolation cannot leak it; never log it.
struct MeetingJoin: Decodable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Meeting: Decodable, Equatable {
        let id: String
        let slug: String
        let name: String
        let spaceID: String
        let status: String

        private enum CodingKeys: String, CodingKey {
            case id, slug, name, status
            case spaceID = "space_id"
        }
    }

    let token: String
    let url: String?
    let roomName: String
    let identity: String
    let meeting: Meeting

    private enum CodingKeys: String, CodingKey {
        case token, url, identity, meeting
        case roomName = "room_name"
    }

    var description: String { "MeetingJoin(room: \(roomName), meeting: \(meeting.id), token: <redacted>)" }
    var debugDescription: String { description }
}

/// The native meeting routes, on `BurrowAPIClient`'s per-host bearer.
struct MeetingAPI {
    enum Failure: Error, Equatable {
        /// 404: no such meeting, or not one this person may join.
        case notFound
        /// 409 `meeting_over`.
        case meetingOver
        /// 409 `not_ringing`: the ring was answered, declined, missed or is over.
        case notRinging
        /// 503: the install has no LiveKit configured.
        case unavailable
        case other(status: Int)
    }

    var client: BurrowAPIClient = .shared

    func join(host: String, meetingID: String) async throws -> MeetingJoin {
        let path = "/api/app/meetings/\(BurrowAPIClient.segment(meetingID))/join"
        let response = try await client.send(host: host, path: path, method: "POST", json: [:])
        guard response.isSuccess else { throw Self.failure(response) }
        do {
            return try JSONDecoder().decode(MeetingJoin.self, from: response.data)
        } catch {
            throw BurrowAPIClient.Failure.badResponse
        }
    }

    func leave(host: String, meetingID: String) async throws {
        let path = "/api/app/meetings/\(BurrowAPIClient.segment(meetingID))/leave"
        let response = try await client.send(host: host, path: path, method: "POST", json: [:])
        guard response.isSuccess else { throw Self.failure(response) }
    }

    // MARK: Rings (task 01a10db7 stages 2 and 5)

    /// `GET /api/app/rings/:id`.
    func ring(host: String, ringID: String) async throws -> RingStatus {
        let response = try await client.send(host: host, path: Self.ringPath(ringID), method: "GET", json: nil)
        guard response.isSuccess else { throw Self.failure(response) }
        do {
            return try JSONDecoder().decode(RingStatus.self, from: response.data)
        } catch {
            throw BurrowAPIClient.Failure.badResponse
        }
    }

    /// `POST /api/app/rings/:id/<answer|decline|missed>`. A ring that is no
    /// longer ringing answers 409 `not_ringing`.
    func transition(host: String, ringID: String, to action: RingAction) async throws {
        let path = Self.ringPath(ringID) + "/" + action.rawValue
        let response = try await client.send(host: host, path: path, method: "POST", json: [:])
        guard response.isSuccess else { throw Self.failure(response) }
    }

    static func ringPath(_ ringID: String) -> String { "/api/app/rings/\(BurrowAPIClient.segment(ringID))" }

    static func failure(_ response: BurrowAPIClient.Response) -> Failure {
        switch (response.status, response.errorCode) {
        case (404, _): return .notFound
        case (409, "meeting_over"): return .meetingOver
        case (409, "not_ringing"): return .notRinging
        case (503, _): return .unavailable
        default: return .other(status: response.status)
        }
    }
}

/// `GET /api/app/rings/:id`. `state` is the server's effective state:
/// `ringing`, `answered`, `declined`, `missed`, `cancelled`, or `over` (the
/// meeting is no longer live, or the ring outlived its window).
struct RingStatus: Decodable, Equatable {
    let id: String
    let state: String
    let meetingID: String
    let meetingStatus: String?
    let spaceID: String?

    private enum CodingKeys: String, CodingKey {
        case id, state
        case meetingID = "meeting_id"
        case meetingStatus = "meeting_status"
        case spaceID = "space_id"
    }

    /// Still worth ringing: the server says ringing and the meeting is live.
    var isRinging: Bool { state == "ringing" && (meetingStatus == nil || meetingStatus == "live") }
}

enum RingAction: String {
    case answer, decline, missed
}
