import XCTest

@testable import App

final class MeetingAPITests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func api(_ tokens: [String: String]) -> MeetingAPI {
        MeetingAPI(client: BurrowAPIClient(session: StubURLProtocol.session(), tokens: MemoryTokenStore(tokens: tokens)))
    }

    private let joinJSON = Data(
        """
        {"token":"lk-jwt-sentinel","url":"wss://lk.example.com","room_name":"space-s1","identity":"user:u1",
         "meeting":{"id":"m1","slug":"design-review","name":"Design review","space_id":"s1","status":"live",
                    "started_at":"2026-10-06T14:00:00Z"}}
        """.utf8)

    func testJoinPostsWithTheHostsBearerAndDecodes() async throws {
        StubURLProtocol.respond = { _ in (200, self.joinJSON) }
        let join = try await api(["a.example.com": "bearer-a", "b.example.com": "bearer-b"])
            .join(host: "b.example.com", meetingID: "m1")

        XCTAssertEqual(join.token, "lk-jwt-sentinel")
        XCTAssertEqual(join.url, "wss://lk.example.com")
        XCTAssertEqual(join.roomName, "space-s1")
        XCTAssertEqual(join.identity, "user:u1")
        XCTAssertEqual(join.meeting, .init(id: "m1", slug: "design-review", name: "Design review", spaceID: "s1", status: "live"))

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://b.example.com/api/app/meetings/m1/join")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer bearer-b", "B's bearer, never A's")
    }

    func testTheJoinNeverDescribesItsToken() async throws {
        StubURLProtocol.respond = { _ in (200, self.joinJSON) }
        let join = try await api(["a.example.com": "t"]).join(host: "a.example.com", meetingID: "m1")
        XCTAssertFalse("\(join)".contains("lk-jwt-sentinel"))
        XCTAssertFalse(String(reflecting: join).contains("lk-jwt-sentinel"))
        XCTAssertTrue("\(join)".contains("space-s1"))
    }

    func testSignedOutMakesNoRequest() async {
        do {
            _ = try await api([:]).join(host: "a.example.com", meetingID: "m1")
            XCTFail("expected notSignedIn")
        } catch {
            XCTAssertEqual(error as? BurrowAPIClient.Failure, .notSignedIn)
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    func testRefusalsMapToFailures() async {
        let cases: [(Int, String, MeetingAPI.Failure)] = [
            (404, #"{"error":"not_found"}"#, .notFound),
            (409, #"{"error":"meeting_over"}"#, .meetingOver),
            (503, #"{"error":"meetings_unavailable"}"#, .unavailable),
            (422, #"{"error":"join_failed"}"#, .other(status: 422)),
        ]
        for (status, body, expected) in cases {
            StubURLProtocol.respond = { _ in (status, Data(body.utf8)) }
            do {
                _ = try await api(["a.example.com": "t"]).join(host: "a.example.com", meetingID: "m1")
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? MeetingAPI.Failure, expected)
            }
        }
    }

    func testLeavePostsToTheLeaveRoute() async throws {
        StubURLProtocol.respond = { _ in (204, Data()) }
        try await api(["a.example.com": "bearer-a"]).leave(host: "a.example.com", meetingID: "m 1")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://a.example.com/api/app/meetings/m%201/leave")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer bearer-a")
    }
}
